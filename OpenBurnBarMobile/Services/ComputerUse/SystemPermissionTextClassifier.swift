#if canImport(UIKit)
import Foundation
import OpenBurnBarComputerUseCore

/// Phase 14 — iOS heuristic wrapper. The phone runs the shared
/// `SystemPermissionToolFailureClassifier` against every assistant
/// text update and every transcript tool-result piece. Mac-structured
/// frames win in the inbox store; this is the safety net for sessions
/// where the Mac side never reports the bucket (e.g. Hermes running on
/// a different host, or older Mac builds without Phase 14).
@MainActor
public final class SystemPermissionTextClassifier {
    public static let shared = SystemPermissionTextClassifier()

    private let classifier = SystemPermissionToolFailureClassifier()
    private let store: SystemPermissionInboxStore

    public init(store: SystemPermissionInboxStore = .shared) {
        self.store = store
    }

    /// Classify a tool result. Forwards a `needsAccess` row into the
    /// inbox when a TCC fingerprint matches.
    public func observe(
        toolName: String?,
        toolResultDetail: String?,
        toolCallId: String?,
        threadID: String
    ) {
        guard let detail = toolResultDetail, !detail.isEmpty else { return }
        guard let match = classifier.classify(toolResult: detail) else { return }
        store.ingestHeuristic(
            kind: match.kind,
            bundleId: match.bundleId,
            threadID: threadID,
            originatingToolCallId: toolCallId,
            instructions: nil
        )
    }

    /// Classify an assistant-text update. Same rule set but limited to
    /// phrases that carry a TCC anchor (permission / denied / etc.).
    public func observeAssistantText(_ text: String, threadID: String, toolCallId: String?) {
        guard !text.isEmpty else { return }
        guard let match = classifier.classify(assistantText: text) else { return }
        store.ingestHeuristic(
            kind: match.kind,
            bundleId: match.bundleId,
            threadID: threadID,
            originatingToolCallId: toolCallId,
            instructions: nil
        )
    }
}
#endif
