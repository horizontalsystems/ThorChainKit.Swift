import BigInt
import CryptoKit
import Foundation
import secp256k1
import XCTest
@testable import ThorChainKit

final class DirectSignCodecTests: XCTestCase {
    private let sender = "thor1w508d6qejxtdg4y5r3zarvary0c5xw7ku6wp68"
    private let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
    private let publicKey = Data(hex: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    private let signature = Data(hex: "e7b6b1d9d3029bc3dd1635a4a866ffe8b376f8a6f5260e08770397d1ab9824db40b78f5a0564a219757745155c80b225acc043ee700796130b4d0119fc9f1011")

    func testOfficialScalarOneVectorMatchesEverySignedByteAndHash() throws {
        let snapshot = try makeSnapshot()
        let payload = try makePayload(snapshot: snapshot)

        XCTAssertEqual(payload.signDocBytes.count, 193)
        XCTAssertEqual(payload.digest.hex, "09f9e241b6ad35055da5129322f7e564690f57c479d9df705debb0d54242569c")

        let signed = try DirectSignCodec.makeTxRaw(payload: payload, compactSignature: signature)
        XCTAssertEqual(signed.txRaw.hex, "0a530a510a0e2f74797065732e4d736753656e64123f0a14751e76e8199196d454941c45d1b3a323f1433bd612145a0dba49dab8fec87c6dd7c01b564ee72a8515a61a110a0472756e65120931303030303030303012590a500a460a1f2f636f736d6f732e63727970746f2e736563703235366b312e5075624b657912230a210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179812040a0208011801120510809bee021a40e7b6b1d9d3029bc3dd1635a4a866ffe8b376f8a6f5260e08770397d1ab9824db40b78f5a0564a219757745155c80b225acc043ee700796130b4d0119fc9f1011")
        XCTAssertEqual(signed.transactionID.hash, "805C61ACBF4F6C210D1B98B9E2690222566F621074CA3FE82BCC46FEC4E3863A")

        let decodedRaw = try Cosmos_Tx_V1beta1_TxRaw(serializedBytes: signed.txRaw)
        let decodedBody = try Cosmos_Tx_V1beta1_TxBody(serializedBytes: decodedRaw.bodyBytes)
        let decodedMessage = try Types_MsgSend(serializedBytes: decodedBody.messages[0].value)
        XCTAssertEqual(decodedBody.messages.count, 1)
        XCTAssertEqual(decodedBody.messages[0].typeURL, "/types.MsgSend")
        XCTAssertEqual(decodedMessage.amount.first?.denom, "rune")
        XCTAssertEqual(decodedMessage.amount.first?.amount, "100000000")
        XCTAssertEqual(decodedRaw.signatures, [signature])
    }

    func testConstructionIsDeterministicAndUsesExactTxRawBytes() throws {
        let snapshot = try makeSnapshot()
        let first = try makePayload(snapshot: snapshot)
        let second = try makePayload(snapshot: snapshot)
        XCTAssertEqual(first.signDocBytes, second.signDocBytes)
        XCTAssertEqual(first.bodyBytes, second.bodyBytes)
        XCTAssertEqual(first.authInfoBytes, second.authInfoBytes)

        let signed = try DirectSignCodec.makeTxRaw(payload: first, compactSignature: signature)
        var mutated = signed.txRaw
        mutated[mutated.startIndex] ^= 1
        XCTAssertNotEqual(DirectSignCodec.transactionId(txRaw: signed.txRaw), DirectSignCodec.transactionId(txRaw: mutated))
    }

    func testByteCarriersRedactDebugAndReflection() throws {
        let payload = try makePayload(snapshot: makeSnapshot())
        let signed = try DirectSignCodec.makeTxRaw(payload: payload, compactSignature: signature)

        for representation in [
            String(describing: payload),
            String(reflecting: payload),
            String(describing: signed),
            String(reflecting: signed)
        ] {
            XCTAssertFalse(representation.contains("bodyBytes"))
            XCTAssertFalse(representation.contains("authInfoBytes"))
            XCTAssertFalse(representation.contains("signDocBytes"))
            XCTAssertFalse(representation.contains("digest"))
            XCTAssertFalse(representation.contains("txRaw"))
            XCTAssertFalse(representation.contains(payload.digest.hex))
            XCTAssertFalse(representation.contains(signed.txRaw.hex))
        }
    }

    func testTxRawRejectsEverySignatureLengthExceptCompact() throws {
        let payload = try makePayload(snapshot: makeSnapshot())
        for length in [0, 63, 65] {
            XCTAssertThrowsError(try DirectSignCodec.makeTxRaw(payload: payload, compactSignature: Data(repeating: 0, count: length)))
        }
        XCTAssertNoThrow(try DirectSignCodec.makeTxRaw(payload: payload, compactSignature: Data(repeating: 0, count: 64)))
    }

    func testLegacyTwentyMillionGasIsOnlyACompatibilityControl() throws {
        let legacySender = "thor18altpx2gwt4c4ejr5uzda4kyzsudyn9q56fnng"
        let legacyPublicKey = Data(hex: "023e4b76861289ad4528b33c2fd21b3a5160cd37b3294234914e21efb6ed4a452b")
        let payload = try makePayload(sender: legacySender, publicKey: legacyPublicKey)
        var auth = try Cosmos_Tx_V1beta1_AuthInfo(serializedBytes: payload.authInfoBytes)
        auth.fee.gasLimit = 20_000_000
        var signDoc = Cosmos_Tx_V1beta1_SignDoc()
        signDoc.bodyBytes = payload.bodyBytes
        signDoc.authInfoBytes = try auth.serializedData()
        signDoc.chainID = "thorchain-1"
        signDoc.accountNumber = 123_456
        let legacyDigest = Data(SHA256.hash(data: try signDoc.serializedData()))
        XCTAssertEqual(legacyDigest.hex, "7e513b23957b2e3caf77e796ba1412851be066cd77f96a7d196c3c856c641ebf")
    }

    func testVultisigInputsUseOfficialGasInProductionCodec() throws {
        let legacySender = "thor18altpx2gwt4c4ejr5uzda4kyzsudyn9q56fnng"
        let legacyPublicKey = Data(hex: "023e4b76861289ad4528b33c2fd21b3a5160cd37b3294234914e21efb6ed4a452b")
        let payload = try makePayload(sender: legacySender, publicKey: legacyPublicKey)
        XCTAssertEqual(payload.signDocBytes.count, 193)
        XCTAssertEqual(payload.digest.hex, "0c03bcd0c0e3dee7b26a762cbd5a636a9858f09260a3b781117067c30e63c312")
    }

    func testStaticSignatureIsVerifiedOnlyByIndependentTestOracle() throws {
        let payload = try makePayload(snapshot: makeSnapshot())
        let key = try secp256k1.Signing.PublicKey(rawRepresentation: publicKey, format: .compressed)
        let parsedSignature = try secp256k1.Signing.ECDSASignature(compactRepresentation: signature)
        XCTAssertTrue(key.ecdsa.isValidSignature(parsedSignature, for: SHA256.hash(data: payload.signDocBytes)))
    }

    func testCodecRejectsMemoOverflowAndMalformedPublicKeyFraming() throws {
        let snapshot = try makeSnapshot()
        XCTAssertThrowsError(try makePayload(snapshot: snapshot, memo: String(repeating: "a", count: 257)))
        for malformedKey in [Data(repeating: 2, count: 32), Data([4] + Array(repeating: UInt8(0), count: 32))] {
            XCTAssertThrowsError(try makePayload(snapshot: snapshot, publicKey: malformedKey))
        }
    }

    func testDepositPutsItsMemoInTheMessageAndLeavesTheBodyMemoEmpty() throws {
        // Three details that are easy to get wrong and invisible until a swap silently
        // does nothing: the instruction lives in the message, not the transaction body;
        // the signer is the raw 20-byte payload; the asset flags travel with the coin.
        let snapshot = try makeSnapshot()
        let asset = Asset(chain: "THOR", symbol: "TCY", ticker: "TCY")

        let payload = try DirectSignCodec.makeDepositSignPayload(
            context: snapshot.depositContext, asset: asset, amount: 100_000_000, memo: "=:BTC.BTC:bc1...", publicKey: publicKey
        )

        let body = try Cosmos_Tx_V1beta1_TxBody(serializedBytes: payload.bodyBytes)
        XCTAssertEqual(body.memo, "")
        XCTAssertEqual(body.messages[0].typeURL, "/types.MsgDeposit")

        let message = try Types_MsgDeposit(serializedBytes: body.messages[0].value)
        XCTAssertEqual(message.memo, "=:BTC.BTC:bc1...")
        XCTAssertEqual(message.signer.count, 20)
        XCTAssertEqual(message.coins.first?.amount, "100000000")
        XCTAssertEqual(message.coins.first?.asset.chain, "THOR")
        XCTAssertEqual(message.coins.first?.asset.ticker, "TCY")
    }

    func testDepositRefusesAnEmptyMemoBecauseItIsTheInstruction() throws {
        XCTAssertThrowsError(try DirectSignCodec.makeDepositSignPayload(
            context: try makeSnapshot().depositContext, asset: .rune, amount: 1, memo: "", publicKey: publicKey
        ))
    }

    func testSignedTransactionCarriesTheSnapshotDenomNotRune() throws {
        // The whole point of the denom work: a TCY send must put "tcy" in the coin.
        // Hardcoding "rune" here would move the wrong asset in the amount computed
        // from the TCY balance, and until this test existed nothing caught it.
        let tcy = try Denom(rawValue: "tcy")
        let payload = try makePayload(snapshot: try makeSnapshot(denom: tcy))
        let runePayload = try makePayload(snapshot: try makeSnapshot())

        let body = try Cosmos_Tx_V1beta1_TxBody(serializedBytes: payload.bodyBytes)
        let message = try Types_MsgSend(serializedBytes: body.messages[0].value)

        XCTAssertEqual(message.amount.first?.denom, "tcy")
        XCTAssertEqual(message.amount.first?.amount, "100000000")
        XCTAssertNotEqual(payload.signDocBytes, runePayload.signDocBytes)
    }

    private func makePayload(snapshot: SendSnapshot, publicKey: Data? = nil, memo: String? = nil) throws -> SignPayload {
        let quote = try makeQuote(sender: snapshot.sender, memo: memo, preflightContext: snapshot)
        return try DirectSignCodec.makeSignPayload(
            snapshot: snapshot,
            quote: PreparedQuote(quote: quote, snapshot: snapshot),
            publicKey: publicKey ?? self.publicKey
        )
    }

    private func makePayload(sender: String, publicKey: Data) throws -> SignPayload {
        let snapshot = try makeSnapshot(sender: sender, publicKey: publicKey)
        return try makePayload(snapshot: snapshot, publicKey: publicKey)
    }

    private func makeSnapshot(sender: String = "thor1w508d6qejxtdg4y5r3zarvary0c5xw7ku6wp68", publicKey: Data? = nil, denom: Denom = .rune) throws -> SendSnapshot {
        try SendSnapshot(
            familyID: "thorchain-mainnet",
            chainID: "thorchain-1",
            height: 1,
            sender: sender,
            recipient: recipient,
            accountNumber: 123_456,
            sequence: 1,
            amount: BigUInt(100_000_000),
            nativeFee: 0,
            denom: denom,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey",
            accountPublicKeyData: publicKey ?? self.publicKey
        )
    }

    private func makeQuote(sender: String = "thor1w508d6qejxtdg4y5r3zarvary0c5xw7ku6wp68", memo: String? = nil, preflightContext: SendSnapshot? = nil) throws -> SendQuote {
        let clock = TestSendClock()
        return try QuoteStore(clock: clock).issue(
            sender: try Address(sender, network: .mainnet),
            recipient: try Address(recipient, network: .mainnet),
            amountMagnitude: SendMagnitude(BigUInt(100_000_000)).data,
            nativeFeeMagnitude: Data(),
            totalDebitMagnitude: SendMagnitude(BigUInt(100_000_000)).data,
            memo: memo,
            acceptedHeight: 1,
            generation: 1,
            accountNumber: 123_456,
            sequence: 1,
            providerFamilyID: "thorchain-mainnet",
            preflightContext: preflightContext
        )
    }
}

private extension Data {
    init(hex: String) {
        self.init(hex.chunked(2).map { UInt8($0, radix: 16)! })
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: min(size, distance(from: start, to: endIndex)))
            return String(self[start..<end])
        }
    }
}
