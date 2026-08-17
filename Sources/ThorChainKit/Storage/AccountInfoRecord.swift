import BigInt
import Foundation

struct StoredBalance: Equatable, Sendable {
    let denom: String
    let amountDecimalString: String
}

struct AccountInfoRecord: Equatable, Sendable {
    let address: String
    let networkChainId: String
    let accountExists: Bool
    let accountNumber: UInt64?
    let sequence: UInt64?
    let acceptedHeight: Int64
    let fetchedAt: Date
    let providerFamilyId: String
    let balances: [StoredBalance]

    init(address: String, networkChainId: String, accountExists: Bool, accountNumber: UInt64?, sequence: UInt64?, acceptedHeight: Int64, fetchedAt: Date, providerFamilyId: String, balances: [StoredBalance]) throws {
        self.address = address
        self.networkChainId = networkChainId
        self.accountExists = accountExists
        self.accountNumber = accountNumber
        self.sequence = sequence
        self.acceptedHeight = acceptedHeight
        self.fetchedAt = fetchedAt
        self.providerFamilyId = providerFamilyId
        self.balances = balances
        try validate()
    }

    init(read: AccountReadTransport, address: Address) throws {
        try self.init(
            address: address.raw,
            networkChainId: address.network.expectedChainId,
            accountExists: read.account != nil,
            accountNumber: read.account?.accountNumber,
            sequence: read.account?.sequence,
            acceptedHeight: read.acceptedHeight,
            fetchedAt: read.observedAt,
            providerFamilyId: read.familyId,
            balances: read.balances.map { StoredBalance(denom: $0.denom.rawValue, amountDecimalString: $0.amountDecimal) }
        )
    }

    func accountState() throws -> AccountState {
        let balances = try Dictionary(uniqueKeysWithValues: balances.map { balance in
            guard let amount = BigUInt(balance.amountDecimalString), String(amount) == balance.amountDecimalString else {
                throw StorageError.invalid
            }
            return try (Denom(rawValue: balance.denom), amount)
        })
        return try AccountState(
            accountNumber: accountNumber,
            sequence: sequence,
            balances: balances,
            acceptedHeight: acceptedHeight,
            fetchedAt: fetchedAt,
            providerFamilyId: providerFamilyId,
            exists: accountExists
        )
    }

    func validate() throws {
        guard !address.isEmpty,
              !networkChainId.isEmpty,
              acceptedHeight > 0,
              !providerFamilyId.isEmpty,
              Set(balances.map(\.denom)).count == balances.count,
              balances.allSatisfy({ !$0.denom.isEmpty && BigUInt($0.amountDecimalString).map(String.init) == $0.amountDecimalString })
        else { throw StorageError.invalid }
        if accountExists && (accountNumber == nil || sequence == nil) { throw StorageError.invalid }
        if !accountExists && (accountNumber != nil || sequence != nil || !balances.isEmpty) { throw StorageError.invalid }
    }
}

enum StorageError: Error, Equatable {
    case invalid
}
