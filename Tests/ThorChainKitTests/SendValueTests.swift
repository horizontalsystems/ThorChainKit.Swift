import BigInt
import XCTest
@testable import ThorChainKit

final class SendValueTests: XCTestCase {
    func testAllPublicMonetaryValuesSnapshotBeforeUse() {
        var amount = BigUInt("18446744073709551617")
        let sendAmount = SendAmount.exact(amount)
        let fee = NativeFeeChange(previous: amount, current: amount + 1)
        amount += 100

        XCTAssertEqual(sendAmount.exactAmount, BigUInt("18446744073709551617"))
        XCTAssertEqual(fee.previous, BigUInt("18446744073709551617"))
        XCTAssertEqual(fee.current, BigUInt("18446744073709551618"))
    }

}
