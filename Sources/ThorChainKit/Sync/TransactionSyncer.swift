import BigInt
import Combine
import Foundation

/// TronKit-shaped lifecycle owner with the Midgard pagination semantics used by
/// the Android THOR kit. It never signs or mutates the local send journal.
final class TransactionSyncer: @unchecked Sendable {
    private static let pageLimit = 50
    private static let maximumPageCount = 20
    private static let pendingRefreshLimit = 10

    private let provider: any IHistoryProvider
    private let repository: TransactionRepository
    private let transactionManager: TransactionManager
    private let address: Address
    private let dispatcher = DispatchQueue(label: "io.horizontalsystems.thorchain-kit.transaction-syncer")
    private let dispatcherKey = DispatchSpecificKey<UInt8>()
    private let stateSubject = CurrentValueSubject<TransactionSyncState, Never>(.notSynced(error: .notStarted))
    private var task: Task<Void, Never>?
    private var syncing = false
    private var syncID: UUID?

    private struct RecentSyncResult {
        let transactions: [Transaction]
        let hashes: Set<String>
        let reachedWatermark: Bool
        let exhausted: Bool
        let nextPageToken: String?
        let newestTimestampNanoseconds: Int64?
    }

    private struct BackfillSyncResult {
        let transactions: [Transaction]
        let nextPageToken: String?
    }

    init(provider: any IHistoryProvider, repository: TransactionRepository, transactionManager: TransactionManager, address: Address) {
        self.provider = provider
        self.repository = repository
        self.transactionManager = transactionManager
        self.address = address
        dispatcher.setSpecific(key: dispatcherKey, value: 1)
    }

    deinit {
        stop()
    }

    var state: TransactionSyncState { withDispatcher { stateSubject.value } }
    var statePublisher: AnyPublisher<TransactionSyncState, Never> { stateSubject.eraseToAnyPublisher() }

    func sync() {
        dispatcher.async { [weak self] in self?.syncOnDispatcher() }
    }

    func stop() {
        withDispatcher { stopOnDispatcher() }
    }

    private func syncOnDispatcher() {
        guard !syncing else { return }
        syncing = true
        let activeSyncID = UUID()
        syncID = activeSyncID
        stateSubject.send(.syncing)
        guard syncing, syncID == activeSyncID else { return }
        task = Task { [weak self, provider, repository, address] in
            do {
                let cursor = try repository.cursor()
                let recent = try await Self.fetchRecent(
                    provider: provider,
                    address: address,
                    cursor: cursor
                )
                try self?.commit(recent: recent, cursor: cursor, syncID: activeSyncID)
                let backfill = try await Self.fetchBackfill(
                    provider: provider,
                    address: address,
                    pageToken: repository.cursor().backfillPageToken
                )
                try self?.commit(backfill: backfill, syncID: activeSyncID)
                let pending = try await Self.fetchPending(
                    provider: provider,
                    repository: repository,
                    address: address,
                    recentHashes: recent.hashes
                )
                try self?.commit(pending: pending, syncID: activeSyncID)
                self?.finish(.synced, syncID: activeSyncID)
            } catch is CancellationError {
                self?.finish(.notSynced(error: .notStarted), syncID: activeSyncID)
            } catch {
                self?.finish(.notSynced(error: Self.map(error)), syncID: activeSyncID)
            }
        }
    }

