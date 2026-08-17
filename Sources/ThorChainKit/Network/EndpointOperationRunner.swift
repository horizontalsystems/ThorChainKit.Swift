import Foundation

enum EndpointOperationError: Error, Equatable, Sendable {
    case deadlineExceeded, cancelled, lifecycleInvalidated, orphanCapReached
}

protocol IEndpointOperationClock: Sendable {
    var now: UInt64 { get }
    func sleep(until: UInt64) async
}

struct SystemEndpointOperationClock: IEndpointOperationClock {
    var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    func sleep(until: UInt64) async {
        let current = DispatchTime.now().uptimeNanoseconds
        guard until > current else { return }
        try? await Task.sleep(nanoseconds: until - current)
    }
}

final class EndpointOperationRunner: @unchecked Sendable {
    // A nil deadline leaves the wait to the transport, as the Android kit does. Only the
    // broadcast path needs its own bound, to decide when an outcome is unknown.
    private let deadline: TimeInterval?
    private let clock: any IEndpointOperationClock
    private let orphanCounter: OrphanCounter

    init(
        deadline: TimeInterval? = nil,
        maximumOrphanedOperations: Int = 8,
        maximumOrphanedOperationsPerFamily: Int? = nil,
        clock: any IEndpointOperationClock = SystemEndpointOperationClock()
    ) {
        self.deadline = deadline
        self.clock = clock
        orphanCounter = OrphanCounter(globalMaximum: maximumOrphanedOperations, familyMaximum: maximumOrphanedOperationsPerFamily ?? maximumOrphanedOperations)
    }

    func run<T: Sendable>(
        familyID: String? = nil,
        lifecycle: @escaping @Sendable () -> Bool = { false },
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let ticket = orphanCounter.start(familyID: familyID) else { throw EndpointOperationError.orphanCapReached }
        let cancellation = CancellationSignal()
        let deadline: UInt64
        if let configured = self.deadline {
            let (absolute, overflow) = clock.now.addingReportingOverflow(UInt64(max(0, configured) * 1_000_000_000))
            deadline = overflow ? UInt64.max : absolute
        } else {
            deadline = UInt64.max
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let gate = CompletionGate<T>(continuation)
                let launchState = DependencyLaunchState()
                func finish(_ result: Result<T, Error>, orphan: Bool) {
                    if gate.finish(result), orphan { orphanCounter.markOrphaned(ticket) }
                }
                func finishOperation(_ result: Result<T, Error>) {
                    orphanCounter.complete(ticket)
                    _ = gate.finish(result)
                }

                cancellation.install {
                    let orphan = launchState.cancel()
                    let error: EndpointOperationError = lifecycle() ? .lifecycleInvalidated : .cancelled
                    if !orphan { self.orphanCounter.complete(ticket) }
                    finish(.failure(error), orphan: orphan)
                }
                if Task.isCancelled {
                    cancellation.cancel()
                    return
                }
                guard launchState.start() else { return }

                Task.detached {
                    do {
                        let result = try await operation()
                        if lifecycle() {
                            finishOperation(.failure(EndpointOperationError.lifecycleInvalidated))
                        } else if cancellation.isCancelled {
                            finishOperation(.failure(EndpointOperationError.cancelled))
                        } else if self.clock.now >= deadline {
                            finishOperation(.failure(EndpointOperationError.deadlineExceeded))
                        } else {
                            finishOperation(.success(result))
                        }
                    } catch {
                        if lifecycle() {
                            finishOperation(.failure(EndpointOperationError.lifecycleInvalidated))
                        } else if cancellation.isCancelled {
                            finishOperation(.failure(EndpointOperationError.cancelled))
                        } else if self.clock.now >= deadline {
                            finishOperation(.failure(EndpointOperationError.deadlineExceeded))
                        } else {
                            finishOperation(.failure(error))
                        }
                    }
                }

                Task.detached {
                    while !gate.isFinished {
                        if lifecycle() {
                            finish(.failure(EndpointOperationError.lifecycleInvalidated), orphan: true)
                            break
                        }
                        if cancellation.isCancelled {
                            finish(.failure(EndpointOperationError.cancelled), orphan: true)
                            break
                        }
                        if self.clock.now >= deadline {
                            finish(.failure(EndpointOperationError.deadlineExceeded), orphan: true)
                            break
                        }
                        let next = min(deadline, self.clock.now &+ 1_000_000)
                        await self.clock.sleep(until: next)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class DependencyLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        started = true
        return true
    }

    func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return true }
        cancelled = true
        return false
    }
}

private final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var callback: (() -> Void)?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func install(_ callback: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            callback()
        } else {
            self.callback = callback
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?()
    }
}

private final class OrphanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let globalMaximum: Int
    private let familyMaximum: Int
    private var active = [UUID: String?]()
    private var orphaned = [UUID: String?]()

    init(globalMaximum: Int, familyMaximum: Int) {
        self.globalMaximum = max(0, globalMaximum)
        self.familyMaximum = max(0, familyMaximum)
    }

    func start(familyID: String?) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard orphaned.isEmpty || orphaned.count < globalMaximum else { return nil }
        if let familyID {
            let familyOrphans = orphaned.values.compactMap { $0 }.filter { $0 == familyID }.count
            guard familyOrphans == 0 || familyOrphans < familyMaximum else { return nil }
        }
        let id = UUID()
        active[id] = familyID
        return id
    }

    func markOrphaned(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let familyID = active.removeValue(forKey: id) else { return }
        orphaned[id] = familyID
    }

    func complete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        active.removeValue(forKey: id)
        orphaned.removeValue(forKey: id)
    }
}

private final class CompletionGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    @discardableResult
    func finish(_ result: sending Result<T, Error>) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
