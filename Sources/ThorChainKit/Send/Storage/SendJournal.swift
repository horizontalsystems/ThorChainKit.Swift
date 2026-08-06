import Foundation
import GRDB

enum SendJournalState: String, Sendable {
    case unknown
    case broadcasting
    case checkTxAccepted = "check_tx_accepted"
    case rejected
}

struct SendJournalRecord: Sendable, Equatable {
    let persistenceNamespace: String
    let transactionID: TransactionID
    let signedTxRaw: Data
    let sender: String
    let recipient: String
    let amount: Data
    // What was sent. The fee is always RUNE, so this names only the amount's asset.
    let denom: Denom
    let quotedNativeFee: Data
    let memo: String?
    let accountNumber: UInt64
    let sequence: UInt64
    let providerFamilyID: String
    let quoteHeight: Int64
    let state: SendJournalState
    let broadcastGeneration: UInt64
    let retryBlockedReason: RetryBlockedReason?
    let checkTxCode: UInt32?
    let codespace: String?
    let sanitizedLog: String?
    let createdAt: Date
    let updatedAt: Date
}

final class SendJournal: @unchecked Sendable {
    private static let recoveryLock = NSLock()
    private static var recoveredStorageNamespaces = Set<String>()

    private let storage: TransactionStorage
    let persistenceNamespace: String
    private let now: @Sendable () -> Date

    init(storage: TransactionStorage, persistenceNamespace: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage
        self.persistenceNamespace = persistenceNamespace
        self.now = now
    }

