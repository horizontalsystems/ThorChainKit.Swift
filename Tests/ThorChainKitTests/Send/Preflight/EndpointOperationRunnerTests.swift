@testable import ThorChainKit
import XCTest

final class EndpointOperationRunnerTests: XCTestCase {
    func testHealthyOperationsDoNotConsumeOrphanQuota() async throws {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 1)
        let gate = AsyncGate()
        let active = Task { try await runner.run { await gate.wait(); return 1 } }
        await gate.waitUntilRegistered()

        let healthyResult = try? await runner.run { 2 }
        XCTAssertEqual(healthyResult, 2)
        active.cancel()
        do { _ = try await active.value; XCTFail("cancelled operation must fail") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("unexpected error: \(error)") }
        gate.open()
    }

    func testZeroOrphanCapAllowsHealthyOperationButRejectsAfterOrphaning() async {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 0)
        let healthyResult = try? await runner.run { 1 }
        XCTAssertEqual(healthyResult, 1)
        let gate = AsyncGate()
        let task = Task { try await runner.run { await gate.wait(); return 2 } }
        await gate.waitUntilRegistered()
        task.cancel()
        _ = try? await task.value
        do { _ = try await runner.run { 3 }; XCTFail("zero cap must reject after orphaning") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .orphanCapReached) }
        catch { XCTFail("unexpected error: \(error)") }
        gate.open()
    }

    func testCancellationBeforeDependencyLaunchDoesNotCreateAnOrphan() async {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 0)
        let task = Task { try await runner.run { XCTFail("dependency must not launch"); return 1 } }
        task.cancel()
        do { _ = try await task.value; XCTFail("pre-cancelled call must fail") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("unexpected error: \(error)") }
        do {
            let result = try await runner.run { 2 }
            XCTAssertEqual(result, 2)
        } catch { XCTFail("pre-cancelled ticket must be released: \(error)") }
    }

    func testCancellationCreatesOrphanAndLateCompletionReleasesCapacity() async {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 1)
        let gate = AsyncGate()
        let task = Task { try await runner.run { await gate.wait(); return 1 } }
        await gate.waitUntilRegistered()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled operation must fail") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("unexpected error: \(error)") }

        do { _ = try await runner.run { 2 }; XCTFail("orphan cap must fail closed") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .orphanCapReached) }
        catch { XCTFail("unexpected error: \(error)") }

        gate.open()
        do { _ = try await runAfterOrphansRelease(runner) { 3 } }
        catch { XCTFail("late completion must release capacity: \(error)") }
    }

    func testDeadlineUsesInjectedClockAndLateCompletionReleasesCapacity() async {
        let clock = TestEndpointOperationClock(now: 100)
        let runner = EndpointOperationRunner(deadline: 1, maximumOrphanedOperations: 1, clock: clock)
        let gate = AsyncGate()
        let task = Task { try await runner.run { await gate.wait(); return 1 } }
        await gate.waitUntilRegistered()
        clock.advance(to: 1_000_000_100)
        do { _ = try await task.value; XCTFail("deadline must win") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .deadlineExceeded) }
        catch { XCTFail("unexpected error: \(error)") }
        do { _ = try await runner.run { 2 }; XCTFail("orphan cap must fail closed") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .orphanCapReached) }
        catch { XCTFail("unexpected error: \(error)") }
        gate.open()
        do { _ = try await runAfterOrphansRelease(runner) { 3 } }
        catch { XCTFail("late completion must release capacity: \(error)") }
    }

    func testReturnedDependencyReleasesCapacityWhenDeadlineIsObserved() async {
        let clock = TestEndpointOperationClock(now: 100)
        let runner = EndpointOperationRunner(deadline: 1, maximumOrphanedOperations: 0, clock: clock)
        let gate = AsyncGate()
        let task = Task {
            try await runner.run {
                await gate.wait()
                clock.advance(to: 1_000_000_100)
                return 1
            }
        }
        await gate.waitUntilRegistered()
        gate.open()
        do { _ = try await task.value; XCTFail("deadline must win at dependency return") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .deadlineExceeded) }
        catch { XCTFail("unexpected error: \(error)") }
        do {
            let result = try await runAfterOrphansRelease(runner) { 2 }
            XCTAssertEqual(result, 2)
        } catch { XCTFail("returned dependency must release capacity: \(error)") }
    }

    func testConcurrentOrphansRemainCountedUntilBothDependenciesReturn() async {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 2)
        let firstGate = AsyncGate(); let secondGate = AsyncGate()
        let first = Task { try await runner.run(familyID: "a") { await firstGate.wait(); return 1 } }
        let second = Task { try await runner.run(familyID: "b") { await secondGate.wait(); return 2 } }
        await firstGate.waitUntilRegistered(); await secondGate.waitUntilRegistered()
        first.cancel(); second.cancel()
        _ = try? await first.value; _ = try? await second.value
        do { _ = try await runner.run { 3 }; XCTFail("all concurrent orphans must consume capacity") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .orphanCapReached) }
        catch { XCTFail("unexpected error: \(error)") }
        firstGate.open(); secondGate.open()
        do {
            let result = try await runAfterOrphansRelease(runner) { 4 }
            XCTAssertEqual(result, 4)
        } catch { XCTFail("both late completions must release capacity: \(error)") }
    }

    func testCancellationImmediatelyBeforeDependencyReturnReleasesCapacity() async {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 0)
        let aboutToReturn = expectation(description: "dependency is paused immediately before return")
        let allowReturn = AsyncGate()
        let task = Task {
            try await runner.run {
                aboutToReturn.fulfill()
                await allowReturn.wait()
                return 1
            }
        }
        await fulfillment(of: [aboutToReturn], timeout: 1)
        task.cancel()
        allowReturn.open()
        do { _ = try await task.value; XCTFail("cancellation must win at dependency return") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("unexpected error: \(error)") }
        do {
            let result = try await runAfterOrphansRelease(runner) { 2 }
            XCTAssertEqual(result, 2)
        } catch { XCTFail("returned dependency must release capacity: \(error)") }
    }

    func testFamilyAndGlobalOrphanCapsAreIndependent() async {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 2, maximumOrphanedOperationsPerFamily: 1)
        let firstGate = AsyncGate()
        let first = Task { try await runner.run(familyID: "family-a") { await firstGate.wait(); return 1 } }
        await firstGate.waitUntilRegistered()
        first.cancel()
        _ = try? await first.value

        do { _ = try await runner.run(familyID: "family-a") { 2 }; XCTFail("family cap must fail closed") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .orphanCapReached) }
        catch { XCTFail("unexpected error: \(error)") }

        let secondGate = AsyncGate()
        let second = Task { try await runner.run(familyID: "family-b") { await secondGate.wait(); return 3 } }
        await secondGate.waitUntilRegistered()
        second.cancel()
        _ = try? await second.value

        do { _ = try await runner.run(familyID: "family-c") { 4 }; XCTFail("global cap must fail closed") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .orphanCapReached) }
        catch { XCTFail("unexpected error: \(error)") }

        firstGate.open(); secondGate.open()
        do { _ = try await runAfterOrphansRelease(runner) { 5 } }
        catch { XCTFail("completed orphans must release capacity: \(error)") }
    }

    func testLifecycleInvalidationWinsOverCancellationAndDeadline() async {
        let clock = TestEndpointOperationClock(now: 100)
        let runner = EndpointOperationRunner(deadline: 1, maximumOrphanedOperations: 1, clock: clock)
        let gate = AsyncGate()
        let state = LifecycleState()
        let task = Task { try await runner.run(lifecycle: { state.invalidated }) { await gate.wait(); return 1 } }
        await gate.waitUntilRegistered()
        state.invalidated = true
        clock.advance(to: 1_000_000_100)
        task.cancel()
        do { _ = try await task.value; XCTFail("lifecycle invalidation must win") }
        catch let error as EndpointOperationError { XCTAssertEqual(error, .lifecycleInvalidated) }
        catch { XCTFail("unexpected error: \(error)") }
        gate.open()
    }

    func testCancellationAndCompletionRaceDoesNotDeadlock() async {
        let runner = EndpointOperationRunner(deadline: 10, maximumOrphanedOperations: 1)
        let gate = AsyncGate()
        let task = Task { try await runner.run { await gate.wait(); return 1 } }
        await gate.waitUntilRegistered()
        let finished = expectation(description: "cancelled operation completes")
        Task {
            _ = await task.result
            finished.fulfill()
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { task.cancel() }
            group.addTask { gate.open() }
        }

        await fulfillment(of: [finished], timeout: 1)
    }
}

