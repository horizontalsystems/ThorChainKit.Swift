import CryptoKit
import Foundation
import BigInt
import SwiftProtobuf

struct SignPayload: Sendable, CustomDebugStringConvertible, CustomReflectable {
    let bodyBytes: Data
    let authInfoBytes: Data
    let signDocBytes: Data
    let digest: Data

    var debugDescription: String { "SignPayload(redacted)" }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }
}

struct SignedTransaction: Sendable, CustomDebugStringConvertible, CustomReflectable {
    let txRaw: Data
    let transactionID: TransactionID

    var debugDescription: String { "SignedTransaction(redacted)" }

    var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .struct)
    }
}

enum DirectSignCodec {
    private static let msgSendTypeURL = "/types.MsgSend"
    private static let msgDepositTypeURL = "/types.MsgDeposit"
    private static let publicKeyTypeURL = "/cosmos.crypto.secp256k1.PubKey"
    // As in the Android kit.
    private static let gasLimit: UInt64 = 6_000_000
    // A deposit executes chain logic rather than moving coins, so it needs far more gas.
    // Mirrors the Android kit, which pairs 6_000_000 for a send with 600_000_000 here.
    private static let depositGasLimit: UInt64 = 600_000_000

    static func makeSignPayload(snapshot: SendSnapshot, quote prepared: PreparedQuote, publicKey: Data, sequence: UInt64) throws -> SignPayload {
        let quote = prepared.quote
        guard prepared.snapshot == snapshot,
              quote.hasConsistentAuthorityProjection,
              quote.preflightContext == snapshot,
              quote.amount > 0,
              quote.internalAuthorityRecord.snapshot.sender == snapshot.sender,
              quote.internalAuthorityRecord.snapshot.recipient == snapshot.recipient,
              quote.internalAuthorityRecord.snapshot.accountNumber == snapshot.accountNumber,
              quote.internalAuthorityRecord.snapshot.sequence == snapshot.sequence,
              quote.internalAuthorityRecord.snapshot.memo == quote.memo,
              quote.internalAuthorityRecord.snapshot.providerFamilyID == snapshot.familyID,
              quote.internalAuthorityRecord.snapshot.acceptedHeight == snapshot.height,
              quote.memo.map({ $0.utf8.count <= snapshot.memoMaximumBytes }) ?? true,
              publicKey.count == 33,
              publicKey.first == 2 || publicKey.first == 3
        else { throw SendError.operationUnavailable }

        let sender = try addressPayload(snapshot.sender)
        let recipient = try addressPayload(snapshot.recipient)
        let message = try msgSend(sender: sender, recipient: recipient, amount: quote.amount, denom: snapshot.denom)
        return try assemble(message: message, typeURL: msgSendTypeURL, memo: quote.memo ?? "", gasLimit: gasLimit, context: snapshot.depositContext(sequence: sequence), publicKey: publicKey)
    }

    /// A deposit has no recipient: it addresses the chain itself, and its instruction
    /// lives in the message memo rather than the transaction body.
    static func makeDepositSignPayload(context: DepositContext, asset: Asset, amount: BigUInt, memo: String, publicKey: Data) throws -> SignPayload {
        guard amount > 0, !memo.isEmpty,
              publicKey.count == 33, publicKey.first == 2 || publicKey.first == 3
        else { throw SendError.operationUnavailable }

        let signer = try addressPayload(context.sender)
        let message = try msgDeposit(asset: asset, amount: amount, memo: memo, signer: signer)
        // TxBody.memo stays empty — the deposit carries its own.
        return try assemble(message: message, typeURL: msgDepositTypeURL, memo: "", gasLimit: depositGasLimit, context: context, publicKey: publicKey)
    }

    private static func assemble(message: Data, typeURL: String, memo: String, gasLimit: UInt64, context: DepositContext, publicKey: Data) throws -> SignPayload {
        let anyMessage = SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = typeURL
            $0.value = message
        }
        let body = Cosmos_Tx_V1beta1_TxBody.with {
            $0.messages = [anyMessage]
            $0.memo = memo
        }
        let bodyBytes = try body.serializedData()

