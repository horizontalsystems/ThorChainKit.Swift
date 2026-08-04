import BigInt
import XCTest
@testable import ThorChainKit

final class SendPreflightCoordinatorTests: XCTestCase {
    func testPreparationUsesOneFamilyAndOneCommonHeight() async throws {
        let address = try sendTestAddress()
        let family = try EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!)
        let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 43, poolGeneration: 1)
        let snapshot = try SendSnapshot.fixture(height: 42)
        let provider = ScriptedSendProvider(leases: [lease], snapshots: [snapshot], runtime: nil)
        let runtime = SendRuntime(address: address)
        await runtime.activate(generation: 1)
        provider.runtime = runtime
        let coordinator = SendPreflightCoordinator(runtime: runtime, provider: provider)
        let prepared = try await coordinator.prepareQuote(request: SendQuoteRequest(sender: address, recipient: try sendOtherAddress(), amount: .exact(100)))

        XCTAssertEqual(prepared.quote.acceptedHeight, 42)
        XCTAssertEqual(prepared.snapshot.familyID, "rorcual-mainnet")
        XCTAssertEqual(prepared.quote.preflightContext, prepared.snapshot)
        XCTAssertEqual(prepared.quote.preflightContext?.digest.count, 32)
        XCTAssertEqual(provider.heights, [42])
    }

    func testPreparationRejectsMemoAboveExactHeightAuthLimit() async throws {
        let address = try sendTestAddress()
        let family = try EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!)
        let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 43, poolGeneration: 1)
        let snapshot = try changed(try SendSnapshot.fixture(height: 42), memoMaximumBytes: 16)
        let provider = ScriptedSendProvider(leases: [lease], snapshots: [snapshot])
        let runtime = SendRuntime(address: address)
        await runtime.activate(generation: 1)
        provider.runtime = runtime

        let request = SendQuoteRequest(sender: address, recipient: try sendOtherAddress(), amount: .exact(100), memo: String(repeating: "a", count: 17))
        do {
            _ = try await SendPreflightCoordinator(runtime: runtime, provider: provider).prepareQuote(request: request)
            XCTFail("expected memo limit rejection")
        } catch {
            XCTAssertEqual(error as? SendError, .memoTooLong(maxUTF8Bytes: 16))
        }
    }

    func testCrossFamilyOrCrossHeightSnapshotFailsClosed() async throws {
        let address = try sendTestAddress()
        let family = try EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!)
        let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1)
        let wrongHeight = try SendSnapshot.fixture(height: 43)
        let runtime = SendRuntime(address: address)
        await runtime.activate(generation: 1)
        let provider = ScriptedSendProvider(leases: [lease], snapshots: [wrongHeight], runtime: runtime)
        let coordinator = SendPreflightCoordinator(runtime: runtime, provider: provider)
        do {
            _ = try await coordinator.prepareQuote(request: SendQuoteRequest(sender: address, recipient: try sendOtherAddress(), amount: .exact(100)))
            XCTFail("mixed height must fail")
        } catch let error as SendError {
            XCTAssertEqual(error, .heightUnproven)
        }
        let activeAttempts = await runtime.activePreflightAttemptCount()
        XCTAssertEqual(activeAttempts, 0)
    }

    func testSnapshotResultMustReturnExplicitFinalRecipientRoute() async throws {
        let sender = try sendTestAddress()
        let family = try EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!)
        let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1)
        for routeID in [nil, "stale-route", "wrong-route"] as [String?] {
            let runtime = SendRuntime(address: sender)
            await runtime.activate(generation: 1)
            let provider = ScriptedSendProvider(leases: [lease], snapshots: [try SendSnapshot.fixture(height: 42)], finalRouteID: routeID, runtime: runtime)
            let coordinator = SendPreflightCoordinator(runtime: runtime, provider: provider)
            do {
                _ = try await coordinator.prepareQuote(request: SendQuoteRequest(sender: sender, recipient: try sendOtherAddress(), amount: .exact(100)))
                XCTFail("missing or stale final route must fail closed")
            } catch let error as SendError {
                XCTAssertEqual(error, .policyUnavailable)
            }
            let activeAttempts = await runtime.activePreflightAttemptCount()
            XCTAssertEqual(activeAttempts, 0)
        }
    }





    func testStoppedGenerationRejectsLatePreflightResult() async throws {
        let sender = try sendTestAddress()
        let family = try EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!)
        let lease = EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1)
        let runtime = SendRuntime(address: sender)
        await runtime.activate(generation: 1)
        let provider = DelayedSendProvider(lease: lease, snapshot: try SendSnapshot.fixture(height: 42), runtime: runtime)
        let coordinator = SendPreflightCoordinator(runtime: runtime, provider: provider)
        let task = Task { try await coordinator.prepareQuote(request: SendQuoteRequest(sender: sender, recipient: try sendOtherAddress(), amount: .exact(100))) }
        await runtime.invalidate(generation: 1)
        do {
            _ = try await task.value
            XCTFail("stopped generation must reject late result")
        } catch let error as SendError {
            XCTAssertEqual(error, .kitNotStarted)
        }
    }

    func testRapidRestartCannotReviveOldAttemptAndNewGenerationPrepares() async throws {
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()
        let family = try EndpointFamilyDescriptor(id: "rorcual-mainnet", cosmosRestURL: URL(string: "https://api-thorchain.rorcual.xyz/")!, cometBftURL: URL(string: "https://rpc-thorchain.rorcual.xyz/")!)
        let runtime = SendRuntime(address: sender)
        await runtime.activate(generation: 1)
        let delayed = DelayedSendProvider(lease: EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 1), snapshot: try SendSnapshot.fixture(height: 42), runtime: runtime)
        let oldTask = Task { try await SendPreflightCoordinator(runtime: runtime, provider: delayed).prepareQuote(request: SendQuoteRequest(sender: sender, recipient: recipient, amount: .exact(100))) }
        while await runtime.activePreflightAttemptCount() == 0 { await Task.yield() }
        await runtime.invalidate(generation: 1)
        await runtime.activate(generation: 2)
        do {
            _ = try await oldTask.value
            XCTFail("old generation must not revive")
        } catch let error as SendError {
            XCTAssertEqual(error, .kitNotStarted)
        }
        let fresh = ScriptedSendProvider(leases: [EndpointLease(family: family, verifiedChainId: "thorchain-1", cosmosReadHeight: 42, cometReferenceHeight: 42, poolGeneration: 2)], snapshots: [try SendSnapshot.fixture(height: 42)], runtime: runtime)
        let prepared = try await SendPreflightCoordinator(runtime: runtime, provider: fresh).prepareQuote(request: SendQuoteRequest(sender: sender, recipient: recipient, amount: .exact(100)))
        XCTAssertEqual(prepared.quote.acceptedHeight, 42)
        let activeAttempts = await runtime.activePreflightAttemptCount()
        XCTAssertEqual(activeAttempts, 0)
    }

}

