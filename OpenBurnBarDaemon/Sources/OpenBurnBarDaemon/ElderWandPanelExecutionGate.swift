import Foundation
import OpenBurnBarEngine

/// Keeps concurrent Elder Wand panel members from colliding on one provider
/// credential while preserving parallel execution across independent accounts.
actor ElderWandPanelExecutionGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var owners: [String: UUID] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var cancelledWaiters: Set<UUID> = []

    func perform<T: Sendable>(
        route: BurnBarProviderRoute,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let key = Self.executionKey(for: route)
        let ownerID = UUID()
        return try await withTaskCancellationHandler {
            await acquire(key: key, ownerID: ownerID)
            defer { release(key: key, ownerID: ownerID) }
            try Task.checkCancellation()
            return try await operation()
        } onCancel: {
            Task { await self.cancelWaiter(key: key, ownerID: ownerID) }
        }
    }

    private func acquire(key: String, ownerID: UUID) async {
        guard cancelledWaiters.remove(ownerID) == nil else { return }
        guard owners[key] != nil else {
            owners[key] = ownerID
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(Waiter(id: ownerID, continuation: continuation))
        }
    }

    private func release(key: String, ownerID: UUID) {
        guard owners[key] == ownerID else { return }
        guard var queued = waiters[key], !queued.isEmpty else {
            owners.removeValue(forKey: key)
            waiters.removeValue(forKey: key)
            return
        }
        let next = queued.removeFirst()
        owners[key] = next.id
        waiters[key] = queued.isEmpty ? nil : queued
        next.continuation.resume()
    }

    private func cancelWaiter(key: String, ownerID: UUID) {
        guard owners[key] != ownerID else { return }
        guard var queued = waiters[key],
              let index = queued.firstIndex(where: { $0.id == ownerID }) else {
            cancelledWaiters.insert(ownerID)
            return
        }
        let cancelled = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        cancelled.continuation.resume()
    }

    private nonisolated static func executionKey(for route: BurnBarProviderRoute) -> String {
        let providerID = route.providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slotID = route.credentialSlotID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let accountID = slotID?.isEmpty == false ? slotID ?? "legacy" : "legacy"
        return "\(providerID)#\(accountID)#\(route.baseURL.lowercased())"
    }
}
