import BigInt
import Foundation
import XCTest
@testable import ThorChainKit

final class SendCoordinatorTests: XCTestCase {
    func testAnExpiredQuoteIsRejectedBeforeBroadcast() async throws {
        // Coverage lost with the H2 test: expiry no longer cancels a running signer, so
        // this single check before broadcast is the whole barrier. The signer is allowed
        // to finish; what must not happen is the transaction going out.
        let sender = try sendOtherAddress()
        let recipient = try sendTestAddress()
        let publicKey = Data(hex: "02a9ac9f7a97da41559e1684011b6a9b0b9c0445297d5f51dea0897fd4a39c31c7")
        let snapshot = try SendSnapshot(
            familyID: "rorcual-mainnet", chainID: "thorchain-1", height: 12,
            sender: sender.raw, recipient: recipient.raw, accountNumber: 1, sequence: 2,
            amount: 100, nativeFee: 2,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey", accountPublicKeyData: publicKey
        )
        let runtime = SendRuntime(address: sender, persistenceNamespace: "coordinator-expiry")
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: sender, recipient: recipient, amount: .exact(snapshot.amount), memo: nil),
            snapshot: snapshot
        )

        // Read the clock as if the whole lifetime had already elapsed.
        let result = await SendCoordinator(runtime: runtime, now: { quote.expiresAt.addingTimeInterval(1) })
            .execute(quote: quote, signer: CountingSigner(publicKey: publicKey))

        XCTAssertEqual(result.failure, .quoteExpired)
    }

    func testAQuoteWithoutARecipientIsSignedAsADeposit() async throws {
        let sender = try sendOtherAddress()
        let publicKey = Data(hex: "02a9ac9f7a97da41559e1684011b6a9b0b9c0445297d5f51dea0897fd4a39c31c7")
        let snapshot = try SendSnapshot(
            familyID: "rorcual-mainnet", chainID: "thorchain-1", height: 12,
            sender: sender.raw, recipient: "", accountNumber: 1, sequence: 2,
            amount: 100, nativeFee: 2,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey", accountPublicKeyData: publicKey
        )
        let runtime = SendRuntime(address: sender, persistenceNamespace: "coordinator-deposit")
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: sender, recipient: nil, amount: .exact(snapshot.amount), memo: "=:BTC.BTC:bc1"),
            snapshot: snapshot
        )

        let payload = try DirectSignCodec.makeDepositSignPayload(
            context: snapshot.depositContext, asset: .rune, amount: quote.amount, memo: "=:BTC.BTC:bc1", publicKey: publicKey
        )
        let body = try Cosmos_Tx_V1beta1_TxBody(serializedBytes: payload.bodyBytes)

        XCTAssertNil(quote.recipient)
        XCTAssertEqual(body.messages[0].typeURL, "/types.MsgDeposit")
    }

    func testDenomReachesTheSigningPayloadFromTheSnapshot() async throws {
        // The coordinator builds the payload from the snapshot; if it ever stopped
        // carrying the denom, a token send would be signed as RUNE. No test drives
        // execute() as far as the handoff, so this asserts on the payload instead.
        let sender = try sendOtherAddress()
        let recipient = try sendTestAddress()
        let publicKey = Data(hex: "02a9ac9f7a97da41559e1684011b6a9b0b9c0445297d5f51dea0897fd4a39c31c7")
        let tcy = try Denom(rawValue: "tcy")
        let snapshot = try SendSnapshot(
            familyID: "rorcual-mainnet", chainID: "thorchain-1", height: 12,
            sender: sender.raw, recipient: recipient.raw, accountNumber: 1, sequence: 2,
            amount: 100, nativeFee: 2, denom: tcy,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey", accountPublicKeyData: publicKey
        )
        let runtime = SendRuntime(address: sender, persistenceNamespace: "coordinator-denom")
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: sender, recipient: recipient, amount: .exact(snapshot.amount), memo: nil, denom: tcy),
            snapshot: snapshot
        )

        let payload = try DirectSignCodec.makeSignPayload(
            snapshot: snapshot,
            quote: PreparedQuote(quote: quote, snapshot: snapshot),
            publicKey: publicKey
        )
        let body = try Cosmos_Tx_V1beta1_TxBody(serializedBytes: payload.bodyBytes)
        let message = try Types_MsgSend(serializedBytes: body.messages[0].value)

        XCTAssertEqual(message.amount.first?.denom, "tcy")
    }

    func testSignerStartsAfterAdmissionQuoteConsumptionBindingAndH1() async throws {
        let sender = try sendOtherAddress()
        let recipient = try sendTestAddress()
        let publicKey = Data(hex: "02a9ac9f7a97da41559e1684011b6a9b0b9c0445297d5f51dea0897fd4a39c31c7")
        let snapshot = try SendSnapshot(
            familyID: "rorcual-mainnet", chainID: "thorchain-1", height: 12,
            sender: sender.raw, recipient: recipient.raw, accountNumber: 1, sequence: 2,
            amount: 100, nativeFee: 2,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey", accountPublicKeyData: publicKey
        )
        let runtime = SendRuntime(address: sender, persistenceNamespace: "coordinator-ordering")
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: sender, recipient: recipient, amount: .exact(snapshot.amount), memo: nil),
            snapshot: snapshot
        )
        let signer = CountingSigner(publicKey: publicKey)

        let result = await SendCoordinator(runtime: runtime).execute(quote: quote, signer: signer)

        XCTAssertEqual(signer.callCount, 1)
        XCTAssertEqual(result.failure, .invalidSignature)
        do {
            _ = try await runtime.consumeQuote(quote)
            XCTFail("consumed quote must not be reusable")
        } catch {
            XCTAssertEqual(error as? SendError, .quoteAlreadyConsumed)
        }
    }

    func testCancelledBeforeAdmissionLeavesQuoteUnused() async throws {
        let runtime = SendRuntime(address: try sendTestAddress(), persistenceNamespace: "coordinator-pre-cancel")
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: try sendTestAddress(), recipient: try sendOtherAddress(), amount: .exact(100), memo: nil),
            snapshot: try SendSnapshot.fixture(height: 12)
        )
        let signer = CountingSigner(publicKey: Data(repeating: 0, count: 33))
        let task = Task { await SendCoordinator(runtime: runtime).execute(quote: quote, signer: signer) }
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result.failure, .signerCancelled)
        XCTAssertEqual(signer.callCount, 0)
        do {
            _ = try await runtime.consumeQuote(quote)
        } catch {
            XCTFail("pre-cancelled quote must remain unused: \(error)")
        }
    }

    func testNonCooperativeSignerCancellationReturnsPromptlyAndLateResultIsDiscarded() async throws {
        let (runtime, quote, publicKey, snapshot) = try await makeBlockingQuote(namespace: "coordinator-cancel")
        let signer = NonCooperativeSigner(publicKey: publicKey)
        let task = Task { await SendCoordinator(runtime: runtime).execute(quote: quote, signer: signer) }
        XCTAssertEqual(signer.started.wait(timeout: .now() + 1), .success)

        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.failure, .signerCancelled)
        XCTAssertEqual(signer.callCount, 1)

        let second = await SendCoordinator(runtime: runtime).execute(quote: quote, signer: signer)
        XCTAssertEqual(second.failure, .sendInProgress)
        XCTAssertEqual(signer.callCount, 1)

        signer.finish(Data(repeating: 1, count: 64))
        XCTAssertEqual(signer.finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(signer.lateHandoffCount, 0)

        let freshQuote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: try sendOtherAddress(), recipient: try sendTestAddress(), amount: .exact(snapshot.amount), memo: nil),
            snapshot: snapshot
        )
        let freshSigner = CountingSigner(publicKey: publicKey)
        _ = await SendCoordinator(runtime: runtime).execute(quote: freshQuote, signer: freshSigner)
        XCTAssertEqual(freshSigner.callCount, 1)
    }

    func testAdmissionAndOperationHoldPrecedeQuoteAccess() async throws {
        let runtime = SendRuntime(address: try sendTestAddress(), persistenceNamespace: "coordinator-order")
        let signer = CountingSigner(publicKey: Data(repeating: 0, count: 33))
        let quote = try issueTestQuote(in: QuoteStore(), clock: TestSendClock())
        let result = await SendCoordinator(runtime: runtime).execute(quote: quote, signer: signer)

        XCTAssertEqual(result.failure, .kitNotStarted)
        let admitted = await runtime.beginAccountAttempt(quote.internalAuthorityRecord.snapshot.sender)
        XCTAssertFalse(admitted)
        XCTAssertEqual(signer.callCount, 0)
    }

    func testStopDoesNotReleaseAdmittedAttemptHold() async throws {
        let runtime = SendRuntime(address: try sendTestAddress(), persistenceNamespace: "coordinator-stop")
        await runtime.activate(generation: 1)
        let sender = try sendTestAddress().raw
        let admitted = await runtime.beginAccountAttempt(sender)
        XCTAssertTrue(admitted)

        await runtime.invalidate(generation: 1)
        let admittedAfterStop = await runtime.beginAccountAttempt(sender)
        XCTAssertFalse(admittedAfterStop)
        await runtime.endAccountAttempt(sender)
    }


    func testCleanupFailureReturnsRepairPending() async throws {
        let sender = try sendOtherAddress()
        let recipient = try sendTestAddress()
        let publicKey = Data(hex: "02a9ac9f7a97da41559e1684011b6a9b0b9c0445297d5f51dea0897fd4a39c31c7")
        let snapshot = try SendSnapshot(
            familyID: "rorcual-mainnet",
            chainID: "thorchain-1",
            height: 12,
            sender: sender.raw,
            recipient: recipient.raw,
            accountNumber: 1,
            sequence: 2,
            amount: 100,
            nativeFee: 2,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey",
            accountPublicKeyData: publicKey
        )
        let runtime = SendRuntime(
            address: sender,
            persistenceNamespace: "coordinator-repair",
            reservationStore: FailingReservationStore()
        )
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: sender, recipient: recipient, amount: .exact(snapshot.amount), memo: nil),
            snapshot: snapshot
        )
        let result = await SendCoordinator(runtime: runtime, network: .mainnet).execute(
            quote: quote,
            signer: CountingSigner(publicKey: publicKey)
        )

        guard case let .repairPending(intent) = result else {
            if case let .failure(error) = result {
                return XCTFail("failed owner cleanup returned \(error)")
            }
            return XCTFail("failed owner cleanup must retain typed repair intent")
        }
        XCTAssertEqual(intent.sequence, 2)
        XCTAssertFalse(intent.reservationOwnerToken.isEmpty)
        XCTAssertEqual(intent.accountGate.sender, sender.raw)
        XCTAssertEqual(intent.operationHold.accountGate, intent.accountGate)
    }

    private func makeBlockingQuote(namespace: String) async throws -> (SendRuntime, SendQuote, Data, SendSnapshot) {
        let sender = try sendOtherAddress()
        let recipient = try sendTestAddress()
        let publicKey = Data(hex: "02a9ac9f7a97da41559e1684011b6a9b0b9c0445297d5f51dea0897fd4a39c31c7")
        let snapshot = try SendSnapshot(
            familyID: "rorcual-mainnet", chainID: "thorchain-1", height: 12,
            sender: sender.raw, recipient: recipient.raw, accountNumber: 1, sequence: 2,
            amount: 100, nativeFee: 2,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey", accountPublicKeyData: publicKey
        )
        let runtime = SendRuntime(address: sender, persistenceNamespace: namespace)
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(sender: sender, recipient: recipient, amount: .exact(snapshot.amount), memo: nil),
            snapshot: snapshot
        )
        return (runtime, quote, publicKey, snapshot)
    }

    private func makeGoldenVector(namespace: String = "coordinator-golden") async throws -> GoldenVector {
        let sender = "thor1w508d6qejxtdg4y5r3zarvary0c5xw7ku6wp68"
        let recipient = "thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean"
        let publicKey = Data(hex: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        let snapshot = try SendSnapshot(
            familyID: "thorchain-mainnet", chainID: "thorchain-1", height: 1,
            sender: sender, recipient: recipient, accountNumber: 123_456, sequence: 1,
            amount: 100_000_000, nativeFee: 0,
            mimir: MimirSnapshot(haltChainGlobal: -1, nodePauseChainGlobal: -1, haltTHORChain: -1, solvencyHaltTHORChain: -1),
            memoMaximumBytes: 256,
            accountPublicKey: "/cosmos.crypto.secp256k1.PubKey", accountPublicKeyData: publicKey
        )
        let runtime = SendRuntime(address: try Address(sender, network: .mainnet), persistenceNamespace: namespace)
        await runtime.activate(generation: 1)
        let quote = try await runtime.issuePreflightQuote(
            request: SendQuoteRequest(
                sender: try Address(sender, network: .mainnet),
                recipient: try Address(recipient, network: .mainnet),
                amount: .exact(snapshot.amount)
            ),
            snapshot: snapshot
        )
        return GoldenVector(
            runtime: runtime,
            quote: quote,
            snapshot: snapshot,
            publicKey: publicKey,
            signature: Data(hex: "23103daa64330d051da3bfa85ea7c8af9080edf19b19a306403303634b0992a32cc1b9061b2e76cd245edb2976bb437bc6636dfb23deae31e38508c5478dae45"),
            digestHex: "1ff56dd4c3627af0cee040965178f50c8d7c854e909d7b54aedbd1b7bf110b68",
            txRawHex: "0a530a510a0e2f74797065732e4d736753656e64123f0a14751e76e8199196d454941c45d1b3a323f1433bd612145a0dba49dab8fec87c6dd7c01b564ee72a8515a61a110a0472756e65120931303030303030303012590a500a460a1f2f636f736d6f732e63727970746f2e736563703235366b312e5075624b657912230a210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179812040a0208011801120510c08db7011a4023103daa64330d051da3bfa85ea7c8af9080edf19b19a306403303634b0992a32cc1b9061b2e76cd245edb2976bb437bc6636dfb23deae31e38508c5478dae45"
        )
    }
}

