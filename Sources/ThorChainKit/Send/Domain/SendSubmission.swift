import Foundation

public struct TransactionID: Hashable, Sendable {
    public let hash: String

    public init?(hash: String) {
        guard hash.count == 64,
              hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("A" ... "F").contains($0)) })
        else { return nil }
        self.hash = hash
    }
}

public struct SendSubmission: Sendable {
    public enum State: Sendable { case checkTxAccepted, unknown }

    public let transactionId: TransactionID
    public let state: State

    init(transactionId: TransactionID, state: State) {
        self.transactionId = transactionId
        self.state = state
    }
}
