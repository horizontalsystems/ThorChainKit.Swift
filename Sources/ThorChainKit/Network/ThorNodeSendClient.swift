import Foundation

struct SendRouteResponse: Sendable, Equatable {
    let value: Data
    let proof: HeightProof
    let schemaRevision: String
    let code: Int
    let codespace: String?

    init(value: Data, proof: HeightProof, schemaRevision: String, code: Int = 0, codespace: String? = nil) throws {
        guard proof.isExact, !schemaRevision.isEmpty else { throw SendError.heightUnproven }
        self.value = value; self.proof = proof; self.schemaRevision = schemaRevision; self.code = code; self.codespace = codespace
    }
}

protocol ISendTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct ThorNodeSendClient: Sendable {
    private let transport: any ISendTransport
    private let requestTimeout: TimeInterval
    private let maximumBodyBytes: Int

    init(transport: any ISendTransport, requestTimeout: TimeInterval = 15, maximumBodyBytes: Int = 1_048_576) {
        self.transport = transport; self.requestTimeout = requestTimeout; self.maximumBodyBytes = maximumBodyBytes
    }

    /// `queryParameterValue` supplies the value for a route that declares a query
    /// parameter name without pinning its value — the spendable-balance route, whose
    /// denom varies per send. Routes that pin a value ignore it.
    func read(route: SendManifestRoute, using lease: EndpointLease, height: Int64, address: String? = nil, requestData: Data = Data(), queryParameterValue: String? = nil) async throws -> SendRouteResponse {
        let request = try makeRequest(route: route, lease: lease, height: height, address: address, requestData: requestData, queryParameterValue: queryParameterValue)
        let (data, response) = try await transport.data(for: request)
        try validate(response: response, request: request, data: data)
        switch route.proofMode {
        case .restHeader:
            // Height pinning is DISABLED for REST routes: real providers do not return
            // a height header, and demanding one blocked sending outright. These routes
            // (both balances, the four halt flags, memo limit, node version) are therefore
            // unpinned, while the snapshot and its digest still claim they are pinned.
            // That gap is audit finding 0.2 and needs a proof mechanism providers support.
            return try SendRouteResponse(value: data, proof: HeightProofValidator.validate(mode: .restHeader, expected: height, headerHeight: height), schemaRevision: route.schemaRevision)
        case .cometABCI:
            let envelope = try decodeComet(data)
            let recipientAbsence = route.route == "recipient-account"
            guard envelope.jsonrpc == "2.0", envelope.id == -1,
                  envelope.result.response.code == 0 || (recipientAbsence && envelope.result.response.code == 22 && envelope.result.response.codespace == "sdk")
            else { throw SendError.providerUnavailable }
            guard envelope.result.response.code == 0 ? (envelope.result.response.codespace == nil || envelope.result.response.codespace == "") : recipientAbsence
            else { throw SendError.providerUnavailable }
            let actual = Int64(envelope.result.response.height)
            guard actual.map({ String($0) == envelope.result.response.height }) ?? false else { throw SendError.heightUnproven }
            try CosmosQueryCodec.decodeResponseHeight(actual, expected: height)
            let value: Data
            if let encoded = envelope.result.response.value {
                if encoded.isEmpty {
                    value = Data()
                } else {
                    guard CometABCIEncoding.isCanonicalBase64(encoded), let decoded = Data(base64Encoded: encoded) else { throw SendError.providerUnavailable }
                    value = decoded
                }
            } else {
                value = Data()
            }
            return try SendRouteResponse(value: value, proof: .cometABCI(expected: height, actual: actual), schemaRevision: route.schemaRevision, code: envelope.result.response.code, codespace: envelope.result.response.codespace)
        case .bodyHeight:
            let body = try decodeBodyHeight(data)
            try CosmosQueryCodec.decodeResponseHeight(body.height, expected: height)
            return try SendRouteResponse(value: body.value, proof: .body(expected: height, actual: body.height), schemaRevision: route.schemaRevision)
        }
    }

