import BigInt
import Foundation

struct QuoteAuthorityEnvelope: Equatable, Hashable, Sendable {
    let clientID: UUID
    let generation: UInt64
    let deadline: UInt64
    let token: Data
}

struct QuoteReviewSnapshot: Equatable, Hashable, Sendable {
    let sender: String
    let recipient: String
    let amountMagnitude: Data
    let nativeFeeMagnitude: Data
    let totalDebitMagnitude: Data
    let memo: String?
    let acceptedHeight: Int64
    let expiresAt: Date
    let accountNumber: UInt64
    let sequence: UInt64
    let providerFamilyID: String
    let preflightContext: SendSnapshot?
    let preflightDigest: Data?

    init(sender: String, recipient: String, amountMagnitude: Data, nativeFeeMagnitude: Data, totalDebitMagnitude: Data, memo: String?, acceptedHeight: Int64, expiresAt: Date, accountNumber: UInt64, sequence: UInt64, providerFamilyID: String, preflightContext: SendSnapshot? = nil, preflightDigest: Data? = nil) {
        self.sender = sender; self.recipient = recipient
        self.amountMagnitude = amountMagnitude; self.nativeFeeMagnitude = nativeFeeMagnitude; self.totalDebitMagnitude = totalDebitMagnitude
        self.memo = memo; self.acceptedHeight = acceptedHeight; self.expiresAt = expiresAt; self.accountNumber = accountNumber
        self.sequence = sequence; self.providerFamilyID = providerFamilyID; self.preflightContext = preflightContext
        self.preflightDigest = preflightDigest ?? preflightContext?.digest
    }
}

struct QuoteAuthorityRecord: Equatable, Hashable, Sendable {
    let envelope: QuoteAuthorityEnvelope
    let snapshot: QuoteReviewSnapshot
}

public struct SendQuote: Sendable, CustomDebugStringConvertible, CustomReflectable {
    // Nil for a deposit: it addresses the chain, not an account.
    public let recipient: Address?
    public var amount: BigUInt { magnitude(amountMagnitude) }
    public var nativeFee: BigUInt { magnitude(nativeFeeMagnitude) }
    public var totalDebit: BigUInt { magnitude(totalDebitMagnitude) }
    public let memo: String?
    public let acceptedHeight: Int64
    public let expiresAt: Date

    private let amountMagnitude: Data
    private let nativeFeeMagnitude: Data
    private let totalDebitMagnitude: Data
    private let authorityRecord: QuoteAuthorityRecord
    private let sender: String

    internal init(
        recipient: Address?,
        amountMagnitude: Data,
        nativeFeeMagnitude: Data,
        totalDebitMagnitude: Data,
        memo: String?,
        acceptedHeight: Int64,
        expiresAt: Date,
        authorityRecord: QuoteAuthorityRecord,
        sender: String
    ) {
        self.recipient = recipient
        self.amountMagnitude = amountMagnitude
        self.nativeFeeMagnitude = nativeFeeMagnitude
        self.totalDebitMagnitude = totalDebitMagnitude
        self.memo = memo
        self.acceptedHeight = acceptedHeight
        self.expiresAt = expiresAt
        self.authorityRecord = authorityRecord
        self.sender = sender
    }

    internal var internalAuthorityRecord: QuoteAuthorityRecord { authorityRecord }

    internal var preflightContext: SendSnapshot? { authorityRecord.snapshot.preflightContext }

    internal var hasConsistentAuthorityProjection: Bool {
        let snapshot = authorityRecord.snapshot
        let amountValue = BigUInt(amountMagnitude)
        let feeValue = BigUInt(nativeFeeMagnitude)
        let totalDebitValue = BigUInt(totalDebitMagnitude)
        return Self.isCanonicalMagnitude(amountMagnitude, value: amountValue, allowingZero: false)
            && Self.isCanonicalMagnitude(nativeFeeMagnitude, value: feeValue, allowingZero: true)
            && Self.isCanonicalMagnitude(totalDebitMagnitude, value: totalDebitValue, allowingZero: false)
            && amountValue + feeValue == totalDebitValue
            && !sender.isEmpty
            && !snapshot.providerFamilyID.isEmpty
            && snapshot.recipient == (recipient?.raw ?? "")
            && snapshot.sender == sender
            && snapshot.expiresAt == expiresAt
            && snapshot.amountMagnitude == amountMagnitude
            && snapshot.nativeFeeMagnitude == nativeFeeMagnitude
            && snapshot.totalDebitMagnitude == totalDebitMagnitude
            && snapshot.memo == memo
            && snapshot.acceptedHeight == acceptedHeight
            && (snapshot.preflightContext.map { context in
                context.digest.count == 32
                    && snapshot.preflightDigest == context.digest
                    && context.familyID == snapshot.providerFamilyID
                    && context.sender == snapshot.sender
                    && context.recipient == snapshot.recipient
                    && context.amount == amountValue
                    && context.nativeFee == feeValue
                    && context.totalDebit == totalDebitValue
                    && context.memoMaximumBytes > 0
                    && context.height == snapshot.acceptedHeight
            } ?? true)
    }

    private static func isCanonicalMagnitude(_ data: Data, value: BigUInt, allowingZero: Bool) -> Bool {
        if data.isEmpty { return allowingZero && value == 0 }
        guard value > 0 else { return false }
        return value.serialize() == data
    }

    public var debugDescription: String {
        "SendQuote(recipient: \(recipient?.raw ?? "-"), amount: \(amount), nativeFee: \(nativeFee), totalDebit: \(totalDebit), memo: \(memo ?? "nil"), acceptedHeight: \(acceptedHeight), expiresAt: \(expiresAt.timeIntervalSince1970))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "recipient": recipient?.raw ?? "-",
            "amount": amount,
            "nativeFee": nativeFee,
            "totalDebit": totalDebit,
            "memo": memo as Any,
            "acceptedHeight": acceptedHeight,
            "expiresAt": expiresAt
        ], displayStyle: .struct)
    }
}

private func magnitude(_ data: Data) -> BigUInt {
    data.isEmpty ? 0 : BigUInt(data)
}
