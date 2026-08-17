import Combine
import Foundation
@testable import ThorChainKit
import XCTest

final class PendingTransactionManagerTests: XCTestCase {
    func testUnknownJournalProjectsAsAvailableAndTerminalAcceptedIsNotApplicable() throws {
        let fixture = try makeJournal()
        let repository = PendingTransactionManager(journal: fixture.journal)
        guard case .ready = repository.refresh() else {
            return XCTFail("valid journal must publish a ready snapshot")
        }
        XCTAssertEqual(repository.snapshot.count, 1)
        guard case .available = repository.snapshot[0].retryAvailability else {
            return XCTFail("unknown journal rows must be retryable")
        }

        XCTAssertTrue(try fixture.journal.transition(
            transactionID: fixture.transaction.transactionID,
            from: .unknown,
            expectedGeneration: 0,
            to: .checkTxAccepted,
            generation: 1
        ))
        guard case .ready = repository.refresh() else {
            return XCTFail("accepted journal must publish a ready snapshot")
        }
        guard case .notApplicable = repository.snapshot[0].retryAvailability else {
            return XCTFail("accepted rows must not be retryable")
        }
    }

    func testRefreshFailurePreservesLastSnapshotAsDegraded() throws {
        let fixture = try makeJournal()
        let repository = PendingTransactionManager(journal: fixture.journal)
        XCTAssertEqual(repository.refresh(), .ready)
        try fixture.database.storage.write { db in
            try db.execute(sql: "DROP TABLE send_journal")
        }

        guard case .degraded = repository.refresh() else {
            return XCTFail("transaction manager refresh must install degraded status")
        }
        XCTAssertEqual(repository.snapshot.count, 1)
    }

    func testRefreshPublishesCommittedTransition() throws {
        let fixture = try makeJournal()
        let repository = PendingTransactionManager(journal: fixture.journal)
        XCTAssertEqual(repository.refresh(), .ready)
        let expectation = expectation(description: "pending refresh")
        var cancellable: AnyCancellable?
        cancellable = repository.publisher.sink { snapshot in
            if let transaction = snapshot.first,
               case .notApplicable = transaction.retryAvailability
            {
                expectation.fulfill()
                cancellable?.cancel()
            }
        }

        XCTAssertTrue(try fixture.journal.transition(
            transactionID: fixture.transaction.transactionID,
            from: .unknown,
            expectedGeneration: 0,
            to: .checkTxAccepted,
            generation: 1
        ))
        _ = repository.refresh()
        wait(for: [expectation], timeout: 2)
    }

    func testRefreshAcknowledgesBroadcastingGeneration() async throws {
        let fixture = try makeJournal()
        let barrier = PendingPublicationBarrier()
        let repository = PendingTransactionManager(journal: fixture.journal, publicationBarrier: barrier)
        XCTAssertTrue(try fixture.journal.transition(
            transactionID: fixture.transaction.transactionID,
            from: .unknown,
            expectedGeneration: 0,
            to: .broadcasting,
            generation: 7
        ))
        _ = repository.refresh()

        let acknowledged = await barrier.wait(transactionID: fixture.transaction.transactionID, generation: 7)
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(barrier.isAcknowledged(transactionID: fixture.transaction.transactionID, generation: 7))
        _ = repository
    }

    private func makeJournal() throws -> RepositoryFixture {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString).sqlite")
        let database = try TransactionStorageFixture.open(path: path.path)
        let namespace = "pending-\(UUID().uuidString)"
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let owner = Data([2, 3, 4])
        let reservations = SequenceReservationStore(storage: database.storage)
        XCTAssertTrue(try reservations.acquire(
            SequenceReservationKey(persistenceNamespace: namespace, senderPayload: sender.payload, sequence: 3),
            ownerToken: owner
        ))
        let raw = Data([0x31, 0x32])
        let transaction = SignedTransaction(txRaw: raw, transactionID: DirectSignCodec.transactionId(txRaw: raw))
        let journal = SendJournal(storage: database.storage, persistenceNamespace: namespace)
        try journal.insertBroadcasting(
            transaction: transaction,
            senderPayload: sender.payload,
            recipientPayload: recipient.payload,
            sender: sender.raw,
            recipient: recipient.raw,
            amount: Data([5]),
            denom: .rune,
            quotedNativeFee: Data([1]),
            memo: nil,
            accountNumber: 1,
            sequence: 3,
            providerFamilyID: "fixture",
            quoteHeight: 12,
            reservationOwnerToken: owner
        )
        XCTAssertTrue(try journal.transition(
            transactionID: transaction.transactionID,
            from: .broadcasting,
            expectedGeneration: 1,
            to: .unknown,
            generation: 0
        ))
        return RepositoryFixture(database: database, journal: journal, transaction: transaction)
    }
}

private struct RepositoryFixture {
    let database: TransactionStorageFixture
    let journal: SendJournal
    let transaction: SignedTransaction
}
