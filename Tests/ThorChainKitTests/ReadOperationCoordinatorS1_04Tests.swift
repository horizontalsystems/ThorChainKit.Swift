import Foundation
import XCTest
@testable import ThorChainKit

final class ReadOperationCoordinatorS1_04Tests: XCTestCase {
    func testCancellationDuringSuccessLinearizationDoesNotReturnSuccess() async throws {
        let first = try family(id: "first")
        let configuration = try EndpointConfiguration(
            families: [first],
            policy: try EndpointPolicy(maximumAttempts: 1, maximumBalancePageCount: 4)
        )
        let client = ScriptedReadClient()
        await client.setOutcome(for: "first", outcome: .success)
        let pool = EndpointPool(
            network: .mainnet,
            configuration: configuration,
            probe: HealthyS1_04Probe()
        )
        let cancellation = CoordinatorCancellationBox()
        let coordinator = ReadOperationCoordinator(
            pool: pool,
            client: client,
            configuration: configuration,
            wallClock: CancellingAccountReadWallClock(cancellation: cancellation)
        )
        let testAddress = try address()
        let operation = Task {
            try await coordinator.read(address: testAddress)
        }
        cancellation.set { operation.cancel() }

        do {
            _ = try await operation.value
            XCTFail("Expected cancellation to win over success")
        } catch is CancellationError {
            // expected
        }
    }

    func testAFailingProviderIsRetriedInPlaceAndNeverSwappedForAnother() async throws {
        let first = try family(id: "first")
        let second = try family(id: "second")
        let configuration = try EndpointConfiguration(
            families: [first, second],
            policy: try EndpointPolicy(maximumBalancePageCount: 4)
        )
        let client = ScriptedReadClient()
        await client.setOutcome(for: "first", outcome: .retryable)
        await client.setOutcome(for: "second", outcome: .success)
        let pool = EndpointPool(
            network: .mainnet,
            configuration: configuration,
            probe: HealthyS1_04Probe()
        )
        let delays = DelayRecorder()
        let coordinator = ReadOperationCoordinator(
            pool: pool,
            client: client,
            configuration: configuration,
            sleeper: { await delays.append($0) }
        )

        // The provider is picked in settings. A second family answering is not a reason
        // to move there behind the user's back, so all three tries go to the same one
        // and the failure is then reported as it came.
        do {
            _ = try await coordinator.read(address: try address())
            XCTFail("a provider that keeps failing must surface its error")
        } catch let error as ThorNodeReadError {
            guard case let .httpStatus(_, code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, 503)
        }

        let familyCalls = await client.familyCalls
        XCTAssertEqual(Set(familyCalls), ["first"])
        // Three attempts, each reading the account and the balances.
        XCTAssertEqual(familyCalls.count, 6)
        let recordedDelays = await delays.values
        XCTAssertEqual(recordedDelays, [1, 2])
    }

    private func family(id: String) throws -> EndpointFamilyDescriptor {
        try EndpointFamilyDescriptor(
            id: id,
            cosmosRestURL: URL(string: "https://\(id).example")!,
            cometBftURL: URL(string: "https://\(id)-rpc.example")!
        )
    }

    private func address() throws -> Address {
        try Address("thor166aczv0jatlnyzz8zsczdzk9xxxgppfpu530jl", network: .mainnet)
    }
}

private final class CoordinatorCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelOperation: (@Sendable () -> Void)?

    func set(_ cancelOperation: @escaping @Sendable () -> Void) {
        lock.lock()
        self.cancelOperation = cancelOperation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let cancelOperation = self.cancelOperation
        lock.unlock()
        cancelOperation?()
    }
}

private struct CancellingAccountReadWallClock: IAccountReadWallClock {
    let cancellation: CoordinatorCancellationBox

    var now: Date {
        cancellation.cancel()
        return Date()
    }
}

private actor DelayRecorder {
    private(set) var values = [TimeInterval]()

    func append(_ value: TimeInterval) { values.append(value) }
}

private actor ScriptedReadClient: INodeApiProvider {
    enum Outcome: Sendable { case success, retryable }

    private var outcomes = [String: Outcome]()
    private(set) var familyCalls = [String]()

    func setOutcome(for family: String, outcome: Outcome) { outcomes[family] = outcome }

    func account(address: Address, using lease: EndpointLease) async throws -> AccountTransport? {
        familyCalls.append(lease.family.id)
        if outcomes[lease.family.id] == .retryable {
            throw ThorNodeReadError.httpStatus(operation: .account, code: 503, retryAfterSeconds: nil)
        }
        return AccountTransport(accountNumber: 1, sequence: 2)
    }

    func balances(address: Address, using lease: EndpointLease) async throws -> [BalanceTransport] {
        familyCalls.append(lease.family.id)
        if outcomes[lease.family.id] == .retryable {
            return []
        }
        return [BalanceTransport(denom: .rune, amountDecimal: "1")]
    }
}

private struct HealthyS1_04Probe: INodeProber {
    func probe(index: Int, family: EndpointFamilyDescriptor) async -> [IndexedProbeOutcome] {
        let cosmos = EndpointOrigin(url: family.cosmosRestURL)!
        let comet = EndpointOrigin(url: family.cometBftURL)!
        return [
            IndexedProbeOutcome(
                index: ProbeRequestIndex(familyIndex: index, familyId: family.id, role: .cosmosRest, request: .cosmosNodeInfo),
                cosmosOrigin: cosmos, cometOrigin: comet,
                result: .cosmosNodeInfo(.success(.init(chainId: "thorchain-1")))
            ),
            IndexedProbeOutcome(
                index: ProbeRequestIndex(familyIndex: index, familyId: family.id, role: .cosmosRest, request: .cosmosLatestBlock),
                cosmosOrigin: cosmos, cometOrigin: comet,
                result: .cosmosLatestBlock(.success(.init(chainId: "thorchain-1", latestHeight: 100)))
            ),
            IndexedProbeOutcome(
                index: ProbeRequestIndex(familyIndex: index, familyId: family.id, role: .cometBft, request: .cometStatus),
                cosmosOrigin: cosmos, cometOrigin: comet,
                result: .cometStatus(.success(.init(chainId: "thorchain-1", latestHeight: 100, catchingUp: false)))
            ),
        ]
    }
}
