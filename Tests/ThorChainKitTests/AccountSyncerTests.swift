import Foundation
@testable import ThorChainKit
import XCTest

final class AccountSyncerTests: XCTestCase {
    func testRefreshStoresAndPublishesCompleteSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try testAddress()
        let accountStorage = try AccountInfoStorage(databaseDirectoryUrl: directory, databaseFileName: "account-info-storage")
        let syncerStorage = try SyncerStorage(databaseDirectoryUrl: directory, databaseFileName: "syncer-state-storage")
        let manager = AccountInfoManager(storage: accountStorage)
        let syncer = Syncer(
            accountInfoManager: manager,
            reader: ImmediateReader(),
            storage: syncerStorage,
            address: address,
            schedule: SyncSchedule(normalInterval: 60, failureBackoff: 60)
        )

        _ = syncer.start()
        for _ in 0 ..< 100 where manager.accountState == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = syncer.stop()

        XCTAssertEqual(manager.accountState?.balances[.rune], 7)
        XCTAssertEqual(syncer.lastBlockHeight, 100)
        XCTAssertEqual(syncerStorage.lastBlockHeight, 100)
        XCTAssertEqual(try accountStorage.accountInfo()?.acceptedHeight, 100)
    }

    func testStoppedReadCannotPersistOrPublish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try testAddress()
        let storage = try AccountInfoStorage(databaseDirectoryUrl: directory, databaseFileName: "account-info-storage")
        let reader = ControlledReader()
        let manager = AccountInfoManager(storage: storage)
        let syncer = try Syncer(accountInfoManager: manager, reader: reader, storage: SyncerStorage(databaseDirectoryUrl: directory, databaseFileName: "syncer-state-storage"), address: address, schedule: SyncSchedule(normalInterval: 60, failureBackoff: 60))

        _ = syncer.start()
        for _ in 0 ..< 100 {
            if await reader.didStart { break }
            await Task.yield()
        }
        let didStart = await reader.didStart
        XCTAssertTrue(didStart)
        _ = syncer.stop()
        await reader.release()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(try storage.accountInfo())
        XCTAssertNil(manager.accountState)
    }

    func testFailedAccountReadStillStartsIndependentTransactionHistorySync() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = try testAddress()
        let transactionStorage = try TransactionStorage(databaseDirectoryUrl: directory, databaseFileName: "transactions")
        let journal = SendJournal(storage: transactionStorage, persistenceNamespace: "history")
        let pending = PendingTransactionManager(journal: journal)
        let transactionManager = TransactionManager(
            storage: transactionStorage,
            repository: TransactionRepository(storage: transactionStorage, persistenceNamespace: "history"),
            journal: journal,
            pendingTransactionManager: pending
        )
        let historyProvider = CountingHistoryProvider()
        let transactionSyncer = TransactionSyncer(
            provider: historyProvider,
            repository: TransactionRepository(storage: transactionStorage, persistenceNamespace: "history"),
            transactionManager: transactionManager,
            address: address
        )
        let accountStorage = try AccountInfoStorage(databaseDirectoryUrl: directory, databaseFileName: "account-info")
        let syncer = try Syncer(
            accountInfoManager: AccountInfoManager(storage: accountStorage),
            reader: FailingReader(),
            storage: SyncerStorage(databaseDirectoryUrl: directory, databaseFileName: "syncer-state"),
            address: address,
            transactionSyncer: transactionSyncer,
            schedule: SyncSchedule(normalInterval: 60, failureBackoff: 60)
        )

        _ = syncer.start()
        await historyProvider.waitForRequest()
        _ = syncer.stop()

        let requestCount = await historyProvider.requestCount()
        XCTAssertEqual(requestCount, 1)
    }
}

private struct ImmediateReader: IAccountProvider {
    func read(address _: Address) async throws -> AccountReadTransport {
        try AccountReadTransport(
            acceptedHeight: 100,
            account: AccountTransport(accountNumber: 1, sequence: 2),
            balances: [BalanceTransport(denom: .rune, amountDecimal: "7")],
            familyId: "primary",
            observedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private func testAddress() throws -> Address {
    try Address("thor166aczv0jatlnyzz8zsczdzk9xxxgppfpu530jl", network: .mainnet)
}

private actor ControlledReader: IAccountProvider {
    private var continuation: CheckedContinuation<AccountReadTransport, Error>?
    private(set) var didStart = false

    func read(address _: Address) async throws -> AccountReadTransport {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: try! AccountReadTransport(
            acceptedHeight: 100,
            account: AccountTransport(accountNumber: 1, sequence: 2),
            balances: [BalanceTransport(denom: .rune, amountDecimal: "7")],
            familyId: "primary",
            observedAt: Date(timeIntervalSince1970: 1)
        ))
        continuation = nil
    }
}

private struct FailingReader: IAccountProvider {
    func read(address _: Address) async throws -> AccountReadTransport {
        throw TestReadError.failed
    }
}

private enum TestReadError: Error { case failed }

private actor CountingHistoryProvider: IHistoryProvider {
    private var requests = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func fetchActions(address _: String, limit _: Int, nextPageToken _: String?, transactionID _: TransactionID?) async throws -> MidgardActionPage {
        requests += 1
        waiter?.resume()
        waiter = nil
        return MidgardActionPage(actions: [], nextPageToken: nil)
    }

    func waitForRequest() async {
        guard requests == 0 else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func requestCount() -> Int { requests }
}