private func runAfterOrphansRelease<T: Sendable>(
    _ runner: EndpointOperationRunner,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    for _ in 0 ..< 100 {
        do {
            return try await runner.run(operation)
        } catch EndpointOperationError.orphanCapReached {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    throw EndpointOperationError.orphanCapReached
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations = [CheckedContinuation<Void, Never>]()

    var isRegistered: Bool {
        lock.lock(); defer { lock.unlock() }
        return !continuations.isEmpty
    }

    func waitUntilRegistered() async {
        while !isRegistered {
            await Task.yield()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock(); continuations.append(continuation); lock.unlock()
        }
    }

    func open() {
        lock.lock(); let pending = continuations; continuations.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class LifecycleState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var invalidated: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class TestEndpointOperationClock: IEndpointOperationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64
    private var waiters = [(UInt64, CheckedContinuation<Void, Never>)]()

    init(now: UInt64) { current = now }

    var now: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func sleep(until: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if current >= until {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((until, continuation))
                lock.unlock()
            }
        }
    }

    func advance(to value: UInt64) {
        lock.lock()
        current = value
        let ready = waiters.partitioned { $0.0 <= value }
        waiters = ready.remaining
        lock.unlock()
        ready.ready.forEach { $0.1.resume() }
    }
}

private extension Array {
    func partitioned(where predicate: (Element) -> Bool) -> (ready: [Element], remaining: [Element]) {
        reduce(into: (ready: [], remaining: [])) { result, element in
            if predicate(element) { result.ready.append(element) } else { result.remaining.append(element) }
        }
    }
}
