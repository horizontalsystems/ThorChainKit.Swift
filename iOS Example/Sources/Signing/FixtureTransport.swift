import CryptoKit
import FixtureSupport
import Foundation
import ThorChainKit
@_spi(Testing) import ThorChainKit

actor FixtureTransport: TestingHTTPTransport {
    public private(set) var requestCount = 0
    private let scenario: FixtureScenario
    private var offline = false
    private var pending = false
    private var acceptedBytes: Data?
    private var acceptedHash: String?
    private var continuations = [CheckedContinuation<Void, Never>]()

    public init(scenario: FixtureScenario) {
        self.scenario = scenario
    }

    public func setOffline(_ value: Bool) { offline = value }
    public var isPending: Bool { pending }
    public func setPending(_ value: Bool) {
        pending = value
        if !value { releasePending() }
    }

    public func releasePending() {
        pending = false
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let url = try requireURL(request)
        if pending {
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuations.append($0) }
            }, onCancel: { Task { await self.releasePending() } })
        }
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let path = url.path
        let response: (Data, Int, [String: String])
        if path == "/cosmos/base/tendermint/v1beta1/node_info" {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: [:])
            response = (#"{"default_node_info":{"network":"thorchain-1"}}"#.data(using: .utf8)!, 200, [:])
        } else if path == "/cosmos/base/tendermint/v1beta1/blocks/latest" {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: [:])
            response = (Data(#"{"block":{"header":{"chain_id":"thorchain-1","height":"12345678"}}}"#.utf8), 200, ["Grpc-Metadata-X-Cosmos-Block-Height": "12345678"])
        } else if path == "/status" {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: [:])
            response = (Data(#"{"result":{"node_info":{"network":"thorchain-1"},"sync_info":{"latest_block_height":"12345678","catching_up":false}}}"#.utf8), 200, ["Grpc-Metadata-X-Cosmos-Block-Height": "12345678"])
        } else if path == "/cosmos/auth/v1beta1/accounts/\(Self.senderAddress)" {
            try requireMethod(request, "GET")
            response = (Data(#"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"123456","sequence":"1"}}"#.utf8), 200, Self.restHeaders)
        } else if path == "/cosmos/bank/v1beta1/balances/\(Self.senderAddress)" {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: ["pagination.limit": "100"])
            response = (Data(#"{"balances":[{"denom":"rune","amount":"700000000"}],"pagination":{"next_key":null}}"#.utf8), 200, Self.restHeaders)
        } else if path == "/abci_query" {
            try requireMethod(request, "GET")
            let query = try queryDictionary(url)
            guard query.count == 3,
                  let abciPath = query["path"], let data = query["data"], query["height"] == "12345678"
            else {
                throw URLError(.cannotParseResponse)
            }
            switch (abciPath, data) {
            case ("/cosmos.auth.v1beta1.Query/Account", Self.senderAccountRequestData):
                response = (cometEnvelope(Self.senderAccountResponse), 200, [:])
            case ("/cosmos.auth.v1beta1.Query/Account", Self.recipientAccountRequestData):
                response = (cometEnvelope(Self.recipientAccountResponse), 200, [:])
            case ("/types.Query/Network", Self.networkRequestData):
                response = (cometEnvelope(Self.networkResponse), 200, [:])
            default:
                throw URLError(.cannotParseResponse)
            }
        } else if path == "/cosmos/bank/v1beta1/spendable_balances/\(Self.senderAddress)/by_denom" {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: ["denom": "rune"])
            response = (Data(#"{"balance":{"denom":"rune","amount":"700000000"}}"#.utf8), 200, Self.restHeaders)
        } else if path == "/thorchain/mimir/key/HaltChainGlobal" ||
            path == "/thorchain/mimir/key/NodePauseChainGlobal" ||
            path == "/thorchain/mimir/key/HaltTHORChain" ||
            path == "/thorchain/mimir/key/SolvencyHaltTHORChain"
        {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: ["height": "12345678"])
            response = (Data("-1".utf8), 200, Self.restHeaders)
        } else if path == "/cosmos/auth/v1beta1/params" {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: [:])
            response = (Data(#"{"params":{"max_memo_characters":"256","tx_sig_limit":"7","tx_size_cost_per_byte":"10","sig_verify_cost_ed25519":"590","sig_verify_cost_secp256k1":"1000"}}"#.utf8), 200, Self.restHeaders)
        } else if path == "/thorchain/version" {
            try requireMethod(request, "GET")
            try requireQuery(url, equals: ["height": "12345678"])
            response = (Data(#"{"current":"3.19.3","next":"3.19.3","next_since_height":"0","querier":"3.19.0"}"#.utf8), 200, Self.restHeaders)
        } else if path == "/cosmos/tx/v1beta1/txs" {
            try requireMethod(request, "POST")
            try requireQuery(url, equals: [:])
            guard let body = request.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  object.count == 2,
                  object["mode"] as? String == "BROADCAST_MODE_SYNC",
                  let encoded = object["tx_bytes"] as? String,
                  let raw = Data(base64Encoded: encoded) else { throw URLError(.cannotParseResponse) }
            guard raw == scenario.expectedSignedBytes else { throw URLError(.cannotParseResponse) }
            let hash = Data(SHA256.hash(data: raw)).map { String(format: "%02X", $0) }.joined()
            guard hash == scenario.expectedTransactionHash else { throw URLError(.cannotParseResponse) }
            if let acceptedBytes {
                guard raw == acceptedBytes, hash == acceptedHash else { throw URLError(.cannotParseResponse) }
            } else {
                acceptedBytes = raw
                acceptedHash = hash
            }
            response = (Data(#"{"tx_response":{"code":0,"codespace":"sdk","txhash":"\#(hash)"}}"#.utf8), 200, [:])
        } else {
            throw URLError(.cannotParseResponse)
        }
        var headers = response.2
        headers["Content-Type"] = "application/json"
        return (
            response.0,
            HTTPURLResponse(url: url, statusCode: response.1, httpVersion: nil, headerFields: headers)!
        )
    }

    private func requireURL(_ request: URLRequest) throws -> URL {
        guard let url = request.url else { throw URLError(.badURL) }
        return url
    }

    private func requireMethod(_ request: URLRequest, _ method: String) throws {
        guard request.httpMethod == method else { throw URLError(.cannotParseResponse) }
    }

    private func queryDictionary(_ url: URL) throws -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.allSatisfy({ $0.value != nil }) else { throw URLError(.cannotParseResponse) }
        let values = Dictionary(items.map { ($0.name, $0.value!) }, uniquingKeysWith: { _, _ in "" })
        guard values.count == items.count else { throw URLError(.cannotParseResponse) }
        return values
    }

    private func requireQuery(_ url: URL, equals expected: [String: String]) throws {
        let actual = try queryDictionary(url)
        guard actual == expected else { throw URLError(.cannotParseResponse) }
    }

    private func cometEnvelope(_ value: Data) -> Data {
        let encoded = value.base64EncodedString()
        return Data(#"{"jsonrpc":"2.0","id":1,"result":{"response":{"code":0,"height":"12345678","value":"\#(encoded)"}}}"#.utf8)
    }

    private static let senderAddress = "thor1w508d6qejxtdg4y5r3zarvary0c5xw7ku6wp68"
    private static let senderAccountRequestData = "0x0A2B74686F723177353038643671656A7874646734793572337A6172766172793063357877376B753677703638"
    private static let recipientAccountRequestData = "0x0A2B74686F72317467786D356A773668726C76736C7264366C71706B346A77757534673239647879747265616E"
    private static let networkRequestData = "0x0A083132333435363738"
    private static let senderAccountResponse = Data(base64Encoded: "ClcKIC9jb3Ntb3MuYXV0aC52MWJldGExLkJhc2VBY2NvdW50EjMKK3Rob3IxdzUwOGQ2cWVqeHRkZzR5NXIzemFydmFyeTBjNXh3N2t1NndwNjgYwMQHIAE=")!
    private static let recipientAccountResponse = Data(base64Encoded: "ClcKIC9jb3Ntb3MuYXV0aC52MWJldGExLkJhc2VBY2NvdW50EjMKK3Rob3IxdGd4bTVqdzZocmx2c2xyZDZscXBrNGp3dXU0ZzI5ZHh5dHJlYW4YwMQHIAE=")!
    private static let networkResponse = Data(base64Encoded: "UgEy")!
    private static let restHeaders = [
        "Content-Type": "application/json",
        "Grpc-Metadata-X-Cosmos-Block-Height": "12345678",
        "x-cosmos-block-height": "12345678",
    ]
}
