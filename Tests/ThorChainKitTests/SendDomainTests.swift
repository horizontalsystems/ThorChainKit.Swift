import BigInt
import XCTest
@testable import ThorChainKit

final class SendDomainTests: XCTestCase {
    func testSendAmountSnapshotsBigUIntAndPreservesMaximumIntent() {
        var value = BigUInt("18446744073709551617")
        let amount = SendAmount.exact(value)
        value += 1

        XCTAssertEqual(amount.exactAmount, BigUInt("18446744073709551617"))
    }


    func testErrorDebugProjectionDoesNotExposeSensitiveText() {
        let error = SendError.broadcastRejected(
            BroadcastRejection(code: 7, codespace: "secret://wallet", sanitizedLog: "insufficient funds")
        )

        let rendered = "\(error) \(String(reflecting: error))"
        XCTAssertFalse(rendered.contains("secret://wallet"))
        XCTAssertTrue(rendered.contains("broadcastRejected"))
    }

    func testPendingValuesKeepBigUIntOutOfStoredRepresentation() throws {
        let recipient = try Address("thor166aczv0jatlnyzz8zsczdzk9xxxgppfpu530jl", network: .mainnet)
        let id = try XCTUnwrap(TransactionID(hash: String(repeating: "A", count: 64)))
        let pending = PendingTransaction(
            transactionId: id,
            recipient: recipient,
            amountMagnitude: SendMagnitude(BigUInt("18446744073709551617")).data,
            nativeFeeMagnitude: Data(),
            memo: nil,
            state: .checkTxAccepted,
            retryAvailability: .available,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(pending.amount, BigUInt("18446744073709551617"))
        XCTAssertEqual(pending.nativeFee, 0)
        XCTAssertFalse(String(reflecting: pending).contains("amountMagnitude"))
    }
}
