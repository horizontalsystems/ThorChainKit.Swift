import Foundation

struct LiveThorNodeClient: INodeApiProvider {
    private let transport: any IHttpTransport
    private let requestTimeout: TimeInterval
    private let clientId: String?
    private let maximumBalancePageCount: Int

    init(
        transport: any IHttpTransport = URLSessionTransport(),
        requestTimeout: TimeInterval = 15,
        clientId: String? = nil,
        maximumBalancePageCount: Int = 100
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.clientId = clientId
        self.maximumBalancePageCount = max(1, maximumBalancePageCount)
    }

    func account(address: Address, using lease: EndpointLease, timeout: TimeInterval? = nil) async throws -> AccountTransport? {
        let request = RequestBuilder(
            baseURL: lease.family.cosmosRestURL,
            requestTimeout: timeout ?? requestTimeout,
            clientId: clientId
        ).request(
            path: ["cosmos", "auth", "v1beta1", "accounts", address.raw],
            cosmosHeight: lease.cosmosReadHeight
        )
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 {
                try requireHeight(response, expected: lease.cosmosReadHeight)
                if isExactAbsence(data, address: address) {
                    return nil
                }
            }
            throw statusError(response, operation: .account)
        }
        try requireHeight(response, expected: lease.cosmosReadHeight)
        let envelope: AccountEnvelope
        do {
            envelope = try JSONDecoder().decode(AccountEnvelope.self, from: data)
        } catch {
            throw ThorNodeReadError.malformedResponse(operation: .account)
        }
        guard let account = envelope.account else {
            throw ThorNodeReadError.malformedResponse(operation: .account)
        }
        guard account.type == "/cosmos.auth.v1beta1.BaseAccount" else {
            throw ThorNodeReadError.unsupportedAccountType
        }
        guard Self.isCanonicalUInt64Decimal(account.accountNumber),
              Self.isCanonicalUInt64Decimal(account.sequence),
              let accountNumber = UInt64(account.accountNumber),
              let sequence = UInt64(account.sequence)
        else {
            throw ThorNodeReadError.invalidAccount
        }
        return AccountTransport(accountNumber: accountNumber, sequence: sequence)
    }

    func balances(address: Address, using lease: EndpointLease, timeout: TimeInterval? = nil) async throws -> [BalanceTransport] {
        var nextKey: String?
        var seenKeys = Set<String>()
        var values = [BalanceTransport]()
        var seenDenoms = Set<String>()

        for page in 1...maximumBalancePageCount {
            var query = [URLQueryItem(name: "pagination.limit", value: "100")]
            if let nextKey, !nextKey.isEmpty {
                query.append(URLQueryItem(name: "pagination.key", value: nextKey))
            }
            let request = RequestBuilder(
                baseURL: lease.family.cosmosRestURL,
                requestTimeout: timeout ?? requestTimeout,
                clientId: clientId
            ).request(
                path: ["cosmos", "bank", "v1beta1", "balances", address.raw],
                queryItems: query,
                cosmosHeight: lease.cosmosReadHeight
            )
            let (data, response) = try await send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw statusError(response, operation: .balances)
            }
            try requireHeight(response, expected: lease.cosmosReadHeight)
            let envelope: BalancesEnvelope
            do {
                envelope = try JSONDecoder().decode(BalancesEnvelope.self, from: data)
            } catch {
                throw ThorNodeReadError.malformedResponse(operation: .balances)
            }
            guard let coins = envelope.balances, let pagination = envelope.pagination else {
                throw ThorNodeReadError.malformedResponse(operation: .balances)
            }
            for coin in coins {
                let denom: Denom
                do {
                    denom = try Denom(rawValue: coin.denom)
                } catch {
                    throw ThorNodeReadError.invalidDenom(coin.denom)
                }
                guard Self.isCanonicalAmount(coin.amount) else {
                    throw ThorNodeReadError.invalidAmount
                }
                guard seenDenoms.insert(denom.rawValue).inserted else {
                    throw ThorNodeReadError.duplicateDenom(denom.rawValue)
                }
                values.append(BalanceTransport(denom: denom, amountDecimal: coin.amount))
            }
            guard let newKey = pagination.nextKey, !newKey.isEmpty else {
                return values.sorted { $0.denom.rawValue < $1.denom.rawValue }
            }
            guard seenKeys.insert(newKey).inserted else {
                throw ThorNodeReadError.paginationCycle
            }
            nextKey = newKey
            if page == maximumBalancePageCount {
                throw ThorNodeReadError.pageLimitExceeded
            }
        }
        throw ThorNodeReadError.pageLimitExceeded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            return try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw ThorNodeReadError.transport(kind: Self.transportKind(error.code))
        } catch {
            throw ThorNodeReadError.transport(kind: .other)
        }
    }

    private func requireHeight(_ response: HTTPURLResponse, expected: Int64) throws {
        let actual = response.value(forHTTPHeaderField: "Grpc-Metadata-X-Cosmos-Block-Height")
        guard actual.flatMap(Int64.init) == expected else {
            throw ThorNodeReadError.heightMismatch(expected: expected, actual: actual)
        }
    }

    private func statusError(_ response: HTTPURLResponse, operation: ThorNodeReadOperation) -> ThorNodeReadError {
        .httpStatus(
            operation: operation,
            code: response.statusCode,
            retryAfterSeconds: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        )
    }

    private func isExactAbsence(_ data: Data, address: Address) -> Bool {
        var scanner = JSONDuplicateKeyScanner(data: data)
        guard scanner.containsDuplicateKeys() == false else { return false }

        let envelope: AbsenceEnvelope
        do {
            envelope = try JSONDecoder().decode(AbsenceEnvelope.self, from: data)
        } catch {
            return false
        }
        return envelope.code == 5
            && envelope.details?.isEmpty == true
            && [
                "rpc error: code = NotFound desc = account \(address.raw) not found: key not found",
                "account \(address.raw) not found",
            ].contains(envelope.message)
    }

    private static func retryAfter(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Int(value),
              (0...60).contains(seconds)
        else { return nil }
        return seconds
    }

    private static func isCanonicalAmount(_ value: String) -> Bool {
        guard value == "0" || (value.first != "0" && !value.isEmpty),
              value.utf8.allSatisfy({ (48...57).contains($0) })
        else { return false }
        let maximum = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        return value.count < maximum.count || (value.count == maximum.count && value <= maximum)
    }

    private static func isCanonicalUInt64Decimal(_ value: String) -> Bool {
        guard value == "0" || (value.first != "0" && !value.isEmpty),
              value.utf8.allSatisfy({ (48...57).contains($0) })
        else { return false }
        return UInt64(value) != nil
    }

    private static func transportKind(_ code: URLError.Code) -> TransportFailureKind {
        switch code {
        case .cannotFindHost, .dnsLookupFailed: .dns
        case .cannotConnectToHost, .networkConnectionLost: .connection
        case .timedOut: .timeout
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected: .tls
        case .notConnectedToInternet: .offline
        default: .other
        }
    }
}

