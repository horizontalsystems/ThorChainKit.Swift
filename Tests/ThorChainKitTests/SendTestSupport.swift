import Foundation
import BigInt
@testable import ThorChainKit

typealias SendRuntime = TransactionSender

extension Kit {
    var sendRuntime: TransactionSender { transactionSender }
}

func makeTestKit(
    address: Address,
    transactionSender: TransactionSender = TransactionSender(),
    preflight: SendPreflightCoordinator? = nil,
    pendingTransactionManager: PendingTransactionManager? = nil,
    persistenceNamespace: String = "test"
) -> Kit {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let accountStorage = try! AccountInfoStorage(databaseDirectoryUrl: directory, databaseFileName: "account-info-storage")
    let syncerStorage = try! SyncerStorage(databaseDirectoryUrl: directory, databaseFileName: "syncer-state-storage")
    let accountInfoManager = AccountInfoManager(storage: accountStorage)
    let syncer = Syncer(accountInfoManager: accountInfoManager, reader: TestAccountReader(), storage: syncerStorage, address: address)
    return Kit(
        address: address,
        syncer: syncer,
        accountInfoManager: accountInfoManager,
        transactionSender: transactionSender,
        pendingTransactionManager: pendingTransactionManager,
        preflight: preflight,
        persistenceNamespace: persistenceNamespace
    )
}

private struct TestAccountReader: IAccountProvider {
    func read(address: Address) async throws -> AccountReadTransport {
        try AccountReadTransport(acceptedHeight: 1, account: nil, balances: [], familyId: "test", observedAt: Date())
    }
}

func sendTestAddress() throws -> Address {
    try Address(
        "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
        network: .mainnet
    )
}

func sendOtherAddress() throws -> Address {
    try Address(
        "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean",
        network: .mainnet
    )
}

final class TestSendClock: ISendMonotonicClock, @unchecked Sendable {
    var now: UInt64

    init(now: UInt64 = 1_000) {
        self.now = now
    }
}

func issueTestQuote(
    in store: QuoteStore,
    clock: TestSendClock,
    generation: UInt64 = 7,
    amount: BigUInt = 100,
    nativeFee: BigUInt = 2,
    memo: String? = nil
) throws -> SendQuote {
    let amountMagnitude = SendMagnitude(amount).data
    let nativeFeeMagnitude = SendMagnitude(nativeFee).data
    let totalDebitMagnitude = SendMagnitude(amount + nativeFee).data
    return try store.issue(
        sender: try sendTestAddress(),
        recipient: try sendTestAddress(),
        amountMagnitude: amountMagnitude,
        nativeFeeMagnitude: nativeFeeMagnitude,
        totalDebitMagnitude: totalDebitMagnitude,
        memo: memo,
        acceptedHeight: 12,
        generation: generation
    )
}
