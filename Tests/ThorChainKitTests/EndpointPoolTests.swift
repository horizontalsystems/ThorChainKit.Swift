import Foundation
@testable import ThorChainKit
import XCTest

final class EndpointPoolTests: XCTestCase {
    func testLeaseSelectsGreatestCometHeightAndBreaksTiesByConfigurationOrder() async throws {
        let families = try [family("first"), family("second"), family("third")]
        let probe = CountingProbe { index, family in
            let heights: [(Int64, Int64)] = [(100, 105), (108, 110), (109, 110)]
            return healthy(index: index, family: family, heights: heights[index])
        }
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: families),
            probe: probe,
            clock: TestEndpointClock()
        )

        let lease = try await pool.lease(excludingFamilyIds: [])

        XCTAssertEqual(lease.family.id, "second")
        XCTAssertEqual(lease.cosmosReadHeight, 108)
        XCTAssertEqual(lease.cometReferenceHeight, 110)
    }

    func testCosmosAndCometRoleHeightSkewIsAcceptedInBothDirections() async throws {
        for heights: (Int64, Int64) in [(100, 101), (101, 100)] {
            let family = try family("skew-\(heights.0)-\(heights.1)")
            let pool = try EndpointPool(
                network: .mainnet,
                configuration: EndpointConfiguration(families: [family]),
                probe: CountingProbe { index, family in healthy(index: index, family: family, heights: heights) },
                clock: TestEndpointClock()
            )
            let lease = try await pool.lease(excludingFamilyIds: [])
            XCTAssertEqual(lease.commonReadHeight, min(heights.0, heights.1))
        }
    }

    func testExactFamilyRefreshBypassesCacheAndNeverFallsBackToAnotherFamily() async throws {
        let first = try family("first-refresh")
        let second = try family("second-refresh")
        let refreshProbe = FamilyRefreshProbe()
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [first, second]),
            probe: refreshProbe,
            clock: TestEndpointClock()
        )
        _ = try await pool.lease(excludingFamilyIds: [])
        let refreshed = try await pool.freshLease(familyID: first.id)
        XCTAssertEqual(refreshed.family.id, first.id)
        let probedFamilies = await refreshProbe.familyIDs
        XCTAssertEqual(probedFamilies.count, 4)
        XCTAssertEqual(probedFamilies.filter { $0 == first.id }.count, 2)
        XCTAssertEqual(probedFamilies.filter { $0 == second.id }.count, 2)

        let targetOnly = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [first, second]),
            probe: CountingProbe { index, family in
                index == 0
                    ? outcomes(index: index, family: family, node: .failure(.transport(kind: .connection)), block: .failure(.transport(kind: .connection)), comet: .failure(.transport(kind: .connection)))
                    : healthy(index: index, family: family, heights: (110, 110))
            },
            clock: TestEndpointClock()
        )
        do {
            _ = try await targetOnly.freshLease(familyID: first.id)
            XCTFail("exact-family refresh must not fall back")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .temporarilyUnavailable)
        }
    }

    func testTransientEmptyProbeIsNotCachedBeforeImmediateRecovery() async throws {
        let family = try family("primary")
        let probe = TransientThenHealthyProbe()
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family]),
            probe: probe,
            clock: TestEndpointClock()
        )

        let firstError = await leaseError(pool)
        XCTAssertEqual(firstError, .temporarilyUnavailable)
        let lease = try await pool.lease(excludingFamilyIds: [])

        XCTAssertEqual(lease.family.id, "primary")
        let probeCount = await probe.count
        XCTAssertEqual(probeCount, 2)
    }

    func testForeignObservationLocksPoolEvenWhenSiblingIsHealthyAndAnotherRequestFails() async throws {
        let families = try [family("foreign"), family("healthy")]
        let probe = CountingProbe { index, family in
            if index == 1 {
                return healthy(index: index, family: family, heights: (100, 100))
            }
            return outcomes(
                index: index,
                family: family,
                node: .success(.init(chainId: "foreign-secret-chain")),
                block: .failure(.transport(kind: .timeout)),
                comet: .success(.init(chainId: "thorchain-1", latestHeight: 100, catchingUp: false))
            )
        }
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: families),
            probe: probe,
            clock: TestEndpointClock()
        )

        let firstError = await leaseError(pool)
        let secondError = await leaseError(pool)

        guard case let .identityFailure(expected, familyId, role, request, code) = firstError else {
            return XCTFail("expected identity failure, got \(String(describing: firstError))")
        }
        XCTAssertEqual(expected, "thorchain-1")
        XCTAssertEqual(familyId, "foreign")
        XCTAssertEqual(role, .cosmosRest)
        XCTAssertEqual(request, .cosmosNodeInfo)
        XCTAssertEqual(code, .mixed)
        XCTAssertEqual(secondError, firstError)
        let probeCount = await probe.count
        XCTAssertEqual(probeCount, 2)
    }

    func testMixedIdentityTakesPrecedenceOverEarlierForeignFamily() async throws {
        let configurations = try [
            [family("foreign"), family("mixed")],
            [family("mixed"), family("foreign")],
        ]

        for families in configurations {
            let probe = CountingProbe { index, family in
                if family.id == "foreign" {
                    return outcomes(
                        index: index,
                        family: family,
                        node: .success(.init(chainId: "foreign-secret-chain")),
                        block: .success(.init(chainId: "foreign-secret-chain", latestHeight: 100)),
                        comet: .success(.init(chainId: "foreign-secret-chain", latestHeight: 100, catchingUp: false))
                    )
                }
                return outcomes(
                    index: index,
                    family: family,
                    node: .success(.init(chainId: "foreign-secret-chain")),
                    block: .success(.init(chainId: "thorchain-1", latestHeight: 100)),
                    comet: .success(.init(chainId: "thorchain-1", latestHeight: 100, catchingUp: false))
                )
            }
            let pool = try EndpointPool(
                network: .mainnet,
                configuration: EndpointConfiguration(families: families),
                probe: probe,
                clock: TestEndpointClock()
            )

            let firstError = await leaseError(pool)
            XCTAssertEqual(
                firstError,
                .identityFailure(
                    expected: "thorchain-1",
                    familyId: "mixed",
                    role: .cosmosRest,
                    request: .cosmosNodeInfo,
                    code: .mixed
                )
            )
            let lockedError = await leaseError(pool)
            XCTAssertEqual(lockedError, firstError)
        }
    }

    func testCatchingUpFamilyFallsBackAndReturnsDistinctErrorWhenAlone() async throws {
        let stale = try family("stale")
        let healthyFamily = try family("healthy")
        let probe = CountingProbe { index, family in
            healthy(index: index, family: family, heights: (100, 100), catchingUp: family.id == "stale")
        }

        let fallbackPool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [stale, healthyFamily]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let fallbackLease = try await fallbackPool.lease(excludingFamilyIds: [])
        XCTAssertEqual(fallbackLease.family.id, "healthy")

        let stalePool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [stale]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let staleError = await leaseError(stalePool)
        XCTAssertEqual(staleError, .catchingUp)
    }

    func testConcurrentWaitersShareProbeAndCancellingOneDoesNotCancelOther() async throws {
        let family = try family("shared")
        let probe = BlockingProbe()
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let first = Task { try await pool.lease(excludingFamilyIds: []) }
        await probe.waitUntilStarted()
        let second = Task { try await pool.lease(excludingFamilyIds: []) }
        await pool.waiterCountForTesting(2)

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("cancelled waiter received a lease")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        await probe.release()
        let secondLease = try await second.value
        XCTAssertEqual(secondLease.family.id, "shared")
        let probeCount = await probe.count
        XCTAssertEqual(probeCount, 1)
    }

    func testResetInvalidatesOldLeaseAndTimedHealthUsesMonotonicClock() async throws {
        let clock = TestEndpointClock()
        let family = try family("primary")
        let probe = CountingProbe { index, family in
            healthy(index: index, family: family, heights: (100, 100))
        }
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family]),
            probe: probe,
            clock: clock
        )
        let oldLease = try await pool.lease(excludingFamilyIds: [])

        await pool.reset()
        let acceptedOldFailure = await pool.recordFailure(
            for: oldLease,
            failure: .transport(retryNotBefore: clock.now.advanced(seconds: 20))
        )
        XCTAssertFalse(acceptedOldFailure)

        let currentLease = try await pool.lease(excludingFamilyIds: [])
        let acceptedCurrentFailure = await pool.recordFailure(
            for: currentLease,
            failure: .retryableStatus(code: 429, retryNotBefore: clock.now.advanced(seconds: 10))
        )
        XCTAssertTrue(acceptedCurrentFailure)
        let unavailableError = await leaseError(pool)
        XCTAssertEqual(unavailableError, .temporarilyUnavailable)

        clock.advance(seconds: 10)
        let recoveredLease = try await pool.lease(excludingFamilyIds: [])
        XCTAssertEqual(recoveredLease.family.id, "primary")
    }

    func testMalformedOutcomeSetIsInvalidButCannotMaskForeignIdentity() async throws {
        let family = try family("malformed")
        let probe = CountingProbe { index, family in
            var values = healthy(index: index, family: family, heights: (100, 100))
            values.append(values[0])
            return values
        }
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family]),
            probe: probe,
            clock: TestEndpointClock()
        )

        let malformedError = await leaseError(pool)
        XCTAssertEqual(
            malformedError,
            .invalidResponse(familyId: "malformed", role: .cosmosRest, field: .httpEnvelope)
        )
    }

    func testFreshCometWithStaleCosmosFallsBackAndReportsStaleWhenAlone() async throws {
        let stale = try family("stale")
        let healthyFamily = try family("healthy")
        let probe = CountingProbe { index, family in
            healthy(
                index: index,
                family: family,
                heights: family.id == "stale" ? (80, 100) : (100, 102)
            )
        }
        let fallbackPool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [stale, healthyFamily]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let fallbackLease = try await fallbackPool.lease(excludingFamilyIds: [])
        XCTAssertEqual(fallbackLease.family.id, "healthy")

        let stalePool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [stale]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let staleError = await leaseError(stalePool)
        XCTAssertEqual(staleError, .staleEndpoint(height: 80, bestKnown: 100))
    }

    func testPreCancelledLeaseDoesNotStartProbe() async throws {
        let probe = CountingProbe { index, family in
            healthy(index: index, family: family, heights: (100, 100))
        }
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family("primary")]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let task = Task { try await pool.lease(excludingFamilyIds: []) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("pre-cancelled lease succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        let probeCount = await probe.count
        XCTAssertEqual(probeCount, 0)
    }

    func testCancellingAllWaitersInstallsNoResult() async throws {
        let probe = SequencedBlockingProbe()
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family("primary")]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let first = Task { try await pool.lease(excludingFamilyIds: []) }
        await probe.waitForCount(1)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("cancelled lease succeeded")
        } catch is CancellationError {}
        await probe.release(1)

        let second = Task { try await pool.lease(excludingFamilyIds: []) }
        await probe.waitForCount(2)
        await probe.release(2)
        let secondLease = try await second.value
        let finalProbeCount = await probe.count
        XCTAssertEqual(secondLease.family.id, "primary")
        XCTAssertEqual(finalProbeCount, 2)
    }

    func testResetDuringProbeRejectsStaleCompletion() async throws {
        let probe = SequencedBlockingProbe()
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family("primary")]),
            probe: probe,
            clock: TestEndpointClock()
        )
        let stale = Task { try await pool.lease(excludingFamilyIds: []) }
        await probe.waitForCount(1)
        await pool.reset()
        do {
            _ = try await stale.value
            XCTFail("reset waiter succeeded")
        } catch is CancellationError {}
        await probe.release(1)

        let current = Task { try await pool.lease(excludingFamilyIds: []) }
        await probe.waitForCount(2)
        await probe.release(2)
        let lease = try await current.value
        XCTAssertEqual(lease.poolGeneration, 1)
        let probeCount = await probe.count
        XCTAssertEqual(probeCount, 2)
    }

    func testTTLExpiryCoalescesOneRevalidation() async throws {
        let clock = TestEndpointClock()
        let probe = SequencedBlockingProbe()
        let policy = try EndpointPolicy(identityRevalidationInterval: 5)
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [family("primary")], policy: policy),
            probe: probe,
            clock: clock
        )
        let initial = Task { try await pool.lease(excludingFamilyIds: []) }
        await probe.waitForCount(1)
        await probe.release(1)
        _ = try await initial.value

        clock.advance(seconds: 5)
        let first = Task { try await pool.lease(excludingFamilyIds: []) }
        let second = Task { try await pool.lease(excludingFamilyIds: []) }
        await pool.waiterCountForTesting(2)
        await probe.waitForCount(2)
        await probe.release(2)
        _ = try await (first.value, second.value)
        let probeCount = await probe.count
        XCTAssertEqual(probeCount, 2)
    }

    func testCooldownExtensionSelectsSiblingUntilLatestDeadline() async throws {
        let clock = TestEndpointClock()
        let families = try [family("primary"), family("sibling")]
        let probe = CountingProbe { index, family in
            healthy(index: index, family: family, heights: index == 0 ? (105, 105) : (103, 103))
        }
        let pool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: families),
            probe: probe,
            clock: clock
        )
        let primary = try await pool.lease(excludingFamilyIds: [])
        XCTAssertEqual(primary.family.id, "primary")
        let acceptedLongCooldown = await pool.recordFailure(
            for: primary,
            failure: .transport(retryNotBefore: clock.now.advanced(seconds: 20))
        )
        let acceptedShortCooldown = await pool.recordFailure(
            for: primary,
            failure: .transport(retryNotBefore: clock.now.advanced(seconds: 10))
        )
        XCTAssertTrue(acceptedLongCooldown)
        XCTAssertTrue(acceptedShortCooldown)
        let firstSibling = try await pool.lease(excludingFamilyIds: [])
        XCTAssertEqual(firstSibling.family.id, "sibling")
        clock.advance(seconds: 19)
        let secondSibling = try await pool.lease(excludingFamilyIds: [])
        XCTAssertEqual(secondSibling.family.id, "sibling")
        clock.advance(seconds: 1)
        let recovered = try await pool.lease(excludingFamilyIds: [])
        XCTAssertEqual(recovered.family.id, "primary")
    }

    func testFixedFallbackPrecedenceAndExclusion() async throws {
        let first = try family("first")
        let second = try family("second")
        let catchingAndInvalid = CountingProbe { index, family in
            index == 0
                ? healthy(index: index, family: family, heights: (100, 100), catchingUp: true)
                : outcomes(
                    index: index,
                    family: family,
                    node: .failure(.invalidResponse(field: .nodeInfoNetwork)),
                    block: .failure(.transport(kind: .timeout)),
                    comet: .failure(.transport(kind: .connection))
                )
        }
        let failurePool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [first, second]),
            probe: catchingAndInvalid,
            clock: TestEndpointClock()
        )
        let precedenceError = await leaseError(failurePool)
        XCTAssertEqual(
            precedenceError,
            .invalidResponse(familyId: "second", role: .cosmosRest, field: .nodeInfoNetwork)
        )

        let healthyProbe = CountingProbe { index, family in
            healthy(index: index, family: family, heights: (100, 100))
        }
        let exclusionPool = try EndpointPool(
            network: .mainnet,
            configuration: EndpointConfiguration(families: [first]),
            probe: healthyProbe,
            clock: TestEndpointClock()
        )
        let exclusionError = await leaseError(exclusionPool, excluding: ["first"])
        XCTAssertEqual(exclusionError, .noEligibleFamily)
    }

    func testHTTPFailuresFollowTerminalAndRetryableMatrix() async throws {
        let first = try family("first")
        for status in [400, 401, 403, 404] {
            let probe = CountingProbe { index, family in
                outcomes(
                    index: index,
                    family: family,
                    node: .failure(.httpStatus(code: status, retryAfterSeconds: nil)),
                    block: .failure(.transport(kind: .timeout)),
                    comet: .failure(.transport(kind: .connection))
                )
            }
            let pool = try EndpointPool(
                network: .mainnet,
                configuration: EndpointConfiguration(families: [first]),
                probe: probe,
                clock: TestEndpointClock()
            )

            let error = await leaseError(pool)
            XCTAssertEqual(
                error,
                .invalidResponse(familyId: "first", role: .cosmosRest, field: .httpEnvelope)
            )
        }
        for status in [408, 429, 502, 503, 504] {
            let probe = CountingProbe { index, family in
                outcomes(
                    index: index,
                    family: family,
                    node: .failure(.httpStatus(code: status, retryAfterSeconds: nil)),
                    block: .failure(.transport(kind: .timeout)),
                    comet: .failure(.transport(kind: .connection))
                )
            }
            let pool = try EndpointPool(
                network: .mainnet,
                configuration: EndpointConfiguration(families: [first]),
                probe: probe,
                clock: TestEndpointClock()
            )

            let error = await leaseError(pool)
            XCTAssertEqual(error, .temporarilyUnavailable)
        }
    }

    func testExtremeNonpositiveHeightsFailClosedWithoutOverflow() async throws {
        let first = try family("first")
        for heights in [(Int64.min, Int64.max), (Int64.max, Int64.min)] {
            let probe = CountingProbe { index, family in
                healthy(index: index, family: family, heights: heights)
            }
            let pool = try EndpointPool(
                network: .mainnet,
                configuration: EndpointConfiguration(families: [first]),
                probe: probe,
                clock: TestEndpointClock()
            )

            let error = await leaseError(pool)
            XCTAssertEqual(error, .staleEndpoint(height: heights.0, bestKnown: heights.1))
        }
    }

    private func leaseError(
        _ pool: EndpointPool,
        excluding: Set<String> = []
    ) async -> ProviderError? {
        do {
            _ = try await pool.lease(excludingFamilyIds: excluding)
            XCTFail("lease unexpectedly succeeded")
            return nil
        } catch let error as ProviderError {
            return error
        } catch {
            XCTFail("unexpected error: \(error)")
            return nil
        }
    }

    private func family(_ id: String) throws -> EndpointFamilyDescriptor {
        try EndpointFamilyDescriptor(
            id: id,
            cosmosRestURL: URL(string: "https://\(id).cosmos.example")!,
            cometBftURL: URL(string: "https://\(id).comet.example")!
        )
    }
}