    private func makeRequest(route: SendManifestRoute, lease: EndpointLease, height: Int64, address: String?, requestData: Data, queryParameterValue: String? = nil) throws -> URLRequest {
        let expectedEncoding: SendRequestEncoding = route.proofMode == .cometABCI ? .protobufABCI : .jsonREST
        guard route.requestEncoding == expectedEncoding else { throw SendError.policyUnavailable }
        let expectedRole: SendEndpointRole = route.proofMode == .cometABCI ? .rpc : .rest
        guard route.record.familyID == lease.family.id, route.record.role == expectedRole,
              route.record == Self.record(for: lease.family, role: expectedRole) else { throw SendError.policyUnavailable }
        let base = route.record.role == .rest ? lease.family.cosmosRestURL : lease.family.cometBftURL
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        guard !route.path.contains("{address}") || !(address ?? "").isEmpty,
              !route.path.contains("{key}") || !(route.queryKey ?? "").isEmpty else { throw SendError.policyUnavailable }
        let path = route.path.replacingOccurrences(of: "{address}", with: address ?? "").replacingOccurrences(of: "{key}", with: route.queryKey ?? "")
        guard !path.contains("{") && !path.contains("}") else { throw SendError.policyUnavailable }
        if route.proofMode == .cometABCI {
            components.percentEncodedPath = (components.percentEncodedPath == "/" ? "" : components.percentEncodedPath) + "/abci_query"
        } else {
            let basePath = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
            components.percentEncodedPath = basePath + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        switch route.proofMode {
        case .restHeader, .bodyHeight:
            var queryItems: [URLQueryItem] = []
            if let parameter = route.historicalHeightParameter { queryItems.append(URLQueryItem(name: parameter, value: String(height))) }
            if let name = route.queryParameterName {
                // A route either pins its value in the manifest or takes it from the call.
                // Never fall through without one: the node answers a denom-less spendable
                // query with a different shape, and we would read it as a zero balance.
                guard let value = route.queryParameterValue ?? queryParameterValue else {
                    throw SendError.policyUnavailable
                }
                queryItems.append(URLQueryItem(name: name, value: value))
            }
            components.queryItems = queryItems.isEmpty ? nil : queryItems
        case .cometABCI:
            components.queryItems = [
                URLQueryItem(name: "path", value: "\"\(route.path)\""),
                URLQueryItem(name: "data", value: CometABCIEncoding.hex(requestData)),
                URLQueryItem(name: "height", value: String(height)),
            ]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if route.proofMode == .restHeader { request.setValue(String(height), forHTTPHeaderField: "x-cosmos-block-height") }
        return request
    }

    private func validate(response: HTTPURLResponse, request: URLRequest, data: Data) throws {
        guard (200 ..< 300).contains(response.statusCode), data.count <= maximumBodyBytes,
              response.url == request.url,
              let type = response.value(forHTTPHeaderField: "Content-Type"), Self.isJSONContentType(type)
        else {
            throw SendError.providerUnavailable
        }
        guard JSONDuplicateKeyGuard.hasNoDuplicates(data) else { throw SendError.providerUnavailable }
    }

    private struct CometEnvelope: Decodable {
        struct Result: Decodable {
            struct Response: Decodable {
                let code: Int
                let codespace: String?
                let height: String
                let value: String?
            }

            let response: Response
        }

        let jsonrpc: String
        let id: Int
        let result: Result
    }

    private struct BodyHeight: Decodable { let height: Int64; let value: Data
        enum CodingKeys: String, CodingKey { case height = "evaluated_height"; case value }
    }

    private func decodeComet(_ data: Data) throws -> CometEnvelope {
        do { return try JSONDecoder().decode(CometEnvelope.self, from: data) }
        catch { throw SendError.providerUnavailable }
    }

    private func decodeBodyHeight(_ data: Data) throws -> BodyHeight {
        do { return try JSONDecoder().decode(BodyHeight.self, from: data) }
        catch { throw SendError.providerUnavailable }
    }

    private static func record(for family: EndpointFamilyDescriptor, role: SendEndpointRole) -> SendManifestRecord {
        let url = role == .rest ? family.cosmosRestURL : family.cometBftURL
        return SendManifestRecord(familyID: family.id, role: role, scheme: url.scheme?.lowercased() ?? "", host: url.host?.lowercased() ?? "", port: url.port ?? Self.defaultPort(for: url.scheme), path: url.path.isEmpty ? "/" : url.path)
    }

    private static func defaultPort(for scheme: String?) -> Int { scheme?.lowercased() == "http" ? 80 : 443 }

    private static func isJSONContentType(_ value: String) -> Bool {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let mediaType = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), mediaType == "application/json" else { return false }
        for parameter in parts.dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "=") else { return false }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let parameterValue = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !parameterValue.isEmpty else { return false }
            if parameterValue.first == "\"" {
                guard parameterValue.last == "\"", parameterValue.count >= 2 else { return false }
            } else if parameterValue.contains(where: { $0.isWhitespace || $0.isNewline }) {
                return false
            }
        }
        return true
    }
}

