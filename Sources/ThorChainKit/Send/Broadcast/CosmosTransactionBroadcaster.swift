import Foundation

enum BroadcastTransportError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidResponse
    case transport
}

protocol ITransactionBroadcaster: Sendable {
    func broadcast(transaction: SignedTransaction) async throws -> BroadcastResponse
}

struct CosmosTransactionBroadcaster: ITransactionBroadcaster {
    let baseURL: URL
    let transport: any IHttpTransport

    init(baseURL: URL, transport: any IHttpTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func broadcast(transaction: SignedTransaction) async throws -> BroadcastResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), components.query == nil, components.fragment == nil else {
            throw BroadcastTransportError.invalidEndpoint
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = prefix.isEmpty ? "/cosmos/tx/v1beta1/txs" : "/\(prefix)/cosmos/tx/v1beta1/txs"
        guard let url = components.url else { throw BroadcastTransportError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let bytes = transaction.txRaw.base64EncodedString()
        request.httpBody = Data("{\"tx_bytes\":\"\(bytes)\",\"mode\":\"BROADCAST_MODE_SYNC\"}".utf8)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw BroadcastTransportError.transport
        }
        guard response.statusCode == 200,
              Self.isJSON(response.value(forHTTPHeaderField: "Content-Type"))
        else {
            throw BroadcastTransportError.invalidResponse
        }
        return try StrictJSONEnvelopeDecoder().decode(data, schema: .broadcast)
    }

    private static func isJSON(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.first == "application/json" else { return false }
        return parts.dropFirst().allSatisfy { !$0.hasPrefix("charset=") || $0 == "charset=utf-8" }
    }
}

enum RetryLookupResponse: Sendable, Equatable {
    case found(transactionID: TransactionID, height: Int64)
    case notFound
    case providerInconsistent
    case transportFailure
}

struct CosmosTransactionLookupClient: Sendable {
    let baseURL: URL
    let transport: any IHttpTransport
    let notFoundMessage: @Sendable (String) -> String

    init(
        baseURL: URL,
        transport: any IHttpTransport = URLSessionTransport(),
        notFoundMessage: @escaping @Sendable (String) -> String = { "rpc error: code = NotFound desc = tx not found: \($0): key not found" }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.notFoundMessage = notFoundMessage
    }

    func lookup(transactionID: TransactionID) async -> RetryLookupResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), components.query == nil, components.fragment == nil else { return .transportFailure }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = prefix.isEmpty ? "/cosmos/tx/v1beta1/txs/\(transactionID.hash)" : "/\(prefix)/cosmos/tx/v1beta1/txs/\(transactionID.hash)"
        guard let url = components.url else { return .transportFailure }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await transport.data(for: request)
            guard Self.isJSON(response.value(forHTTPHeaderField: "Content-Type")) else { return .transportFailure }
            switch response.statusCode {
            case 200: return Self.decodeFound(data: data, expected: transactionID)
            case 404: return Self.decodeNotFound(data: data, expected: transactionID, message: notFoundMessage(transactionID.hash))
            case 429, 500 ... 599: return .transportFailure
            default: return .providerInconsistent
            }
        } catch {
            return .transportFailure
        }
    }

    private static func decodeFound(data: Data, expected: TransactionID) -> RetryLookupResponse {
        guard data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1, let response = object["tx_response"] as? [String: Any],
              let hash = response["txhash"] as? String,
              let remote = StrictJSONEnvelopeDecoder.hashBytes(hash),
              remote == StrictJSONEnvelopeDecoder.hashBytes(expected.hash),
              let heightString = response["height"] as? String,
              let height = Int64(heightString), height > 0, heightString == String(height),
              (try? StrictJSONEnvelopeDecoder.validateJSONDocument(data)) != nil else { return .providerInconsistent }
        return .found(transactionID: expected, height: height)
    }

    private static func decodeNotFound(data: Data, expected _: TransactionID, message: String) -> RetryLookupResponse {
        guard (try? StrictJSONEnvelopeDecoder.validateJSONDocument(data, maximumBodyBytes: 4 * 1024)) != nil,
              data.count <= 4 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["code", "message", "details"]),
              let code = object["code"] as? Int, code == 5,
              let actualMessage = object["message"] as? String, actualMessage == message,
              let details = object["details"] as? [Any], details.isEmpty else { return .providerInconsistent }
        return .notFound
    }

    private static func isJSON(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.first == "application/json" else { return false }
        return parts.dropFirst().allSatisfy { !$0.hasPrefix("charset=") || $0 == "charset=utf-8" }
    }
}
