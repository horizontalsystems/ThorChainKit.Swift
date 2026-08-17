import Foundation
@testable import ThorChainKit
import XCTest

final class BroadcastRetryTests: XCTestCase {
    func testRetryUsesByteIdenticalTxRawWithoutSignerOrCodec() async throws {
        let fixture = try makeUnknownRecord(namespace: "retry-bytes-\(UUID().uuidString)")
        let capture = RetryCapture()
        let events = RetryEvents()
        let runtime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            broadcastOperation: { _, transaction in
                capture.append(transaction.txRaw)
                return BroadcastResponse(txHash: transaction.transactionID.hash, code: 0, codespace: nil, sanitizedLog: nil)
            },
            lookupOperation: { _, _ in .notFound },
            retryAccountOperation: { RetryAccountSnapshot(sequence: 4, nativeFee: Data([1])) },
            retryFamilySelection: { _ in },
            retryEndpointLeaseOperation: { _ in },
            retryPolicyOperation: {},
            retryObservability: SendRetryObservability { events.append($0) }
        )
        await runtime.activate(generation: 1)

        let submission = try await runtime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))

        guard case .checkTxAccepted = submission.state else {
            return XCTFail("matching CheckTx response must terminalize as accepted")
        }
        XCTAssertEqual(capture.raws, [fixture.raw])
        XCTAssertEqual(events.values, [.operationHoldAcquired, .journalRead, .retryCAS, .publicationWait, .familySelection, .endpointLease, .lookup, .policyRead, .accountRead, .broadcast, .transport, .operationHoldReleased])
    }

    func testRetryLookupTimeoutReturnsUnknownAndIgnoresLateResult() async throws {
        let fixture = try makeUnknownRecord(namespace: "retry-lookup-timeout-\(UUID().uuidString)")
        let deferred = DeferredLookup()
        let runtime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            broadcastOperation: { _, _ in
                XCTFail("lookup timeout must not broadcast")
                return BroadcastResponse(txHash: fixture.transaction.transactionID.hash, code: 0, codespace: nil, sanitizedLog: nil)
            },
            lookupOperation: { _, _ in await deferred.wait() },
            operationDeadline: 0.03,
            retryFamilySelection: { _ in },
            retryEndpointLeaseOperation: { _ in }
        )
        await runtime.activate(generation: 1)

        let submission = try await runtime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))
        guard case .unknown = submission.state else {
            return XCTFail("lookup timeout must remain unknown")
        }

        deferred.resolve(.found(transactionID: fixture.transaction.transactionID, height: 1))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(try fixture.journal.record(for: fixture.transaction.transactionID)?.state, .unknown)
    }

    func testRetryBroadcastTimeoutReturnsUnknownAndIgnoresLateResult() async throws {
        let fixture = try makeUnknownRecord(namespace: "retry-broadcast-timeout-\(UUID().uuidString)")
        let deferred = DeferredBroadcast()
        let runtime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            broadcastOperation: { _, _ in try await deferred.wait() },
            lookupOperation: { _, _ in .notFound },
            operationDeadline: 0.03,
            retryAccountOperation: { RetryAccountSnapshot(sequence: 4, nativeFee: Data([1])) },
            retryFamilySelection: { _ in },
            retryEndpointLeaseOperation: { _ in },
            retryPolicyOperation: {}
        )
        await runtime.activate(generation: 1)

        let submission = try await runtime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))
        guard case .unknown = submission.state else {
            return XCTFail("broadcast timeout must remain unknown")
        }

        deferred.resolve(BroadcastResponse(txHash: fixture.transaction.transactionID.hash, code: 0, codespace: nil, sanitizedLog: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(try fixture.journal.record(for: fixture.transaction.transactionID)?.state, .unknown)
    }

    func testSequenceAdvancedBlocksBeforeAnyIOAndSurvivesRestart() async throws {
        let fixture = try makeUnknownRecord(namespace: "retry-sequence-\(UUID().uuidString)")
        XCTAssertTrue(try fixture.journal.transition(
            transactionID: fixture.transaction.transactionID,
            from: .unknown,
            expectedGeneration: 0,
            to: .unknown,
            generation: 0,
            blockedReason: .sequenceAdvanced
        ))

        let firstCapture = RetryCapture()
        let firstEvents = RetryEvents()
        let firstRuntime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            broadcastOperation: { _, transaction in
                firstCapture.append(transaction.txRaw)
                firstCapture.transportCall()
                return BroadcastResponse(txHash: transaction.transactionID.hash, code: 0, codespace: nil, sanitizedLog: nil)
            },
            lookupOperation: { _, _ in
                firstCapture.lookupCalls += 1
                return .notFound
            },
            retryAccountOperation: { firstCapture.accountRead(); return RetryAccountSnapshot(sequence: 4, nativeFee: Data([1])) },
            retryFamilySelection: { _ in firstCapture.familySelection() },
            retryEndpointLeaseOperation: { _ in firstCapture.endpointLease() },
            retryPolicyOperation: { firstCapture.policyRead() },
            retryObservability: SendRetryObservability { firstEvents.append($0) }
        )
        await firstRuntime.activate(generation: 1)
        do {
            _ = try await firstRuntime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))
            XCTFail("sequence-advanced retry must be blocked")
        } catch let error as SendError {
            XCTAssertEqual(error, .retryBlocked(.sequenceAdvanced))
        }
        XCTAssertEqual(firstCapture.lookupCalls, 0)
        XCTAssertEqual(firstCapture.raws, [])
        XCTAssertEqual(firstCapture.familySelections, 0)
        XCTAssertEqual(firstCapture.endpointLeases, 0)
        XCTAssertEqual(firstCapture.policyReads, 0)
        XCTAssertEqual(firstCapture.accountReads, 0)
        XCTAssertEqual(firstCapture.transportCalls, 0)
        XCTAssertEqual(firstEvents.values, [.operationHoldAcquired, .journalRead, .operationHoldReleased])

        let secondCapture = RetryCapture()
        let secondEvents = RetryEvents()
        let secondRuntime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            broadcastOperation: { _, transaction in
                secondCapture.append(transaction.txRaw)
                secondCapture.transportCall()
                return BroadcastResponse(txHash: transaction.transactionID.hash, code: 0, codespace: nil, sanitizedLog: nil)
            },
            lookupOperation: { _, _ in
                secondCapture.lookupCalls += 1
                return .notFound
            },
            retryAccountOperation: { secondCapture.accountRead(); return RetryAccountSnapshot(sequence: 4, nativeFee: Data([1])) },
            retryFamilySelection: { _ in secondCapture.familySelection() },
            retryEndpointLeaseOperation: { _ in secondCapture.endpointLease() },
            retryPolicyOperation: { secondCapture.policyRead() },
            retryObservability: SendRetryObservability { secondEvents.append($0) }
        )
        await secondRuntime.activate(generation: 1)
        do {
            _ = try await secondRuntime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))
            XCTFail("persisted sequence-advanced retry must remain blocked")
        } catch let error as SendError {
            XCTAssertEqual(error, .retryBlocked(.sequenceAdvanced))
        }
        XCTAssertEqual(secondCapture.lookupCalls, 0)
        XCTAssertEqual(secondCapture.raws, [])
        XCTAssertEqual(secondCapture.familySelections, 0)
        XCTAssertEqual(secondCapture.endpointLeases, 0)
        XCTAssertEqual(secondCapture.policyReads, 0)
        XCTAssertEqual(secondCapture.accountReads, 0)
        XCTAssertEqual(secondCapture.transportCalls, 0)
        XCTAssertEqual(secondEvents.values, [.operationHoldAcquired, .journalRead, .operationHoldReleased])
        XCTAssertEqual(try fixture.journal.record(for: fixture.transaction.transactionID)?.retryBlockedReason, .sequenceAdvanced)
    }

    func testSequenceAdvancedMutationIsObservedAfterAccountRead() async throws {
        let fixture = try makeUnknownRecord(namespace: "retry-sequence-mutation-\(UUID().uuidString)")
        let capture = RetryCapture()
        let events = RetryEvents()
        let runtime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            broadcastOperation: { _, transaction in
                capture.append(transaction.txRaw)
                capture.transportCall()
                return BroadcastResponse(txHash: transaction.transactionID.hash, code: 0, codespace: nil, sanitizedLog: nil)
            },
            lookupOperation: { _, _ in .notFound },
            retryAccountOperation: { capture.accountRead(); return RetryAccountSnapshot(sequence: 5, nativeFee: Data([1])) },
            retryFamilySelection: { _ in capture.familySelection() },
            retryEndpointLeaseOperation: { _ in capture.endpointLease() },
            retryPolicyOperation: { capture.policyRead() },
            retryObservability: SendRetryObservability { events.append($0) }
        )
        await runtime.activate(generation: 1)

        do {
            _ = try await runtime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))
            XCTFail("sequence advancement must block rebroadcast")
        } catch let error as SendError {
            XCTAssertEqual(error, .retryBlocked(.sequenceAdvanced))
        }
        XCTAssertEqual(capture.raws, [])
        XCTAssertEqual(capture.transportCalls, 0)
        XCTAssertEqual(events.values, [.operationHoldAcquired, .journalRead, .retryCAS, .publicationWait, .familySelection, .endpointLease, .lookup, .policyRead, .accountRead, .sequenceAdvancedMutation, .operationHoldReleased])
    }

    func testUnapprovedProductionFamilyIsUnavailableWithoutIO() async throws {
        let fixture = try makeUnknownRecord(namespace: "retry-unavailable-\(UUID().uuidString)")
        let capture = RetryCapture()
        let events = RetryEvents()
        let runtime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            retryObservability: SendRetryObservability { events.append($0) }
        )
        await runtime.activate(generation: 1)

        do {
            _ = try await runtime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))
            XCTFail("unapproved production retry must be unavailable")
        } catch let error as SendError {
            XCTAssertEqual(error, .operationUnavailable)
        }
        XCTAssertEqual(capture.lookupCalls, 0)
        XCTAssertEqual(capture.raws, [])
        XCTAssertEqual(events.values, [.operationHoldAcquired, .journalRead, .operationHoldReleased])
    }

    func testPublicationFailureNormalizesBeforeAnyEndpointIO() async throws {
        let fixture = try makeUnknownRecord(namespace: "retry-publication-\(UUID().uuidString)")
        let barrier = PendingPublicationBarrier()
        barrier.fail(transactionID: fixture.transaction.transactionID, generation: 1)
        let capture = RetryCapture()
        let runtime = SendRuntime(
            address: fixture.sender,
            persistenceNamespace: fixture.namespace,
            journal: fixture.journal,
            broadcastOperation: { _, transaction in
                capture.append(transaction.txRaw)
                return BroadcastResponse(txHash: transaction.transactionID.hash, code: 0, codespace: nil, sanitizedLog: nil)
            },
            publicationBarrier: barrier,
            lookupOperation: { _, _ in
                capture.lookupCalls += 1
                return .notFound
            }
        )
        await runtime.activate(generation: 1)

        let submission = try await runtime.retryBroadcast(transactionId: fixture.transaction.transactionID, acceptingNativeFee: Data([1]))

        guard case .unknown = submission.state else {
            return XCTFail("failed publication must remain unknown")
        }
        XCTAssertEqual(capture.lookupCalls, 0)
        XCTAssertEqual(capture.raws, [])
        XCTAssertEqual(try fixture.journal.record(for: fixture.transaction.transactionID)?.state, .unknown)
    }

    func testLateGenerationCannotOverwriteTerminalState() throws {
        let fixture = try makeUnknownRecord(namespace: "retry-generation-\(UUID().uuidString)")
        XCTAssertTrue(try fixture.journal.transition(
            transactionID: fixture.transaction.transactionID,
            from: .unknown,
            expectedGeneration: 0,
            to: .broadcasting,
            generation: 1
        ))
        XCTAssertTrue(try fixture.journal.transition(
            transactionID: fixture.transaction.transactionID,
            from: .broadcasting,
            expectedGeneration: 1,
            to: .checkTxAccepted,
            generation: 1
        ))
        XCTAssertFalse(try fixture.journal.transition(
            transactionID: fixture.transaction.transactionID,
            from: .broadcasting,
            expectedGeneration: 1,
            to: .unknown,
            generation: 1
        ))
        guard case .checkTxAccepted = try XCTUnwrap(fixture.journal.record(for: fixture.transaction.transactionID)?.state) else {
            return XCTFail("late generation must not downgrade a terminal row")
        }
    }

    private func makeUnknownRecord(namespace: String) throws -> RetryFixture {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(namespace).sqlite")
        let database = try TransactionStorageFixture.open(path: path.path)
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let owner = Data([7, 8, 9])
        let reservations = SequenceReservationStore(storage: database.storage)
        let key = SequenceReservationKey(persistenceNamespace: namespace, senderPayload: sender.payload, sequence: 4)
        XCTAssertTrue(try reservations.acquire(key, ownerToken: owner))
        let raw = Data([0x01, 0x02, 0x03, 0x04])
        let transaction = SignedTransaction(txRaw: raw, transactionID: DirectSignCodec.transactionId(txRaw: raw))
        let journal = SendJournal(storage: database.storage, persistenceNamespace: namespace)
        try journal.insertBroadcasting(
            transaction: transaction,
            senderPayload: sender.payload,
            recipientPayload: recipient.payload,
            sender: sender.raw,
            recipient: recipient.raw,
            amount: Data([5]),
            denom: .rune,
            quotedNativeFee: Data([1]),
            memo: nil,
            accountNumber: 1,
            sequence: 4,
            providerFamilyID: "fixture",
            quoteHeight: 12,
            reservationOwnerToken: owner
        )
        XCTAssertTrue(try journal.transition(
            transactionID: transaction.transactionID,
            from: .broadcasting,
            expectedGeneration: 1,
            to: .unknown,
            generation: 0
        ))
        return RetryFixture(database: database, journal: journal, namespace: namespace, sender: sender, transaction: transaction, raw: raw)
    }
}

