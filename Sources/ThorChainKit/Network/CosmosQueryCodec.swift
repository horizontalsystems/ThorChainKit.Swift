import Foundation
import SwiftProtobuf

enum CosmosQueryCodec {
    struct AccountPayload: Sendable, Equatable {
        let typeURL: String
        let address: String
        let accountNumber: UInt64
        let sequence: UInt64
        let publicKeyTypeURL: String?
        let publicKeyData: Data?
    }

    static func accountRequest(address: String) throws -> Data {
        var request = Cosmos_Auth_V1beta1_QueryAccountRequest()
        request.address = address
        return try request.serializedData()
    }

    static func networkRequest(height: Int64) throws -> Data {
        var request = Types_QueryNetworkRequest()
        request.height = String(height)
        return try request.serializedData()
    }

    static func spendableRequest(address: String, denom: String = "rune") throws -> Data {
        var request = Cosmos_Bank_V1beta1_QuerySpendableBalanceByDenomRequest()
        request.address = address
        request.denom = denom
        return try request.serializedData()
    }

    static func decodeAccountResponse(_ data: Data) throws -> Data {
        let response = try Cosmos_Auth_V1beta1_QueryAccountResponse(serializedBytes: data)
        return response.account.value
    }

    static func decodeAccountPayload(_ data: Data) throws -> AccountPayload? {
        guard !data.isEmpty else { return nil }
        let response = try Cosmos_Auth_V1beta1_QueryAccountResponse(serializedBytes: data)
        guard try response.serializedData() == data else { throw SendError.accountUnavailable }
        guard response.hasAccount else { throw SendError.accountUnavailable }
        let typeURL = response.account.typeURL
        let baseData: Data
        switch typeURL {
        case "/cosmos.auth.v1beta1.BaseAccount":
            baseData = response.account.value
        case "/cosmos.auth.v1beta1.ModuleAccount":
            let module = try Cosmos_Auth_V1beta1_ModuleAccount(serializedBytes: response.account.value)
            guard module.hasBaseAccount else { throw SendError.accountUnavailable }
            baseData = try module.baseAccount.serializedData()
        case "/cosmos.vesting.v1beta1.BaseVestingAccount":
            let vesting = try Cosmos_Vesting_V1beta1_BaseVestingAccount(serializedBytes: response.account.value)
            guard vesting.hasBaseAccount else { throw SendError.accountUnavailable }
            baseData = try vesting.baseAccount.serializedData()
        case "/cosmos.vesting.v1beta1.ContinuousVestingAccount":
            let vesting = try Cosmos_Vesting_V1beta1_ContinuousVestingAccount(serializedBytes: response.account.value)
            guard vesting.hasBaseVestingAccount, vesting.baseVestingAccount.hasBaseAccount else { throw SendError.accountUnavailable }
            baseData = try vesting.baseVestingAccount.baseAccount.serializedData()
        case "/cosmos.vesting.v1beta1.DelayedVestingAccount":
            let vesting = try Cosmos_Vesting_V1beta1_DelayedVestingAccount(serializedBytes: response.account.value)
            guard vesting.hasBaseVestingAccount, vesting.baseVestingAccount.hasBaseAccount else { throw SendError.accountUnavailable }
            baseData = try vesting.baseVestingAccount.baseAccount.serializedData()
        case "/cosmos.vesting.v1beta1.PeriodicVestingAccount":
            let vesting = try Cosmos_Vesting_V1beta1_PeriodicVestingAccount(serializedBytes: response.account.value)
            guard vesting.hasBaseVestingAccount, vesting.baseVestingAccount.hasBaseAccount else { throw SendError.accountUnavailable }
            baseData = try vesting.baseVestingAccount.baseAccount.serializedData()
        case "/cosmos.vesting.v1beta1.PermanentLockedAccount":
            let vesting = try Cosmos_Vesting_V1beta1_PermanentLockedAccount(serializedBytes: response.account.value)
            guard vesting.hasBaseVestingAccount, vesting.baseVestingAccount.hasBaseAccount else { throw SendError.accountUnavailable }
            baseData = try vesting.baseVestingAccount.baseAccount.serializedData()
        default:
            throw SendError.accountUnavailable
        }
        let account = try Cosmos_Auth_V1beta1_BaseAccount(serializedBytes: baseData)
        guard !account.address.isEmpty else { throw SendError.accountUnavailable }
        let publicKeyTypeURL: String?
        let publicKeyData: Data?
        if account.hasPubKey {
            guard account.pubKey.typeURL == "/cosmos.crypto.secp256k1.PubKey", !account.pubKey.value.isEmpty else {
                throw SendError.accountUnavailable
            }
            let publicKey = try Cosmos_Crypto_Secp256k1_PubKey(serializedBytes: account.pubKey.value)
            guard publicKey.key.count == 33, publicKey.key.first == 2 || publicKey.key.first == 3 else {
                throw SendError.accountUnavailable
            }
            publicKeyTypeURL = account.pubKey.typeURL
            publicKeyData = publicKey.key
        } else {
            publicKeyTypeURL = nil
            publicKeyData = nil
        }
        return AccountPayload(typeURL: typeURL, address: account.address, accountNumber: account.accountNumber, sequence: account.sequence, publicKeyTypeURL: publicKeyTypeURL, publicKeyData: publicKeyData)
    }

    static func decodeResponseHeight(_ value: Int64?, expected: Int64) throws {
        guard let value, value == expected, value > 0 else { throw SendError.heightUnproven }
    }
}
