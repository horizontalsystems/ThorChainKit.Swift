import BigInt
import Foundation
@testable import ThorChainKit
import XCTest

final class PendingTransactionTests: XCTestCase {
    func testPendingStateNamesPreserveCheckTxMeaningAndUnknownOutcome() throws {
        let accepted = try pending(id: "A", createdAt: 1, state: .checkTxAccepted)
        let unknown = try pending(id: "B", createdAt: 2, state: .unknown)

        if case .checkTxAccepted = accepted.state {} else { XCTFail("expected CheckTx state") }
        if case .unknown = unknown.state {} else { XCTFail("expected ambiguous state") }
        XCTAssertEqual(accepted.amount, 100)
        XCTAssertEqual(accepted.nativeFee, 2)
    }

    func testPendingReviewOrderUsesCreatedAtThenCanonicalHash() throws {
        let laterHash = try pending(id: "B", createdAt: 2, state: .unknown)
        let firstHash = try pending(id: "A", createdAt: 1, state: .unknown)
        let sameTimeHigher = try pending(id: "C", createdAt: 1, state: .unknown)
        let sorted = [sameTimeHigher, laterHash, firstHash].sorted {
            ($0.createdAt, $0.transactionId.hash) < ($1.createdAt, $1.transactionId.hash)
        }

        XCTAssertEqual(sorted.map { $0.transactionId.hash }, [String(repeating: "A", count: 64), String(repeating: "C", count: 64), String(repeating: "B", count: 64)])
    }

    func testPendingRejectsNonCanonicalAmountMagnitudes() {
        XCTAssertFalse(PendingTransaction.isCanonicalMagnitude(Data(), allowingZero: false))
        XCTAssertFalse(PendingTransaction.isCanonicalMagnitude(Data([0]), allowingZero: false))
        XCTAssertFalse(PendingTransaction.isCanonicalMagnitude(Data([0, 100]), allowingZero: false))
    }

    func testPendingRejectsNonCanonicalFeeMagnitudesButAllowsEmptyZero() {
        XCTAssertTrue(PendingTransaction.isCanonicalMagnitude(Data(), allowingZero: true))
        XCTAssertFalse(PendingTransaction.isCanonicalMagnitude(Data([0]), allowingZero: true))
        XCTAssertFalse(PendingTransaction.isCanonicalMagnitude(Data([0, 2]), allowingZero: true))
    }

    private func pending(id: String, createdAt: TimeInterval, state: PendingTransaction.State) throws -> PendingTransaction {
        try PendingTransaction(
            transactionId: XCTUnwrap(TransactionID(hash: String(repeating: id, count: 64))),
            recipient: sendTestAddress(),
            amountMagnitude: SendMagnitude(100).data,
            nativeFeeMagnitude: SendMagnitude(2).data,
            memo: nil,
            state: state,
            retryAvailability: .available,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
