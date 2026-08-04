import BigInt
import Foundation

fileprivate final class SendRuntimeAdmissionState: Sendable {
    private let stateQueue = DispatchQueue(label: "ThorChainKit.Send.Admission")
    private let generationKey = DispatchSpecificKey<UInt64>()

    func activate(generation: UInt64) {
        stateQueue.sync { stateQueue.setSpecific(key: generationKey, value: generation) }
    }

    func invalidate(generation: UInt64) {
        stateQueue.sync {
            if stateQueue.getSpecific(key: generationKey) == generation {
                stateQueue.setSpecific(key: generationKey, value: nil)
            }
        }
    }

    func isActive() -> Bool {
        stateQueue.sync { stateQueue.getSpecific(key: generationKey) != nil }
    }

    func isActive(generation: UInt64) -> Bool {
        stateQueue.sync { stateQueue.getSpecific(key: generationKey) == generation }
    }
}

struct RetryAccountSnapshot: Sendable {
    let sequence: UInt64
    let nativeFee: Data
}

enum SendRetryEvent: Sendable, Equatable {
    case operationHoldAcquired
    case journalRead
    case retryCAS
    case publicationWait
    case familySelection
    case endpointLease
    case lookup
    case policyRead
    case accountRead
    case broadcast
    case transport
    case sequenceAdvancedMutation
    case operationHoldReleased
}

struct SendRetryObservability: Sendable {
    let record: @Sendable (SendRetryEvent) -> Void

    init(record: @escaping @Sendable (SendRetryEvent) -> Void = { _ in }) {
        self.record = record
    }
}

private struct AccountAttemptState: Sendable {
    let hold: OperationHold
    let ownerToken: Data
}