private actor CountingProbe: INodeProber {
    private let handler: @Sendable (Int, EndpointFamilyDescriptor) -> [IndexedProbeOutcome]
    private(set) var count = 0

    init(handler: @escaping @Sendable (Int, EndpointFamilyDescriptor) -> [IndexedProbeOutcome]) {
        self.handler = handler
    }

    func probe(index: Int, family: EndpointFamilyDescriptor) async -> [IndexedProbeOutcome] {
        count += 1
        return handler(index, family)
    }
}

private actor FamilyRefreshProbe: INodeProber {
    private(set) var familyIDs = [String]()

    func probe(index: Int, family: EndpointFamilyDescriptor) async -> [IndexedProbeOutcome] {
        familyIDs.append(family.id)
        let priorProbe = familyIDs.dropLast().contains(family.id)
        let height: Int64 = family.id == "first-refresh" && priorProbe ? 120 : index == 0 ? 100 : 110
        return healthy(index: index, family: family, heights: (height, height))
    }
}

private actor TransientThenHealthyProbe: INodeProber {
    private(set) var count = 0

    func probe(index: Int, family: EndpointFamilyDescriptor) async -> [IndexedProbeOutcome] {
        count += 1
        guard count > 1 else {
            return outcomes(
                index: index,
                family: family,
                node: .failure(.transport(kind: .connection)),
                block: .failure(.transport(kind: .connection)),
                comet: .failure(.transport(kind: .connection))
            )
        }
        return healthy(index: index, family: family, heights: (100, 100))
    }
}

