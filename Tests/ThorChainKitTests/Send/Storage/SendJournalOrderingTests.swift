import Foundation
@testable import ThorChainKit
import XCTest

final class SendJournalOrderingTests: XCTestCase {
    func testFailedInitialCommitMakesZeroTransportCalls() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("journal-order-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try TransactionStorageFixture.open(path: path.path)
        let namespace = "journal-order-test"
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let reservations = SequenceReservationStore(storage: database.storage)
        let owner = Data([9])
        let key = SequenceReservationKey(persistenceNamespace: namespace, senderPayload: sender.payload, sequence: 1)
        XCTAssertTrue(try reservations.acquire(key, ownerToken: owner))

        let transportCalls = 0
        let journal = SendJournal(storage: database.storage, persistenceNamespace: namespace)
        let raw = Data([0xAA])
        let transaction = SignedTransaction(txRaw: raw, transactionID: DirectSignCodec.transactionId(txRaw: raw))
        XCTAssertThrowsError(try journal.insertBroadcasting(
            transaction: transaction,
            senderPayload: sender.payload,
            recipientPayload: recipient.payload,
            sender: sender.raw,
            recipient: recipient.raw,
            amount: Data([1]),
            denom: .rune,
            quotedNativeFee: Data([1]),
            memo: nil,
            accountNumber: 1,
            sequence: 1,
            providerFamilyID: "fixture",
            quoteHeight: 1,
            reservationOwnerToken: Data([8])
        ))
        XCTAssertEqual(transportCalls, 0)
        XCTAssertNil(try journal.record(for: transaction.transactionID))
    }

    func testSignedBytesAndHashAreImmutable() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("journal-immutable-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try TransactionStorageFixture.open(path: path.path)
        let namespace = "journal-immutable-test"
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let owner = Data([3, 4])
        let reservations = SequenceReservationStore(storage: database.storage)
        XCTAssertTrue(try reservations.acquire(
            SequenceReservationKey(persistenceNamespace: namespace, senderPayload: sender.payload, sequence: 2),
            ownerToken: owner
        ))

        var raw = Data([0x10, 0x20, 0x30])
        let original = raw
        let transaction = SignedTransaction(txRaw: raw, transactionID: DirectSignCodec.transactionId(txRaw: raw))
        raw[0] = 0xFF
        let journal = SendJournal(storage: database.storage, persistenceNamespace: namespace)
        try journal.insertBroadcasting(
            transaction: transaction,
            senderPayload: sender.payload,
            recipientPayload: recipient.payload,
            sender: sender.raw,
            recipient: recipient.raw,
            amount: Data([1]),
            denom: .rune,
            quotedNativeFee: Data([1]),
            memo: nil,
            accountNumber: 1,
            sequence: 2,
            providerFamilyID: "fixture",
            quoteHeight: 1,
            reservationOwnerToken: owner
        )
        let record = try XCTUnwrap(journal.record(for: transaction.transactionID))
        XCTAssertEqual(record.signedTxRaw, original)
        XCTAssertEqual(record.transactionID, transaction.transactionID)
    }

    func testReservationLinkCommitsAtomically() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try TransactionStorageFixture.open(path: path.path)
        let namespace = "journal-test"
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let owner = Data([1, 2, 3])
        let key = SequenceReservationKey(persistenceNamespace: namespace, senderPayload: sender.payload, sequence: 7)
        let reservations = SequenceReservationStore(storage: database.storage)
        XCTAssertTrue(try reservations.acquire(key, ownerToken: owner))

        let raw = Data([0x01, 0x02, 0x03])
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
            sequence: 7,
            providerFamilyID: "fixture",
            quoteHeight: 12,
            reservationOwnerToken: owner
        )

        let record = try XCTUnwrap(journal.record(for: transaction.transactionID))
        XCTAssertEqual(record.state, .broadcasting)
        XCTAssertEqual(record.signedTxRaw, raw)
        let linkedHash: String? = try database.storage.read { db in
            try String.fetchOne(db, sql: "SELECT local_hash FROM send_sequence_reservations WHERE persistence_namespace = ? AND sequence = ?", arguments: [namespace, 7])
        }
        XCTAssertEqual(linkedHash, transaction.transactionID.hash)
    }

    func testFailedReservationLinkRollsBackJournalInsert() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try TransactionStorageFixture.open(path: path.path)
        let namespace = "journal-rollback-test"
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let reservationOwner = Data([1])
        let wrongOwner = Data([2])
        let reservations = SequenceReservationStore(storage: database.storage)
        let key = SequenceReservationKey(persistenceNamespace: namespace, senderPayload: sender.payload, sequence: 8)
        XCTAssertTrue(try reservations.acquire(key, ownerToken: reservationOwner))

        let transaction = SignedTransaction(txRaw: Data([4, 5, 6]), transactionID: DirectSignCodec.transactionId(txRaw: Data([4, 5, 6])))
        let journal = SendJournal(storage: database.storage, persistenceNamespace: namespace)
        XCTAssertThrowsError(try journal.insertBroadcasting(
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
            sequence: 8,
            providerFamilyID: "fixture",
            quoteHeight: 12,
            reservationOwnerToken: wrongOwner
        ))
        XCTAssertNil(try journal.record(for: transaction.transactionID))
    }
}