    private static func fetchRecent(
        provider: any IHistoryProvider,
        address: Address,
        cursor: TransactionSyncCursor
    ) async throws -> RecentSyncResult {
        var updated = [Transaction]()
        var nextPageToken: String?
        var reachedWatermark = false
        var exhausted = false

        for _ in 0 ..< maximumPageCount {
            try Task.checkCancellation()
            let page = try await provider.fetchActions(
                address: address.raw,
                limit: pageLimit,
                nextPageToken: nextPageToken,
                transactionID: nil
            )
            try Task.checkCancellation()
            let transactions = try page.actions.compactMap(transaction)
            updated.append(contentsOf: transactions)
            // Midgard exposes an opaque page token but no documented secondary
            // ordering key for actions sharing the same timestamp. Keep paging
            // through the complete watermark timestamp segment; otherwise an
            // equal-timestamp action on the next page can be skipped forever.
            reachedWatermark = transactions.contains { !$0.isPending && $0.timestampNanoseconds < cursor.lastTimestampNanoseconds }
            nextPageToken = page.nextPageToken
            exhausted = page.nextPageToken == nil || page.actions.isEmpty
            if reachedWatermark || exhausted { break }
        }

        return RecentSyncResult(
            transactions: updated,
            hashes: Set(updated.map { $0.transactionId.hash }),
            reachedWatermark: reachedWatermark,
            exhausted: exhausted,
            nextPageToken: nextPageToken,
            newestTimestampNanoseconds: updated.lazy.filter { !$0.isPending }.map(\.timestampNanoseconds).max()
        )
    }

    private static func fetchBackfill(
        provider: any IHistoryProvider,
        address: Address,
        pageToken: String?
    ) async throws -> BackfillSyncResult {
        var token = pageToken
        guard token != nil else { return BackfillSyncResult(transactions: [], nextPageToken: nil) }
        var updated = [Transaction]()

        for _ in 0 ..< maximumPageCount {
            try Task.checkCancellation()
            let page = try await provider.fetchActions(
                address: address.raw,
                limit: pageLimit,
                nextPageToken: token,
                transactionID: nil
            )
            try Task.checkCancellation()
            try updated.append(contentsOf: page.actions.compactMap(transaction))
            token = page.nextPageToken
            if token == nil || page.actions.isEmpty {
                token = nil
                break
            }
        }
        return BackfillSyncResult(transactions: updated, nextPageToken: token)
    }

    private static func fetchPending(
        provider: any IHistoryProvider,
        repository: TransactionRepository,
        address: Address,
        recentHashes: Set<String>
    ) async throws -> [Transaction] {
        let stale = try repository.pendingTransactions()
            .filter { !recentHashes.contains($0.transactionId.hash) }
            .prefix(pendingRefreshLimit)
        var refreshed = [Transaction]()
        for pending in stale {
            try Task.checkCancellation()
            let page = try await provider.fetchActions(
                address: address.raw,
                limit: 10,
                nextPageToken: nil,
                transactionID: pending.transactionId
            )
            try Task.checkCancellation()
            for transaction in try page.actions.compactMap(transaction) where transaction.transactionId == pending.transactionId {
                refreshed.append(transaction)
            }
        }
        return refreshed
    }

    static func transaction(_ action: MidgardAction) throws -> Transaction? {
        guard let incoming = action.incoming, let outgoing = action.outgoing else {
            throw MidgardProviderError.invalidResponse
        }
        guard let hash = (incoming + outgoing).compactMap(\.transactionHash).first(where: { !$0.isEmpty }) else {
            return nil
        }
        guard let transactionId = TransactionID(hash: hash.uppercased()),
              let height = action.height, height >= 0,
              let nanoseconds = action.date, nanoseconds >= 0,
              let type = action.type, !type.isEmpty,
              let status = action.status, !status.isEmpty
        else {
            throw MidgardProviderError.invalidResponse
        }
        return try Transaction(
            transactionId: transactionId,
            blockHeight: height,
            timestamp: Date(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000),
            timestampNanoseconds: nanoseconds,
            type: type,
            status: status,
            memo: memo(action.metadata),
            incoming: transfers(incoming),
            outgoing: transfers(outgoing),
            fee: networkFee(action.metadata)
        )
    }

