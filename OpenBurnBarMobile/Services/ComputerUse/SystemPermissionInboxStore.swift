#if canImport(UIKit)
import Foundation
import Observation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Phase 14 — Observable store that the SwiftUI chat surface watches
/// to render the inline permission pill and full grant sheet. The
/// store collapses every TCC signal — Mac-structured frames coming
/// over iroh and iOS text-heuristic classifications — into a single
/// `SystemPermissionItem` keyed by thread id + (kind, bundleId) so the
/// inline pill never duplicates and the sheet always shows the freshest
/// status.
@MainActor
@Observable
public final class SystemPermissionInboxStore {
    public static let shared = SystemPermissionInboxStore()

    /// `[threadID: [dedupeKey: SystemPermissionItem]]`. Inner key is
    /// `SystemPermissionItem.dedupeKey` so a `screenRecording` row and
    /// a `automation/com.apple.Safari` row never collide.
    public private(set) var itemsByThread: [String: [String: SystemPermissionItem]] = [:]

    /// Closure the chat tab attaches at startup; resolved per-item when
    /// the user taps "Retry now" or when the monitor flips a bucket
    /// to `granted`. Receiving nil means there is no pending tool to
    /// retry — the sheet will still close cleanly.
    public var retryHandler: (@MainActor (SystemPermissionItem) async -> Void)?

    public init() {}

    public func clear(threadID: String) {
        itemsByThread.removeValue(forKey: threadID)
    }

    public func clear(threadID: String, dedupeKey: String) {
        guard var bucket = itemsByThread[threadID] else { return }
        bucket.removeValue(forKey: dedupeKey)
        itemsByThread[threadID] = bucket.isEmpty ? nil : bucket
    }

    /// Returns the most recently updated item for the active thread —
    /// the chat surface uses this to decide whether to render the
    /// inline pill in the assistant message footer.
    public func latestItem(forThread threadID: String) -> SystemPermissionItem? {
        guard let bucket = itemsByThread[threadID], !bucket.isEmpty else { return nil }
        return bucket.values.sorted { $0.lastChangedAt > $1.lastChangedAt }.first
    }

    public func items(forThread threadID: String) -> [SystemPermissionItem] {
        guard let bucket = itemsByThread[threadID] else { return [] }
        return bucket.values.sorted { $0.lastChangedAt > $1.lastChangedAt }
    }

    /// Ingest a Mac-structured status frame. Source is `.macStructured`,
    /// the highest-priority source — overwrites any prior heuristic
    /// item with the same dedupe key.
    public func ingest(wireStatus status: HermesRealtimeRelaySystemPermissionStatus, threadID: String) {
        let item = SystemPermissionItem.make(wire: status, threadId: threadID)
        upsert(item: item, threadID: threadID)
    }

    /// Ingest a classifier match observed on the phone (heuristic).
    /// Mac structured signals always win — heuristics never overwrite
    /// a `granted` row coming from a structured source.
    public func ingestHeuristic(
        kind: SystemPermissionKind,
        bundleId: String?,
        threadID: String,
        originatingToolCallId: String?,
        instructions: String?
    ) {
        let item = SystemPermissionItem(
            kind: kind,
            bundleId: bundleId,
            originatingToolCallId: originatingToolCallId,
            originatingToolName: nil,
            threadId: threadID,
            status: .needsAccess,
            deepLink: kind.systemSettingsDeepLink,
            instructions: instructions,
            failureCategory: nil,
            lastChangedAt: Date(),
            source: .iosHeuristic
        )
        upsert(item: item, threadID: threadID)
    }

    private func upsert(item: SystemPermissionItem, threadID: String) {
        var bucket = itemsByThread[threadID] ?? [:]
        if let existing = bucket[item.dedupeKey] {
            if existing.source.priority > item.source.priority { return }
            if existing.status == .granted && item.status != .granted &&
                item.source != .macStructured {
                return
            }
        }
        bucket[item.dedupeKey] = item
        itemsByThread[threadID] = bucket
    }
}

extension SystemPermissionItem.Source {
    /// Higher wins — `.macStructured` always overwrites `.iosHeuristic`.
    fileprivate var priority: Int {
        switch self {
        case .macStructured: return 2
        case .iosHeuristic: return 1
        }
    }
}
#endif
