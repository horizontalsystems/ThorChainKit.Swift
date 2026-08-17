@testable import ThorChainKit
import XCTest

final class S1_04ContractTests: XCTestCase {
    func testTransportRecordsAreSendableAndAccountAbsenceRequiresEmptyBalances() throws {
        XCTAssertThrowsError(try AccountReadTransport(
            acceptedHeight: 1,
            account: nil,
            balances: [BalanceTransport(denom: .rune, amountDecimal: "1")],
            familyId: "fixture",
            observedAt: Date(timeIntervalSince1970: 0)
        ))
    }
}