    private static func transfers(_ transactions: [MidgardActionTransaction]) throws -> [CoinTransfer] {
        try transactions.flatMap { transaction in
            guard let address = transaction.address, !address.isEmpty else {
                throw MidgardProviderError.invalidResponse
            }
            return try (transaction.coins ?? []).map { coin in
                guard let asset = coin.asset, !asset.isEmpty,
                      let amountString = coin.amount, let amount = BigUInt(amountString)
                else {
                    throw MidgardProviderError.invalidResponse
                }
                return CoinTransfer(address: address, asset: asset, amount: amount)
            }
        }
    }

    private static func memo(_ metadata: MidgardJSONValue?) -> String? {
        metadata?.object?.values.compactMap { $0.object?["memo"]?.string }.first
    }

    /// Only the amount is taken. Midgard labels a send's `networkFees` entry with the
    /// asset that moved — a TCY send reports `asset: "TCY"` — but the charge is the
    /// native fee in RUNE: the same amount appears whatever was sent. Trusting that
    /// label would show "0.2 TCY" as the fee for a 0.01 TCY transfer.
    private static func networkFee(_ metadata: MidgardJSONValue?) -> BigUInt? {
        let fees = metadata?.object?.values.compactMap { $0.object?["networkFees"]?.array }.first
        guard let entry = fees?.first, let raw = entry.object?["amount"]?.string else { return nil }
        return BigUInt(raw)
    }

    private func commit(recent: RecentSyncResult, cursor: TransactionSyncCursor, syncID: UUID) throws {
        try withActiveSync(syncID) { [self] in
            _ = try self.transactionManager.save(transactions: recent.transactions)
            if !recent.reachedWatermark, !recent.exhausted, let nextPageToken = recent.nextPageToken {
                try self.repository.save(backfillPageToken: nextPageToken)
            }
            if let newest = recent.newestTimestampNanoseconds, newest > cursor.lastTimestampNanoseconds {
                try self.repository.save(lastTimestampNanoseconds: newest)
            }
            self.transactionManager.process(initial: cursor.lastTimestampNanoseconds == 0)
        }
    }

    private func commit(backfill: BackfillSyncResult, syncID: UUID) throws {
        try withActiveSync(syncID) { [self] in
            _ = try self.transactionManager.save(transactions: backfill.transactions)
            try self.repository.save(backfillPageToken: backfill.nextPageToken)
            self.transactionManager.process(initial: false)
        }
    }

    private func commit(pending: [Transaction], syncID: UUID) throws {
        try withActiveSync(syncID) { [self] in
            _ = try self.transactionManager.save(transactions: pending)
            self.transactionManager.process(initial: false)
        }
    }

    private func withActiveSync<T>(_ expectedSyncID: UUID, _ body: @escaping () throws -> T) throws -> T {
        let guarded = { [self] in
            guard self.syncID == expectedSyncID, self.syncing, !Task.isCancelled else { throw CancellationError() }
            return try body()
        }
        if DispatchQueue.getSpecific(key: dispatcherKey) == 1 {
            return try guarded()
        }
        return try dispatcher.sync(execute: guarded)
    }

    private static func map(_ error: Error) -> TransactionSyncError {
        if error is StorageError { return .storageUnavailable }
        guard let error = error as? MidgardProviderError else { return .providerUnavailable }
        switch error {
        case .unavailable, .clientStatus: return .providerUnavailable
        case .invalidResponse: return .invalidResponse
        }
    }

    private func stopOnDispatcher() {
        task?.cancel()
        task = nil
        syncID = nil
        syncing = false
        stateSubject.send(.notSynced(error: .notStarted))
    }

    private func finish(_ state: TransactionSyncState, syncID: UUID) {
        dispatcher.async { [weak self] in
            guard let self else { return }
            guard self.syncID == syncID else { return }
            task = nil
            self.syncID = nil
            syncing = false
            stateSubject.send(state)
        }
    }

    private func withDispatcher<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: dispatcherKey) == 1 { return body() }
        return dispatcher.sync(execute: body)
    }
}
