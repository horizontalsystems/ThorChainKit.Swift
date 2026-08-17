public struct Denom: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard (3 ... 128).contains(bytes.count),
              bytes.first.map(Self.isLetter) == true,
              bytes.dropFirst().allSatisfy(Self.isAllowed)
        else {
            throw KitConfigurationError.invalidDenom
        }
        self.rawValue = rawValue
    }

    public static let rune = try! Denom(rawValue: "rune")
    public static let cacao = try! Denom(rawValue: "cacao")

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        isLetter(byte)
            || (48 ... 57).contains(byte)
            || [47, 58, 46, 95, 45].contains(byte)
    }
}

// THORChain bank denom notation. All native assets are bank denoms with 8 decimals:
// "rune", "tcy", "x/ruji" (THOR-native tokens), "btc-btc" (secured), "btc/btc" (synth)
public extension Denom {
    static let decimals = 8

    // THOR-native denoms whose notation is irregular (not derivable from the asset)
    private static let nativeAssets: [String: Asset] = [
        "rune": .rune,
        "tcy": Asset(chain: "THOR", symbol: "TCY", ticker: "TCY"),
        "x/ruji": Asset(chain: "THOR", symbol: "RUJI", ticker: "RUJI"),
    ]

    static func asset(for denom: String) throws -> Asset {
        let lowered = denom.lowercased()

        if let native = nativeAssets[lowered] {
            return native
        }

        // "x/<name>" is the app-layer (Rujira) namespace for THOR-native tokens —
        // NOT a synth of a chain called "X"
        if lowered.hasPrefix("x/") {
            let symbol = String(lowered.dropFirst(2)).uppercased()
            return Asset(chain: "THOR", symbol: symbol, ticker: String(symbol.prefix { $0 != "-" }))
        }

        guard lowered.contains(where: Asset.isDelimiter) else {
            // plain denom: a THOR-native token (like "tcy")
            let symbol = lowered.uppercased()
            return Asset(chain: "THOR", symbol: symbol, ticker: symbol)
        }

        // "chain-symbol" (secured) or "chain/symbol" (synth)
        return try Asset(notation: lowered)
    }

    // NOTE: a THOR-native Asset does not carry whether its bank denom uses the plain
    // ("tcy") or the "x/" ("x/ruji") notation — only denoms in nativeAssets round-trip
    // exactly. For sends, pass the bank denom string itself; never derive it via
    // denom(for:) for an unknown x/-token.
    static func denom(for asset: Asset) -> String {
        if let native = nativeAssets.first(where: { $0.value == asset }) {
            return native.key
        }

        if asset.chain == "THOR", !asset.synth, !asset.trade, !asset.secured {
            return asset.symbol.lowercased()
        }

        return asset.description.lowercased()
    }
}

// Per-chain denom <-> Asset translation. thornode-family chains share the delimiter
// grammar (Asset) but differ in their native denom and the irregular native-token naming
// rules. THOR keeps the historical Denom statics; Maya follows the same shape as the
// Android kit's MayaAssetResolver.
public extension Network.Chain {
    // MAYA-native denoms whose notation is irregular (not derivable from the asset)
    private static let mayaNativeAssets: [String: Asset] = [
        "cacao": .cacao,
        "maya": Asset(chain: "MAYA", symbol: "MAYA", ticker: "MAYA"),
    ]

    func asset(for denom: String) throws -> Asset {
        switch self {
        case .thor:
            return try Denom.asset(for: denom)
        case .maya:
            let lowered = denom.lowercased()

            if let native = Self.mayaNativeAssets[lowered] {
                return native
            }

            // Maya has no Rujira "x/" app-layer namespace, so (unlike THOR) a plain
            // delimiter-free denom is a MAYA-native token directly
            guard lowered.contains(where: Asset.isDelimiter) else {
                let symbol = lowered.uppercased()
                return Asset(chain: "MAYA", symbol: symbol, ticker: symbol)
            }

            // "chain-symbol" (secured) or "chain/symbol" (synth)
            return try Asset(notation: lowered)
        }
    }

    func denom(for asset: Asset) -> String {
        switch self {
        case .thor:
            return Denom.denom(for: asset)
        case .maya:
            if let native = Self.mayaNativeAssets.first(where: { $0.value == asset }) {
                return native.key
            }

            if asset.chain == "MAYA", !asset.synth, !asset.trade, !asset.secured {
                return asset.symbol.lowercased()
            }

            return asset.description.lowercased()
        }
    }
}
