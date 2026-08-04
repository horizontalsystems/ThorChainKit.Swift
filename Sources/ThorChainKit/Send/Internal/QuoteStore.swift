import BigInt
import Foundation

protocol ISendMonotonicClock: Sendable {
    var now: UInt64 { get }
}

struct SystemSendMonotonicClock: ISendMonotonicClock {
    var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

final class QuoteStore: Sendable {
    private enum State: Equatable, Sendable { case active, consumed, invalidated }
    let clientID: UUID
    private let clock: any ISendMonotonicClock
    private let stateQueue: DispatchQueue
    private let recordsKey = DispatchSpecificKey<[QuoteAuthorityRecord: State]>()

    init(clientID: UUID = UUID(), clock: any ISendMonotonicClock = SystemSendMonotonicClock()) {
        self.clientID = clientID
        self.clock = clock
        stateQueue = DispatchQueue(label: "ThorChainKit.Send.QuoteStore")
    }

    func issue(
        sender: Address,
        recipient: Address?,
        amountMagnitude: Data,
        nativeFeeMagnitude: Data,
        totalDebitMagnitude: Data,
        memo: String?,
        acceptedHeight: Int64,
        generation: UInt64,
        accountNumber: UInt64 = 0,
        sequence: UInt64 = 0,
        providerFamilyID: String = "contract",
        preflightContext: SendSnapshot? = nil
    ) throws -> SendQuote {
        var random = SystemRandomNumberGenerator()
        return try stateQueue.sync {
            var records = stateQueue.getSpecific(key: recordsKey) ?? [:]
            purgeExpired(&records)
            let amount = BigUInt(amountMagnitude)
            let fee = BigUInt(nativeFeeMagnitude)
            let totalDebit = BigUInt(totalDebitMagnitude)
            guard Self.isCanonicalMagnitude(amountMagnitude, value: amount, allowingZero: false),
                  Self.isCanonicalMagnitude(nativeFeeMagnitude, value: fee, allowingZero: true),
                  Self.isCanonicalMagnitude(totalDebitMagnitude, value: totalDebit, allowingZero: false),
                  amount + fee == totalDebit,
                  !providerFamilyID.isEmpty
            else { throw SendError.operationUnavailable }
            // Must outlive reading the confirmation screen plus biometric auth. Ten
            // seconds raced them: the clock starts when preflight finishes, so by the
            // time the user taps Send the quote is already several seconds old.
            let deadlineDate = Date().addingTimeInterval(120)
            let (deadline, overflow) = clock.now.addingReportingOverflow(120_000_000_000)
            guard !overflow else { throw SendError.operationUnavailable }
            for _ in 0..<8 {
                let token = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
                let record = QuoteAuthorityRecord(
                    envelope: QuoteAuthorityEnvelope(
                        clientID: clientID,
                        generation: generation,
                        deadline: deadline,
                        token: token
                    ),
                    snapshot: QuoteReviewSnapshot(
                        sender: sender.raw,
                        recipient: recipient?.raw ?? "",
                        amountMagnitude: amountMagnitude,
                        nativeFeeMagnitude: nativeFeeMagnitude,
                        totalDebitMagnitude: totalDebitMagnitude,
                        memo: memo,
                        acceptedHeight: acceptedHeight,
                        expiresAt: deadlineDate,
                        accountNumber: accountNumber,
                        sequence: sequence,
                        providerFamilyID: providerFamilyID,
                        preflightContext: preflightContext
                    )
                )
                guard records[record] == nil else { continue }
                records[record] = .active
                stateQueue.setSpecific(key: recordsKey, value: records)
                return SendQuote(
                    recipient: recipient,
                    amountMagnitude: amountMagnitude,
                    nativeFeeMagnitude: nativeFeeMagnitude,
                    totalDebitMagnitude: totalDebitMagnitude,
                    memo: memo,
                    acceptedHeight: acceptedHeight,
                    expiresAt: deadlineDate,
                    authorityRecord: record,
                    sender: sender.raw
                )
            }
            stateQueue.setSpecific(key: recordsKey, value: records)
            throw SendError.operationUnavailable
        }
    }

    func insert(_ quote: SendQuote) throws {
        let record = quote.internalAuthorityRecord
        try stateQueue.sync {
            var records = stateQueue.getSpecific(key: recordsKey) ?? [:]
            purgeExpired(&records)
            guard record.envelope.clientID == clientID,
                  record.envelope.token.count == 32,
                  quote.hasConsistentAuthorityProjection,
                  records[record] == nil
            else { throw SendError.operationUnavailable }
            records[record] = .active
            stateQueue.setSpecific(key: recordsKey, value: records)
        }
    }

    func consume(_ quote: SendQuote, activeGeneration: UInt64) throws -> QuoteAuthorityRecord {
        let record = quote.internalAuthorityRecord
        return try stateQueue.sync {
            var records = stateQueue.getSpecific(key: recordsKey) ?? [:]
            purgeExpired(&records)
            guard record.envelope.clientID == clientID else { throw SendError.quoteOwnershipMismatch }
            guard record.envelope.generation == activeGeneration else { throw SendError.quoteGenerationInvalidated }
            if clock.now >= record.envelope.deadline {
                records[record] = .invalidated
                stateQueue.setSpecific(key: recordsKey, value: records)
                throw SendError.quoteExpired
            }
            guard quote.hasConsistentAuthorityProjection else { throw SendError.operationUnavailable }
            guard let state = records[record] else { throw SendError.operationUnavailable }
            switch state {
            case .active:
                records[record] = .consumed
                stateQueue.setSpecific(key: recordsKey, value: records)
                return record
            case .consumed:
                throw SendError.quoteAlreadyConsumed
            case .invalidated:
                throw SendError.quoteGenerationInvalidated
            }
        }
    }

    func invalidate(generation: UInt64) {
        stateQueue.sync {
            var records = stateQueue.getSpecific(key: recordsKey) ?? [:]
            purgeExpired(&records)
            for record in records.keys where record.envelope.generation == generation {
                if records[record] == .active { records[record] = .invalidated }
            }
            stateQueue.setSpecific(key: recordsKey, value: records)
        }
    }

    func isEmpty() -> Bool {
        stateQueue.sync {
            var records = stateQueue.getSpecific(key: recordsKey) ?? [:]
            purgeExpired(&records)
            stateQueue.setSpecific(key: recordsKey, value: records)
            return records.isEmpty
        }
    }

    private func purgeExpired(_ records: inout [QuoteAuthorityRecord: State]) {
        let now = clock.now
        records = records.filter { record, _ in now < record.envelope.deadline }
    }

    private static func isCanonicalMagnitude(_ data: Data, value: BigUInt, allowingZero: Bool) -> Bool {
        if data.isEmpty { return allowingZero && value == 0 }
        guard value > 0 else { return false }
        return value.serialize() == data
    }
}
