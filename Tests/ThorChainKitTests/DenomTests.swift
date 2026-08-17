import Foundation
@testable import ThorChainKit
import XCTest

final class DenomTests: XCTestCase {
    func testAssetForThorNatives() throws {
        XCTAssertEqual(try Denom.asset(for: "rune"), .rune)
        XCTAssertEqual(try Denom.asset(for: "tcy"), Asset(chain: "THOR", symbol: "TCY", ticker: "TCY"))
        XCTAssertEqual(try Denom.asset(for: "x/ruji"), Asset(chain: "THOR", symbol: "RUJI", ticker: "RUJI"))
    }

    func testAssetForGenericXDenomsAreThorNativeNotSynths() throws {
        // any x/<name> denom is a THOR-native (Rujira) token, not a synth of chain "X"
        let asset = try Denom.asset(for: "x/nami")

        XCTAssertEqual(asset, Asset(chain: "THOR", symbol: "NAMI", ticker: "NAMI"))
        XCTAssertFalse(asset.synth)
        XCTAssertFalse(asset.trade)
        XCTAssertFalse(asset.secured)

        XCTAssertEqual(
            try Denom.asset(for: "x/bow-xyk-1"),
            Asset(chain: "THOR", symbol: "BOW-XYK-1", ticker: "BOW")
        )
    }

    func testAssetForSecured() throws {
        XCTAssertEqual(
            try Denom.asset(for: "btc-btc"),
            Asset(chain: "BTC", symbol: "BTC", ticker: "BTC", secured: true)
        )
        XCTAssertEqual(
            try Denom.asset(for: "eth-usdc-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
            Asset(
                chain: "ETH",
                symbol: "USDC-0XA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48",
                ticker: "USDC",
                secured: true
            )
        )
    }

    func testAssetForSynth() throws {
        XCTAssertEqual(
            try Denom.asset(for: "btc/btc"),
            Asset(chain: "BTC", symbol: "BTC", ticker: "BTC", synth: true)
        )
    }

    func testAssetForTrade() throws {
        XCTAssertEqual(
            try Denom.asset(for: "btc~btc"),
            Asset(chain: "BTC", symbol: "BTC", ticker: "BTC", trade: true)
        )
    }

    func testDenomForInverse() throws {
        // every asset(for:) result maps back to the original denom
        for denom in [
            "rune",
            "tcy",
            "x/ruji",
            "btc-btc",
            "btc/btc",
            "btc~btc",
            "eth-usdc-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        ] {
            XCTAssertEqual(try Denom.denom(for: Denom.asset(for: denom)), denom)
        }
    }

    func testDenomForFutureThorNative() throws {
        XCTAssertEqual(Denom.denom(for: Asset(chain: "THOR", symbol: "NEWTOKEN", ticker: "NEWTOKEN")), "newtoken")
        XCTAssertEqual(
            try Denom.asset(for: "newtoken"),
            Asset(chain: "THOR", symbol: "NEWTOKEN", ticker: "NEWTOKEN")
        )
    }

    func testMidgardFullNotationResolvesToTheSameAssetAsItsBankDenom() throws {
        // Midgard reports swap assets in full notation but native sends in bank-denom
        // notation; both forms must land on the same asset
        XCTAssertEqual(try Denom.asset(for: "THOR.RUNE"), .rune)
        XCTAssertEqual(try Denom.asset(for: "THOR.TCY"), try Denom.asset(for: "tcy"))
    }

    func testMalformedNotationIsRejected() {
        for notation in ["", ".", "-rune", "rune-", "/", "btc/"] {
            XCTAssertThrowsError(try Asset(notation: notation), notation)
        }
    }
}
