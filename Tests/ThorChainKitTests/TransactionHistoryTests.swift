import BigInt
import Combine
import Foundation
import XCTest
@testable import ThorChainKit

final class TransactionHistoryTests: XCTestCase {
    func testMidgardProviderDecodesActionStringsAndIgnoresAdditiveJSON() async throws {
        let address = try sendTestAddress()
        let hash = String(repeating: "A", count: 64)
        let response = try httpResponse(body: """
        {
          "actions": [{
            "date": "1785408389116780091", "height": "27220171",
            "type": "send", "status": "success", "ignored": {"future": true},
            "in": [{"address": "\(address.raw)", "txID": "\(hash)", "coins": [{"asset": "THOR.RUNE", "amount": "42"}]}],
            "out": [{"address": "thor1g2tj3e6a76unm26cy8x2jpxz0wysnaerasq74p", "txID": "\(hash)", "coins": [{"asset": "THOR.RUNE", "amount": "42"}]}],
            "metadata": {"send": {"memo": "memo", "future": [1, 2]}}
          }],
          "meta": {"nextPageToken": "cursor", "ignored": true}
        }
        """)
        let transport = HistoryTransport(result: response)
        let provider = MidgardProvider(
            baseURLs: [URL(string: "https://midgard.example/base/")!],
            requestTimeout: 5,
            clientId: "fixture",
            transport: transport
        )

        let page = try await provider.fetchActions(address: address.raw, limit: 50, nextPageToken: "previous", transactionID: nil)
        XCTAssertEqual(page.actions.count, 1)
        XCTAssertEqual(page.nextPageToken, "cursor")
        XCTAssertEqual(page.actions.first?.height, 27_220_171)
        XCTAssertEqual(page.actions.first?.date, 1_785_408_389_116_780_091)

        let request = await transport.request
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/base/v2/actions")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "address" })?.value, address.raw)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "50")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "nextPageToken" })?.value, "previous")
    }

    func testRepositoryPreservesBackfillTokenWhenWatermarkChanges() throws {
        let repository = try repository(namespace: "cursor")
        try repository.save(backfillPageToken: "older")
        try repository.save(lastTimestampNanoseconds: 100)
        XCTAssertEqual(try repository.cursor(), TransactionSyncCursor(lastTimestampNanoseconds: 100, backfillPageToken: "older"))

        try repository.save(backfillPageToken: nil)
        XCTAssertEqual(try repository.cursor(), TransactionSyncCursor(lastTimestampNanoseconds: 100, backfillPageToken: nil))
    }

    func testRepositoryUsesTransactionHashAsPaginationCursor() throws {
        let repository = try repository(namespace: "pagination")
        let newest = try transactionID(3)
        let middle = try transactionID(2)
        let oldest = try transactionID(1)
        try repository.save([
            transaction(id: newest, status: "success", timestamp: 300),
            transaction(id: middle, status: "success", timestamp: 200),
            transaction(id: oldest, status: "success", timestamp: 100),
        ])

        XCTAssertEqual(try repository.transactions(hash: middle.hash, descending: true, limit: nil).map(\.transactionId), [oldest])
        XCTAssertEqual(try repository.transactions(hash: middle.hash, descending: false, limit: nil).map(\.transactionId), [newest])
    }

    func testTerminalActionClearsJournalButPendingActionDoesNot() throws {
        let fixture = try journalFixture()
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)

        try manager.save(transactions: [transaction(id: fixture.transactionID, status: "pending")])
        XCTAssertEqual(try fixture.journal.pendingRecords().count, 1)