private func changed(
    _ snapshot: SendSnapshot,
    familyID: String? = nil,
    chainID: String? = nil,
    height: Int64? = nil,
    accountNumber: UInt64? = nil,
    sequence: UInt64? = nil,
    accountPublicKey: String? = nil,
        accountPublicKeyData: Data? = nil,
        nativeFee: BigUInt? = nil,
        mimir: MimirSnapshot? = nil,
        memoMaximumBytes: Int? = nil,
        recipientClassification: RecipientAccountClassification? = nil,
    policyRevision: String? = nil,
    restEndpoint: String? = nil,
    rpcEndpoint: String? = nil,
    manifestRevision: String? = nil
) throws -> SendSnapshot {
    try SendSnapshot(
        familyID: familyID ?? snapshot.familyID, chainID: chainID ?? snapshot.chainID, height: height ?? snapshot.height,
        sender: snapshot.sender, recipient: snapshot.recipient, accountNumber: accountNumber ?? snapshot.accountNumber,
        sequence: sequence ?? snapshot.sequence, amount: snapshot.amount, nativeFee: nativeFee ?? snapshot.nativeFee, mimir: mimir ?? snapshot.mimir,
        memoMaximumBytes: memoMaximumBytes ?? snapshot.memoMaximumBytes,
        recipientClassification: recipientClassification ?? snapshot.recipientClassification,
        policyRevision: policyRevision ?? snapshot.policyRevision, accountPublicKey: accountPublicKey ?? snapshot.accountPublicKey,
        accountPublicKeyData: accountPublicKeyData ?? snapshot.accountPublicKeyData, restEndpoint: restEndpoint ?? snapshot.restEndpoint,
        rpcEndpoint: rpcEndpoint ?? snapshot.rpcEndpoint, manifestRevision: manifestRevision ?? snapshot.manifestRevision
    )
}

