import Foundation

/// ccusage's all-source discovery and Antigravity both open the same SQLite databases.
/// The shared gate covers every collector instance without blocking JSONL-only providers.
enum CcusageSQLiteAccess {
    private static let gate = Gate()

    static func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await gate.acquire(id)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await gate.release(id)
            return result
        } catch {
            await gate.release(id)
            throw error
        }
    }

    private actor Gate {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, any Error>
        }
        private var owner: UUID?
        private var queue: [Waiter] = []

        func acquire(_ id: UUID) async throws {
            try Task.checkCancellation()
            if owner == nil { owner = id; return }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.append(Waiter(id: id, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            if Task.isCancelled {
                release(id)
                throw CancellationError()
            }
        }
        func release(_ id: UUID) {
            guard owner == id else { return }
            if queue.isEmpty { owner = nil; return }
            let next = queue.removeFirst()
            owner = next.id
            next.continuation.resume()
        }
        private func cancelWaiter(_ id: UUID) {
            guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
            let waiter = queue.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Every subscriber may cancel independently. The shared discovery process is cancelled when its
/// final subscriber leaves; a late result from that flight cannot overwrite a replacement flight.
actor CcusageSourceDiscovery {
    static let shared = CcusageSourceDiscovery()
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Set<String>, any Error>]
    }
    private var entries: [String: (sources: Set<String>, date: Date)] = [:]
    private var flights: [String: Flight] = [:]

    func get(_ key: String, allowExpired: Bool = false) -> Set<String>? {
        guard let entry = entries[key], allowExpired || Date().timeIntervalSince(entry.date) < 600 else { return nil }
        return entry.sources
    }

    func resolve(_ key: String, useCache: Bool,
                 loader: @escaping @Sendable () async throws -> Set<String>) async throws -> Set<String> {
        try Task.checkCancellation()
        if useCache, let cached = get(key) { return cached }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if flights[key] != nil {
                    flights[key]!.waiters[waiterID] = continuation
                    return
                }
                let flightID = UUID()
                let task = Task {
                    let result: Result<Set<String>, any Error>
                    do {
                        let sources = try await loader()
                        try Task.checkCancellation()
                        result = .success(sources)
                    } catch { result = .failure(error) }
                    finish(key, id: flightID, result: result)
                }
                flights[key] = Flight(id: flightID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancelWaiter(key, id: waiterID) }
        }
    }

    private func finish(_ key: String, id: UUID, result: Result<Set<String>, any Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights[key] = nil
        if case let .success(sources) = result { entries[key] = (sources, Date()) }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func cancelWaiter(_ key: String, id: UUID) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
    }
}
