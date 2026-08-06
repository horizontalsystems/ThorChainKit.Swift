import Foundation

struct SendAccountInfo: Sendable, Equatable {
    let accountNumber: UInt64
    let sequence: UInt64
}

// Reads the account at the node's latest state, unlike the quote's pinned-height reads:
// the sequence must be fresh at signing time, or a send after any recent transaction is
// a guaranteed CheckTx rejection (sdk/32). Mirrors the Android kit's fetchAccount.
struct CosmosAccountClient: Sendable {
    let baseURL: URL
    let transport: any IHttpTransport

    init(baseURL: URL, transport: any IHttpTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func fetchAccount(address: String) async throws -> SendAccountInfo {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), components.query == nil, components.fragment == nil else {
            throw SendError.accountUnavailable
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = prefix.isEmpty ? "/cosmos/auth/v1beta1/accounts/\(address)" : "/\(prefix)/cosmos/auth/v1beta1/accounts/\(address)"
        guard let url = components.url else { throw SendError.accountUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SendError.providerUnavailable
        }
        guard response.statusCode == 200, Self.isJSON(response.value(forHTTPHeaderField: "Content-Type")) else {
            throw SendError.accountUnavailable
        }
        guard (try? StrictJSONEnvelopeDecoder.validateJSONDocument(data)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["account"] as? [String: Any],
              account["@type"] as? String != "/cosmos.auth.v1beta1.ModuleAccount" else {
            throw SendError.accountUnavailable
        }
        // vesting accounts nest the base account one level deeper; module/eth-style
        // accounts nest it directly
        let fields = (account["base_vesting_account"] as? [String: Any])?["base_account"] as? [String: Any]
            ?? account["base_account"] as? [String: Any]
            ?? account
        guard let accountAddress = fields["address"] as? String, accountAddress == address,
              let accountNumberString = fields["account_number"] as? String, let accountNumber = UInt64(accountNumberString),
              let sequenceString = fields["sequence"] as? String, let sequence = UInt64(sequenceString) else {
            throw SendError.accountUnavailable
        }
        return SendAccountInfo(accountNumber: accountNumber, sequence: sequence)
    }

    private static func isJSON(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.first == "application/json" else { return false }
        return parts.dropFirst().allSatisfy { !$0.hasPrefix("charset=") || $0 == "charset=utf-8" }
    }
}
