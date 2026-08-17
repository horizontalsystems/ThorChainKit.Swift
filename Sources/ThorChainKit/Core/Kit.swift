import BigInt
import Combine
import Foundation

public final class Kit {
    public let address: Address
    public let network: Network

    private let syncer: Syncer
    let transactionSender: TransactionSender
    private let pendingTransactionManager: PendingTransactionManager?
    private let transactionManager: TransactionManager?
    private let transactionSyncer: TransactionSyncer?
    let preflight: SendPreflightCoordinator?
    private let accountInfoManager: AccountInfoManager
    private var pendingCancellables = Set<AnyCancellable>()
    private let lifecycleLock = NSLock()
    private var activeGeneration: UInt64?
    let persistenceNamespace: String

    init(address: Address, syncer: Syncer, accountInfoManager: AccountInfoManager, transactionSender: TransactionSender, pendingTransactionManager: PendingTransactionManager?, transactionManager: TransactionManager? = nil, transactionSyncer: TransactionSyncer? = nil, preflight: SendPreflightCoordinator?, persistenceNamespace: String) {
        self.address = address
        network = address.network
        self.syncer = syncer
        self.accountInfoManager = accountInfoManager
        self.transactionSender = transactionSender
        self.pendingTransactionManager = pendingTransactionManager
        self.transactionManager = transactionManager
        self.transactionSyncer = transactionSyncer
        self.preflight = preflight
        self.persistenceNamespace = persistenceNamespace
        // The journal stays internal: Cosmos broadcast leaves an unresolved window, so a
        // local record is needed. It is not a second public transaction type — unconfirmed
        // sends reach the app through TransactionManager as ordinary pending transactions,
        // the way TronKit does it.
        _ = pendingTransactionManager?.refresh()
    }

    public var lastBlockHeight: Int64? { syncer.lastBlockHeight }
    public var syncState: SyncState { syncer.state }
    public var accountState: AccountState? { accountInfoManager.accountState }
    // Balance of the chain's settlement asset: RUNE on THORChain, CACAO on Maya.
    // `runeBalance` is a source-compatibility alias — on a Maya kit "rune" is not a bank
    // denom, so anything but the native read would silently return zero.
    public var runeBalance: BigUInt { nativeBalance }
    public var nativeBalance: BigUInt { balance(denom: network.nativeDenom) }
    public var decimals: Int { network.decimals }
    // One account read carries every denom, so all of an account's tokens are served
    // by this kit — a denom without its own adapter simply goes unread.
    public var balances: [Denom: BigUInt] { accountState?.balances ?? [:] }

    public func balance(denom: Denom) -> BigUInt {
        accountState?.balances[denom] ?? 0
    }

    public func balancePublisher(denom: Denom) -> AnyPublisher<BigUInt, Never> {
        accountStatePublisher
            .map { $0?.balances[denom] ?? 0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public var accountExists: Bool { accountState?.exists ?? false }
    public var transactionsSyncState: TransactionSyncState { transactionSyncer?.state ?? .notSynced(error: .notStarted) }
    public var transactionsSyncStatePublisher: AnyPublisher<TransactionSyncState, Never> {
        transactionSyncer?.statePublisher ?? Just(.notSynced(error: .notStarted)).eraseToAnyPublisher()
    }

    public var allTransactionsPublisher: AnyPublisher<([Transaction], Bool), Never> {
        transactionManager?.allTransactionsPublisher ?? Empty().eraseToAnyPublisher()
    }

    public var transactionsPublisher: AnyPublisher<[Transaction], Never> {
        transactionManager?.transactionsPublisher ?? Empty().eraseToAnyPublisher()
    }

    public var lastBlockHeightPublisher: AnyPublisher<Int64?, Never> { syncer.lastBlockHeightPublisher }
    public var syncStatePublisher: AnyPublisher<SyncState, Never> { syncer.statePublisher }
    public var accountStatePublisher: AnyPublisher<AccountState?, Never> { accountInfoManager.accountStatePublisher }

    public func transactions(hash: String? = nil, descending: Bool = true, limit: Int? = nil) -> [Transaction] {
        transactionManager?.transactions(hash: hash, descending: descending, limit: limit) ?? []
    }

    public func start() {
        let generation = syncer.start()
        lifecycleLock.lock()
        activeGeneration = generation
        lifecycleLock.unlock()
        Task { [weak self, transactionSender] in
            guard self?.isCurrent(generation: generation) == true else { return }
            await transactionSender.activate(generation: generation)
            if self?.isCurrent(generation: generation) != true {
                await transactionSender.invalidate(generation: generation)
            }
        }
    }

    public func stop() {
        guard let generation = syncer.stop() else { return }
        lifecycleLock.lock()
        if activeGeneration == generation { activeGeneration = nil }
        lifecycleLock.unlock()
        transactionSender.invalidateImmediately(generation: generation)
        Task { [transactionSender] in await transactionSender.invalidate(generation: generation) }
        transactionSyncer?.stop()
    }

    public func refresh() {
        syncer.refresh()
    }

    private func isCurrent(generation: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return activeGeneration == generation
    }
}
