import BigInt
import Foundation
import GRDB

struct TransactionSyncCursor: Equatable, Sendable {
    let lastTimestampNanoseconds: Int64
    let backfillPageToken: String?
}

/// The persisted source for the Midgard transaction projection and its cursor.
/// Keeping the watermark and continuation token in this repository prevents one
/// write from accidentally discarding the other.
final class TransactionRepository: @unchecked Sendable {
    private let storage: TransactionStorage
    private let persistenceNamespace: String

    init(storage: TransactionStorage, persistenceNamespace: String) {
        self.storage = storage
        self.persistenceNamespace = persistenceNamespace
    }

    func transactions(hash: String? = nil, descending: Bool = true, limit: Int? = nil) throws -> [Transaction] {
        guard limit.map({ $0 > 0 }) ?? true else { return [] }
        return try storage.read { db in
            var sql = "SELECT tx_hash, block_height, timestamp, type, status, memo, incoming, outgoing, fee FROM transactions WHERE persistence_namespace = ?"
            var arguments: [any DatabaseValueConvertible] = [persistenceNamespace]
            if let hash,
               let cursor = try Row.fetchOne(
                   db,
                   sql: "SELECT timestamp, tx_hash FROM transactions WHERE persistence_namespace = ? AND tx_hash = ?",
                   arguments: [persistenceNamespace, hash]
               ),
               let timestamp: Int64 = cursor["timestamp"],
               let transactionHash: String = cursor["tx_hash"]
            {
                let comparison = descending ? "<" : ">"
                sql += " AND (timestamp \(comparison) ? OR (timestamp = ? AND tx_hash \(comparison) ?))"
                arguments.append(timestamp)
                arguments.append(timestamp)
                arguments.append(transactionHash)
            }
            let order = descending ? "DESC" : "ASC"
            sql += " ORDER BY timestamp \(order), tx_hash \(order)"
            if let limit {
                sql += " LIMIT \(limit)"
            }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(Self.transaction)
        }
    }