        try manager.save(transactions: [transaction(id: fixture.transactionID, status: "success")])
        XCTAssertTrue(try fixture.journal.pendingRecords().isEmpty)
        XCTAssertEqual(manager.transactions().first?.status, "success")
    }

    func testMidgardNetworkFeeIsTakenAsRuneWhateverAssetItClaims() throws {
        // Verbatim from a real mainnet action: 0.01 TCY was sent and Midgard labels the
        // fee `asset: "TCY"`, while the charge is the native RUNE fee — the identical
        // 20000000 shows up on RUNE sends too. Trusting the label would render the fee
        // as 0.2 TCY on a 0.01 TCY transfer, twenty times the amount moved.
        let json = Data(#"""
        {"date":"1785736558923059878","height":"27272536","type":"send","status":"success",
        "in":[{"address":"thor13wvcnffnln7s8g3y2wzvvukfj4y8zxe98z65ld","txID":"71113A65E42AB49C11E2B62BCDE319A5BB66B6FCAA574ECDCB38C70B50D0886F","coins":[{"amount":"1000000","asset":"TCY"}]}],
        "out":[{"address":"thor1nyvskcndxfxne0hqwceselq55anayg7a9tes5h","txID":"71113A65E42AB49C11E2B62BCDE319A5BB66B6FCAA574ECDCB38C70B50D0886F","coins":[{"amount":"1000000","asset":"TCY"}]}],
        "metadata":{"send":{"code":"0","memo":"Ere","reason":"","networkFees":[{"amount":"20000000","asset":"TCY"}]}}}
        """#.utf8)

        let action = try JSONDecoder().decode(MidgardAction.self, from: json)
        let transaction = try XCTUnwrap(TransactionSyncer.transaction(action))

        XCTAssertEqual(transaction.fee, 20_000_000)
        XCTAssertEqual(transaction.memo, "Ere")
        XCTAssertEqual(transaction.incoming.first?.asset, "TCY")
    }

    func testFeeSurvivesStorageAndIsOverwrittenOnConflict() throws {
        // The fixture never set a fee before, so the column round-trip and the
        // ON CONFLICT branch that updates it were both unreachable from tests.
        let fixture = try journalFixture(insertJournal: false)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let id = fixture.transactionID

        _ = try repository.save([transaction(id: id, status: "success", fee: 20_000_000)])
        XCTAssertEqual(try repository.transactions().first?.fee, 20_000_000)

        _ = try repository.save([transaction(id: id, status: "success", fee: 30_000_000)])
        XCTAssertEqual(try repository.transactions().first?.fee, 30_000_000)
    }

    func testJournalRoundTripsTheDenomAndFeeItWasGiven() throws {
        // Both used to be unrepresentable: the column did not exist and the local
        // projection hardcoded THOR.RUNE with no fee. The fixture wrote only .rune and
        // an empty fee, so neither branch was ever reached from a test.
        let fixture = try journalFixture(insertJournal: false)
        let tcy = try Denom(rawValue: "tcy")
        try fixture.insertBroadcasting(denom: tcy, quotedNativeFee: SendMagnitude(BigUInt(2_000_000)).data)

        let record = try XCTUnwrap(try fixture.journal.record(for: fixture.transactionID))

        XCTAssertEqual(record.denom, tcy)
        XCTAssertEqual(BigUInt(record.quotedNativeFee), 2_000_000)
    }

    func testStoredTransactionPreservesItsDate() throws {
        let fixture = try journalFixture()
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)

        let seconds: TimeInterval = 1_785_427_946.5
        try manager.save(transactions: [transaction(id: fixture.transactionID, status: "success", timestamp: seconds)])

        let stored = try XCTUnwrap(manager.transactions().first)
        XCTAssertEqual(stored.timestamp.timeIntervalSince1970, seconds, accuracy: 0.001)
        XCTAssertEqual(stored.timestampNanoseconds, Int64(seconds * 1_000_000_000))
    }

    func testUnknownActionDoesNotClearJournal() throws {
        let fixture = try journalFixture()
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)

        try manager.save(transactions: [transaction(id: fixture.transactionID, status: "unknown")])

        XCTAssertEqual(try fixture.journal.pendingRecords().count, 1)
        XCTAssertEqual(manager.transactions().first?.status, "unknown")
    }

    func testTransactionManagerPublishesOnlyUnprocessedDelta() throws {
        let fixture = try historyFixture()
        let first = transaction(id: try transactionID(1), status: "success")
        let second = transaction(id: try transactionID(2), status: "success")
        var emissions = [([Transaction], Bool)]()
        let cancellable = fixture.manager.allTransactionsPublisher.sink { emissions.append($0) }

        try fixture.manager.save(transactions: [first])
        fixture.manager.process(initial: true)
        fixture.manager.process(initial: false)
        try fixture.manager.save(transactions: [second])
        fixture.manager.process(initial: false)

        XCTAssertEqual(emissions.count, 2)
        XCTAssertEqual(emissions[0].0, [first])
        XCTAssertTrue(emissions[0].1)
        XCTAssertEqual(emissions[1].0, [second])
        XCTAssertFalse(emissions[1].1)
        withExtendedLifetime(cancellable) {}
    }

    func testLocalJournalTransactionIsPublishedThenReplacedByMidgard() throws {
        let fixture = try journalFixture()
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)
        var emissions = [[Transaction]]()
        let cancellable = manager.transactionsPublisher.sink { emissions.append($0) }

        try manager.reconcileLocalTransactions()

        XCTAssertEqual(manager.transactions().first?.transactionId, fixture.transactionID)
        XCTAssertEqual(manager.transactions().first?.status, "pending")
        XCTAssertEqual(emissions.last?.first?.status, "pending")

        try manager.save(transactions: [transaction(id: fixture.transactionID, status: "success")])
        manager.process(initial: false)

        XCTAssertEqual(manager.transactions().first?.status, "success")
        XCTAssertTrue(try fixture.journal.pendingRecords().isEmpty)
        XCTAssertEqual(emissions.last?.first?.status, "success")
        withExtendedLifetime(cancellable) {}
    }

    func testADepositIsPublishedAsPendingBeforeMidgardEverSeesIt() throws {
        // A swap of RUNE is a deposit: it has no recipient. The row still has to reach
        // the transactions tab the moment it is journaled, not when Midgard indexes it.
        let fixture = try journalFixture(insertJournal: false)
        try fixture.insertBroadcasting(asDeposit: true)
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)
        var emissions = [[Transaction]]()
        let cancellable = manager.transactionsPublisher.sink { emissions.append($0) }
        try manager.reconcileLocalTransactions()

        XCTAssertEqual(emissions.last?.first?.transactionId, fixture.transactionID)
        XCTAssertEqual(emissions.last?.first?.status, "pending")
        XCTAssertEqual(emissions.last?.first?.incoming.first?.address, fixture.sender.raw)
        withExtendedLifetime(cancellable) {}
    }

    func testRejectedLocalJournalTransactionBecomesFailedHistoryRecord() throws {
        let fixture = try journalFixture()
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)

        try manager.save(transactions: [transaction(id: fixture.transactionID, status: "pending")])
        try manager.reconcileLocalTransactions()
        XCTAssertEqual(manager.transactions().first?.status, "pending")

        XCTAssertTrue(try fixture.journal.transition(
            transactionID: fixture.transactionID,
            from: .broadcasting,
            expectedGeneration: 1,
            to: .rejected,
            generation: 0
        ))
        try manager.reconcileLocalTransactions()

        XCTAssertEqual(manager.transactions().first?.status, "failed")
        XCTAssertTrue(try fixture.journal.pendingRecords().isEmpty)
    }

    func testTerminalHistoryAndJournalReconciliationRollBackTogether() throws {
        let fixture = try journalFixture()
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)
        try fixture.storage.write { db in
            try db.execute(sql: "CREATE TRIGGER prevent_history_reconciliation BEFORE DELETE ON send_journal BEGIN SELECT RAISE(ABORT, 'test'); END")
        }

        XCTAssertThrowsError(try manager.save(transactions: [transaction(id: fixture.transactionID, status: "success")]))
        XCTAssertTrue(try repository.transactions().isEmpty)
        XCTAssertEqual(try fixture.journal.pendingRecords().count, 1)
    }

    func testSyncerRechecksPendingHashOutsideRecentPage() throws {
        let fixture = try journalFixture()
        let pending = PendingTransactionManager(journal: fixture.journal)
        let repository = TransactionRepository(storage: fixture.storage, persistenceNamespace: fixture.namespace)
        let manager = TransactionManager(storage: fixture.storage, repository: repository, journal: fixture.journal, pendingTransactionManager: pending)
        let provider = HistoryProvider(
            pending: action(id: fixture.transactionID, status: "pending"),
            confirmed: action(id: fixture.transactionID, status: "success")
        )
        let syncer = TransactionSyncer(provider: provider, repository: repository, transactionManager: manager, address: try sendTestAddress())
        let first = expectation(description: "first sync")
        let second = expectation(description: "second sync")
        var syncedCount = 0
        let cancellable = syncer.statePublisher.sink { state in
            guard state == .synced else { return }
            syncedCount += 1
            if syncedCount == 1 { first.fulfill() }
            if syncedCount == 2 { second.fulfill() }
        }

        syncer.sync()
        wait(for: [first], timeout: 2)
        XCTAssertEqual(manager.transactions().first?.status, "pending")
        XCTAssertEqual(try fixture.journal.pendingRecords().count, 1)

        syncer.sync()
        wait(for: [second], timeout: 2)
        XCTAssertEqual(manager.transactions().first?.status, "success")
        XCTAssertTrue(try fixture.journal.pendingRecords().isEmpty)
        _ = cancellable
    }

    func testSyncerStopsRecentPagingAtTerminalWatermark() async throws {
        let fixture = try historyFixture()
        let repository = fixture.repository
        try repository.save(lastTimestampNanoseconds: 123_000_000_000)
        let provider = ScriptedHistoryProvider { request in
            XCTAssertNil(request.transactionID)
            return MidgardActionPage(
                actions: [self.action(id: try self.transactionID(3), status: "success", nanoseconds: 122_999_999_999)],
                nextPageToken: "must-not-be-requested"
            )
        }
        let syncer = TransactionSyncer(provider: provider, repository: repository, transactionManager: fixture.manager, address: try sendTestAddress())

        await waitForState(.synced, syncer: syncer)

        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testSyncerContinuesThroughActionsAtWatermarkTimestamp() async throws {
        let fixture = try historyFixture()
        let watermark = 123_000_000_000 as Int64
        try fixture.repository.save(lastTimestampNanoseconds: watermark)
        let provider = ScriptedHistoryProvider { request in
            switch request.nextPageToken {
            case nil:
                return MidgardActionPage(
                    actions: [self.action(id: try self.transactionID(9), status: "success", nanoseconds: watermark)],
                    nextPageToken: "same-timestamp"
                )
            case "same-timestamp":
                return MidgardActionPage(
                    actions: [self.action(id: try self.transactionID(8), status: "success", nanoseconds: watermark)],
                    nextPageToken: "older"
                )
            case "older":
                return MidgardActionPage(
                    actions: [self.action(id: try self.transactionID(7), status: "success", nanoseconds: watermark - 1)],
                    nextPageToken: nil
                )
            default:
                XCTFail("unexpected page token")
                return MidgardActionPage(actions: [], nextPageToken: nil)
            }
        }
        let syncer = TransactionSyncer(provider: provider, repository: fixture.repository, transactionManager: fixture.manager, address: try sendTestAddress())

        await waitForState(.synced, syncer: syncer)

        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try fixture.repository.cursor().lastTimestampNanoseconds, watermark)
        XCTAssertEqual(Set(try fixture.repository.transactions().map(\.transactionId)), [try transactionID(9), try transactionID(8), try transactionID(7)])
    }

    func testSyncerDoesNotRecheckPendingActionSeenInRecentPage() async throws {
        let fixture = try historyFixture()
        let pending = transaction(id: try transactionID(4), status: "pending")
        let provider = ScriptedHistoryProvider { request in
            XCTAssertNil(request.transactionID)
            return MidgardActionPage(actions: [self.action(id: pending.transactionId, status: "pending")], nextPageToken: nil)
        }
        let syncer = TransactionSyncer(provider: provider, repository: fixture.repository, transactionManager: fixture.manager, address: try sendTestAddress())

        await waitForState(.synced, syncer: syncer)

        let requests = await provider.requests()
        XCTAssertFalse(requests.contains { $0.transactionID != nil })
    }

    func testSyncerLimitsStalePendingRechecksToTen() async throws {
        let fixture = try historyFixture()
        try fixture.repository.save((1 ... 11).map { transaction(id: try! transactionID($0 + 10), status: "pending") })
        let provider = ScriptedHistoryProvider { _ in MidgardActionPage(actions: [], nextPageToken: nil) }
        let syncer = TransactionSyncer(provider: provider, repository: fixture.repository, transactionManager: fixture.manager, address: try sendTestAddress())

        await waitForState(.synced, syncer: syncer)

        let requests = await provider.requests()
        XCTAssertEqual(requests.filter { $0.transactionID == nil }.count, 1)
        XCTAssertEqual(requests.filter { $0.transactionID != nil }.count, 10)
    }

    func testPageCapPersistsBackfillTokenBeforeBackfillFailure() async throws {
        let fixture = try historyFixture()
        let provider = PageCapHistoryProvider(action: try action(id: transactionID(42), status: "success"))
        let syncer = TransactionSyncer(provider: provider, repository: fixture.repository, transactionManager: fixture.manager, address: try sendTestAddress())

        await waitForState(.notSynced(error: .providerUnavailable), syncer: syncer)

        XCTAssertEqual(try fixture.repository.cursor().backfillPageToken, "backfill")
        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 21)
    }

    func testReentrantStopFromStateSubscriberDoesNotStartHistoryRequest() async throws {
        let fixture = try historyFixture()
        let provider = ScriptedHistoryProvider { _ in MidgardActionPage(actions: [], nextPageToken: nil) }
        let syncer = TransactionSyncer(provider: provider, repository: fixture.repository, transactionManager: fixture.manager, address: try sendTestAddress())
        let stopped = expectation(description: "reentrant stop")
        let cancellable = syncer.statePublisher.sink { state in
            guard state == .syncing else { return }
            syncer.stop()
            stopped.fulfill()
        }

        syncer.sync()
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertEqual(syncer.state, .notSynced(error: .notStarted))
        let requests = await provider.requests()
        XCTAssertTrue(requests.isEmpty)
        withExtendedLifetime(cancellable) {}
    }

    func testCancelledOldSyncCannotOverwriteNewSyncState() async throws {
        let fixture = try historyFixture()
        let oldTimestamp: Int64 = 100_000_000_000
        let newTimestamp: Int64 = 200_000_000_000
        let provider = GateHistoryProvider(
            firstPage: MidgardActionPage(actions: [try action(id: transactionID(1), status: "success", nanoseconds: oldTimestamp)], nextPageToken: nil),
            followingPage: MidgardActionPage(actions: [try action(id: transactionID(2), status: "success", nanoseconds: newTimestamp)], nextPageToken: nil)
        )
        let syncer = TransactionSyncer(provider: provider, repository: fixture.repository, transactionManager: fixture.manager, address: try sendTestAddress())
        let newSyncCompleted = expectation(description: "new sync completed")
        let obsoleteCompletion = expectation(description: "old sync changed state")
        obsoleteCompletion.isInverted = true
        let gate = StateEventGate()
        let cancellable = syncer.statePublisher.sink { state in
            if state == .synced { newSyncCompleted.fulfill() }
            if case .notSynced = state, gate.isArmed { obsoleteCompletion.fulfill() }
        }

        syncer.sync()
        await provider.waitForFirstRequest()
        syncer.stop()
        syncer.sync()
        await fulfillment(of: [newSyncCompleted], timeout: 2)
        XCTAssertEqual(try fixture.repository.cursor().lastTimestampNanoseconds, newTimestamp)

        gate.arm()
        await provider.releaseFirstRequest()
        await fulfillment(of: [obsoleteCompletion], timeout: 0.2)
        XCTAssertEqual(syncer.state, .synced)
        XCTAssertEqual(try fixture.repository.cursor().lastTimestampNanoseconds, newTimestamp)
        withExtendedLifetime(cancellable) {}
    }

    func testSecondSenderDoesNotRepeatJournalRecoveryForSameDatabase() throws {
        let fixture = try journalFixture(insertJournal: false)
        _ = TransactionSender(
            address: try sendTestAddress(),
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            reservationStore: SequenceReservationStore(storage: fixture.storage)
        )
        try fixture.insertBroadcasting()

        _ = TransactionSender(
            address: try sendTestAddress(),
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            reservationStore: SequenceReservationStore(storage: fixture.storage)
        )

        XCTAssertEqual(try fixture.journal.record(for: fixture.transactionID)?.state, .broadcasting)
    }

    private func repository(namespace: String) throws -> TransactionRepository {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite").path
        let storage = try TransactionStorage(path: path)
        return TransactionRepository(storage: storage, persistenceNamespace: namespace)
    }

    private func historyFixture() throws -> HistoryFixture {
        let journal = try journalFixture(insertJournal: false)
        let pending = PendingTransactionManager(journal: journal.journal)
        let repository = TransactionRepository(storage: journal.storage, persistenceNamespace: journal.namespace)
        let manager = TransactionManager(storage: journal.storage, repository: repository, journal: journal.journal, pendingTransactionManager: pending)
        return HistoryFixture(repository: repository, manager: manager)
    }

    private func journalFixture(insertJournal: Bool = true) throws -> JournalFixture {
        let storage = try TransactionStorage(path: FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite").path)
        let namespace = "history"
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let transactionID = try XCTUnwrap(TransactionID(hash: String(repeating: "B", count: 64)))
        let owner = Data([1])
        let journal = SendJournal(storage: storage, persistenceNamespace: namespace)
        let fixture = JournalFixture(storage: storage, namespace: namespace, journal: journal, transactionID: transactionID, sender: sender, recipient: recipient, owner: owner)
        if insertJournal { try fixture.insertBroadcasting() }
        return fixture
    }

    private func transaction(id: TransactionID, status: String, timestamp: TimeInterval = 123, fee: BigUInt? = nil) -> Transaction {
        Transaction(
            transactionId: id,
            blockHeight: 123,
            timestamp: Date(timeIntervalSince1970: timestamp),
            type: "send",
            status: status,
            memo: "memo",
            incoming: [CoinTransfer(address: "sender", asset: "THOR.RUNE", amount: 42)],
            outgoing: [CoinTransfer(address: "recipient", asset: "THOR.RUNE", amount: 42)],
            fee: fee
        )
    }

    private func action(id: TransactionID, status: String, nanoseconds: Int64 = 123_000_000_000) -> MidgardAction {
        try! JSONDecoder().decode(MidgardAction.self, from: Data("""
        {"date":"\(nanoseconds)","height":"123","type":"send","status":"\(status)","in":[{"address":"sender","txID":"\(id.hash)","coins":[{"asset":"THOR.RUNE","amount":"42"}]}],"out":[{"address":"recipient","txID":"\(id.hash)","coins":[{"asset":"THOR.RUNE","amount":"42"}]}]}
        """.utf8))
    }

    private func transactionID(_ value: Int) throws -> TransactionID {
        try XCTUnwrap(TransactionID(hash: String(format: "%064X", value)))
    }

    private func waitForState(_ expected: TransactionSyncState, syncer: TransactionSyncer) async {
        let fulfilled = expectation(description: "transaction sync \(expected)")
        let cancellable = syncer.statePublisher.sink { state in
            if state == expected { fulfilled.fulfill() }
        }
        syncer.sync()
        await fulfillment(of: [fulfilled], timeout: 2)
        withExtendedLifetime(cancellable) {}
    }

    private func httpResponse(body: String) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(URL(string: "https://midgard.example/base/v2/actions"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}

private struct JournalFixture {
    let storage: TransactionStorage
    let namespace: String
    let journal: SendJournal
    let transactionID: TransactionID
    let sender: Address
    let recipient: Address
    let owner: Data

    func insertBroadcasting(denom: Denom = .rune, quotedNativeFee: Data = Data(), asDeposit: Bool = false) throws {
        let reservations = SequenceReservationStore(storage: storage)
        XCTAssertTrue(try reservations.acquire(SequenceReservationKey(persistenceNamespace: namespace, senderPayload: sender.payload, sequence: 7), ownerToken: owner))
        try journal.insertBroadcasting(
            transaction: SignedTransaction(txRaw: Data([1, 2]), transactionID: transactionID),
            senderPayload: sender.payload,
            recipientPayload: asDeposit ? nil : recipient.payload,
            sender: sender.raw,
            recipient: asDeposit ? "" : recipient.raw,
            amount: Data([42]),
            denom: denom,
            quotedNativeFee: quotedNativeFee,
            memo: "memo",
            accountNumber: 1,
            sequence: 7,
            providerFamilyID: "fixture",
            quoteHeight: 123,
            reservationOwnerToken: owner
        )
    }
}

private struct HistoryFixture {
    let repository: TransactionRepository
    let manager: TransactionManager
}

private struct HistoryRequest: Sendable {
    let nextPageToken: String?
    let transactionID: TransactionID?
}

private actor ScriptedHistoryProvider: IHistoryProvider {
    private let response: @Sendable (HistoryRequest) throws -> MidgardActionPage
    private var recordedRequests = [HistoryRequest]()

    init(response: @escaping @Sendable (HistoryRequest) throws -> MidgardActionPage) {
        self.response = response
    }

    func fetchActions(address: String, limit: Int, nextPageToken: String?, transactionID: TransactionID?) async throws -> MidgardActionPage {
        let request = HistoryRequest(nextPageToken: nextPageToken, transactionID: transactionID)
        recordedRequests.append(request)
        return try response(request)
    }

    func requests() -> [HistoryRequest] { recordedRequests }
}

private actor PageCapHistoryProvider: IHistoryProvider {
    private let action: MidgardAction
    private var recordedRequests = [HistoryRequest]()

    init(action: MidgardAction) {
        self.action = action
    }

    func fetchActions(address: String, limit: Int, nextPageToken: String?, transactionID: TransactionID?) async throws -> MidgardActionPage {
        let request = HistoryRequest(nextPageToken: nextPageToken, transactionID: transactionID)
        recordedRequests.append(request)
        if nextPageToken == "backfill" { throw MidgardProviderError.unavailable }
        let next = recordedRequests.count == 20 ? "backfill" : "recent-\(recordedRequests.count)"
        return MidgardActionPage(actions: [action], nextPageToken: next)
    }

    func requests() -> [HistoryRequest] { recordedRequests }
}

private actor GateHistoryProvider: IHistoryProvider {
    private let firstPage: MidgardActionPage
    private let followingPage: MidgardActionPage
    private var firstRequestStarted = false
    private var firstRequestWaiter: CheckedContinuation<Void, Never>?
    private var firstRequestRelease: CheckedContinuation<Void, Never>?

    init(firstPage: MidgardActionPage, followingPage: MidgardActionPage) {
        self.firstPage = firstPage
        self.followingPage = followingPage
    }

    func fetchActions(address: String, limit: Int, nextPageToken: String?, transactionID: TransactionID?) async throws -> MidgardActionPage {
        guard !firstRequestStarted else { return followingPage }
        firstRequestStarted = true
        firstRequestWaiter?.resume()
        firstRequestWaiter = nil
        await withCheckedContinuation { firstRequestRelease = $0 }
        return firstPage
    }

    func waitForFirstRequest() async {
        guard !firstRequestStarted else { return }
        await withCheckedContinuation { firstRequestWaiter = $0 }
    }

    func releaseFirstRequest() {
        firstRequestRelease?.resume()
        firstRequestRelease = nil
    }
}

private final class StateEventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed
    }

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }
}

private actor HistoryTransport: IHttpTransport {
    let result: (Data, HTTPURLResponse)
    private(set) var request: URLRequest?

    init(result: (Data, HTTPURLResponse)) { self.result = result }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return result
    }
}

private actor HistoryProvider: IHistoryProvider {
    private let pending: MidgardAction
    private let confirmed: MidgardAction
    private var recentRequests = 0

    init(pending: MidgardAction, confirmed: MidgardAction) {
        self.pending = pending
        self.confirmed = confirmed
    }

    func fetchActions(address: String, limit: Int, nextPageToken: String?, transactionID: TransactionID?) async throws -> MidgardActionPage {
        if transactionID != nil {
            return MidgardActionPage(actions: [confirmed], nextPageToken: nil)
        }
        recentRequests += 1
        return MidgardActionPage(actions: recentRequests == 1 ? [pending] : [], nextPageToken: nil)
    }
}