        let publicKeyMessage = Cosmos_Crypto_Secp256k1_PubKey.with { $0.key = publicKey }
        let publicKeyBytes = try publicKeyMessage.serializedData()
        let publicKeyAny = SwiftProtobuf.Google_Protobuf_Any.with {
            $0.typeURL = publicKeyTypeURL
            $0.value = publicKeyBytes
        }
        let modeInfo = Cosmos_Tx_Signing_V1beta1_ModeInfo.with {
            $0.single.mode = .direct
        }
        let signerInfo = Cosmos_Tx_V1beta1_SignerInfo.with {
            $0.publicKey = publicKeyAny
            $0.modeInfo = modeInfo
            $0.sequence = context.sequence
        }
        let fee = Cosmos_Tx_V1beta1_Fee.with { $0.gasLimit = gasLimit }
        let authInfo = Cosmos_Tx_V1beta1_AuthInfo.with {
            $0.signerInfos = [signerInfo]
            $0.fee = fee
        }
        let authInfoBytes = try authInfo.serializedData()
        let signDoc = Cosmos_Tx_V1beta1_SignDoc.with {
            $0.bodyBytes = bodyBytes
            $0.authInfoBytes = authInfoBytes
            $0.chainID = context.chainID
            $0.accountNumber = context.accountNumber
        }
        let signDocBytes = try signDoc.serializedData()
        return SignPayload(
            bodyBytes: bodyBytes,
            authInfoBytes: authInfoBytes,
            signDocBytes: signDocBytes,
            digest: Data(SHA256.hash(data: signDocBytes))
        )
    }

    static func makeTxRaw(payload: SignPayload, compactSignature: Data) throws -> SignedTransaction {
        guard compactSignature.count == 64 else { throw SendError.invalidSignature }
        let raw = Cosmos_Tx_V1beta1_TxRaw.with {
            $0.bodyBytes = payload.bodyBytes
            $0.authInfoBytes = payload.authInfoBytes
            $0.signatures = [compactSignature]
        }
        let txRaw = try raw.serializedData()
        return SignedTransaction(txRaw: txRaw, transactionID: transactionId(txRaw: txRaw))
    }

    static func transactionId(txRaw: Data) -> TransactionID {
        let digest = SHA256.hash(data: txRaw)
        let hash = digest.map { String(format: "%02X", $0) }.joined()
        return TransactionID(hash: hash)!
    }

    private static func msgSend(sender: Data, recipient: Data, amount: BigUInt, denom: Denom) throws -> Data {
        var message = Types_MsgSend()
        message.fromAddress = sender
        message.toAddress = recipient
        var coin = Cosmos_Base_V1beta1_Coin()
        coin.denom = denom.rawValue
        coin.amount = String(amount)
        message.amount = [coin]
        return try message.serializedData()
    }

    private static func msgDeposit(asset: Asset, amount: BigUInt, memo: String, signer: Data) throws -> Data {
        var coin = Common_Coin()
        coin.asset = Common_Asset.with {
            $0.chain = asset.chain
            $0.symbol = asset.symbol
            $0.ticker = asset.ticker
            $0.synth = asset.synth
            $0.trade = asset.trade
            $0.secured = asset.secured
        }
        coin.amount = String(amount)
        // THORChain reads a deposit amount in the asset's own base units; the field is
        // informational and the Android kit leaves it at zero.
        coin.decimals = 0
        var message = Types_MsgDeposit()
        message.coins = [coin]
        message.memo = memo
        // Raw 20-byte account payload, not bech32 — same as MsgSend's addresses.
        message.signer = signer
        return try message.serializedData()
    }

    private static func addressPayload(_ raw: String) throws -> Data {
        let decoded = try Bech32Codec.decode(raw)
        guard raw == raw.lowercased(), ["thor", "sthor", "cthor"].contains(decoded.hrp) else {
            throw SendError.invalidRecipient
        }
        let payload = try BitConversion.convert(decoded.words, fromBits: 5, toBits: 8, pad: false)
        guard payload.count == 20, Bech32Codec.encode(hrp: decoded.hrp, words: decoded.words) == raw else {
            throw SendError.invalidRecipient
        }
        return Data(payload)
    }
}