private final class ScriptedSendProvider: ISendPreflightProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [EndpointLease]
    private var snapshots: [SendSnapshot]
    var runtime: SendRuntime?
    private(set) var heights = [Int64]()

    private let finalRouteID: String?

    init(leases: [EndpointLease], snapshots: [SendSnapshot], finalRouteID: String? = "recipient-account", runtime: SendRuntime? = nil) {
        self.leases = leases; self.snapshots = snapshots; self.finalRouteID = finalRouteID; self.runtime = runtime
    }

    func estimateFee() async throws -> BigUInt { 2 }

    func lease(minimumHeight: Int64?) async throws -> EndpointLease {
        let lease = try withLock {
            guard !leases.isEmpty else { throw SendError.providerUnavailable }
            return leases.removeFirst()
        }
        guard minimumHeight.map({ lease.commonReadHeight >= $0 }) ?? true else { throw SendError.heightUnproven }
        return lease
    }

    func snapshot(request: SendQuoteRequest, lease: EndpointLease, height: Int64, policy: SendPolicy, attempt: SendPreflightAttempt) async throws -> SendSnapshot {
        try withLock {
            heights.append(height)
            guard !snapshots.isEmpty else { throw SendError.providerUnavailable }
            return snapshots.removeFirst()
        }
    }

    func snapshotResult(request: SendQuoteRequest, lease: EndpointLease, height: Int64, policy: SendPolicy, attempt: SendPreflightAttempt) async throws -> SendSnapshotResult {
        let finalAttempt = finalRouteID.map { attempt.withRoute($0) } ?? attempt
        let boundAttempt: SendPreflightAttempt
        if let runtime, let routeID = finalAttempt.routeID {
            boundAttempt = try await runtime.bindRoute(attempt, routeID: routeID)
        } else {
            boundAttempt = finalAttempt
        }
        return SendSnapshotResult(snapshot: try await snapshot(request: request, lease: lease, height: height, policy: policy, attempt: attempt), attempt: boundAttempt)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private struct DelayedSendProvider: ISendPreflightProvider {
    let leaseValue: EndpointLease
    let snapshotValue: SendSnapshot
    let runtime: SendRuntime?

    init(lease: EndpointLease, snapshot: SendSnapshot, runtime: SendRuntime? = nil) { leaseValue = lease; snapshotValue = snapshot; self.runtime = runtime }

    func estimateFee() async throws -> BigUInt { 2 }

    func lease(minimumHeight: Int64?) async throws -> EndpointLease {
        try await Task.sleep(nanoseconds: 50_000_000)
        return leaseValue
    }

    func snapshot(request: SendQuoteRequest, lease: EndpointLease, height: Int64, policy: SendPolicy, attempt: SendPreflightAttempt) async throws -> SendSnapshot {
        try await Task.sleep(nanoseconds: 50_000_000)
        return snapshotValue
    }

    func snapshotResult(request: SendQuoteRequest, lease: EndpointLease, height: Int64, policy: SendPolicy, attempt: SendPreflightAttempt) async throws -> SendSnapshotResult {
        let finalAttempt: SendPreflightAttempt
        if let runtime {
            finalAttempt = try await runtime.bindRoute(attempt, routeID: "recipient-account")
        } else {
            finalAttempt = attempt.withRoute("recipient-account")
        }
        return SendSnapshotResult(snapshot: try await snapshot(request: request, lease: lease, height: height, policy: policy, attempt: attempt), attempt: finalAttempt)
    }
}
