import BigInt
import Foundation

struct PendingTransaction: Sendable, CustomDebugStringConvertible, CustomReflectable {
    enum State: Sendable { case checkTxAccepted, unknown }
    enum RetryAvailability: Sendable { case available, inFlight, sequenceAdvanced, providerInconsistent, notApplicable }

    let transactionId: TransactionID
    let recipient: Address?
    var amount: BigUInt { magnitude(amountMagnitude) }
    var nativeFee: BigUInt { magnitude(nativeFeeMagnitude) }
    let memo: String?
    let state: State
    let retryAvailability: RetryAvailability
    let createdAt: Date

    private let amountMagnitude: Data
    private let nativeFeeMagnitude: Data

    init(
        transactionId: TransactionID,
        recipient: Address?,
        amountMagnitude: Data,
        nativeFeeMagnitude: Data,
        memo: String?,
        state: State,
        retryAvailability: RetryAvailability,
        createdAt: Date
    ) {
        precondition(
            Self.isCanonicalMagnitude(amountMagnitude, allowingZero: false)
                && Self.isCanonicalMagnitude(nativeFeeMagnitude, allowingZero: true)
        )
        self.transactionId = transactionId
        self.recipient = recipient
        self.amountMagnitude = amountMagnitude
        self.nativeFeeMagnitude = nativeFeeMagnitude
        self.memo = memo
        self.state = state
        self.retryAvailability = retryAvailability
        self.createdAt = createdAt
    }

    var debugDescription: String {
        "PendingTransaction(transactionId: \(transactionId.hash), recipient: \(recipient?.raw ?? "nil"), amount: \(amount), nativeFee: \(nativeFee), memo: \(memo ?? "nil"), createdAt: \(createdAt.timeIntervalSince1970))"
    }

    var customMirror: Mirror {
        Mirror(self, children: [
            "transactionId": transactionId.hash,
            "recipient": recipient?.raw as Any,
            "amount": amount,
            "nativeFee": nativeFee,
            "memo": memo as Any,
            "state": state,
            "retryAvailability": retryAvailability,
            "createdAt": createdAt,
        ], displayStyle: .struct)
    }

    static func isCanonicalMagnitude(_ data: Data, allowingZero: Bool) -> Bool {
        let value = BigUInt(data)
        if data.isEmpty { return allowingZero && value == 0 }
        guard value > 0 else { return false }
        return value.serialize() == data
    }
}

enum PendingTransactionsStatus: Sendable { case ready, degraded }

private func magnitude(_ data: Data) -> BigUInt {
    data.isEmpty ? 0 : BigUInt(data)
}
