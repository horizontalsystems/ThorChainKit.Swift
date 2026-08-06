import Foundation
import XCTest
@testable import ThorChainKit

final class StrictJSONEnvelopeDecoderTests: XCTestCase {
    func testDuplicateKeysAndTrailingTokensAreNotAuthoritative() {
        let decoder = StrictJSONEnvelopeDecoder()
        XCTAssertThrowsError(try decoder.decode(Data(#"{"tx_response":{"txhash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","code":0,"code":1}}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(Data(#"{"tx_response":{"txhash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","code":0}} trailing"#.utf8)))
    }

    func testBroadcastEnvelopeReturnsOnlyBoundedFields() throws {
        let data = Data(#"{"tx_response":{"height":"0","txhash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","codespace":"sdk","code":19,"data":"","raw_log":"sequence mismatch","logs":[],"gas_wanted":"0","gas_used":"0","tx":null,"events":[]},"ignored_top_level":true}"#.utf8)
        let response = try StrictJSONEnvelopeDecoder().decode(data)
        XCTAssertEqual(response.txHash, String(repeating: "A", count: 64))
        XCTAssertEqual(response.code, 19)
        XCTAssertEqual(response.codespace, "sdk")
        XCTAssertEqual(response.sanitizedLog, "sequence mismatch")
    }
}
