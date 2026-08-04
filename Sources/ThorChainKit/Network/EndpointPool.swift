import Foundation

actor EndpointPool {
    private let network: Network
    private let configuration: EndpointConfiguration
    private let probe: any INodeProber
    private let clock: any IEndpointClock

    private var generation: UInt64 = 0
    private var cachedFamilies: [VerifiedFamily]?
    private var cacheDate: EndpointInstant?
    private var health = [String: EndpointHealth]()
    private var identityLock: ProviderError?
    private var sharedProbe: SharedProbe?
    private var waiters = [UUID: Waiter]()
    private var waiterCountObservers = [(Int, CheckedContinuation<Void, Never>)]()

    init(
        network: Network,
        configuration: EndpointConfiguration,
        probe: any INodeProber,
        clock: any IEndpointClock = SystemEndpointClock()
    ) {
        self.network = network
        self.configuration = configuration
        self.probe = probe
        self.clock = clock
    }

    func lease(excludingFamilyIds: Set<String>) async throws -> EndpointLease {
        if let identityLock { throw identityLock }
        if cacheIsCurrent, let cachedFamilies {
            return try select(from: cachedFamilies, excluding: excludingFamilyIds, fallback: .noEligibleFamily)
        }

        let waiterID = UUID()
        let latch = CancellationLatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enroll(
                    id: waiterID,
                    latch: latch,
                    excluding: excludingFamilyIds,
                    continuation: continuation
                )
            }
        } onCancel: {
            latch.cancel()
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    // The height carried by a lease the identity probe has just produced is seconds old
    // at most, and asking for it again cost a second round trip on every read — on a slow
    // node that was seven seconds of the thirty a cold start took.
    private static let leaseHeightFreshness: TimeInterval = 5

    func readLease(excludingFamilyIds: Set<String>) async throws -> EndpointLease {
        let started = Date()
        let cachedLease = try await lease(excludingFamilyIds: excludingFamilyIds)
        if let cacheDate, clock.now < cacheDate.advanced(seconds: Self.leaseHeightFreshness) {
            return cachedLease
        }
        let latestBlock = await probe.latestBlock(family: cachedLease.family)
        if case let .success(block) = latestBlock,
           block.chainId == cachedLease.verifiedChainId,
           block.latestHeight > 0 {
            return EndpointLease(
                family: cachedLease.family,
                verifiedChainId: cachedLease.verifiedChainId,
                cosmosReadHeight: block.latestHeight,
                cometReferenceHeight: cachedLease.cometReferenceHeight,
                poolGeneration: cachedLease.poolGeneration
            )
        }
        return cachedLease
    }

    func freshLease(excludingFamilyIds: Set<String>) async throws -> EndpointLease {
        cachedFamilies = nil
        cacheDate = nil
        return try await lease(excludingFamilyIds: excludingFamilyIds)
    }

    func freshLease(familyID: String) async throws -> EndpointLease {
        cachedFamilies = nil
        cacheDate = nil
        let excluded = Set(configuration.families.map(\.id).filter { $0 != familyID })
        let lease = try await lease(excludingFamilyIds: excluded)
        guard lease.family.id == familyID else { throw ProviderError.noEligibleFamily }
        return lease
    }

    @discardableResult
    func recordFailure(for lease: EndpointLease, failure: EndpointFailure) -> Bool {
        guard lease.poolGeneration == generation,
              configuration.families.contains(where: { $0 == lease.family })
        else {
            return false
        }
        let retryNotBefore = failure.retryNotBefore
        if let existing = health[lease.family.id], existing.retryNotBefore >= retryNotBefore {
            return true
        }
        health[lease.family.id] = EndpointHealth(retryNotBefore: retryNotBefore)
        return true
    }

    func isCurrent(_ lease: EndpointLease) -> Bool {
        lease.poolGeneration == generation
            && configuration.families.contains(where: { $0 == lease.family })
    }

    func reset() {
        generation &+= 1
        sharedProbe?.task.cancel()
        sharedProbe = nil
        cachedFamilies = nil
        cacheDate = nil
        health.removeAll()
        identityLock = nil
        let pending = waiters.values
        waiters.removeAll()
        notifyWaiterCountObservers()
        pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    func waiterCountForTesting(_ expected: Int) async {
        if waiters.count >= expected { return }
        await withCheckedContinuation { waiterCountObservers.append((expected, $0)) }
    }

    private var cacheIsCurrent: Bool {
        guard let cacheDate else { return false }
        return clock.now < cacheDate.advanced(seconds: configuration.policy.identityRevalidationInterval)
    }

    private func enroll(
        id: UUID,
        latch: CancellationLatch,
        excluding: Set<String>,
        continuation: CheckedContinuation<EndpointLease, Error>
    ) {
        guard !latch.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters[id] = Waiter(latch: latch, excluding: excluding, continuation: continuation)
        notifyWaiterCountObservers()
        guard sharedProbe == nil else { return }

        let token = UUID()
        let currentGeneration = generation
        let families = configuration.families
        let probe = probe
        let task = Task {
            await withTaskGroup(of: (Int, [IndexedProbeOutcome]).self) { group in
                for (index, family) in families.enumerated() {
                    group.addTask {
                        (index, await probe.probe(index: index, family: family))
                    }
                }
                var collected = [(Int, [IndexedProbeOutcome])]()
                for await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        sharedProbe = SharedProbe(generation: currentGeneration, token: token, task: task)
        Task {
            let outcomes = await task.value
            completeProbe(generation: currentGeneration, token: token, outcomes: outcomes)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        notifyWaiterCountObservers()
        if waiters.isEmpty {
            sharedProbe?.task.cancel()
            sharedProbe = nil
        }
    }

    private func completeProbe(
        generation completedGeneration: UInt64,
        token: UUID,
        outcomes: [[IndexedProbeOutcome]]
    ) {
        guard completedGeneration == generation, sharedProbe?.token == token else { return }
        sharedProbe = nil

        let ordered = waiters.sorted { $0.key.uuidString < $1.key.uuidString }
        var locked = [(UUID, Waiter)]()
        for (id, waiter) in ordered where waiter.latch.lockIfActive() {
            locked.append((id, waiter))
        }
        let cancelledIDs = Set(ordered.map(\.key)).subtracting(locked.map(\.0))
        let evaluation = evaluate(outcomes)

        if !locked.isEmpty {
            if case let .failure(error) = evaluation, error.isIdentityFailure {
                identityLock = error
            }
            if case let .success(families, _) = evaluation, !families.isEmpty {
                cachedFamilies = families
                cacheDate = clock.now
            }
        }

        for (id, _) in locked { waiters.removeValue(forKey: id) }
        for id in cancelledIDs { waiters.removeValue(forKey: id) }
        notifyWaiterCountObservers()

        let deliveries = locked.map { _, waiter -> (Waiter, Result<EndpointLease, Error>) in
            switch evaluation {
            case let .success(families, fallback):
                do {
                    return (waiter, .success(try select(
                        from: families,
                        excluding: waiter.excluding,
                        fallback: fallback
                    )))
                } catch {
                    return (waiter, .failure(error))
                }
            case let .failure(error):
                return (waiter, .failure(error))
            }
        }
        locked.forEach { $0.1.latch.unlock() }
        deliveries.forEach { waiter, result in waiter.continuation.resume(with: result) }
        for id in cancelledIDs {
            ordered.first(where: { $0.key == id })?.value.continuation.resume(throwing: CancellationError())
        }
    }

    private func evaluate(_ allOutcomes: [[IndexedProbeOutcome]]) -> ProbeEvaluation {
        if let identityError = identityError(in: allOutcomes) {
            return .failure(identityError)
        }

        var verified = [VerifiedFamily]()
        var issues = [FamilyIssue]()
        for (index, family) in configuration.families.enumerated() {
            let outcomes = index < allOutcomes.count ? allOutcomes[index] : []
            guard hasExactShape(outcomes, familyIndex: index, family: family) else {
                issues.append(.invalid(family.id, .cosmosRest, .httpEnvelope))
                continue
            }
            guard case let .cosmosNodeInfo(.success(node)) = outcomes[0].result,
                  case let .cosmosLatestBlock(.success(block)) = outcomes[1].result,
                  case let .cometStatus(.success(comet)) = outcomes[2].result
            else {
                issues.append(failureIssue(outcomes, familyId: family.id))
                continue
            }
            if comet.catchingUp {
                issues.append(.catchingUp)
                continue
            }
            guard block.latestHeight > 0, comet.latestHeight > 0 else {
                issues.append(.stale(block.latestHeight, comet.latestHeight))
                continue
            }
            let skew = block.latestHeight >= comet.latestHeight
                ? block.latestHeight - comet.latestHeight
                : comet.latestHeight - block.latestHeight
            if skew > configuration.policy.maximumHeightLag {
                issues.append(.stale(block.latestHeight, comet.latestHeight))
                continue
            }
            verified.append(VerifiedFamily(
                originalIndex: index,
                family: family,
                chainId: node.chainId,
                cosmosHeight: block.latestHeight,
                cometHeight: comet.latestHeight
            ))
        }

        if let best = verified.map(\.cometHeight).max() {
            verified = verified.filter {
                let lag = best - $0.cometHeight
                if lag > configuration.policy.maximumHeightLag {
                    issues.append(.stale($0.cometHeight, best))
                    return false
                }
                return true
            }
        }
        return .success(verified, fallback: fallbackError(issues))
    }

    private func identityError(in allOutcomes: [[IndexedProbeOutcome]]) -> ProviderError? {
        var candidates: [(
            familyIndex: Int,
            familyId: String,
            observation: IdentityObservation,
            code: IdentityFailureCode
        )] = []

        for (familyIndex, outcomes) in allOutcomes.enumerated() {
            guard familyIndex < configuration.families.count else { continue }
            let family = configuration.families[familyIndex]
            let observations = outcomes.compactMap(identityObservation)
                .sorted {
                    return $0.request.rawValue < $1.request.rawValue
                }
            let identities = Set(observations.map(\.chainId))
            if identities.count > 1, let first = observations.first {
                candidates.append((familyIndex, family.id, first, .mixed))
            }
            else if let foreign = observations.first(where: { $0.chainId != network.expectedChainId }) {
                candidates.append((familyIndex, family.id, foreign, .foreign))
            }
        }

        guard let candidate = candidates.sorted(by: {
            if $0.code != $1.code {
                return $0.code == .mixed
            }
            if $0.familyIndex != $1.familyIndex {
                return $0.familyIndex < $1.familyIndex
            }
            return $0.observation.request.rawValue < $1.observation.request.rawValue
        }).first else {
            return nil
        }
        return .identityFailure(
            expected: network.expectedChainId,
            familyId: candidate.familyId,
            role: candidate.observation.role,
            request: candidate.observation.request,
            code: candidate.code
        )
    }

    private func identityObservation(_ outcome: IndexedProbeOutcome) -> IdentityObservation? {
        switch outcome.result {
        case let .cosmosNodeInfo(.success(value)):
            IdentityObservation(chainId: value.chainId, role: .cosmosRest, request: .cosmosNodeInfo)
        case let .cosmosLatestBlock(.success(value)):
            IdentityObservation(chainId: value.chainId, role: .cosmosRest, request: .cosmosLatestBlock)
        case let .cometStatus(.success(value)):
            IdentityObservation(chainId: value.chainId, role: .cometBft, request: .cometStatus)
        default:
            nil
        }
    }

    private func hasExactShape(
        _ outcomes: [IndexedProbeOutcome],
        familyIndex: Int,
        family: EndpointFamilyDescriptor
    ) -> Bool {
        guard outcomes.count == 3 else { return false }
        for (position, request) in ProbeRequestKind.allCases.enumerated() {
            let outcome = outcomes[position]
            let role: EndpointRole = request == .cometStatus ? .cometBft : .cosmosRest
            guard outcome.index == ProbeRequestIndex(
                familyIndex: familyIndex,
                familyId: family.id,
                role: role,
                request: request
            ) else {
                return false
            }
            switch (request, outcome.result) {
            case (.cosmosNodeInfo, .cosmosNodeInfo),
                 (.cosmosLatestBlock, .cosmosLatestBlock),
                 (.cometStatus, .cometStatus):
                break
            default:
                return false
            }
        }
        return true
    }

    private func failureIssue(_ outcomes: [IndexedProbeOutcome], familyId: String) -> FamilyIssue {
        for outcome in outcomes {
            let failure: RoleProbeFailure?
            switch outcome.result {
            case let .cosmosNodeInfo(.failure(value)),
                 let .cosmosLatestBlock(.failure(value)),
                 let .cometStatus(.failure(value)):
                failure = value
            default:
                failure = nil
            }
            if case let .invalidResponse(field) = failure {
                return .invalid(familyId, outcome.index.role, field)
            }
            if case let .httpStatus(code, _) = failure,
               !configuration.policy.retryableStatusCodes.contains(code)
            {
                return .invalid(familyId, outcome.index.role, .httpEnvelope)
            }
        }
        return .temporary
    }

    private func fallbackError(_ issues: [FamilyIssue]) -> ProviderError {
        if let invalid = issues.compactMap({ issue -> (String, EndpointRole, ProbeField)? in
            if case let .invalid(family, role, field) = issue { return (family, role, field) }
            return nil
        }).first {
            return .invalidResponse(familyId: invalid.0, role: invalid.1, field: invalid.2)
        }
        if issues.contains(where: { if case .catchingUp = $0 { true } else { false } }) {
            return .catchingUp
        }
        if let stale = issues.compactMap({ issue -> (Int64, Int64)? in
            if case let .stale(height, best) = issue { return (height, best) }
            return nil
        }).first {
            return .staleEndpoint(height: stale.0, bestKnown: stale.1)
        }
        if issues.contains(where: { if case .temporary = $0 { true } else { false } }) {
            return .temporarilyUnavailable
        }
        return .noEligibleFamily
    }

    private func select(
        from families: [VerifiedFamily],
        excluding: Set<String>,
        fallback: ProviderError
    ) throws -> EndpointLease {
        let now = clock.now
        let candidates = families.filter { family in
            guard !excluding.contains(family.family.id) else { return false }
            guard let unavailable = health[family.family.id]?.retryNotBefore else { return true }
            return unavailable <= now
        }
        guard let selected = candidates.max(by: {
            if $0.cometHeight == $1.cometHeight { return $0.originalIndex > $1.originalIndex }
            return $0.cometHeight < $1.cometHeight
        }) else {
            let hasUnexcluded = families.contains { !excluding.contains($0.family.id) }
            throw hasUnexcluded ? ProviderError.temporarilyUnavailable : fallback
        }
        return EndpointLease(
            family: selected.family,
            verifiedChainId: selected.chainId,
            cosmosReadHeight: selected.cosmosHeight,
            cometReferenceHeight: selected.cometHeight,
            poolGeneration: generation
        )
    }

    private func notifyWaiterCountObservers() {
        let ready = waiterCountObservers.filter { waiters.count >= $0.0 }
        waiterCountObservers.removeAll { waiters.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private struct SharedProbe {
    let generation: UInt64
    let token: UUID
    let task: Task<[[IndexedProbeOutcome]], Never>
}

private struct Waiter {
    let latch: CancellationLatch
    let excluding: Set<String>
    let continuation: CheckedContinuation<EndpointLease, Error>
}

private struct VerifiedFamily {
    let originalIndex: Int
    let family: EndpointFamilyDescriptor
    let chainId: String
    let cosmosHeight: Int64
    let cometHeight: Int64
}

private struct IdentityObservation {
    let chainId: String
    let role: EndpointRole
    let request: ProbeRequestKind
}

private enum FamilyIssue {
    case catchingUp
    case stale(Int64, Int64)
    case invalid(String, EndpointRole, ProbeField)
    case temporary
}

private enum ProbeEvaluation {
    case success([VerifiedFamily], fallback: ProviderError)
    case failure(ProviderError)
}

private extension ProviderError {
    var isIdentityFailure: Bool {
        if case .identityFailure = self { return true }
        return false
    }
}

private final class CancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func lockIfActive() -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            return false
        }
        return true
    }

    func unlock() {
        lock.unlock()
    }
}
