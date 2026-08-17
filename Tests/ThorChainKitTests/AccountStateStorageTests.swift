import Foundation
@testable import ThorChainKit
import XCTest

final class AccountInfoStorageTests: XCTestCase {
    func testRestoresOneCompleteAccountSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try AccountInfoStorage(databaseDirectoryUrl: directory, databaseFileName: "account-info-storage-test")
        let record = try accountInfo()

        try storage.save(accountInfo: record)

        XCTAssertEqual(try storage.accountInfo(), record)
    }
}

final class SyncerStorageTests: XCTestCase {
    func testPersistsLastBlockHeightOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SyncerStorage(databaseDirectoryUrl: directory, databaseFileName: "syncer-state-storage-test")

        try storage.save(lastBlockHeight: 123)

        XCTAssertEqual(storage.lastBlockHeight, 123)
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func accountInfo() throws -> AccountInfoRecord {
    try AccountInfoRecord(
        address: "thor166aczv0jatlnyzz8zsczdzk9xxxgppfpu530jl",
        networkChainId: "thorchain-1",
        accountExists: true,
        accountNumber: 1,
        sequence: 2,
        acceptedHeight: 123,
        fetchedAt: Date(timeIntervalSince1970: 1),
        providerFamilyId: "primary",
        balances: [StoredBalance(denom: "rune", amountDecimalString: "7")]
    )
}
