import Combine
import Foundation

final class AccountInfoManager {
    private let storage: AccountInfoStorage
    private let accountStateSubject = CurrentValueSubject<AccountState?, Never>(nil)

    init(storage: AccountInfoStorage) {
        self.storage = storage
    }

    var accountState: AccountState? {
        accountStateSubject.value
    }

    var accountStatePublisher: AnyPublisher<AccountState?, Never> {
        accountStateSubject.eraseToAnyPublisher()
    }

    func handleCached(address: Address) throws {
        guard let accountInfo = try storage.accountInfo() else { return }
        try handle(accountInfo: accountInfo, address: address, save: false)
    }

    func handle(accountInfo: AccountInfoRecord, address: Address) throws {
        try handle(accountInfo: accountInfo, address: address, save: true)
    }

    private func handle(accountInfo: AccountInfoRecord, address: Address, save: Bool) throws {
        guard accountInfo.address == address.raw,
              accountInfo.networkChainId == address.network.expectedChainId
        else { throw StorageError.invalid }
        if save { try storage.save(accountInfo: accountInfo) }
        try accountStateSubject.send(accountInfo.accountState())
    }
}
