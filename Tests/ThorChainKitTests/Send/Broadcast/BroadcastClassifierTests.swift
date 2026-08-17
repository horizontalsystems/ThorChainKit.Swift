import Foundation
@testable import ThorChainKit
import XCTest

final class BroadcastClassifierTests: XCTestCase {
    func testStrictWireMatrix() throws {
        let local = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        XCTAssertEqual(
            BroadcastClassifier.classify(
                localHash: local,
                response: BroadcastResponse(txHash: local.hash, code: 0, codespace: nil, sanitizedLog: nil)
            ),
            .checkTxAccepted
        )
        XCTAssertEqual(
            BroadcastClassifier.classify(
                localHash: local,
                response: BroadcastResponse(txHash: local.hash, code: 19, codespace: nil, sanitizedLog: nil)
            ),
            .unknown
        )
        XCTAssertEqual(
            BroadcastClassifier.classify(localHash: local, response: nil),
            .unknown
        )
    }

    func testHashMismatchWinsOverCode() throws {
        let local = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        let response = BroadcastResponse(txHash: String(repeating: "B", count: 64), code: 0, codespace: nil, sanitizedLog: nil)
        XCTAssertEqual(BroadcastClassifier.classify(localHash: local, response: response), .unknown)
    }

    func testSdkDuplicateCodeIsAcceptedOnlyWithMatchingHash() throws {
        let local = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        let response = BroadcastResponse(txHash: local.hash, code: 19, codespace: "sdk", sanitizedLog: nil)
        XCTAssertEqual(BroadcastClassifier.classify(localHash: local, response: response), .checkTxAccepted)
    }

    func testTerminalStateCannotDowngrade() throws {
        let local = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        let accepted = BroadcastClassifier.classify(
            localHash: local,
            response: BroadcastResponse(txHash: local.hash, code: 0, codespace: nil, sanitizedLog: nil)
        )
        let mismatch = BroadcastClassifier.classify(
            localHash: local,
            response: BroadcastResponse(txHash: String(repeating: "B", count: 64), code: 0, codespace: nil, sanitizedLog: nil)
        )
        XCTAssertEqual(accepted, .checkTxAccepted)
        XCTAssertEqual(mismatch, .unknown)
    }
}
