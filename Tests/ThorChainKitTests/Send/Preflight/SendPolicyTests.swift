import BigInt
import XCTest
@testable import ThorChainKit

final class SendPolicyTests: XCTestCase {
    func testAmountIsTakenAsGivenAndOnlyZeroIsRefused() throws {
        let policy = try SendPolicy()

        // The balance is deliberately absent here: whatever the caller asks for is what
        // gets signed, and the chain refuses a send it cannot cover. A second balance
        // read at this point disagreed with the screen the amount was chosen on.
        XCTAssertEqual(try policy.resolve(amount: .exact(1)), 1)
        XCTAssertEqual(try policy.resolve(amount: .exact(BigUInt(10).power(30))), BigUInt(10).power(30))
        XCTAssertThrowsError(try policy.resolve(amount: .exact(0))) {
            XCTAssertEqual($0 as? SendError, .invalidAmount)
        }
    }

    func testMemoUsesUTF8BytesAndCanonicalPositiveLimit() throws {
        let policy = try SendPolicy(memoMaximumBytes: 4)

        XCTAssertNoThrow(try policy.validate(memo: "éé"))
        XCTAssertThrowsError(try policy.validate(memo: "ééa")) { error in
            XCTAssertEqual(error as? SendError, .memoTooLong(maxUTF8Bytes: 4))
        }
        XCTAssertThrowsError(try SendPolicy(memoMaximumBytes: 0))
        XCTAssertThrowsError(try SendPolicy(memoMaximumBytes: 4, revision: ""))
    }
}
