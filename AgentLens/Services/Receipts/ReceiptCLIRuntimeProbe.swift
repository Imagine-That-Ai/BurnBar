import AppKit
import Foundation
import OpenBurnBarKernel

// MARK: - Runtime probe

/// Whether the CLI process, terminal job, or dedicated agent app for a
/// receipt's harness is still running.
///
/// The flyout must not fire while Alberto is still in the conversation.
/// Quiet time is enough to *print* a slip into the register; announcing
/// it requires the runtime to be gone.
protocol ReceiptCLIRuntimeProbe: Sendable {
    func isSessionRuntimeOpen(provider: AgentProvider, projectPath: String?) async -> Bool
    func snapshotForPoll() async -> any ReceiptCLIRuntimeProbe
}

extension ReceiptCLIRuntimeProbe {
    func snapshotForPoll() async -> any ReceiptCLIRuntimeProbe { self }
}

/// Test / preview seam: the session is always open, or always closed.
struct FixedReceiptCLIRuntimeProbe: ReceiptCLIRuntimeProbe, Sendable {
    var isOpen: Bool

    func isSessionRuntimeOpen(provider: AgentProvider, projectPath: String?) async -> Bool {
        isOpen
    }
}

/// Live Mac probe: one `/bin/ps` snapshot plus dedicated agent-app
/// bundle ids. Ownership rules live in `AgentCLIProcessClassifier` so
/// Pixel Clock and receipts cannot drift.
struct ProcessReceiptCLIRuntimeProbe: ReceiptCLIRuntimeProbe, Sendable {
    var processLines: @Sendable () -> [String]
    var runningBundleIDs: @Sendable () -> Set<String>

    init(
        processLines: @escaping @Sendable () -> [String] = { ProcessReceiptCLIRuntimeProbe.liveProcessLines() },
        runningBundleIDs: @escaping @Sendable () -> Set<String> = { ProcessReceiptCLIRuntimeProbe.liveRunningBundleIDs() }
    ) {
        self.processLines = processLines
        self.runningBundleIDs = runningBundleIDs
    }

    func isSessionRuntimeOpen(provider: AgentProvider, projectPath: String?) async -> Bool {
        let family = AgentCLIProcessClassifier.runtimeFamily(for: provider)
        if dedicatedAppIsRunning(provider) { return true }
        let lines = await Self.snapshotLines(processLines)
        if AgentCLIProcessClassifier.isUnknownProcessSnapshot(lines) { return true }
        return Self.familyIsOpen(family: family, projectPath: projectPath, lines: lines)
    }

    func snapshotForPoll() async -> any ReceiptCLIRuntimeProbe {
        let lines = await Self.snapshotLines(processLines)
        let bundles = runningBundleIDs()
        return ProcessReceiptCLIRuntimeProbe(
            processLines: { lines },
            runningBundleIDs: { bundles }
        )
    }

    /// Family-wide when argv has no workspace; session-true when a long
    /// project path is on one process line and a different workspace is
    /// on the others.
    static func familyIsOpen(
        family: AgentProvider,
        projectPath: String?,
        lines: [String]
    ) -> Bool {
        let familyLines = lines.filter { line in
            guard let found = AgentCLIProcessClassifier.provider(forProcessLine: line) else {
                return false
            }
            return AgentCLIProcessClassifier.runtimeFamily(for: found) == family
        }
        guard !familyLines.isEmpty else { return false }
        return AgentCLIProcessClassifier.projectPathKeepsSessionOpen(
            projectPath: projectPath,
            familyLines: familyLines
        )
    }

    static func provider(forProcessLine line: String) -> AgentProvider? {
        AgentCLIProcessClassifier.provider(forProcessLine: line)
    }

    private func dedicatedAppIsRunning(_ provider: AgentProvider) -> Bool {
        let running = runningBundleIDs()
        return Self.dedicatedBundleIDs(for: provider).contains { running.contains($0) }
    }

    static func dedicatedBundleIDs(for provider: AgentProvider) -> Set<String> {
        switch provider {
        case .codex:
            // Codex Desktop / CLI host — not ChatGPT.app, which people leave open.
            return ["com.openai.codex-desktop", "com.openai.codex.desktop"]
        case .claudeCode:
            // Claude Desktop is a chat app people leave open, like Cursor.app.
            // Only the dedicated CLI host holds a Claude Code slip.
            return ["com.anthropic.claude-code"]
        case .factory:
            return ["com.factory.app", "com.factory.desktop"]
        case .warp:
            // Warp is the terminal the agent lives in — unlike Cursor.app,
            // leaving it open means the conversation is still in front.
            return [
                "dev.warp.Warp-Stable",
                "dev.warp.Warp",
                "dev.warp.Warp-Nightly",
                "dev.warp.Warp-Preview"
            ]
        default:
            // Cursor.app / Windsurf.app are IDEs. They must not mute
            // receipts; only a named CLI (`cursor-agent`, …) counts.
            return []
        }
    }

    private static func snapshotLines(_ fetch: @escaping @Sendable () -> [String]) async -> [String] {
        await Task.detached { fetch() }.value
    }

    static func liveProcessLines() -> [String] {
        AgentCLIProcessClassifier.liveProcessLines()
    }

    static func liveRunningBundleIDs() -> Set<String> {
        Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
    }
}
