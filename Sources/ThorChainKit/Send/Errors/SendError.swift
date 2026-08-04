import BigInt
import Foundation


public enum RetryBlockedReason: String, Hashable, Sendable {
    case sequenceAdvanced, providerInconsistent
}

public struct NativeFeeChange: Equatable, Sendable {
    public var previous: BigUInt { magnitude(previousMagnitude) }
    public var current: BigUInt { magnitude(currentMagnitude) }
    private let previousMagnitude: Data
    private let currentMagnitude: Data

    internal init(previous: BigUInt, current: BigUInt) {
        previousMagnitude = SendMagnitude(previous).data
        currentMagnitude = SendMagnitude(current).data
    }
}

public enum BroadcastCodespaceCategory: String, Hashable, Sendable { case sdk, thorchain, other }

enum BroadcastDiagnostic: String, Sendable { case invalidResponse, providerUnavailable }

public struct BroadcastRejection: Equatable, Sendable {
    public let code: UInt32
    public let codespace: BroadcastCodespaceCategory
    public let sanitizedLog: String?

    internal init(code: UInt32, codespace: String?, sanitizedLog: BroadcastDiagnostic?) {
        self.code = code == 0 ? 1 : code
        switch codespace?.lowercased() {
        case "sdk": self.codespace = .sdk
        case "thorchain": self.codespace = .thorchain
        default: self.codespace = .other
        }
        self.sanitizedLog = sanitizedLog?.rawValue
    }
}

public enum SendError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case invalidAmount, invalidRecipient, recipientIsModule
    case memoTooLong(maxUTF8Bytes: Int)
    case chainHalted, accountUnavailable, insufficientBalance, providerUnavailable
    case heightUnproven, policyUnavailable, kitNotStarted, operationUnavailable
    case quoteExpired, quoteGenerationInvalidated
    case quoteAlreadyConsumed, quoteOwnershipMismatch, signerAddressMismatch
    case invalidPublicKey, signerCancelled, signerFailed, invalidSignature
    case sendInProgress, storageUnavailable, broadcastRejected(BroadcastRejection)
    case retryRecordMissing, retryTerminal, retryFeeChanged(NativeFeeChange)
    case retryBlocked(RetryBlockedReason)

    public var description: String { render }

    public var errorDescription: String? { render }

    public var debugDescription: String { render }

    public var customMirror: Mirror {
        Mirror(self, children: [("description", render)], displayStyle: .enum)
    }

    private var render: String {
        switch self {
        case .invalidAmount: return "invalidAmount"
        case .invalidRecipient: return "invalidRecipient"
        case .recipientIsModule: return "recipientIsModule"
        case let .memoTooLong(max): return "memoTooLong(maxUTF8Bytes: \(max))"
        case .chainHalted: return "chainHalted"
        case .accountUnavailable: return "accountUnavailable"
        case .insufficientBalance: return "insufficientBalance"
        case .providerUnavailable: return "providerUnavailable"
        case .heightUnproven: return "heightUnproven"
        case .policyUnavailable: return "policyUnavailable"
        case .kitNotStarted: return "kitNotStarted"
        case .operationUnavailable: return "operationUnavailable"
        case .quoteExpired: return "quoteExpired"
        case .quoteGenerationInvalidated: return "quoteGenerationInvalidated"
        case .quoteAlreadyConsumed: return "quoteAlreadyConsumed"
        case .quoteOwnershipMismatch: return "quoteOwnershipMismatch"
        case .signerAddressMismatch: return "signerAddressMismatch"
        case .invalidPublicKey: return "invalidPublicKey"
        case .signerCancelled: return "signerCancelled"
        case .signerFailed: return "signerFailed"
        case .invalidSignature: return "invalidSignature"
        case .sendInProgress: return "sendInProgress"
        case .storageUnavailable: return "storageUnavailable"
        case let .broadcastRejected(rejection): return "broadcastRejected(code: \(rejection.code), codespace: \(rejection.codespace.rawValue), sanitizedLog: \(rejection.sanitizedLog ?? "nil"))"
        case .retryRecordMissing: return "retryRecordMissing"
        case .retryTerminal: return "retryTerminal"
        case let .retryFeeChanged(change): return "retryFeeChanged(previous: \(change.previous), current: \(change.current))"
        case let .retryBlocked(reason): return "retryBlocked(\(reason.rawValue))"
        }
    }
}

private func magnitude(_ data: Data) -> BigUInt {
    data.isEmpty ? 0 : BigUInt(data)
}
