#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OSLog
import OpenBurnBarComputerUseCore

/// Phase 14 — Lightweight singleton that observes tool result strings
/// emitted by the chat pipeline (Hermes, Claude Code, Codex, CLI
/// bridges), classifies them against `SystemPermissionToolFailureClassifier`,
/// and forwards matches to `SystemPermissionMonitor.shared.ingestClassified(...)`.
///
/// Lives next to the monitor so any caller — `ChatSessionController`,
/// `CLIAgentRelayChatExecutor`, an embedded Computer Use coordinator —
/// can drive it without taking a hard dependency on the monitor
/// itself. The watcher is the *Mac-side structured signal* the user
/// chose in Q4; the iOS heuristic path uses its own thin wrapper.
@MainActor
public final class SystemPermissionToolFailureWatcher {
    public static let shared = SystemPermissionToolFailureWatcher()
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "SystemPermissionConcierge")

    private let classifier = SystemPermissionToolFailureClassifier()

    public init() {}

    /// Observe a single tool-result piece. `toolCallId` is the unique
    /// id of the failed tool call so the eventual retry can be paired
    /// back. When the toolCallId is missing we fall back to a
    /// deterministic compound id built from the tool name + a hash of
    /// the detail body.
    public func observe(
        toolName: String?,
        detail: String?,
        toolCallId: String? = nil
    ) async {
        guard let body = detail, !body.isEmpty else { return }
        guard let match = classifier.classify(toolResult: body) else { return }
        let resolvedCallId = toolCallId ?? Self.fallbackToolCallId(toolName: toolName, detail: body)
        Self.log.info("system_permission_tool_failure tool=\(toolName ?? "?", privacy: .public) kind=\(match.kind.rawValue, privacy: .public)")
        await SystemPermissionMonitor.shared.ingestClassified(
            match: match,
            toolCallId: resolvedCallId,
            toolName: toolName
        )
    }

    /// Observe assistant text (used when the model surfaces a TCC
    /// denial in prose without a structured tool result). Same
    /// classifier rules, but only the assistant entry point is used so
    /// we never flag a refusal that lacks a permission anchor.
    public func observeAssistantText(_ text: String, toolCallId: String? = nil) async {
        guard let match = classifier.classify(assistantText: text) else { return }
        let resolvedCallId = toolCallId ?? Self.fallbackToolCallId(toolName: "assistant_text", detail: text)
        Self.log.info("system_permission_assistant_text_match kind=\(match.kind.rawValue, privacy: .public)")
        await SystemPermissionMonitor.shared.ingestClassified(
            match: match,
            toolCallId: resolvedCallId,
            toolName: nil
        )
    }

    private static func fallbackToolCallId(toolName: String?, detail: String) -> String {
        let name = toolName ?? "tool"
        let digest = abs(detail.hashValue)
        return "syspermsignal://\(name)/\(digest)"
    }
}
#endif
