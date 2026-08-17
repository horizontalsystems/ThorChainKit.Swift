import Foundation
@testable import ThorChainKit
import XCTest

final class LifecycleInvariantProbeTests: XCTestCase {
    func testDirectSyncerLifecycleIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try AccountInfoManager(storage: AccountInfoStorage(databaseDirectoryUrl: directory, databaseFileName: "account-info-storage"))
        let syncer = try Syncer(
            accountInfoManager: manager,
            reader: ProbeReader(),
            storage: SyncerStorage(databaseDirectoryUrl: directory, databaseFileName: "syncer-state-storage"),
            address: sendTestAddress(),
            schedule: SyncSchedule(normalInterval: 60, failureBackoff: 60)
        )

        let first = syncer.start()
        let second = syncer.start()
        XCTAssertEqual(first, second)
        XCTAssertEqual(syncer.stop(), first)
        XCTAssertNil(syncer.stop())
        syncer.refresh()
    }
}

private struct ProbeReader: IAccountProvider {
    func read(address _: Address) async throws -> AccountReadTransport {
        try AccountReadTransport(
            acceptedHeight: 1,
            account: nil,
            balances: [],
            familyId: "probe",
            observedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
