import Foundation

/// THORChain asset notation: THOR.RUNE (native), BTC/BTC (synth), BTC~BTC (trade), BTC-BTC (secured)
public struct Asset: Hashable, Sendable, CustomStringConvertible {
    public let chain: String
    public let symbol: String
    public let ticker: String
    public let synth: Bool
    public let trade: Bool
    public let secured: Bool

    public static let rune = Asset(chain: "THOR", symbol: "RUNE", ticker: "RUNE")
    public static let cacao = Asset(chain: "MAYA", symbol: "CACAO", ticker: "CACAO")

    init(chain: String, symbol: String, ticker: String, synth: Bool = false, trade: Bool = false, secured: Bool = false) {
        self.chain = chain
        self.symbol = symbol
        self.ticker = ticker
        self.synth = synth
        self.trade = trade
        self.secured = secured
    }

    public init(notation: String) throws {
        guard let index = notation.firstIndex(where: Self.isDelimiter),
              index > notation.startIndex,
              notation.index(after: index) < notation.endIndex
        else {
            throw AssetError.invalidNotation
        }

        let delimiter = notation[index]
        let symbol = String(notation[notation.index(after: index)...]).uppercased()

        chain = String(notation[..<index]).uppercased()
        self.symbol = symbol
        // "ETH-USDC-0X…" carries the contract in the symbol; the ticker is what is shown
        ticker = String(symbol.prefix { $0 != "-" })
        synth = delimiter == "/"
        trade = delimiter == "~"
        secured = delimiter == "-"
    }

    public var description: String {
        let delimiter: Character

        if synth {
            delimiter = "/"
        } else if trade {
            delimiter = "~"
        } else if secured {
            delimiter = "-"
        } else {
            delimiter = "."
        }

        return "\(chain)\(delimiter)\(symbol)"
    }

    static func isDelimiter(_ character: Character) -> Bool {
        character == "." || character == "/" || character == "~" || character == "-"
    }
}

public enum AssetError: Error, Equatable {
    case invalidNotation
}
