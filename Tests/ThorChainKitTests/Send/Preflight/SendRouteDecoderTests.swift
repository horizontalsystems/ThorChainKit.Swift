@testable import ThorChainKit
import XCTest

final class SendRouteDecoderTests: XCTestCase {
    func testBalanceRejectsADenomOtherThanTheRequestedOne() {
        // The node answering a `?denom=tcy` query with a RUNE balance must fail, not be
        // read as the token's balance — that would authorise a transfer of whatever the
        // RUNE balance happens to be. Every other case here asks for rune and gets rune,
        // so this cross-asset mismatch was the one shape never exercised.
        XCTAssertThrowsError(try SendRouteDecoders.balance(Data(#"{"balance":{"denom":"rune","amount":"999999999"}}"#.utf8), expecting: "tcy")) {
            XCTAssertEqual($0 as? SendError, .insufficientBalance)
        }
        XCTAssertThrowsError(try SendRouteDecoders.balance(Data(#"{"balance":{"denom":"tcy","amount":"1"}}"#.utf8), expecting: "rune")) {
            XCTAssertEqual($0 as? SendError, .insufficientBalance)
        }
    }

    func testFeeAllowsZeroAndRejectsMalformedBounds() throws {
        var response = Types_QueryNetworkResponse()
        response.nativeTxFeeRune = "0"
        XCTAssertEqual(try SendRouteDecoders.networkFee(response.serializedData()), 0)
        for value in ["", "-1", "01", "18446744073709551616", "184467440737095516160000000000000000000"] {
            response.nativeTxFeeRune = value
            XCTAssertThrowsError(try SendRouteDecoders.networkFee(response.serializedData()))
        }
    }

    func testBalanceRequiresLiteralRuneAndCanonicalUnsignedAmount() throws {
        XCTAssertEqual(try SendRouteDecoders.balance(Data(#"{"balance":{"denom":"rune","amount":"0"}}"#.utf8), expecting: "rune").amount, "0")
        for body in [
            #"{"balance":{"denom":"RUNE","amount":"1"}}"#,
            #"{"balance":{"denom":"rune","amount":"01"}}"#,
            #"{"balance":{"denom":"rune","amount":"-1"}}"#,
            #"{"balance":{"denom":"rune","amount":"1","extra":true}}"#,
            #"{"denom":"rune","amount":"1"}"#,
        ] {
            XCTAssertThrowsError(try SendRouteDecoders.balance(Data(body.utf8), expecting: "rune"))
        }
        for body in [
            #"{"balance":{"denom":"rune"}}"#,
            #"{"balance":{"denom":"rune","amount":1}}"#,
            #"{"balance":{"denom":"rune","amount":""}}"#,
        ] {
            XCTAssertThrowsError(try SendRouteDecoders.balance(Data(body.utf8), expecting: "rune"))
        }
    }

    func testMimirMapRejectsAnythingButWholeNumbers() throws {
        let body = #"{"HALTCHAINGLOBAL":0,"NODEPAUSECHAINGLOBAL":26195469,"HALTTHORCHAIN":-1}"#
        let values = try SendRouteDecoders.mimir(Data(body.utf8))
        XCTAssertEqual(values["HALTCHAINGLOBAL"], 0)
        XCTAssertEqual(values["NODEPAUSECHAINGLOBAL"], 26_195_469)
        XCTAssertEqual(values["HALTTHORCHAIN"], -1)
        for body in ["", "{}", "-1", #"{"HALTTHORCHAIN":-2}"#, #"{"HALTTHORCHAIN":"0"}"#, #"{"HALTTHORCHAIN":1.5}"#] {
            XCTAssertThrowsError(try SendRouteDecoders.mimir(Data(body.utf8)))
        }
    }
}
