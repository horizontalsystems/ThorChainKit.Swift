import Foundation
@testable import ThorChainKit
import XCTest

final class KitLifecycleTests: XCTestCase {
    func testKitDelegatesDirectlyToSyncer() async throws {
        let kit = try makeTestKit(address: sendTestAddress(), persistenceNamespace: "lifecycle")

        kit.start()
        kit.start()
        kit.refresh()
        kit.stop()
        kit.stop()
        kit.refresh()

        if case .idle = kit.syncState {} else { XCTFail("stopped kit must be idle") }
    }

    func testInitialAccountPublishersReplayEmptyState() throws {
        let kit = try makeTestKit(address: sendTestAddress(), persistenceNamespace: "lifecycle")
        XCTAssertNil(kit.lastBlockHeight)
        XCTAssertEqual(kit.syncState, .idle(cached: false))
        XCTAssertNil(kit.accountState)
    }
}
