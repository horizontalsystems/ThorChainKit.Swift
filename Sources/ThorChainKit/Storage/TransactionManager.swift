import BigInt
import Combine
import Foundation

/// Historical counterpart of TronKit.TransactionManager. It owns the normalized
/// cache and its publication; it never owns a signer or a Cosmos sequence.
final class TransactionManager: @unchecked Sendable {
    private let storage: TransactionStorage
    private let repository: TransactionRepository
    private let journal: SendJournal
    private let pendingTransactionManager: PendingTransactionManager
    private let allTransactionsSubject = PassthroughSubject<([Transaction], Bool), Never>()
    private let transactionsSubject = PassthroughSubject<[Transaction], Never>()

    init(storage: TransactionStorage, repository: TransactionRepository, journal: SendJournal, pendingTransactionManager: PendingTransactionManager) {
        self.storage = storage
        self.repository = repository
        self.journal = journal
        self.pendingTransactionManager = pendingTransactionManager
    }

    var allTransactionsPublisher: AnyPublisher<([Transaction], Bool), Never> {
        allTransactionsSubject.eraseToAnyPublisher()
    }

    var transactionsPublisher: AnyPublisher<[Transaction], Never> {
        transactionsSubject.eraseToAnyPublisher()
    }

    func transactions(hash: String? = nil, descending: Bool = true, limit: Int? = nil) -> [Transaction] {
        (try? repository.transactions(hash: hash, descending: descending, limit: limit)) ?? []
    }

    @discardableResult
    func save(transactions: [Transaction]) throws -> [Transaction] {
        let changed = try storage.write { db in
            let changed = try repository.save(transactions, in: db)
            try journal.removeIncluded(transactionIDs: transactions.filter(\.isTerminal).map(\.transactionId), in: db)
            return changed
        }
        _ = pendingTransactionManager.refresh()
        return changed
    }

    func process(initial: Bool) {
        let transactions: [Transaction]
        do {
            transactions = try storage.write { db in
                let transactions = try repository.unprocessedTransactions(in: db)
                try repository.markProcessed(in: db)
                return transactions
            }
        } catch {
            return
        }
        guard !transactions.isEmpty else { return }
        allTransactionsSubject.send((transactions, initial))
        transactionsSubject.send(transactions)
    }

    func reconcileLocalTransactions() throws {
        let records = try journal.records()
        let pending = records.compactMap(Self.localTransaction)
        let rejected = Set(records.filter { $0.state == .rejected }.map(\.transactionID))

        let changed = try storage.write { db -> Bool in
            var changed = !(try repository.saveLocal(pending, in: db)).isEmpty
            for transactionID in rejected {
                guard let transaction = try repository.pendingTransaction(transactionID: transactionID, in: db) else { continue }
                let failed = Transaction(
                    transactionId: transaction.transactionId,
                    blockHeight: transaction.blockHeight,
                    timestamp: transaction.timestamp,
                    timestampNanoseconds: transaction.timestampNanoseconds,
                    type: transaction.type,
                    status: "failed",
                    memo: transaction.memo,
                    incoming: transaction.incoming,
                    outgoing: transaction.outgoing,
                    // The fee was charged whether or not the transaction was accepted.
                    fee: transaction.fee
                )
                changed = !(try repository.save([failed], in: db)).isEmpty || changed
            }
            return changed
        }
        _ = pendingTransactionManager.refresh()
        if changed { process(initial: false) }
    }

    private static func localTransaction(_ record: SendJournalRecord) -> Transaction? {
        let amount = BigUInt(record.amount)
        guard record.state != .rejected, amount > 0 else { return nil }
        let nanoseconds = Int64(record.createdAt.timeIntervalSince1970 * 1_000_000_000)
        // Midgard notation, because the record that replaces this one will use it. A bare
        // bank denom like "tcy" would never match its own confirmation.
        let asset = (try? Denom.asset(for: record.denom.rawValue))?.description ?? Asset.rune.description
        return Transaction(
            transactionId: record.transactionID,
            blockHeight: 0,
            timestamp: record.createdAt,
            timestampNanoseconds: nanoseconds,
            type: "send",
            status: "pending",
            memo: record.memo,
            // Midgard notation, matching the record that will replace this one once the
            // action appears: `in` is the sending side, `out` the receiving side.
            incoming: [CoinTransfer(address: record.sender, asset: asset, amount: amount)],
            // A deposit has no recipient, and a transfer to nowhere cannot be read back:
            // the stored form rejects an empty address. Writing one made the row
            // invisible until Midgard replaced it with an indexed action.
            outgoing: record.recipient.isEmpty ? [] : [CoinTransfer(address: record.recipient, asset: asset, amount: amount)],
            // Quoted at preflight and charged in RUNE whatever was sent.
            fee: record.quotedNativeFee.isEmpty ? nil : BigUInt(record.quotedNativeFee)
        )
    }
}
