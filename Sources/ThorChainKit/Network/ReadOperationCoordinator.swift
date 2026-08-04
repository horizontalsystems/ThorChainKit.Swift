import Foundation

protocol IAccountReadWallClock: Sendable {
    var now: Date { get }
}

struct SystemAccountReadWallClock: IAccountReadWallClock {
    var now: Date { Date() }
}

struct ReadOperationCoordinator: IAccountProvider {
    private let pool: EndpointPool
    private let client: any INodeApiProvider
    private let configuration: EndpointConfiguration
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let endpointClock: any IEndpointClock
    private let wallClock: any IAccountReadWallClock

    init(
        pool: EndpointPool,
        client: any INodeApiProvider,
        configuration: EndpointConfiguration,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        endpointClock: any IEndpointClock = SystemEndpointClock(),
        wallClock: any IAccountReadWallClock = SystemAccountReadWallClock()
    ) {
        self.pool = pool
        self.client = client
        self.configuration = configuration
        self.sleeper = sleeper
        self.endpointClock = endpointClock
        self.wallClock = wallClock
    }

    // Retries stay on the same provider: it is chosen in settings, and quietly moving to
    // another one would contradict that choice. Three tries, a second apart then two,
    // which reads as a long loading rather than an error the user cannot act on.
    private static let retryDelays: [TimeInterval] = [1, 2]

    // A dead connection answers nothing at all, while a healthy read has never taken
    // more than eight seconds. The first attempt is therefore impatient and the later
    // ones are not, so a stalled socket costs eight seconds instead of fifteen.
    private static let attemptTimeouts: [TimeInterval] = [8]

    func read(address: Address) async throws -> AccountReadTransport {
        let attempts = configuration.policy.maximumAttempts ?? Self.retryDelays.count + 1

        for attempt in 1 ... attempts {
            try Task.checkCancellation()
            let lease = try await pool.readLease(excludingFamilyIds: [])
            try Task.checkCancellation()

            let outcome = await runAttempt(
                address: address,
                lease: lease,
                timeout: attempt <= Self.attemptTimeouts.count ? Self.attemptTimeouts[attempt - 1] : nil,
                retryableStatusCodes: configuration.policy.retryableStatusCodes
            )
            if Task.isCancelled { throw CancellationError() }

            switch outcome {
            case let .success(account, balances):
                guard account != nil || balances.isEmpty else {
                    throw ThorNodeReadError.absentAccountWithBalances
                }
                guard await pool.isCurrent(lease) else {
                    throw ThorNodeReadError.staleLease
                }
                try Task.checkCancellation()
                let observedAt = wallClock.now
                try Task.checkCancellation()
                return try AccountReadTransport(
                    acceptedHeight: lease.cosmosReadHeight,
                    account: account,
                    balances: balances,
                    familyId: lease.family.id,
                    observedAt: observedAt
                )
            case let .failure(failure):
                if case .cancelled = failure { throw CancellationError() }
                // The last failure is what the user is shown, so it is thrown as it came
                // rather than flattened into "attempts exhausted".
                guard failure.isRetryable(statusCodes: configuration.policy.retryableStatusCodes),
                      attempt < attempts
                else { throw failure.error }

                let delay = failure.retryAfterSeconds.map(TimeInterval.init) ?? Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                try await sleeper(delay)
            }
        }
        throw ThorNodeReadError.attemptsExhausted
    }

    private func runAttempt(
        address: Address,
        lease: EndpointLease,
        timeout: TimeInterval?,
        retryableStatusCodes: Set<Int>
    ) async -> AttemptOutcome {
        await withTaskGroup(of: ChildOutcome.self) { group in
            group.addTask {
                guard !Task.isCancelled else { return .account(.failure(.cancelled)) }
                do {
                    return .account(.success(try await client.account(address: address, using: lease, timeout: timeout)))
                } catch {
                    return .account(.failure(ReadFailure(error: error)))
                }
            }
            group.addTask {
                guard !Task.isCancelled else { return .balances(.failure(.cancelled)) }
                do {
                    return .balances(.success(try await client.balances(address: address, using: lease, timeout: timeout)))
                } catch {
                    return .balances(.failure(ReadFailure(error: error)))
                }
            }

            var account: Result<AccountTransport?, ReadFailure>?
            var balances: Result<[BalanceTransport], ReadFailure>?
            for await child in group {
                switch child {
                case let .account(result): account = result
                case let .balances(result): balances = result
                }
                if child.isFailure {
                    group.cancelAll()
                }
            }

            if Task.isCancelled { return .failure(.cancelled) }
            if let account, let balances,
               case let .success(accountValue) = account,
               case let .success(balanceValue) = balances {
                return .success(accountValue, balanceValue)
            }

            let failures = [account?.failure, balances?.failure].compactMap { $0 }
            if failures.isEmpty { return .failure(.cancelled) }
            let realFailures = failures.filter { if case .cancelled = $0 { return false }; return true }
            if realFailures.isEmpty { return .failure(.cancelled) }
            let selected = realFailures.first {
                !$0.isRetryable(statusCodes: retryableStatusCodes)
            } ?? realFailures.first!
            return .failure(selected)
        }
    }

}

private enum AttemptOutcome: Sendable {
    case success(AccountTransport?, [BalanceTransport])
    case failure(ReadFailure)
}

private enum ChildOutcome: Sendable {
    case account(Result<AccountTransport?, ReadFailure>)
    case balances(Result<[BalanceTransport], ReadFailure>)

    var isFailure: Bool {
        switch self {
        case let .account(result): result.failure != nil
        case let .balances(result): result.failure != nil
        }
    }
}

private enum ReadFailure: Error, Equatable, Sendable {
    case read(ThorNodeReadError)
    case provider(ProviderError)
    case cancelled
    case other

    init(error: Error) {
        if error is CancellationError {
            self = .cancelled
        } else if let error = error as? ThorNodeReadError {
            self = error == .cancelled ? .cancelled : .read(error)
        } else if let error = error as? ProviderError {
            self = .provider(error)
        } else {
            self = .other
        }
    }

    var error: Error {
        switch self {
        case let .read(error): error
        case let .provider(error): error
        case .cancelled: CancellationError()
        case .other: ThorNodeReadError.malformedResponse(operation: .account)
        }
    }

    var retryAfterSeconds: Int? {
        guard case let .read(error) = self else { return nil }
        return error.retryAfterSeconds
    }

    func isRetryable(statusCodes: Set<Int>) -> Bool {
        guard case let .read(error) = self else { return false }
        return error.isRetryable(statusCodes: statusCodes)
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
