import Foundation
@_spi(Testing) import ThorChainKit

#if EXAMPLE_FIXTURE
    import FixtureSupport
#else
    import LiveSupport
#endif

enum ExampleMode: String, Sendable {
    case fixture = "FIXTURE"
    case live = "LIVE"

    var accessibilityValue: String {
        switch self {
        case .fixture: return "send.mode.fixture"
        case .live: return "send.mode.live"
        }
    }
}

struct EndpointPolicySnapshot: Equatable, Sendable {
    let selectedFamilyId: String
    let expectedChainId: String
    let identityClassification: String
    let cosmosOrigin: String
    let cometOrigin: String
    let cosmosHeight: String
    let cometHeight: String
    let heightSkew: String
    let catchingUp: String
    let rejectionReason: String
}

enum EndpointScenario: Sendable {
    case healthy, mixedIdentity, catchingUp, staleCosmos
}

struct AccountReadFixtureResult: Equatable, Sendable {
    let mode: String
    let exists: String
    let rune: String
    let height: String
    let family: String
}

@MainActor
struct ExampleRuntime {
    let kit: Kit
    let network: Network
    let endpointConfiguration: EndpointConfiguration
    let mode: ExampleMode
    let recipient: String
    let fixtureNamespace: String?
    let signer: (any Signer)?
    #if EXAMPLE_FIXTURE
        private let fixtureTransport: FixtureTransport
        private let fixtureScenario: FixtureScenario
    #endif

    init() throws {
        network = .mainnet
        #if EXAMPLE_FIXTURE
            let cosmos = Configuration.cosmosRestURL
            let comet = Configuration.cometBftURL
        #else
            let cosmos = Configuration.liveCosmosRestURL
            let comet = Configuration.liveCometBftURL
        #endif
        endpointConfiguration = try EndpointConfiguration(families: [EndpointFamilyDescriptor(
            id: "rorcual-mainnet",
            cosmosRestURL: cosmos,
            cometBftURL: comet
        )])
        #if EXAMPLE_FIXTURE
            mode = .fixture
            let scenario = FixtureScenario()
            let transport = FixtureTransport(scenario: scenario)
            fixtureScenario = scenario
            fixtureTransport = transport
            let address = try Address(Configuration.address, network: network)
            recipient = Configuration.recipient
            fixtureNamespace = scenario.namespace
            kit = try Kit.fixture(
                address: address,
                walletId: scenario.namespace,
                endpoints: endpointConfiguration,
                transport: transport,
                databasePath: Self.fixtureDatabasePath(namespace: scenario.namespace),
                observedAt: Date(timeIntervalSince1970: 1)
            )
            let golden = FixtureSigner.golden()
            signer = FixtureSigner(
                expectedDigest: scenario.expectedDigest,
                signature: golden.signature,
                compressedPublicKey: golden.compressedPublicKey
            )
        #else
            mode = .live
            let session = try LiveSendSession(
                secretURL: Configuration.liveSecretURL,
                endpoints: endpointConfiguration
            )
            kit = session.kit
            recipient = session.recipient.raw
            fixtureNamespace = nil
            signer = session.signer
        #endif
    }

    func fixtureRequestCount() async -> Int {
        #if EXAMPLE_FIXTURE
            return await fixtureTransport.requestCount
        #else
            return 0
        #endif
    }

    func writeFixtureEvidence(syncState: String, acceptedHeight: Int64?, lastBlockHeight: Int64?, rune: String, requestCount: Int) {
        guard mode == .fixture else { return }
        let evidence: [String: Any] = [
            "syncState": syncState,
            "acceptedHeight": acceptedHeight as Any,
            "lastBlockHeight": lastBlockHeight as Any,
            "rune": rune,
            "requestCount": requestCount,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: evidence) else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThorChainKitExample", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("lifecycle-evidence.json"), options: .atomic)
    }

    func setFixtureOffline(_ value: Bool) async {
        #if EXAMPLE_FIXTURE
            await fixtureTransport.setOffline(value)
        #else
            _ = value
        #endif
    }

    func fixturePending() async -> Bool {
        #if EXAMPLE_FIXTURE
            return await fixtureTransport.isPending
        #else
            return false
        #endif
    }

    func setFixturePending(_ value: Bool) async {
        #if EXAMPLE_FIXTURE
            await fixtureTransport.setPending(value)
        #else
            _ = value
        #endif
    }

    func releaseFixturePending() async {
        #if EXAMPLE_FIXTURE
            await fixtureTransport.releasePending()
        #endif
    }

    func isQuoteExpired(_ date: Date) async -> Bool {
        return Date() >= date
    }

    func endpointSnapshot(scenario: EndpointScenario) async -> EndpointPolicySnapshot {
        let snapshot = await TestingEndpointPolicySession(
            network: network,
            configuration: endpointConfiguration,
            script: scenario.script
        ).snapshot()
        return EndpointPolicySnapshot(
            selectedFamilyId: snapshot.selectedFamilyId ?? "nil",
            expectedChainId: snapshot.expectedChainId,
            identityClassification: snapshot.identityClassification,
            cosmosOrigin: "\(snapshot.cosmosOrigin.scheme)://\(snapshot.cosmosOrigin.host)",
            cometOrigin: "\(snapshot.cometOrigin.scheme)://\(snapshot.cometOrigin.host)",
            cosmosHeight: snapshot.cosmosHeight.map(String.init) ?? "nil",
            cometHeight: snapshot.cometHeight.map(String.init) ?? "nil",
            heightSkew: snapshot.heightSkew.map(String.init) ?? "nil",
            catchingUp: String(snapshot.catchingUp),
            rejectionReason: snapshot.rejectionReason ?? "none"
        )
    }

    func accountFixture() async throws -> AccountReadFixtureResult {
        let projection = try await TestingAccountReadSession(
            address: kit.address,
            configuration: endpointConfiguration,
            transport: ExampleAccountReadTransport()
        ).read()
        return AccountReadFixtureResult(
            mode: mode.rawValue,
            exists: String(projection.accountExists),
            rune: projection.runeAmountDecimal,
            height: String(projection.acceptedHeight),
            family: projection.providerFamilyId
        )
    }

    private static func fixtureDatabasePath(namespace: String) throws -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThorChainKitExample", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(namespace).sqlite").path
    }
}

private extension EndpointScenario {
    var script: TestingEndpointPolicySession.Script {
        switch self {
        case .healthy: .healthy
        case .mixedIdentity: .mixedIdentity
        case .catchingUp: .catchingUp
        case .staleCosmos: .staleCosmos
        }
    }
}

private actor ExampleAccountReadTransport: TestingHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let path = url.path
        let body: String
        if path.hasSuffix("node_info") {
            body = #"{"default_node_info":{"network":"thorchain-1"}}"#
        } else if path.hasSuffix("blocks/latest") || path == "/status" {
            body = #"{"result":{"node_info":{"network":"thorchain-1"},"sync_info":{"latest_block_height":"12345678","catching_up":false},"block":{"header":{"chain_id":"thorchain-1","height":"12345678"}}}}"#
        } else if path.contains("/accounts/") {
            body = #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"123456","sequence":"1"}}"#
        } else {
            body = #"{"balances":[{"denom":"rune","amount":"700000000"}],"pagination":{"next_key":null}}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Grpc-Metadata-X-Cosmos-Block-Height": "12345678"])!)
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).compactMap {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start ..< end], radix: 16)
        })
    }
}