extension LiveThorNodeClient: ISendTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
}

private struct AccountEnvelope: Decodable {
    struct Account: Decodable {
        let type: String?
        let accountNumber: String
        let sequence: String

        enum CodingKeys: String, CodingKey {
            case type = "@type"
            case accountNumber = "account_number"
            case sequence
        }
    }
    let account: Account?
}

private struct BalancesEnvelope: Decodable {
    struct Coin: Decodable {
        let denom: String
        let amount: String
    }
    struct Pagination: Decodable {
        let nextKey: String?

        enum CodingKeys: String, CodingKey { case nextKey = "next_key" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.nextKey) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.nextKey,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "missing next_key")
                )
            }
            nextKey = try container.decodeIfPresent(String.self, forKey: .nextKey)
        }
    }
    let balances: [Coin]?
    let pagination: Pagination?
}

private struct AbsenceEnvelope: Decodable {
    let code: Int?
    let message: String?
    let details: [JSONValue]?
}

private indirect enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        do { self = .string(try container.decode(String.self)); return } catch { }
        do { self = .number(try container.decode(Double.self)); return } catch { }
        do { self = .bool(try container.decode(Bool.self)); return } catch { }
        do { self = .object(try container.decode([String: JSONValue].self)); return } catch { }
        self = .array(try container.decode([JSONValue].self))
    }
}

private struct JSONDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func containsDuplicateKeys() -> Bool {
        guard parseValue() == false else { return true }
        skipWhitespace()
        return index != bytes.count
    }

    private mutating func parseValue() -> Bool {
        skipWhitespace()
        guard let byte = peek else { return true }
        switch byte {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x22: return readString() == nil
        default: return parseLiteral()
        }
    }

    private mutating func parseObject() -> Bool {
        guard consume(0x7B) else { return true }
        skipWhitespace()
        if consume(0x7D) { return false }

        var keys = Set<String>()
        while true {
            skipWhitespace()
            guard let key = readString() else { return true }
            guard keys.insert(key).inserted else { return true }
            skipWhitespace()
            guard consume(0x3A), parseValue() == false else { return true }
            skipWhitespace()
            if consume(0x7D) { return false }
            guard consume(0x2C) else { return true }
        }
    }

    private mutating func parseArray() -> Bool {
        guard consume(0x5B) else { return true }
        skipWhitespace()
        if consume(0x5D) { return false }

        while true {
            guard parseValue() == false else { return true }
            skipWhitespace()
            if consume(0x5D) { return false }
            guard consume(0x2C) else { return true }
        }
    }

    private mutating func parseLiteral() -> Bool {
        let start = index
        while let byte = peek, !isDelimiter(byte) {
            index += 1
        }
        return index == start
    }

    private mutating func readString() -> String? {
        guard consume(0x22) else { return nil }
        let start = index
        var escaped = false
        while let byte = peek {
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                var token = Data([0x22])
                token.append(contentsOf: bytes[start..<(index - 1)])
                token.append(0x22)
                do {
                    return try JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String
                } catch {
                    return nil
                }
            } else if byte < 0x20 {
                return nil
            }
        }
        return nil
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20 {
            index += 1
        }
    }

    private func isDelimiter(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
            || byte == 0x2C || byte == 0x5D || byte == 0x7D
    }
}
