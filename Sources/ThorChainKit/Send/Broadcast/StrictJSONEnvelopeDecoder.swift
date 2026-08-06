import Foundation

enum StrictJSONSchema: Sendable { case broadcast, lookupFound, lookupNotFound }

struct BroadcastResponse: Sendable, Equatable {
    let txHash: String
    let code: UInt32
    let codespace: String?
    let sanitizedLog: String?
}

enum StrictJSONEnvelopeError: Error, Equatable, Sendable {
    case oversized
    case invalidUTF8
    case byteOrderMark
    case invalidJSON
    case duplicateKey
    case invalidEnvelope
}

struct StrictJSONEnvelopeDecoder: Sendable {
    let maximumBodyBytes: Int

    init(maximumBodyBytes: Int = 64 * 1024) {
        self.maximumBodyBytes = maximumBodyBytes
    }

    func decodeBroadcastResponse(_ data: Data) throws -> BroadcastResponse {
        try decode(data, schema: .broadcast)
    }

    func decode(_ data: Data, schema: StrictJSONSchema = .broadcast) throws -> BroadcastResponse {
        try Self.validateJSONDocument(data, maximumBodyBytes: maximumBodyBytes)
        var scanner = DuplicateKeyScanner(data: data)
        do { try scanner.scanDocument() } catch { throw StrictJSONEnvelopeError.duplicateKey }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw StrictJSONEnvelopeError.invalidJSON
        }
        switch schema {
        case .broadcast:
            return try decodeBroadcast(object)
        case .lookupFound:
            return try decodeBroadcast(object)
        case .lookupNotFound:
            throw StrictJSONEnvelopeError.invalidEnvelope
        }
    }

    static func validateJSONDocument(_ data: Data, maximumBodyBytes: Int = 64 * 1024) throws {
        guard data.count <= maximumBodyBytes else { throw StrictJSONEnvelopeError.oversized }
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else { throw StrictJSONEnvelopeError.byteOrderMark }
        guard String(data: data, encoding: .utf8) != nil else { throw StrictJSONEnvelopeError.invalidUTF8 }
        guard try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) is [String: Any] else {
            throw StrictJSONEnvelopeError.invalidJSON
        }
        var scanner = DuplicateKeyScanner(data: data)
        try scanner.scanDocument()
    }

    private func decodeBroadcast(_ object: [String: Any]) throws -> BroadcastResponse {
        guard let response = object["tx_response"] as? [String: Any],
              let hash = response["txhash"] as? String,
              let hashBytes = Self.hashBytes(hash), hashBytes.count == 32,
              let number = response["code"] as? NSNumber,
              String(cString: number.objCType) != "c", String(cString: number.objCType) != "B", String(cString: number.objCType) != "d", String(cString: number.objCType) != "f",
              let integer = Int64(exactly: number), integer >= 0,
              let code = UInt32(exactly: integer) else {
            throw StrictJSONEnvelopeError.invalidEnvelope
        }
        let codespace = try response["codespace"].map(Self.validatedASCII)
        let diagnostic: String?
        if let rawLog = response["raw_log"] {
            guard let rawLog = rawLog as? String else { throw StrictJSONEnvelopeError.invalidEnvelope }
            diagnostic = Self.sanitizedLog(rawLog)
        } else {
            diagnostic = nil
        }
        return BroadcastResponse(txHash: hash.uppercased(), code: code, codespace: codespace, sanitizedLog: diagnostic)
    }

    // The node's raw_log is untrusted, but it carries the only actionable diagnostic of
    // a CheckTx rejection ("account sequence mismatch, expected 7, got 6"). Keep the
    // printable-ASCII subset, capped, instead of discarding it. Non-printables become
    // spaces rather than vanishing so adjacent tokens do not glue together.
    static func sanitizedLog(_ raw: String, maximumLength: Int = 256) -> String? {
        let mapped = raw.unicodeScalars.map { $0.value >= 0x20 && $0.value <= 0x7E ? Character($0) : " " }
        let trimmed = String(mapped).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }

    private static func validatedASCII(_ value: Any) throws -> String {
        guard let value = value as? String, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            throw StrictJSONEnvelopeError.invalidEnvelope
        }
        return value
    }

    static func hashBytes(_ value: String) -> Data? {
        guard value.count == 64, value.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0) || ("A"..."F").contains($0)) }) else { return nil }
        var result = Data(capacity: 32)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

private struct DuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) { bytes = Array(data) }

    mutating func scanDocument() throws {
        try skipWhitespace()
        try scanValue()
        try skipWhitespace()
        guard index == bytes.count else { throw StrictJSONEnvelopeError.invalidJSON }
    }

    private mutating func scanValue() throws {
        try skipWhitespace()
        guard let byte = current else { throw StrictJSONEnvelopeError.invalidJSON }
        switch byte {
        case 0x7B: try scanObject()
        case 0x5B: try scanArray()
        case 0x22: _ = try scanString()
        default: try scanPrimitive()
        }
    }

    private mutating func scanObject() throws {
        index += 1
        var keys = Set<String>()
        try skipWhitespace()
        if current == 0x7D { index += 1; return }
        while true {
            try skipWhitespace()
            let key = try scanString()
            guard keys.insert(key).inserted else { throw StrictJSONEnvelopeError.duplicateKey }
            try skipWhitespace(); try consume(0x3A); try scanValue(); try skipWhitespace()
            if current == 0x7D { index += 1; return }
            try consume(0x2C)
        }
    }

    private mutating func scanArray() throws {
        index += 1
        try skipWhitespace()
        if current == 0x5D { index += 1; return }
        while true {
            try scanValue(); try skipWhitespace()
            if current == 0x5D { index += 1; return }
            try consume(0x2C)
        }
    }

    private mutating func scanString() throws -> String {
        let start = index
        try consume(0x22)
        while let byte = current {
            index += 1
            if byte == 0x22 {
                let data = Data(bytes[(start..<index)])
                guard let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else { throw StrictJSONEnvelopeError.invalidJSON }
                return value
            }
            if byte == 0x5C {
                guard current != nil else { throw StrictJSONEnvelopeError.invalidJSON }
                index += 1
            } else if byte < 0x20 {
                throw StrictJSONEnvelopeError.invalidJSON
            }
        }
        throw StrictJSONEnvelopeError.invalidJSON
    }

    private mutating func scanPrimitive() throws {
        let start = index
        while let byte = current, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(byte) { index += 1 }
        guard start < index else { throw StrictJSONEnvelopeError.invalidJSON }
    }

    private mutating func skipWhitespace() throws {
        while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard current == expected else { throw StrictJSONEnvelopeError.invalidJSON }
        index += 1
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }
}