private actor BlockingProbe: INodeProber {
    private(set) var count = 0
    private var started = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func probe(index: Int, family: EndpointFamilyDescriptor) async -> [IndexedProbeOutcome] {
        count += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return healthy(index: index, family: family, heights: (100, 100))
    }
}

private actor SequencedBlockingProbe: INodeProber {
    private(set) var count = 0
    private var countWaiters = [(Int, CheckedContinuation<Void, Never>)]()
    private var releases = [Int: CheckedContinuation<Void, Never>]()
    private var released = Set<Int>()

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func release(_ call: Int) {
        if let continuation = releases.removeValue(forKey: call) {
            continuation.resume()
        } else {
            released.insert(call)
        }
    }

    func probe(index: Int, family: EndpointFamilyDescriptor) async -> [IndexedProbeOutcome] {
        count += 1
        let call = count
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
        if released.remove(call) == nil {
            await withCheckedContinuation { releases[call] = $0 }
        }
        return healthy(index: index, family: family, heights: (100, 100))
    }
}

private final class TestEndpointClock: IEndpointClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = EndpointInstant(nanoseconds: 0)

    var now: EndpointInstant {
        lock.withLock { instant }
    }

    func advance(seconds: Int64) {
        lock.withLock { instant = instant.advanced(seconds: TimeInterval(seconds)) }
    }
}

