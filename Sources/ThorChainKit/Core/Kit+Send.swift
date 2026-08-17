import BigInt
import Foundation

public extension Kit {
    /// `denom` is what gets sent; nil means the chain's native coin (RUNE/CACAO). The
    /// network fee is charged in the native denom regardless, so a non-native send needs
    /// a native balance for the fee on top of the token balance. The default is derived
    /// from the network — a bare `.rune` default would silently move the wrong asset on
    /// a Maya kit.
    func quote(to recipient: Address, amount: SendAmount, memo: String? = nil, denom: Denom? = nil) async throws -> SendQuote {
        let denom = denom ?? network.nativeDenom
        if let preflight {
            return try await preflight.prepareQuote(
                request: SendQuoteRequest(
                    sender: address,
                    recipient: recipient,
                    amount: amount,
                    memo: memo == "" ? nil : memo,
                    denom: denom
                )
            ).quote
        }
        // The fallback path predates denoms and would quote the chain's native asset
        // whatever was asked for. Refuse rather than send the wrong asset.
        guard denom == network.nativeDenom else { throw SendError.operationUnavailable }
        return try await transactionSender.quote(to: recipient, amount: amount, memo: memo == "" ? nil : memo)
    }

    /// The chain-wide network fee, in native base units (RUNE/CACAO).
    func estimateFee() async throws -> BigUInt {
        guard let preflight else { throw SendError.operationUnavailable }
        return try await preflight.estimateFee()
    }

    /// A deposit addresses the chain: no recipient, and the memo is the instruction.
    /// The sign payload derives the on-chain asset from `denom` via the chain's own
    /// resolver; the `asset` parameter is retained for source compatibility only.
    func depositQuote(asset _: Asset, denom: Denom, amount: SendAmount, memo: String) async throws -> SendQuote {
        guard let preflight, !memo.isEmpty else { throw SendError.operationUnavailable }
        return try await preflight.prepareQuote(
            request: SendQuoteRequest(
                sender: address,
                recipient: nil,
                amount: amount,
                memo: memo,
                denom: denom
            )
        ).quote
    }

    func send(quote: SendQuote, signer: any ISigner) async throws -> SendSubmission {
        try await transactionSender.send(quote: quote, signer: signer)
    }

    func retryBroadcast(transactionId: TransactionID, acceptingNativeFee: BigUInt? = nil) async throws -> SendSubmission {
        let snapshot = acceptingNativeFee.map { SendMagnitude($0).data }
        return try await transactionSender.retryBroadcast(
            transactionId: transactionId,
            acceptingNativeFee: snapshot
        )
    }
}
