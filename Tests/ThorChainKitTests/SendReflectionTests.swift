import BigInt
import Foundation
@testable import ThorChainKit
import XCTest

final class SendReflectionTests: XCTestCase {
    func testPendingReflectionOmitsStoredMagnitudeFields() throws {
        let pending = try PendingTransaction(
            transactionId: XCTUnwrap(TransactionID(hash: String(repeating: "B", count: 64))),
            recipient: sendTestAddress(),
            amountMagnitude: SendMagnitude(BigUInt("18446744073709551617")).data,
            nativeFeeMagnitude: SendMagnitude(1).data,
            memo: nil,
            state: .unknown,
            retryAvailability: .notApplicable,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertFalse(String(reflecting: pending).contains("amountMagnitude"))
        XCTAssertFalse(String(reflecting: pending).contains("nativeFeeMagnitude"))
    }
}

private func capturedDump<T>(_ value: T) -> String {
    var output = StringDumpOutput()
    dump(value, to: &output)
    return output.value
}

private struct StringDumpOutput: TextOutputStream {
    var value = ""

    mutating func write(_ string: String) {
        value.append(string)
    }
}
