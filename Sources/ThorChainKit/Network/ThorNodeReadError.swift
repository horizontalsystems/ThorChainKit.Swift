import Foundation

enum ThorNodeReadOperation: String, Equatable, Sendable {
    case account
    case balances
}

enum ThorNodeReadError: Error, Equatable, Sendable {
    case cancelled
    case transport(kind: TransportFailureKind)
    case httpStatus(operation: ThorNodeReadOperation, code: Int, retryAfterSeconds: Int?)
    case malformedResponse(operation: ThorNodeReadOperation)
    case unsupportedAccountType
    case invalidAccount
    case heightMismatch(expected: Int64, actual: String?)
    case invalidDenom(String)
    case invalidAmount
    case duplicateDenom(String)
    case paginationCycle
    case pageLimitExceeded
    case absentAccountWithBalances
    case staleLease
    case attemptsExhausted

    var retryAfterSeconds: Int? {
        guard case let .httpStatus(_, _, retryAfterSeconds) = self else { return nil }
        return retryAfterSeconds
    }

    func isRetryable(statusCodes: Set<Int>) -> Bool {
        switch self {
        // Anything from 500 up is the provider failing, not answering; only a client
        // error is a definitive answer. Same rule as the Android kit.
        case let .httpStatus(_, code, _): statusCodes.contains(code) || code >= 500
        case .transport: true
        default: false
        }
    }
}