    func pendingTransactions() throws -> [Transaction] {
        try storage.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT tx_hash, block_height, timestamp, type, status, memo, incoming, outgoing, fee FROM transactions WHERE persistence_namespace = ? AND status = ? ORDER BY timestamp DESC, tx_hash DESC",
                arguments: [persistenceNamespace, "pending"]
            ).map(Self.transaction)
        }
    }

    @discardableResult
    func save(_ transactions: [Transaction]) throws -> [Transaction] {
        guard !transactions.isEmpty else { return [] }
        return try storage.write { db in
            try save(transactions, in: db)
        }
    }

    func save(_ transactions: [Transaction], in db: Database) throws -> [Transaction] {
        var changed = [Transaction]()
        for transaction in transactions {
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT tx_hash, block_height, timestamp, type, status, memo, incoming, outgoing, fee FROM transactions WHERE persistence_namespace = ? AND tx_hash = ?",
                arguments: [persistenceNamespace, transaction.transactionId.hash]
            ),
                let persisted = try? Self.transaction(existing),
                persisted == transaction
            {
                continue
            }
            try db.execute(
                sql: """
                INSERT INTO transactions
                (persistence_namespace, tx_hash, block_height, timestamp, type, status, memo, incoming, outgoing, fee, processed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(persistence_namespace, tx_hash) DO UPDATE SET
                    block_height = excluded.block_height,
                    timestamp = excluded.timestamp,
                    type = excluded.type,
                    status = excluded.status,
                    memo = excluded.memo,
                    incoming = excluded.incoming,
                    outgoing = excluded.outgoing,
                    fee = excluded.fee,
                    processed = 0
                """,
                arguments: [
                    persistenceNamespace,
                    transaction.transactionId.hash,
                    transaction.blockHeight,
                    transaction.timestampNanoseconds,
                    transaction.type,
                    transaction.status,
                    transaction.memo,
                    Self.transferData(transaction.incoming),
                    Self.transferData(transaction.outgoing),
                    transaction.fee.map(String.init),
                ]
            )
            changed.append(transaction)
        }
        return changed
    }

    func saveLocal(_ transactions: [Transaction], in db: Database) throws -> [Transaction] {
        var inserted = [Transaction]()
        for transaction in transactions {
            try db.execute(
                sql: """
                INSERT INTO transactions
                (persistence_namespace, tx_hash, block_height, timestamp, type, status, memo, incoming, outgoing, fee, processed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(persistence_namespace, tx_hash) DO NOTHING
                """,
                arguments: [
                    persistenceNamespace,
                    transaction.transactionId.hash,
                    transaction.blockHeight,
                    transaction.timestampNanoseconds,
                    transaction.type,
                    transaction.status,
                    transaction.memo,
                    Self.transferData(transaction.incoming),
                    Self.transferData(transaction.outgoing),
                    transaction.fee.map(String.init),
                ]
            )
            if db.changesCount == 1 { inserted.append(transaction) }
        }
        return inserted
    }

    func unprocessedTransactions() throws -> [Transaction] {
        try storage.read { db in
            try unprocessedTransactions(in: db)
        }
    }

    func unprocessedTransactions(in db: Database) throws -> [Transaction] {
        try Row.fetchAll(
            db,
            sql: "SELECT tx_hash, block_height, timestamp, type, status, memo, incoming, outgoing, fee FROM transactions WHERE persistence_namespace = ? AND processed = 0",
            arguments: [persistenceNamespace]
        ).map(Self.transaction)
    }

    func pendingTransaction(transactionID: TransactionID, in db: Database) throws -> Transaction? {
        try Row.fetchOne(
            db,
            sql: "SELECT tx_hash, block_height, timestamp, type, status, memo, incoming, outgoing, fee FROM transactions WHERE persistence_namespace = ? AND tx_hash = ? AND status = ?",
            arguments: [persistenceNamespace, transactionID.hash, "pending"]
        ).map(Self.transaction)
    }

    func markProcessed(in db: Database) throws {
        try db.execute(
            sql: "UPDATE transactions SET processed = 1 WHERE persistence_namespace = ? AND processed = 0",
            arguments: [persistenceNamespace]
        )
    }

    func cursor() throws -> TransactionSyncCursor {
        try storage.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT last_timestamp, backfill_page_token FROM transaction_sync_state WHERE persistence_namespace = ?",
                arguments: [persistenceNamespace]
            ) else {
                return TransactionSyncCursor(lastTimestampNanoseconds: 0, backfillPageToken: nil)
            }
            guard let timestamp: Int64 = row["last_timestamp"], timestamp >= 0 else { throw StorageError.invalid }
            return TransactionSyncCursor(lastTimestampNanoseconds: timestamp, backfillPageToken: row["backfill_page_token"])
        }
    }

    func save(lastTimestampNanoseconds: Int64) throws {
        guard lastTimestampNanoseconds >= 0 else { throw StorageError.invalid }
        try storage.write { db in
            let current = try Self.cursor(db: db, namespace: persistenceNamespace)
            try db.execute(
                sql: "INSERT OR REPLACE INTO transaction_sync_state (persistence_namespace, last_timestamp, backfill_page_token) VALUES (?, ?, ?)",
                arguments: [persistenceNamespace, lastTimestampNanoseconds, current.backfillPageToken]
            )
        }
    }

    func save(backfillPageToken: String?) throws {
        try storage.write { db in
            let current = try Self.cursor(db: db, namespace: persistenceNamespace)
            try db.execute(
                sql: "INSERT OR REPLACE INTO transaction_sync_state (persistence_namespace, last_timestamp, backfill_page_token) VALUES (?, ?, ?)",
                arguments: [persistenceNamespace, current.lastTimestampNanoseconds, backfillPageToken]
            )
        }
    }

    private static func cursor(db: Database, namespace: String) throws -> TransactionSyncCursor {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT last_timestamp, backfill_page_token FROM transaction_sync_state WHERE persistence_namespace = ?",
            arguments: [namespace]
        ) else {
            return TransactionSyncCursor(lastTimestampNanoseconds: 0, backfillPageToken: nil)
        }
        guard let timestamp: Int64 = row["last_timestamp"], timestamp >= 0 else { throw StorageError.invalid }
        return TransactionSyncCursor(lastTimestampNanoseconds: timestamp, backfillPageToken: row["backfill_page_token"])
    }

    private static func transaction(_ row: Row) throws -> Transaction {
        guard let hash: String = row["tx_hash"], let transactionId = TransactionID(hash: hash),
              let height: Int64 = row["block_height"], height >= 0,
              let timestamp: Int64 = row["timestamp"], timestamp >= 0,
              let type: String = row["type"], !type.isEmpty,
              let status: String = row["status"], !status.isEmpty,
              let incoming: Data = row["incoming"],
              let outgoing: Data = row["outgoing"]
        else {
            throw StorageError.invalid
        }
        let feeRaw: String? = row["fee"]
        return try Transaction(
            transactionId: transactionId,
            blockHeight: height,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000_000_000),
            timestampNanoseconds: timestamp,
            type: type,
            status: status,
            memo: row["memo"],
            incoming: transfers(incoming),
            outgoing: transfers(outgoing),
            fee: feeRaw.flatMap { BigUInt($0) }
        )
    }

    private static func transferData(_ transfers: [CoinTransfer]) throws -> Data {
        try JSONEncoder().encode(transfers.map(PersistedTransfer.init))
    }

    private static func transfers(_ data: Data) throws -> [CoinTransfer] {
        try JSONDecoder().decode([PersistedTransfer].self, from: data).map { transfer in
            guard let amount = BigUInt(transfer.amount), !transfer.address.isEmpty, !transfer.asset.isEmpty else {
                throw StorageError.invalid
            }
            return CoinTransfer(address: transfer.address, asset: transfer.asset, amount: amount)
        }
    }
}

private struct PersistedTransfer: Codable {
    let address: String
    let asset: String
    let amount: String

    init(_ transfer: CoinTransfer) {
        address = transfer.address
        asset = transfer.asset
        amount = transfer.amount.description
    }
}
