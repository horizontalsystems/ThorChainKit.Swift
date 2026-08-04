import Combine
import Foundation

final class Syncer: @unchecked Sendable {
    private let dispatcher: DispatchQueue
    private let dispatcherKey = DispatchSpecificKey<UInt8>()
    private let address: Address
    private let reader: any IAccountProvider
    private let accountInfoManager: AccountInfoManager
    private let storage: SyncerStorage
    private let transactionSyncer: TransactionSyncer?
    private let schedule: SyncSchedule
    private let publishing = StatePublishing()

    private var running = false
    private var generation: UInt64 = 0
    private var loopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshInFlight = false

    init(
        accountInfoManager: AccountInfoManager,
        reader: any IAccountProvider,
        storage: SyncerStorage,
        address: Address,
        transactionSyncer: TransactionSyncer? = nil,
        schedule: SyncSchedule = .default,
        dispatcher: DispatchQueue = DispatchQueue(label: "io.horizontalsystems.thorchain-kit.syncer")
    ) {
        self.accountInfoManager = accountInfoManager
        self.reader = reader
        self.storage = storage
        self.address = address
        self.transactionSyncer = transactionSyncer
        self.schedule = schedule
        self.dispatcher = dispatcher
        dispatcher.setSpecific(key: dispatcherKey, value: 1)
        publishing.apply(StateSnapshot(accountState: nil, syncState: .idle(cached: false), lastBlockHeight: storage.lastBlockHeight))
    }

    // The loop holds `self` weakly, so nothing cancels it once this object goes away —
    // it would wake every interval forever. Ownership ends the sync, as in TronKit.
    deinit {
        _ = stop()
    }

    var lastBlockHeight: Int64? { withDispatcher { publishing.snapshot.lastBlockHeight } }
    var state: SyncState { withDispatcher { publishing.snapshot.syncState } }
    var lastBlockHeightPublisher: AnyPublisher<Int64?, Never> { publishing.lastBlockHeightSubject.eraseToAnyPublisher() }
    var statePublisher: AnyPublisher<SyncState, Never> { publishing.syncStateSubject.eraseToAnyPublisher() }

    func start() -> UInt64 {
        withDispatcher {
            guard !running else { return generation }
            generation &+= 1
            let activeGeneration = generation
            running = true
            do {
                try accountInfoManager.handleCached(address: address)
                publish(.idle(cached: accountInfoManager.accountState != nil))
            } catch {
                publish(.notSynced(.storageUnavailable, cached: accountInfoManager.accountState))
            }
            loopTask = Task { [weak self] in
                self?.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(self?.schedule.normalInterval ?? 60) * 1_000_000_000)
                    self?.refresh()
                }
            }
            return activeGeneration
        }
    }

    func stop() -> UInt64? {
        withDispatcher {
            guard running else { return nil }
            let activeGeneration = generation
            running = false
            generation &+= 1
            loopTask?.cancel()
            loopTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            refreshInFlight = false
            publish(.idle(cached: accountInfoManager.accountState != nil))
            return activeGeneration
        }
    }

    func refresh() {
        dispatcher.async { [weak self] in self?.refreshOnDispatcher() }
    }

    private func refreshOnDispatcher() {
        guard running else { return }
        // A tick landing on a running refresh is dropped, not queued: replaying it the
        // moment the slow one finishes turns a bad network into back-to-back syncing with
        // no pause at all. The Android kit drops it the same way.
        if refreshInFlight { return }
        refreshInFlight = true
        let activeGeneration = generation
        // A tick never downgrades a synced state: announcing every refresh made the
        // balance blink into "syncing" every fifteen seconds. TronKit and the Android
        // kit both set Syncing only when the timer becomes ready, never per tick.
        if case .synced = publishing.snapshot.syncState {} else {
            publish(.syncing(previous: accountInfoManager.accountState))
        }
        // Midgard history is independent of the THORNode account/balance read.
        // This mirrors TronKit: a failed balance refresh must not leave history stale.
        transactionSyncer?.sync()
        refreshTask = Task { [weak self, reader, address] in
            do {
                let read = try await reader.read(address: address)
                self?.dispatcher.async { self?.handle(read: read, generation: activeGeneration) }
            } catch {
                self?.dispatcher.async { self?.handle(error: error, generation: activeGeneration) }
            }
        }
    }

    private func handle(read: AccountReadTransport, generation: UInt64) {
        defer { finishRefresh(generation: generation) }
        guard running, self.generation == generation else { return }
        do {
            let accountInfo = try AccountInfoRecord(read: read, address: address)
            try accountInfoManager.handle(accountInfo: accountInfo, address: address)
            try storage.save(lastBlockHeight: read.acceptedHeight)
            publish(.synced(accountInfoManager.accountState!))
        } catch {
            publish(.notSynced(.storageUnavailable, cached: accountInfoManager.accountState))
        }
    }

    private func handle(error: Error, generation: UInt64) {
        defer { finishRefresh(generation: generation) }
        guard running, self.generation == generation else { return }
        publish(.notSynced(map(error), cached: accountInfoManager.accountState))
    }

    private func finishRefresh(generation: UInt64) {
        guard self.generation == generation else { return }
        refreshInFlight = false
        refreshTask = nil
    }


    private func publish(_ state: SyncState) {
        let account = accountInfoManager.accountState
        let height: Int64?
        if case let .synced(value) = state { height = value.acceptedHeight } else { height = publishing.snapshot.lastBlockHeight }
        publishing.apply(StateSnapshot(accountState: account, syncState: state, lastBlockHeight: height))
    }

    private func map(_ error: Error) -> SyncError {
        if error is StorageError { return .storageUnavailable }
        guard let error = error as? ThorNodeReadError else { return .nodeUnavailable }
        switch error {
        case .transport: return .noConnection
        case .httpStatus(_, 429, _): return .rateLimited
        case .httpStatus: return .nodeUnavailable
        case .unsupportedAccountType, .invalidAccount, .heightMismatch, .invalidDenom, .invalidAmount, .duplicateDenom, .paginationCycle, .pageLimitExceeded, .absentAccountWithBalances, .attemptsExhausted, .malformedResponse: return .invalidResponse
        case .staleLease: return .nodeUnavailable
        case .cancelled: return .internalInvariant
        }
    }

    private func withDispatcher<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: dispatcherKey) == 1 { return body() }
        return dispatcher.sync(execute: body)
    }
}
