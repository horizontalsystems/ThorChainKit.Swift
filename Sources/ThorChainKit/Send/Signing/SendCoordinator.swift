import Foundation

actor SendCoordinator {
    private let runtime: TransactionSender
    private let persistenceNamespace: String
    private let network: Network
    private let now: @Sendable () -> Date

    init(
        runtime: TransactionSender,
        persistenceNamespace: String = "",
        network: Network = .mainnet,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runtime = runtime
        self.persistenceNamespace = persistenceNamespace
        self.network = network
        self.now = now
    }

    func execute(quote: SendQuote, signer: any ISigner) async -> SendCoordinatorResult {
        let sender = quote.internalAuthorityRecord.snapshot.sender
        guard !Task.isCancelled else { return .failure(.signerCancelled) }
        guard await runtime.isAdmissionActive() else { return .failure(.kitNotStarted) }

        let ownerToken = Self.makeOwnerToken()
        guard let operationHold = await runtime.acquireAccountAttempt(sender, ownerToken: ownerToken) else {
            return .failure(.sendInProgress)
        }
        guard !Task.isCancelled else {
            return await finalize(
                result: .failure(.signerCancelled),
                runtime: runtime,
                sender: sender,
                sequence: quote.internalAuthorityRecord.snapshot.sequence,
                ownerToken: ownerToken,
                operationHold: operationHold,
                reservationAcquired: false,
                signerFenceAcquired: false
            )
        }

        var reservationAcquired = false
        var ownershipTransferred = false
        var signerFenceAcquired = false
        var retainSignerFence = false
        var effectiveSequence = quote.internalAuthorityRecord.snapshot.sequence
        let result: SendCoordinatorResult

        do {
            let publicKey = signer.compressedPublicKey
            guard let h1 = quote.preflightContext else { throw SendError.operationUnavailable }
            try bind(publicKey: publicKey, snapshot: h1)
            // The quote's sequence was read at a pinned height and may be minutes stale;
            // signing it after the account has since transacted is a guaranteed CheckTx
            // rejection (sdk/32). Like the Android kit, read the account fresh right
            // before signing and sign whatever the chain reports now. The bounds keep a
            // lagging or hostile node from rolling the sequence back (stale re-sign) or
            // arming a far-future, never-expiring transaction.
            if let fresh = try await runtime.freshAccount(familyID: h1.familyID, sender: sender) {
                guard fresh.accountNumber == h1.accountNumber else { throw SendError.accountUnavailable }
                guard fresh.sequence >= h1.sequence, fresh.sequence - h1.sequence <= Self.maximumSequenceCatchUp else {
                    throw SendError.providerUnavailable
                }
                effectiveSequence = fresh.sequence
            }
            // Consumed only after the fresh read: a transient network failure must not burn
            // the quote. The account hold taken above serialises execute per sender, so
            // deferring consumption cannot double-consume.
            try await runtime.consumeQuote(quote)
            guard try await runtime.acquireReservation(sender: sender, sequence: effectiveSequence, ownerToken: ownerToken) else {
                throw SendError.sendInProgress
            }
            reservationAcquired = true

            let prepared = PreparedQuote(quote: quote, snapshot: h1)
            // No recipient means a deposit: the memo is the instruction, not a note.
            let payload: SignPayload
            if quote.recipient == nil {
                guard let memo = quote.memo else { throw SendError.operationUnavailable }
                payload = try DirectSignCodec.makeDepositSignPayload(
                    context: h1.depositContext(sequence: effectiveSequence),
                    asset: try Denom.asset(for: h1.denom.rawValue),
                    amount: quote.amount,
                    memo: memo,
                    publicKey: publicKey
                )
            } else {
                payload = try DirectSignCodec.makeSignPayload(snapshot: h1, quote: prepared, publicKey: publicKey, sequence: effectiveSequence)
            }
            guard await runtime.beginSignerFence(sender) else { throw SendError.sendInProgress }
            signerFenceAcquired = true
            let signerResult = await runSigner(
                signer,
                digest: payload.digest,
                sender: sender,
                expiresAt: quote.expiresAt
            )
            if signerResult.signerFinished {
                await runtime.endSignerFence(sender)
                signerFenceAcquired = false
            } else {
                retainSignerFence = true
            }
            let signature: Data
            switch signerResult.outcome {
            case let .success(value): signature = value
            case let .failure(error): throw error
            }

            try Task.checkCancellation()
            guard quote.expiresAt > now() else { throw SendError.quoteExpired }
            try Task.checkCancellation()

            let compact = try SignerVerifier().verify(signature: signature, digest: payload.digest, publicKey: publicKey)
            let transaction = try DirectSignCodec.makeTxRaw(payload: payload, compactSignature: compact.rawValue)
            ownershipTransferred = true
            result = .handoff(SendAttemptHandoff(
                transaction: transaction,
                accountGate: operationHold.accountGate,
                sender: h1.sender,
                recipient: h1.recipient,
                recipientPayload: h1.recipient.isEmpty ? nil : try Address(h1.recipient, network: network).payload,
                amount: SendMagnitude(h1.amount).data,
                denom: h1.denom,
                quotedNativeFee: SendMagnitude(h1.nativeFee).data,
                memo: quote.memo,
                accountNumber: h1.accountNumber,
                providerFamilyID: h1.familyID,
                quoteHeight: h1.height,
                persistenceNamespace: persistenceNamespace,
                sequence: effectiveSequence,
                reservationOwnerToken: ownerToken,
                operationHold: operationHold,
                runtime: runtime
            ))
        } catch is CancellationError {
            result = .failure(.signerCancelled)
        } catch let error as SignerRaceFailure {
            switch error {
            case .signerCancelled: result = .failure(.signerCancelled)
            case .signerFailed: result = .failure(.signerFailed)
            }
        } catch let error as SendError {
            result = .failure(error)
        } catch {
            result = .failure(.signerFailed)
        }

        return await finalize(
            result: result,
            runtime: runtime,
            sender: sender,
            sequence: effectiveSequence,
            ownerToken: ownerToken,
            operationHold: operationHold,
            reservationAcquired: reservationAcquired,
            signerFenceAcquired: signerFenceAcquired,
            retainSignerFence: retainSignerFence,
            ownershipTransferred: ownershipTransferred
        )
    }

    private func runSigner(
        _ signer: any ISigner,
        digest: Data,
        sender: String,
        expiresAt: Date
    ) async -> SignerRaceResult {
        // Expiry deliberately does NOT cancel a signer that has already started: the
        // user is mid-Face-ID and cannot be blamed for how long authentication takes.
        // The quote is still checked once before broadcast, which is the barrier that
        // matters — it cannot interrupt work already under way.
        let operation = SignerOperation(signer: signer, digest: digest, runtime: runtime, sender: sender)
        operation.start()
        return await withTaskCancellationHandler(operation: {
            await operation.wait()
        }, onCancel: {
            operation.cancel(.signerCancelled)
        })
    }

    private func finalize(
        result: SendCoordinatorResult,
        runtime: TransactionSender,
        sender: String,
        sequence: UInt64,
        ownerToken: Data,
        operationHold: OperationHold,
        reservationAcquired: Bool,
        signerFenceAcquired: Bool,
        retainSignerFence: Bool = false,
        ownershipTransferred: Bool = false
    ) async -> SendCoordinatorResult {
        if signerFenceAcquired && !retainSignerFence { await runtime.endSignerFence(sender) }
        guard !ownershipTransferred else { return result }
        if reservationAcquired {
            do {
                guard try await runtime.releaseReservation(sender: sender, sequence: sequence, ownerToken: ownerToken) else {
                    return repairIntent(operationHold: operationHold, sequence: sequence, ownerToken: ownerToken)
                }
            } catch {
                return repairIntent(operationHold: operationHold, sequence: sequence, ownerToken: ownerToken)
            }
        }
        guard await runtime.releaseOperationHold(operationHold, ownerToken: ownerToken) else {
            return repairIntent(operationHold: operationHold, sequence: sequence, ownerToken: ownerToken)
        }
        return result
    }

    private func repairIntent(operationHold: OperationHold, sequence: UInt64, ownerToken: Data) -> SendCoordinatorResult {
        .repairPending(RepairIntent(
            accountGate: operationHold.accountGate,
            persistenceNamespace: persistenceNamespace,
            sequence: sequence,
            reservationOwnerToken: ownerToken,
            operationHold: operationHold
        ))
    }

    private func bind(publicKey: Data, snapshot: SendSnapshot) throws {
        let validatedAddress: Address
        do {
            validatedAddress = try AccountAddressFactory.address(compressedPublicKey: publicKey, network: network)
        } catch {
            throw SendError.invalidPublicKey
        }
        guard validatedAddress.raw == snapshot.sender else { throw SendError.signerAddressMismatch }
        if let expected = snapshot.accountPublicKeyData, expected != publicKey {
            throw SendError.signerAddressMismatch
        }
    }

    // Covers every legitimate advance (the user's own recent sends) while refusing a
    // node-chosen far-future sequence.
    private static let maximumSequenceCatchUp: UInt64 = 16

    private static func makeOwnerToken() -> Data {
        var value = UUID().uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private enum SignerRaceFailure: Error, Sendable {
    case signerCancelled
    case signerFailed
}

private enum SignerRaceOutcome: Sendable {
    case success(Data)
    case failure(SignerRaceFailure)
}

private struct SignerRaceResult: Sendable {
    let outcome: SignerRaceOutcome
    let signerFinished: Bool
}

private final class SignerOperation: @unchecked Sendable {
    private let signer: any ISigner
    private let digest: Data
    private let runtime: TransactionSender
    private let sender: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var result: SignerRaceResult?
    private var waiter: CheckedContinuation<SignerRaceResult, Never>?

    init(signer: any ISigner, digest: Data, runtime: TransactionSender, sender: String) {
        self.signer = signer
        self.digest = digest
        self.runtime = runtime
        self.sender = sender
    }

    func start() {
        let task = Task { [self] in
            do {
                complete(.success(try await signer.sign(digest: digest)))
            } catch is CancellationError {
                complete(.failure(.signerCancelled))
            } catch {
                complete(.failure(.signerFailed))
            }
            await runtime.endSignerFence(sender)
        }
        lock.lock()
        self.task = task
        let shouldCancel = result != nil
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func wait() async -> SignerRaceResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func cancel(_ failure: SignerRaceFailure) {
        lock.lock()
        let task = self.task
        let waiter: CheckedContinuation<SignerRaceResult, Never>?
        if result == nil {
            result = SignerRaceResult(outcome: .failure(failure), signerFinished: false)
            waiter = self.waiter
            self.waiter = nil
        } else {
            waiter = nil
        }
        let result = self.result
        lock.unlock()
        task?.cancel()
        waiter?.resume(returning: result!)
    }

    private func complete(_ outcome: SignerRaceOutcome) {
        lock.lock()
        let waiter: CheckedContinuation<SignerRaceResult, Never>?
        if result == nil {
            result = SignerRaceResult(outcome: outcome, signerFinished: true)
            waiter = self.waiter
            self.waiter = nil
        } else {
            result = SignerRaceResult(outcome: result!.outcome, signerFinished: true)
            waiter = nil
        }
        let result = self.result!
        lock.unlock()
        waiter?.resume(returning: result)
    }
}