private struct RetryFixture {
    let database: TransactionStorageFixture
    let journal: SendJournal
    let namespace: String
    let sender: Address
    let transaction: SignedTransaction
    let raw: Data
}

private final class RetryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRaws = [Data]()
    private var storedLookupCalls = 0
    private var storedFamilySelections = 0
    private var storedEndpointLeases = 0
    private var storedPolicyReads = 0
    private var storedAccountReads = 0
    private var storedTransportCalls = 0

    var raws: [Data] {
        lock.lock(); defer { lock.unlock() }
        return storedRaws
    }

    var lookupCalls: Int {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedLookupCalls
        }
        set {
            lock.lock(); storedLookupCalls = newValue; lock.unlock()
        }
    }

    var familySelections: Int { count { storedFamilySelections } }
    var endpointLeases: Int { count { storedEndpointLeases } }
    var policyReads: Int { count { storedPolicyReads } }
    var accountReads: Int { count { storedAccountReads } }
    var transportCalls: Int { count { storedTransportCalls } }

    func familySelection() { increment { storedFamilySelections += 1 } }
    func endpointLease() { increment { storedEndpointLeases += 1 } }
    func policyRead() { increment { storedPolicyReads += 1 } }
    func accountRead() { increment { storedAccountReads += 1 } }
    func transportCall() { increment { storedTransportCalls += 1 } }

    func append(_ raw: Data) {
        lock.lock(); storedRaws.append(raw); lock.unlock()
    }

    private func count(_ read: () -> Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func increment(_ update: () -> Void) {
        lock.lock(); update(); lock.unlock()
    }
}

private final class RetryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues = [SendRetryEvent]()

    var values: [SendRetryEvent] {
        lock.lock(); defer { lock.unlock() }
        return storedValues
    }

    func append(_ event: SendRetryEvent) {
        lock.lock(); storedValues.append(event); lock.unlock()
    }
}

private final class DeferredLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RetryLookupResponse, Never>?

    func wait() async -> RetryLookupResponse {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ response: RetryLookupResponse) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}

private final class DeferredBroadcast: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BroadcastResponse, Error>?

    func wait() async throws -> BroadcastResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ response: BroadcastResponse) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}