    func insertBroadcasting(
        transaction: SignedTransaction,
        senderPayload: Data,
        recipientPayload: Data?,
        sender: String,
        recipient: String,
        amount: Data,
        denom: Denom,
        quotedNativeFee: Data,
        memo: String?,
        accountNumber: UInt64,
        sequence: UInt64,
        providerFamilyID: String,
        quoteHeight: Int64,
        reservationOwnerToken: Data,
        generation: UInt64 = 1
    ) throws {
        guard !senderPayload.isEmpty, recipientPayload.map({ !$0.isEmpty }) ?? true,
              !transaction.txRaw.isEmpty, !reservationOwnerToken.isEmpty,
              generation > 0, accountNumber <= UInt64(Int64.max),
              sequence <= UInt64(Int64.max), quoteHeight > 0 else {
            throw SendError.storageUnavailable
        }
        let timestamp = now()
        try storage.write { db in
            try db.execute(
                sql: """
                INSERT INTO send_journal
                (persistence_namespace, local_hash, signed_tx_raw, sender_payload, recipient_payload,
                 sender, recipient, amount, denom, quoted_native_fee, memo, account_number, sequence,
                 provider_family_id, quote_height, state, broadcast_generation, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    persistenceNamespace, transaction.transactionID.hash, transaction.txRaw,
                    senderPayload, recipientPayload, sender, recipient, amount, denom.rawValue,
                    quotedNativeFee, memo, String(accountNumber), String(sequence),
                    providerFamilyID, String(quoteHeight), SendJournalState.broadcasting.rawValue,
                    Int64(generation), timestamp, timestamp
                ]
            )
            try db.execute(
                sql: """
                UPDATE send_sequence_reservations
                SET local_hash = ?
                WHERE persistence_namespace = ? AND sender_payload = ? AND sequence = ? AND owner_token = ?
                """,
                arguments: [transaction.transactionID.hash, persistenceNamespace, senderPayload, Int64(sequence), reservationOwnerToken]
            )
            guard db.changesCount == 1 else { throw SendError.storageUnavailable }
        }
    }

    func record(for transactionID: TransactionID) throws -> SendJournalRecord? {
        try storage.read { db in
            try row(for: transactionID, db: db).map(makeRecord)
        }
    }

    func normalizeBroadcastingToUnknown() throws -> Int {
        let changed = try storage.write { db in
            try db.execute(
                sql: "UPDATE send_journal SET state = ?, broadcast_generation = 0, updated_at = ? WHERE persistence_namespace = ? AND state = ?",
                arguments: [SendJournalState.unknown.rawValue, now(), persistenceNamespace, SendJournalState.broadcasting.rawValue]
            )
            return db.changesCount
        }
        return changed
    }

    /// Recovery is process-local and must run once per physical database and
    /// namespace. A second Kit can share that database while the first sender is
    /// active; it must not rewrite the first sender's in-flight journal rows.
    func recover() throws {
        let key = "\(storage.identity)\u{0}\(persistenceNamespace)"
        Self.recoveryLock.lock()
        guard Self.recoveredStorageNamespaces.insert(key).inserted else {
            Self.recoveryLock.unlock()
            return
        }
        Self.recoveryLock.unlock()

        do {
            try storage.write { db in
                try db.execute(
                    sql: "DELETE FROM send_sequence_reservations WHERE persistence_namespace = ? AND local_hash IS NULL",
                    arguments: [persistenceNamespace]
                )
                try db.execute(
                    sql: "UPDATE send_journal SET state = ?, broadcast_generation = 0, updated_at = ? WHERE persistence_namespace = ? AND state = ?",
                    arguments: [SendJournalState.unknown.rawValue, now(), persistenceNamespace, SendJournalState.broadcasting.rawValue]
                )
            }
        } catch {
            Self.recoveryLock.lock()
            Self.recoveredStorageNamespaces.remove(key)
            Self.recoveryLock.unlock()
            throw error
        }
    }

    func removeUnlinkedReservations() throws -> Int {
        try storage.write { db in
            try db.execute(
                sql: "DELETE FROM send_sequence_reservations WHERE persistence_namespace = ? AND local_hash IS NULL",
                arguments: [persistenceNamespace]
            )
            return db.changesCount
        }
    }

    func transition(
        transactionID: TransactionID,
        from expectedState: SendJournalState,
        expectedGeneration: UInt64,
        to state: SendJournalState,
        generation: UInt64,
        blockedReason: RetryBlockedReason? = nil,
        code: UInt32? = nil,
        codespace: String? = nil,
        sanitizedLog: String? = nil
    ) throws -> Bool {
        let changed = try storage.write { db in
            var changed = false
            try db.execute(
                sql: """
                UPDATE send_journal
                SET state = ?, broadcast_generation = ?, retry_blocked_reason = ?, check_tx_code = ?,
                    codespace = ?, sanitized_log = ?, updated_at = ?
                WHERE persistence_namespace = ? AND local_hash = ? AND state = ? AND broadcast_generation = ?
                """,
                arguments: [
                    state.rawValue, Int64(generation), blockedReason?.rawValue, code.map { Int64($0) },
                    codespace, sanitizedLog, now(), persistenceNamespace, transactionID.hash,
                    expectedState.rawValue, Int64(expectedGeneration)
                ]
            )
            guard db.changesCount == 1 else { return false }
            changed = true
            if state == .rejected {
                try db.execute(
                    sql: "DELETE FROM send_sequence_reservations WHERE persistence_namespace = ? AND local_hash = ?",
                    arguments: [persistenceNamespace, transactionID.hash]
                )
            }
            return changed
        }
        return changed
    }

    func pendingRecords() throws -> [SendJournalRecord] {
        try storage.read { db in
            try pendingRecords(in: db)
        }
    }

    func records() throws -> [SendJournalRecord] {
        try storage.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM send_journal WHERE persistence_namespace = ?",
                arguments: [persistenceNamespace]
            ).map(makeRecord)
        }
    }

    func removeIncluded(transactionIDs: [TransactionID]) throws {
        guard !transactionIDs.isEmpty else { return }
        try storage.write { db in
            try removeIncluded(transactionIDs: transactionIDs, in: db)
        }
    }

    func removeIncluded(transactionIDs: [TransactionID], in db: Database) throws {
        for transactionID in transactionIDs {
            try db.execute(
                sql: "DELETE FROM send_journal WHERE persistence_namespace = ? AND local_hash = ?",
                arguments: [persistenceNamespace, transactionID.hash]
            )
            try db.execute(
                sql: "DELETE FROM send_sequence_reservations WHERE persistence_namespace = ? AND local_hash = ?",
                arguments: [persistenceNamespace, transactionID.hash]
            )
        }
    }

    func pendingRecords(in db: Database) throws -> [SendJournalRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM send_journal WHERE persistence_namespace = ? AND state IN (?, ?, ?) ORDER BY created_at DESC, local_hash DESC",
            arguments: [persistenceNamespace, SendJournalState.unknown.rawValue, SendJournalState.broadcasting.rawValue, SendJournalState.checkTxAccepted.rawValue]
        )
        return try rows.map(makeRecord)
    }

    private func row(for transactionID: TransactionID, db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM send_journal WHERE persistence_namespace = ? AND local_hash = ?",
            arguments: [persistenceNamespace, transactionID.hash]
        )
    }

    private func makeRecord(_ row: Row) throws -> SendJournalRecord {
        guard let hash: String = row["local_hash"], let transactionID = TransactionID(hash: hash),
              let raw: Data = row["signed_tx_raw"], let sender: String = row["sender"],
              let recipient: String = row["recipient"], let amount: Data = row["amount"],
              let fee: Data = row["quoted_native_fee"], let accountString: String = row["account_number"],
              let accountNumber = UInt64(accountString), let sequenceString: String = row["sequence"],
              let sequence = UInt64(sequenceString), let family: String = row["provider_family_id"],
              let heightString: String = row["quote_height"], let height = Int64(heightString),
              let stateRaw: String = row["state"], let state = SendJournalState(rawValue: stateRaw),
              let generationValue: Int64 = row["broadcast_generation"], generationValue >= 0,
              let createdAt: Date = row["created_at"], let updatedAt: Date = row["updated_at"] else {
            throw SendError.storageUnavailable
        }
        let rawCode: Int64? = row["check_tx_code"]
        let code = rawCode.flatMap { $0 >= 0 ? UInt32(exactly: $0) : nil }
        let rawReason: String? = row["retry_blocked_reason"]
        let diagnostic: String? = row["sanitized_log"]
        let reason = rawReason.flatMap(RetryBlockedReason.init(rawValue:))
        return SendJournalRecord(
            persistenceNamespace: persistenceNamespace, transactionID: transactionID, signedTxRaw: raw,
            sender: sender, recipient: recipient, amount: amount,
            denom: try {
                // Every neighbouring field throws on unreadable data; defaulting to RUNE
                // here would turn a stored TCY send into a displayed RUNE send.
                guard let raw: String = row["denom"] else { throw SendError.storageUnavailable }
                return try Denom(rawValue: raw)
            }(),
            quotedNativeFee: fee,
            memo: row["memo"], accountNumber: accountNumber, sequence: sequence,
            providerFamilyID: family, quoteHeight: height, state: state,
            broadcastGeneration: UInt64(generationValue), retryBlockedReason: reason,
            checkTxCode: code, codespace: row["codespace"], sanitizedLog: diagnostic,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