private struct GoldenVector {
    let runtime: SendRuntime
    let quote: SendQuote
    let snapshot: SendSnapshot
    let publicKey: Data
    let signature: Data
    let digestHex: String
    let txRawHex: String
}

private final class CoordinatorH2Provider: ISendPreflightProvider, @unchecked Sendable {
    private let runtime: SendRuntime
    private let base: SendSnapshot
    private let h2: SendSnapshot
    private let blocksH2: Bool
    private let family: EndpointFamilyDescriptor
    private let lock = NSLock()
    private var leasesIssued = 0
    private var snapshotsIssued = 0
    private var h2Continuation: CheckedContinuation<Void, Never>?

    let h2Started = DispatchSemaphore(value: 0)

    init(runtime: SendRuntime, base: SendSnapshot, h2: SendSnapshot, blocksH2: Bool = false) throws {
        self.runtime = runtime
        self.base = base
        self.h2 = h2
        self.blocksH2 = blocksH2
        family = try EndpointFamilyDescriptor(
            id: base.familyID,
            cosmosRestURL: URL(string: "https://rest.coordinator-h2.example")!,
            cometBftURL: URL(string: "https://rpc.coordinator-h2.example")!
        )
    }

    var snapshotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return snapshotsIssued
    }

    func estimateFee() async throws -> BigUInt { 2 }

    func lease(minimumHeight: Int64?) async throws -> EndpointLease {
        withLock { leasesIssued += 1 }
        return EndpointLease(family: family, verifiedChainId: base.chainID, cosmosReadHeight: base.height, cometReferenceHeight: base.height, poolGeneration: 1)
    }

    func snapshot(request: SendQuoteRequest, lease: EndpointLease, height: Int64, policy: SendPolicy, attempt: SendPreflightAttempt) async throws -> SendSnapshot {
        try await snapshotResult(request: request, lease: lease, height: height, policy: policy, attempt: attempt).snapshot
    }

    func snapshotResult(request: SendQuoteRequest, lease: EndpointLease, height: Int64, policy: SendPolicy, attempt: SendPreflightAttempt) async throws -> SendSnapshotResult {
        let index = withLock {
            snapshotsIssued += 1
            return snapshotsIssued
        }
        if index == 2, blocksH2 {
            h2Started.signal()
            await withCheckedContinuation { continuation in
                withLock { h2Continuation = continuation }
            }
        }
        let snapshot = index == 1 ? base : h2
        let boundAttempt = try await runtime.bindRoute(attempt, routeID: "recipient-account")
        return SendSnapshotResult(snapshot: snapshot, attempt: boundAttempt)
    }

    func releaseH2() {
        let continuation = withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = h2Continuation
            h2Continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class CountingSigner: ISigner, @unchecked Sendable {
    let compressedPublicKey: Data
    private(set) var callCount = 0

    init(publicKey: Data) {
        compressedPublicKey = publicKey
    }

    func sign(digest: Data) async throws -> Data {
        callCount += 1
        return Data()
    }
}

private final class NonCooperativeSigner: ISigner, @unchecked Sendable {
    let compressedPublicKey: Data
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let stateQueue = DispatchQueue(label: "ThorChainKit.Tests.NonCooperativeSigner")
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var callCount = 0
    private(set) var lateHandoffCount = 0

    init(publicKey: Data) { compressedPublicKey = publicKey }

    func sign(digest: Data) async throws -> Data {
        stateQueue.sync { callCount += 1 }
        started.signal()
        return await withCheckedContinuation { continuation in
            stateQueue.sync { self.continuation = continuation }
        }
    }

    func finish(_ signature: Data) {
        let continuation = stateQueue.sync { () -> CheckedContinuation<Data, Never>? in
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: signature)
        finished.signal()
    }
}

private final class TaskCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SendCoordinatorResult, Never>?
    private var requested = false

    func install(_ task: Task<SendCoordinatorResult, Never>) {
        lock.lock()
        self.task = task
        let requested = self.requested
        lock.unlock()
        if requested { task.cancel() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private extension SendCoordinatorResult {
    var failure: SendError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

private final class FailingReservationStore: ISequenceReservationManager, @unchecked Sendable {
    func acquire(_ key: SequenceReservationKey, ownerToken: Data) throws -> Bool { true }
    func release(_ key: SequenceReservationKey, ownerToken: Data) throws -> Bool { false }
}

private extension Data {
    var coordinatorHex: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        })
    }
}

private func coordinatorChanged(_ snapshot: SendSnapshot, height: Int64? = nil, sequence: UInt64? = nil) throws -> SendSnapshot {
    try SendSnapshot(
        familyID: snapshot.familyID,
        chainID: snapshot.chainID,
        height: height ?? snapshot.height,
        sender: snapshot.sender,
        recipient: snapshot.recipient,
        accountNumber: snapshot.accountNumber,
        sequence: sequence ?? snapshot.sequence,
        amount: snapshot.amount,
        nativeFee: snapshot.nativeFee,
        mimir: snapshot.mimir,
        memoMaximumBytes: snapshot.memoMaximumBytes,
        recipientClassification: snapshot.recipientClassification,
        policyRevision: snapshot.policyRevision,
        accountPublicKey: snapshot.accountPublicKey,
        accountPublicKeyData: snapshot.accountPublicKeyData,
        restEndpoint: snapshot.restEndpoint,
        rpcEndpoint: snapshot.rpcEndpoint,
        manifestRevision: snapshot.manifestRevision
    )
}
