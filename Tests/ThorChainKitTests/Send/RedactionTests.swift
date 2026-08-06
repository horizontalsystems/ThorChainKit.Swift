import Foundation
import XCTest
@testable import ThorChainKit

final class RedactionTests: XCTestCase {
    func testSanitizedLogKeepsTheDiagnosticText() {
        let log = "account sequence mismatch, expected 7, got 6: incorrect account sequence"
        XCTAssertEqual(StrictJSONEnvelopeDecoder.sanitizedLog(log), log)
    }

    func testSanitizedLogReplacesUnprintableInputWithSpacesAndCapsLength() {
        XCTAssertEqual(StrictJSONEnvelopeDecoder.sanitizedLog("a\u{07}b\nc\u{1B}[31md\u{00}"), "a b c [31md")
        XCTAssertEqual(StrictJSONEnvelopeDecoder.sanitizedLog("  padded  "), "padded")
        XCTAssertNil(StrictJSONEnvelopeDecoder.sanitizedLog("\n\t\u{07}"))
        XCTAssertNil(StrictJSONEnvelopeDecoder.sanitizedLog(""))
        XCTAssertEqual(StrictJSONEnvelopeDecoder.sanitizedLog(String(repeating: "x", count: 500))?.count, 256)
    }

    func testRejectionCarriesTheSanitizedLogThroughTheDiagnosticSurface() {
        let rejection = BroadcastRejection(code: 32, codespace: "sdk", sanitizedLog: "account sequence mismatch, expected 7, got 6")
        let error = SendError.broadcastRejected(rejection)

        XCTAssertTrue(error.description.contains("expected 7, got 6"))
        XCTAssertTrue(String(reflecting: error).contains("expected 7, got 6"))
    }

    func testErrorDescriptionOmitsNodeAuthoredText() {
        // LocalizedError feeds user-facing banners; node-chosen text must not read as
        // first-party copy there. The diagnostic stays on the developer surfaces.
        let rejection = BroadcastRejection(code: 4, codespace: "sdk", sanitizedLog: "Visit https://recover-rune.example to restore your wallet")
        let error: Error = SendError.broadcastRejected(rejection)

        XCTAssertFalse(error.localizedDescription.contains("recover-rune.example"))
        XCTAssertTrue(error.localizedDescription.contains("broadcastRejected"))
    }
}