actor TransactionSender {
    private let address: Address?
    private let persistenceNamespace: String
    private let quoteStore: QuoteStore
    private let sequenceReservations: (any ISequenceReservationManager)?
    private let journal: SendJournal?
    private let transactionManager: PendingTransactionManager?
    private let historyTransactionManager: TransactionManager?
    private let publicationBarrier: PendingPublicationBarrier
    private let broadcastOperation: (@Sendable (String, SignedTransaction) async throws -> BroadcastResponse)?
    private let lookupOperation: (@Sendable (String, TransactionID) async -> RetryLookupResponse)?
    private let operationRunner: EndpointOperationRunner
    private let retryAccountOperation: (@Sendable () async throws -> RetryAccountSnapshot)?
    private let retryFamilySelection: (@Sendable (String) async throws -> Void)?
    private let retryEndpointLeaseOperation: (@Sendable (String) async throws -> Void)?
    private let retryPolicyOperation: (@Sendable () async throws -> Void)?
    private let retryObservability: SendRetryObservability
    private let network: Network?
    fileprivate nonisolated let admissionState = SendRuntimeAdmissionState()
    private var activeGeneration: UInt64?
    private var preflightAttempts = [UUID: (generation: UInt64, familyID: String?, routeID: String?)]()
    private var activeAccounts = [String: AccountAttemptState]()
    private var signerFences = Set<String>()

    init(
        address: Address? = nil,
        clientID: UUID = UUID(),
        persistenceNamespace: String = UUID().uuidString,
        journal: SendJournal? = nil,
        reservationStore: (any ISequenceReservationManager)? = nil,
        broadcastOperation: (@Sendable (String, SignedTransaction) async throws -> BroadcastResponse)? = nil,
        transactionManager: PendingTransactionManager? = nil,
        historyTransactionManager: TransactionManager? = nil,
        publicationBarrier: PendingPublicationBarrier = PendingPublicationBarrier(),
        lookupOperation: (@Sendable (String, TransactionID) async -> RetryLookupResponse)? = nil,
        operationDeadline: TimeInterval = 15,
        retryAccountOperation: (@Sendable () async throws -> RetryAccountSnapshot)? = nil,
        retryFamilySelection: (@Sendable (String) async throws -> Void)? = nil,
        retryEndpointLeaseOperation: (@Sendable (String) async throws -> Void)? = nil,
        retryPolicyOperation: (@Sendable () async throws -> Void)? = nil,
        retryObservability: SendRetryObservability = SendRetryObservability()
    ) {
        self.address = address
        self.persistenceNamespace = persistenceNamespace
        network = address?.network
        quoteStore = QuoteStore(clientID: clientID)
        sequenceReservations = reservationStore
        self.journal = journal
        self.publicationBarrier = publicationBarrier
        self.transactionManager = transactionManager ?? journal.map {
            PendingTransactionManager(
                journal: $0,
                network: address?.network ?? .mainnet,
                publicationBarrier: publicationBarrier
            )
        }
        self.historyTransactionManager = historyTransactionManager
        self.broadcastOperation = broadcastOperation
        self.lookupOperation = lookupOperation
        operationRunner = EndpointOperationRunner(deadline: operationDeadline)
        self.retryAccountOperation = retryAccountOperation
        self.retryFamilySelection = retryFamilySelection
        self.retryEndpointLeaseOperation = retryEndpointLeaseOperation
        self.retryPolicyOperation = retryPolicyOperation
        self.retryObservability = retryObservability
        _ = try? journal?.recover()
        _ = self.transactionManager?.refresh()
        try? self.historyTransactionManager?.reconcileLocalTransactions()
    }

    func authorityClientID() -> UUID { quoteStore.clientID }

    private func refreshTransactionState() {
        _ = transactionManager?.refresh()
        try? historyTransactionManager?.reconcileLocalTransactions()
    }

    func activate(generation: UInt64) {
        activeGeneration = generation
        admissionState.activate(generation: generation)
    }

    func invalidate(generation: UInt64) {
        if activeGeneration == generation { activeGeneration = nil }
        admissionState.invalidate(generation: generation)
        quoteStore.invalidate(generation: generation)
        preflightAttempts = preflightAttempts.filter { $0.value.generation != generation }
    }

    nonisolated func invalidateImmediately(generation: UInt64) {
        admissionState.invalidate(generation: generation)
    }

    nonisolated func isAdmissionActive(generation: UInt64) -> Bool {
        admissionState.isActive(generation: generation)
    }

    func isAdmissionActive() -> Bool {
        guard let activeGeneration else { return false }
        return admissionState.isActive(generation: activeGeneration)
    }

    func acquireReservation(sender: String, sequence: UInt64, ownerToken: Data) throws -> Bool {
        guard let sequenceReservations, let network else { return true }
        let senderAddress = try Address(sender, network: network)
        return try sequenceReservations.acquire(
            SequenceReservationKey(
                persistenceNamespace: persistenceNamespace,
                senderPayload: senderAddress.payload,
                sequence: sequence
            ),
            ownerToken: ownerToken
        )
    }

    func releaseReservation(sender: String, sequence: UInt64, ownerToken: Data) throws -> Bool {
        guard let sequenceReservations, let network else { return true }
        let senderAddress = try Address(sender, network: network)
        return try sequenceReservations.release(
            SequenceReservationKey(
                persistenceNamespace: persistenceNamespace,
                senderPayload: senderAddress.payload,
                sequence: sequence
            ),
            ownerToken: ownerToken
        )
    }

    func admittedGeneration() throws -> UInt64 {
        guard let activeGeneration else { throw SendError.kitNotStarted }
        return activeGeneration
    }

    func consumeQuote(_ quote: SendQuote) throws {
        _ = try quoteStore.consume(quote, activeGeneration: try admittedGeneration())
    }

    func beginAccountAttempt(_ sender: String) -> Bool {
        guard admissionState.isActive() else { return false }
        guard activeAccounts[sender] == nil, !signerFences.contains(sender) else { return false }
        activeAccounts[sender] = AccountAttemptState(
            hold: OperationHold(
                id: UUID(),
                accountGate: AccountGate(persistenceNamespace: persistenceNamespace, sender: sender)
            ),
            ownerToken: Data()
        )
        return true
    }

    func acquireAccountAttempt(_ sender: String, ownerToken: Data) -> OperationHold? {
        guard admissionState.isActive() else { return nil }
        let hold = OperationHold(
            id: UUID(),
            accountGate: AccountGate(
                persistenceNamespace: persistenceNamespace,
                sender: sender
            )
        )
        guard activeAccounts[sender] == nil, !signerFences.contains(sender) else { return nil }
        activeAccounts[sender] = AccountAttemptState(hold: hold, ownerToken: ownerToken)
        return hold
    }

    func endAccountAttempt(_ sender: String) {
        activeAccounts.removeValue(forKey: sender)
    }

    func releaseOperationHold(_ hold: OperationHold, ownerToken: Data) -> Bool {
        guard let state = activeAccounts[hold.accountGate.sender],
              state.hold == hold,
              state.ownerToken == ownerToken else { return false }
        activeAccounts.removeValue(forKey: hold.accountGate.sender)
        return true
    }

    func beginSignerFence(_ sender: String) -> Bool {
        guard !signerFences.contains(sender) else { return false }
        signerFences.insert(sender)
        return true
    }

    func endSignerFence(_ sender: String) {
        signerFences.remove(sender)
    }

    func beginPreflight() throws -> SendPreflightAttempt {
        guard let generation = activeGeneration, admissionState.isActive(generation: generation) else { throw SendError.kitNotStarted }
        let attempt = SendPreflightAttempt(clientID: quoteStore.clientID, generation: generation, attemptID: UUID(), familyID: nil, routeID: nil)
        preflightAttempts[attempt.attemptID] = (generation, nil, nil)
        return attempt
    }

    func bindFamily(_ attempt: SendPreflightAttempt, familyID: String) throws -> SendPreflightAttempt {
        try guardPreflight(attempt)
        guard !familyID.isEmpty else { throw SendError.policyUnavailable }
        preflightAttempts[attempt.attemptID]?.familyID = familyID
        return SendPreflightAttempt(clientID: attempt.clientID, generation: attempt.generation, attemptID: attempt.attemptID, familyID: familyID, routeID: attempt.routeID)
    }

    func bindRoute(_ attempt: SendPreflightAttempt, routeID: String) throws -> SendPreflightAttempt {
        try guardPreflight(attempt)
        guard !routeID.isEmpty else { throw SendError.policyUnavailable }
        preflightAttempts[attempt.attemptID]?.routeID = routeID
        return SendPreflightAttempt(clientID: attempt.clientID, generation: attempt.generation, attemptID: attempt.attemptID, familyID: attempt.familyID, routeID: routeID)
    }

    func guardPreflight(_ attempt: SendPreflightAttempt, familyID: String? = nil, routeID: String? = nil) throws {
        guard let current = preflightAttempts[attempt.attemptID], current.generation == attempt.generation,
              current.familyID == attempt.familyID, current.routeID == attempt.routeID,
              attempt.clientID == quoteStore.clientID,
              activeGeneration == attempt.generation, admissionState.isActive(generation: attempt.generation)
        else { throw SendError.kitNotStarted }
        if let familyID, current.familyID != familyID { throw SendError.policyUnavailable }
        if let routeID, current.routeID != routeID { throw SendError.policyUnavailable }
    }

    func finishPreflight(_ attempt: SendPreflightAttempt) {
        preflightAttempts.removeValue(forKey: attempt.attemptID)
    }

    func activePreflightAttemptCount() -> Int { preflightAttempts.count }

    func quote(to recipient: Address, amount: SendAmount, memo: String?) throws -> SendQuote {
        try admit()
        guard let address else { throw SendError.operationUnavailable }
        if let exact = amount.exactAmount, exact == 0 { throw SendError.invalidAmount }
        guard recipient.network == address.network else { throw SendError.invalidRecipient }
        try Task.checkCancellation()
        _ = memo
        throw SendError.operationUnavailable
    }

    func issuePreflightQuote(request: SendQuoteRequest, snapshot: SendSnapshot) throws -> SendQuote {
        try admit()
        let amount = snapshot.amount
        let fee = snapshot.nativeFee
        return try quoteStore.issue(
            sender: request.sender,
            recipient: request.recipient,
            amountMagnitude: SendMagnitude(amount).data,
            nativeFeeMagnitude: SendMagnitude(fee).data,
            totalDebitMagnitude: SendMagnitude(snapshot.totalDebit).data,
            memo: request.memo,
            acceptedHeight: snapshot.height,
            generation: activeGeneration ?? 0,
            accountNumber: snapshot.accountNumber,
            sequence: snapshot.sequence,
            providerFamilyID: snapshot.familyID,
            preflightContext: snapshot
        )
    }

    func send(quote: SendQuote, signer: any ISigner) async throws -> SendSubmission {
        try admit()
        guard journal != nil else { throw SendError.operationUnavailable }
        let result = await SendCoordinator(
            runtime: self,
            persistenceNamespace: persistenceNamespace,
            network: network ?? .mainnet
        ).execute(quote: quote, signer: signer)
        guard case let .handoff(handoff) = result else {
            switch result {
            case let .failure(error): throw error
            case .repairPending: throw SendError.storageUnavailable
            case .handoff: fatalError("unreachable")
            }
        }
        guard let journal else {
            _ = releaseOperationHold(handoff.operationHold, ownerToken: handoff.reservationOwnerToken)
            throw SendError.operationUnavailable
        }
        do {
            try journal.insertBroadcasting(
                transaction: handoff.transaction,
                senderPayload: try Address(handoff.sender, network: network ?? .mainnet).payload,
                recipientPayload: handoff.recipientPayload,
                sender: handoff.sender,
                recipient: handoff.recipient,
                amount: handoff.amount,
                denom: handoff.denom,
                quotedNativeFee: handoff.quotedNativeFee,
                memo: handoff.memo,
                accountNumber: handoff.accountNumber,
                sequence: handoff.sequence,
                providerFamilyID: handoff.providerFamilyID,
                quoteHeight: handoff.quoteHeight,
                reservationOwnerToken: handoff.reservationOwnerToken
            )
            refreshTransactionState()
            guard await publicationBarrier.wait(transactionID: handoff.transaction.transactionID, generation: 1) else {
                _ = try? journal.transition(transactionID: handoff.transaction.transactionID, from: .broadcasting, expectedGeneration: 1, to: .unknown, generation: 0)
                refreshTransactionState()
                return SendSubmission(transactionId: handoff.transaction.transactionID, state: .unknown)
            }
        } catch {
            _ = releaseOperationHold(handoff.operationHold, ownerToken: handoff.reservationOwnerToken)
            throw SendError.storageUnavailable
        }
        defer { _ = releaseOperationHold(handoff.operationHold, ownerToken: handoff.reservationOwnerToken) }
        guard let broadcastOperation else {
            _ = try? journal.transition(transactionID: handoff.transaction.transactionID, from: .broadcasting, expectedGeneration: 1, to: .unknown, generation: 0)
            refreshTransactionState()
            return SendSubmission(transactionId: handoff.transaction.transactionID, state: .unknown)
        }
        do {
            let response = try await operationRunner.run(familyID: handoff.providerFamilyID) {
                try await broadcastOperation(handoff.providerFamilyID, handoff.transaction)
            }
            switch BroadcastClassifier.classify(localHash: handoff.transaction.transactionID, response: response) {
            case .checkTxAccepted:
                guard (try? journal.transition(transactionID: handoff.transaction.transactionID, from: .broadcasting, expectedGeneration: 1, to: .checkTxAccepted, generation: 1, code: response.code, codespace: response.codespace, sanitizedLog: response.sanitizedLog)) == true else {
                    return SendSubmission(transactionId: handoff.transaction.transactionID, state: .unknown)
                }
                refreshTransactionState()
                return SendSubmission(transactionId: handoff.transaction.transactionID, state: .checkTxAccepted)
            case let .rejected(rejection):
                guard (try? journal.transition(transactionID: handoff.transaction.transactionID, from: .broadcasting, expectedGeneration: 1, to: .rejected, generation: 0, code: rejection.code, codespace: response.codespace, sanitizedLog: response.sanitizedLog)) == true else {
                    return SendSubmission(transactionId: handoff.transaction.transactionID, state: .unknown)
                }
                refreshTransactionState()
                throw SendError.broadcastRejected(rejection)
            case .unknown:
                _ = try? journal.transition(transactionID: handoff.transaction.transactionID, from: .broadcasting, expectedGeneration: 1, to: .unknown, generation: 0, code: response.code, codespace: response.codespace, sanitizedLog: response.sanitizedLog)
                refreshTransactionState()
                return SendSubmission(transactionId: handoff.transaction.transactionID, state: .unknown)
            }
        } catch is CancellationError {
            _ = try? journal.transition(transactionID: handoff.transaction.transactionID, from: .broadcasting, expectedGeneration: 1, to: .unknown, generation: 0)
            refreshTransactionState()
            return SendSubmission(transactionId: handoff.transaction.transactionID, state: .unknown)
        } catch let error as SendError {
            throw error
        } catch {
            _ = try? journal.transition(transactionID: handoff.transaction.transactionID, from: .broadcasting, expectedGeneration: 1, to: .unknown, generation: 0)
            refreshTransactionState()
            return SendSubmission(transactionId: handoff.transaction.transactionID, state: .unknown)
        }
    }

    func retryBroadcast(transactionId: TransactionID, acceptingNativeFee: Data?) async throws -> SendSubmission {
        try admit()
        guard journal != nil else { throw SendError.operationUnavailable }
        guard let address else { throw SendError.operationUnavailable }
        let ownerToken = Data(UUID().uuidString.utf8)
        guard let operationHold = acquireAccountAttempt(address.raw, ownerToken: ownerToken) else { throw SendError.sendInProgress }
        retryObservability.record(.operationHoldAcquired)
        defer {
            _ = releaseOperationHold(operationHold, ownerToken: ownerToken)
            retryObservability.record(.operationHoldReleased)
        }
        guard let journal, let record = try journal.record(for: transactionId) else { throw SendError.retryRecordMissing }
        retryObservability.record(.journalRead)
        if record.state == .checkTxAccepted || record.state == .rejected { throw SendError.retryTerminal }
        if record.retryBlockedReason == .sequenceAdvanced { throw SendError.retryBlocked(.sequenceAdvanced) }
        guard let lookupOperation, let broadcastOperation else { throw SendError.operationUnavailable }
        if retryAccountOperation == nil,
           let acceptingNativeFee, acceptingNativeFee != record.quotedNativeFee {
            throw SendError.retryFeeChanged(NativeFeeChange(previous: BigUInt(record.quotedNativeFee), current: BigUInt(acceptingNativeFee)))
        }
        let nextGeneration = max(1, record.broadcastGeneration &+ 1)
        guard record.state == .unknown,
              retryCAS(journal: journal, transactionId: transactionId, expectedGeneration: record.broadcastGeneration, nextGeneration: nextGeneration) else {
            throw SendError.sendInProgress
        }
        refreshTransactionState()
        retryObservability.record(.publicationWait)
        guard await publicationBarrier.wait(transactionID: transactionId, generation: nextGeneration) else {
            _ = try? journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration)
            refreshTransactionState()
            return SendSubmission(transactionId: transactionId, state: .unknown)
        }
        let transaction = SignedTransaction(txRaw: record.signedTxRaw, transactionID: transactionId)
        do {
            if let retryFamilySelection {
                retryObservability.record(.familySelection)
                try await retryFamilySelection(record.providerFamilyID)
            }
            if let retryEndpointLeaseOperation {
                retryObservability.record(.endpointLease)
                try await retryEndpointLeaseOperation(record.providerFamilyID)
            }
            retryObservability.record(.lookup)
            let lookupResult = try await operationRunner.run(familyID: record.providerFamilyID) {
                await lookupOperation(record.providerFamilyID, transactionId)
            }
            switch lookupResult {
            case let .found(foundID, _):
                guard foundID == transactionId,
                      try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .checkTxAccepted, generation: nextGeneration) else { return SendSubmission(transactionId: transactionId, state: .unknown) }
                refreshTransactionState()
                return SendSubmission(transactionId: transactionId, state: .checkTxAccepted)
            case .providerInconsistent:
                _ = try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration, blockedReason: .providerInconsistent)
                refreshTransactionState()
                throw SendError.retryBlocked(.providerInconsistent)
            case .transportFailure:
                _ = try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration)
                refreshTransactionState()
                return SendSubmission(transactionId: transactionId, state: .unknown)
            case .notFound:
                if let retryPolicyOperation {
                    retryObservability.record(.policyRead)
                    try await retryPolicyOperation()
                }
                if let retryAccountOperation {
                    retryObservability.record(.accountRead)
                    let snapshot = try await retryAccountOperation()
                    if snapshot.sequence < record.sequence {
                        _ = try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration, blockedReason: .providerInconsistent)
                        refreshTransactionState()
                        throw SendError.retryBlocked(.providerInconsistent)
                    }
                    if snapshot.sequence > record.sequence {
                        retryObservability.record(.sequenceAdvancedMutation)
                        _ = try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration, blockedReason: .sequenceAdvanced)
                        refreshTransactionState()
                        throw SendError.retryBlocked(.sequenceAdvanced)
                    }
                    if snapshot.nativeFee != record.quotedNativeFee,
                       acceptingNativeFee != snapshot.nativeFee {
                        _ = try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration)
                        refreshTransactionState()
                        throw SendError.retryFeeChanged(NativeFeeChange(previous: BigUInt(record.quotedNativeFee), current: BigUInt(snapshot.nativeFee)))
                    }
                    if snapshot.nativeFee == record.quotedNativeFee,
                       let acceptingNativeFee, acceptingNativeFee != snapshot.nativeFee {
                        _ = try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration)
                        refreshTransactionState()
                        throw SendError.retryFeeChanged(NativeFeeChange(previous: BigUInt(record.quotedNativeFee), current: BigUInt(snapshot.nativeFee)))
                    }
                }
            }
            retryObservability.record(.broadcast)
            retryObservability.record(.transport)
            let response = try await operationRunner.run(familyID: record.providerFamilyID) {
                try await broadcastOperation(record.providerFamilyID, transaction)
            }
            switch BroadcastClassifier.classify(localHash: transactionId, response: response) {
            case .checkTxAccepted:
                guard try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .checkTxAccepted, generation: nextGeneration, code: response.code, codespace: response.codespace, sanitizedLog: response.sanitizedLog) else { return SendSubmission(transactionId: transactionId, state: .unknown) }
                refreshTransactionState()
                return SendSubmission(transactionId: transactionId, state: .checkTxAccepted)
            case let .rejected(rejection):
                guard try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .rejected, generation: nextGeneration, code: rejection.code, codespace: response.codespace, sanitizedLog: response.sanitizedLog) else { return SendSubmission(transactionId: transactionId, state: .unknown) }
                refreshTransactionState()
                throw SendError.broadcastRejected(rejection)
            case .unknown:
                _ = try journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration, code: response.code, codespace: response.codespace, sanitizedLog: response.sanitizedLog)
                refreshTransactionState()
                return SendSubmission(transactionId: transactionId, state: .unknown)
            }
        } catch let error as SendError { throw error }
        catch {
            _ = try? journal.transition(transactionID: transactionId, from: .broadcasting, expectedGeneration: nextGeneration, to: .unknown, generation: nextGeneration)
            refreshTransactionState()
            return SendSubmission(transactionId: transactionId, state: .unknown)
        }
    }

    private func admit() throws {
        guard activeGeneration != nil, admissionState.isActive() else { throw SendError.kitNotStarted }
    }

    private func retryCAS(
        journal: SendJournal,
        transactionId: TransactionID,
        expectedGeneration: UInt64,
        nextGeneration: UInt64
    ) -> Bool {
        retryObservability.record(.retryCAS)
        return (try? journal.transition(
            transactionID: transactionId,
            from: .unknown,
            expectedGeneration: expectedGeneration,
            to: .broadcasting,
            generation: nextGeneration
        )) == true
    }
}
