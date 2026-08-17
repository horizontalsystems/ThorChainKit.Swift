import Foundation

public struct Network: Hashable, Sendable {
    public enum Environment: String, Hashable, Sendable {
        case mainnet
        case stagenet
        case chainnet
    }

    // thornode-family chain served by the kit. Everything chain-specific that is not an
    // endpoint or a chain-id — native denom, decimals, API path segment, asset notation —
    // dispatches on this, mirroring the Android kit's per-chain Network parameters.
    public enum Chain: String, Hashable, Sendable {
        case thor
        case maya

        public var nativeDenom: Denom {
            switch self {
            case .thor: return .rune
            case .maya: return .cacao
            }
        }

        public var nativeAsset: Asset {
            switch self {
            case .thor: return .rune
            case .maya: return .cacao
            }
        }

        public var decimals: Int {
            switch self {
            case .thor: return 8
            case .maya: return 10
            }
        }

        // API path segment identifying the protocol module on the node, e.g. "thorchain"
        // in /thorchain/mimir (Maya uses "mayachain")
        public var protocolPath: String {
            switch self {
            case .thor: return "thorchain"
            case .maya: return "mayachain"
            }
        }

        // chain tag used in fully-qualified asset identifiers, e.g. "THOR" in THOR.RUNE
        public var assetChainTag: String {
            switch self {
            case .thor: return "THOR"
            case .maya: return "MAYA"
            }
        }
    }

    public let environment: Environment
    public let expectedChainId: String
    public let accountHrp: String
    public let coinType: UInt32
    public let chain: Chain

    public var nativeDenom: Denom { chain.nativeDenom }
    public var decimals: Int { chain.decimals }
    public var protocolPath: String { chain.protocolPath }

    public static let mainnet = try! Network(
        environment: .mainnet,
        expectedChainId: "thorchain-1",
        accountHrp: "thor"
    )

    // Maya Protocol (mayanode, a thornode fork). Reuses SLIP-44 coin type 931; the "maya"
    // address prefix keeps it distinct from THORChain. Settlement asset is CACAO (10 decimals).
    public static let mayaMainnet = try! Network(
        environment: .mainnet,
        expectedChainId: "mayachain-mainnet-v1",
        accountHrp: "maya",
        chain: .maya
    )

    public static func stagenet(expectedChainId: String) throws -> Network {
        try Network(
            environment: .stagenet,
            expectedChainId: expectedChainId,
            accountHrp: "sthor"
        )
    }

    public static func chainnet(expectedChainId: String) throws -> Network {
        try Network(
            environment: .chainnet,
            expectedChainId: expectedChainId,
            accountHrp: "cthor"
        )
    }

    var persistenceKey: String {
        environment.rawValue + "\0" + expectedChainId
    }

    private init(
        environment: Environment,
        expectedChainId: String,
        accountHrp: String,
        chain: Chain = .thor
    ) throws {
        guard Self.isValid(chainId: expectedChainId) else {
            throw KitConfigurationError.invalidChainId
        }
        self.environment = environment
        self.expectedChainId = expectedChainId
        self.accountHrp = accountHrp
        self.chain = chain
        coinType = 931
    }

    private static func isValid(chainId: String) -> Bool {
        let bytes = chainId.utf8.count
        return (1 ... 50).contains(bytes)
            && !chainId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chainId.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
