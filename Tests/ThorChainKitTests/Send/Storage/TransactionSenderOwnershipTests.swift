import Foundation
@testable import ThorChainKit
import XCTest

final class TransactionSenderOwnershipTests: XCTestCase {
    func testPerKitLifecycleIsIndependent() async throws {
        let sender = try sendTestAddress()
        let namespace = "ownership-\(UUID().uuidString)"
        let first = TransactionSender(address: sender, clientID: UUID(), persistenceNamespace: namespace)
        let second = TransactionSender(address: sender, clientID: UUID(), persistenceNamespace: namespace)
        await first.activate(generation: 1)
        await second.activate(generation: 1)
        let firstActive = await first.isAdmissionActive()
        let secondActive = await second.isAdmissionActive()
        XCTAssertTrue(firstActive)
        XCTAssertTrue(secondActive)

        await first.invalidate(generation: 1)

        let firstStopped = await first.isAdmissionActive()
        let secondStillActive = await second.isAdmissionActive()
        XCTAssertFalse(firstStopped)
        XCTAssertTrue(secondStillActive)
    }
}