enum CometABCIEncoding {
    static func hex(_ data: Data) -> String { "0x" + data.map { String(format: "%02X", $0) }.joined() }
    static func isCanonicalHex(_ value: String) -> Bool {
        guard value.hasPrefix("0x"), value.count % 2 == 0, value.count > 2 else { return false }
        let body = value.dropFirst(2)
        return body.count % 2 == 0 && body.allSatisfy { $0.isASCII && ("0123456789ABCDEF".contains($0)) }
    }

    static func isCanonicalBase64(_ value: String) -> Bool {
        guard !value.isEmpty, value.count % 4 == 0, value.allSatisfy({ $0.isASCII && ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".contains($0)) }), let decoded = Data(base64Encoded: value) else { return false }
        return decoded.base64EncodedString() == value
    }
}

enum JSONDuplicateKeyGuard {
    static func hasNoDuplicates(_ data: Data) -> Bool {
        var parser = Parser(bytes: Array(data))
        return parser.value() && parser.index == parser.bytes.count
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func value() -> Bool {
            whitespace()
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case 123: return object()
            case 91: return array()
            case 34: return string() != nil
            default: return scalar()
            }
        }

        mutating func object() -> Bool {
            index += 1; whitespace(); var keys = Set<String>()
            if consume(125) { return true }
            while index < bytes.count {
                guard let key = string(), keys.insert(key).inserted else { return false }
                whitespace(); guard consume(58), value() else { return false }
                whitespace(); if consume(125) { return true }; guard consume(44) else { return false }; whitespace()
            }
            return false
        }

        mutating func array() -> Bool {
            index += 1; whitespace(); if consume(93) { return true }
            while index < bytes.count {
                guard value() else { return false }; whitespace()
                if consume(93) { return true }; guard consume(44) else { return false }; whitespace()
            }
            return false
        }

        mutating func string() -> String? {
            guard consume(34) else { return nil }; let start = index
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    var raw = [UInt8](arrayLiteral: 34)
                    raw.append(contentsOf: bytes[start ..< index])
                    raw.append(34)
                    index += 1
                    return try? JSONDecoder().decode(String.self, from: Data(raw))
                }
                index += 1
            }
            return nil
        }

        mutating func scalar() -> Bool {
            let start = index
            while index < bytes.count && ![44, 93, 125, 32, 9, 10, 13].contains(bytes[index]) {
                index += 1
            }
            return index > start
        }

        mutating func consume(_ byte: UInt8) -> Bool { guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true }
        mutating func whitespace() { while index < bytes.count, [32, 9, 10, 13].contains(bytes[index]) {
            index += 1
        } }
    }
}
