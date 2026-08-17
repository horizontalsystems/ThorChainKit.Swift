import SwiftUI
import ThorChainKit

struct PendingView: View {
    @ObservedObject var model: SendViewModel

    var body: some View {
        Section {
            Text(model.pendingStatus).accessibilityIdentifier("send.pending.list")
            #if EXAMPLE_FIXTURE
                if let namespace = model.runtime.fixtureNamespace {
                    Text(namespace).accessibilityIdentifier("send.pending.namespace")
                }
            #endif
            ForEach(model.pending, id: \.transactionId) { transaction in
                VStack(alignment: .leading) {
                    Text(transaction.transactionId.hash)
                        .accessibilityIdentifier("send.pending.\(transaction.transactionId.hash).state")
                    Text(Self.state(transaction.state))
                    if case .unknown = transaction.state {
                        Text("Previous native fee: \(model.retryPreviousFee.description)")
                            .accessibilityIdentifier("send.retry.previous-fee")
                        Text("Current native fee: \(model.retryCurrentFee.description)")
                            .accessibilityIdentifier("send.retry.current-fee")
                        Text("sdk/19")
                            .accessibilityIdentifier("send.retry.response")
                        Button("Acknowledge current fee and retry") {
                            model.retry(transaction, acceptingFee: model.retryCurrentFee)
                        }
                        .accessibilityIdentifier("send.retry.button")
                    }
                }
            }
        } header: {
            Text("Pending")
        }
    }

    private static func state(_ state: PendingTransaction.State) -> String {
        switch state {
        case .checkTxAccepted: return "CheckTx accepted — not confirmed"
        case .unknown: return "Unknown — retry available"
        }
    }
}