private func healthy(
    index: Int,
    family: EndpointFamilyDescriptor,
    heights: (Int64, Int64),
    catchingUp: Bool = false
) -> [IndexedProbeOutcome] {
    outcomes(
        index: index,
        family: family,
        node: .success(.init(chainId: "thorchain-1")),
        block: .success(.init(chainId: "thorchain-1", latestHeight: heights.0)),
        comet: .success(.init(chainId: "thorchain-1", latestHeight: heights.1, catchingUp: catchingUp))
    )
}

private func outcomes(
    index: Int,
    family: EndpointFamilyDescriptor,
    node: Result<CosmosNodeInfoObservation, RoleProbeFailure>,
    block: Result<CosmosLatestBlockObservation, RoleProbeFailure>,
    comet: Result<CometObservation, RoleProbeFailure>
) -> [IndexedProbeOutcome] {
    let cosmosOrigin = EndpointOrigin(url: family.cosmosRestURL)!
    let cometOrigin = EndpointOrigin(url: family.cometBftURL)!
    return [
        IndexedProbeOutcome(
            index: .init(familyIndex: index, familyId: family.id, role: .cosmosRest, request: .cosmosNodeInfo),
            cosmosOrigin: cosmosOrigin,
            cometOrigin: cometOrigin,
            result: .cosmosNodeInfo(node)
        ),
        IndexedProbeOutcome(
            index: .init(familyIndex: index, familyId: family.id, role: .cosmosRest, request: .cosmosLatestBlock),
            cosmosOrigin: cosmosOrigin,
            cometOrigin: cometOrigin,
            result: .cosmosLatestBlock(block)
        ),
        IndexedProbeOutcome(
            index: .init(familyIndex: index, familyId: family.id, role: .cometBft, request: .cometStatus),
            cosmosOrigin: cosmosOrigin,
            cometOrigin: cometOrigin,
            result: .cometStatus(comet)
        ),
    ]
}
