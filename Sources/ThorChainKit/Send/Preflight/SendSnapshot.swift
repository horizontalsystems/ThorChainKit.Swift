/// What signing needs regardless of the message: a deposit addresses the chain and has
/// no recipient, so it cannot carry a send snapshot.
struct DepositContext: Sendable, Equatable {
    let sender: String
    let chainID: String
    let accountNumber: UInt64
    let sequence: UInt64
}

extension SendSnapshot {
    // The sequence is explicit: signing must use the freshly-read one, not the value
    // captured at quote time.
    func depositContext(sequence: UInt64) -> DepositContext {
        DepositContext(sender: sender, chainID: chainID, accountNumber: accountNumber, sequence: sequence)
    }
}

import BigInt
import CryptoKit
import Foundation

struct SendSnapshot: Equatable, Hashable, Sendable {
    let familyID: String
    let chainID: String
    let restEndpoint: String
    let rpcEndpoint: String
    let manifestRevision: String
    let height: Int64
    let sender: String
    // Empty for a deposit, which addresses the chain.
    let recipient: String
    let accountNumber: UInt64
    let sequence: UInt64
    let accountPublicKey: String?
    let accountPublicKeyData: Data?
    private let amountMagnitude: Data
    let denom: Denom
    private let nativeFeeMagnitude: Data
    private let totalDebitMagnitude: Data
    let mimir: MimirSnapshot
    let memoMaximumBytes: Int
    let recipientClassification: RecipientAccountClassification
    let policyRevision: String
    let digest: Data

    var amount: BigUInt { amountMagnitude.isEmpty ? 0 : BigUInt(amountMagnitude) }
    var nativeFee: BigUInt { nativeFeeMagnitude.isEmpty ? 0 : BigUInt(nativeFeeMagnitude) }
    var totalDebit: BigUInt { totalDebitMagnitude.isEmpty ? 0 : BigUInt(totalDebitMagnitude) }
    var snapshotDigest: Data { digest }
    var digestHex: String { digest.map { String(format: "%02x", $0) }.joined() }

    init(
        familyID: String, chainID: String, height: Int64, sender: String, recipient: String,
        accountNumber: UInt64, sequence: UInt64, amount: BigUInt, nativeFee: BigUInt, denom: Denom = .rune,
        mimir: MimirSnapshot, memoMaximumBytes: Int,
        recipientClassification: RecipientAccountClassification = .user,
        policyRevision: String = "s2-02-v1", accountPublicKey: String? = nil, accountPublicKeyData: Data? = nil,
        restEndpoint: String = "", rpcEndpoint: String = "", manifestRevision: String = "s2-03-manifest-v1"
    ) throws {
        let total = amount + nativeFee
        guard height > 0, !familyID.isEmpty, !chainID.isEmpty, !sender.isEmpty,
              amount > 0, total > 0, memoMaximumBytes > 0,
              (accountPublicKey == nil) == (accountPublicKeyData == nil),
              accountPublicKeyData.map({ $0.count == 33 && ($0.first == 2 || $0.first == 3) && accountPublicKey == "/cosmos.crypto.secp256k1.PubKey" }) ?? true else { throw SendError.operationUnavailable }
        self.familyID = familyID; self.chainID = chainID; self.restEndpoint = restEndpoint; self.rpcEndpoint = rpcEndpoint; self.manifestRevision = manifestRevision; self.height = height
        self.sender = sender; self.recipient = recipient; self.accountNumber = accountNumber; self.sequence = sequence; self.accountPublicKey = accountPublicKey; self.accountPublicKeyData = accountPublicKeyData
        amountMagnitude = SendMagnitude(amount).data; nativeFeeMagnitude = SendMagnitude(nativeFee).data; self.denom = denom
        totalDebitMagnitude = SendMagnitude(total).data; self.mimir = mimir; self.memoMaximumBytes = memoMaximumBytes
        self.recipientClassification = recipientClassification; self.policyRevision = policyRevision
        digest = Self.makeDigest(
            familyID: familyID, chainID: chainID, restEndpoint: restEndpoint, rpcEndpoint: rpcEndpoint, manifestRevision: manifestRevision, height: height, sender: sender, recipient: recipient,
            accountNumber: accountNumber, sequence: sequence, amount: amountMagnitude, denom: denom.rawValue, fee: nativeFeeMagnitude,
            total: totalDebitMagnitude, mimir: mimir, memoMaximumBytes: memoMaximumBytes, classification: recipientClassification,
            policyRevision: policyRevision, accountPublicKey: accountPublicKey, accountPublicKeyData: accountPublicKeyData
        )
    }

    static func fixture(height: Int64) throws -> SendSnapshot {
        try SendSnapshot(
            familyID: "rorcual-mainnet", chainID: "thorchain-1", height: height,
            sender: "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2",
            recipient: "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean", accountNumber: 1, sequence: 2,
            amount: 100, nativeFee: 2, mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256
        )
    }

    private static func makeDigest(familyID: String, chainID: String, restEndpoint: String, rpcEndpoint: String, manifestRevision: String, height: Int64, sender: String, recipient: String, accountNumber: UInt64, sequence: UInt64, amount: Data, denom: String, fee: Data, total: Data, mimir: MimirSnapshot, memoMaximumBytes: Int, classification: RecipientAccountClassification, policyRevision: String, accountPublicKey: String?, accountPublicKeyData: Data?) -> Data {
        var data = Data()
        func append(_ value: Data) { var length = UInt64(value.count).bigEndian; data.append(Data(bytes: &length, count: 8)); data.append(value) }
        append(Data(familyID.utf8)); append(Data(chainID.utf8)); append(Data(restEndpoint.utf8)); append(Data(rpcEndpoint.utf8)); append(Data(manifestRevision.utf8)); append(Data(String(height).utf8)); append(Data(sender.utf8)); append(Data(recipient.utf8))
        append(Data(String(accountNumber).utf8)); append(Data(String(sequence).utf8)); append(Data((accountPublicKey ?? "").utf8)); append(accountPublicKeyData ?? Data()); append(amount); append(Data(denom.utf8)); append(fee); append(total)
        append(Data("\(mimir.haltChainGlobal),\(mimir.nodePauseChainGlobal),\(mimir.haltTHORChain),\(mimir.solvencyHaltTHORChain)".utf8))
        append(Data(String(memoMaximumBytes).utf8)); append(Data(classification.rawValue.utf8)); append(Data(policyRevision.utf8))
        return Data(SHA256.hash(data: data))
    }
}
