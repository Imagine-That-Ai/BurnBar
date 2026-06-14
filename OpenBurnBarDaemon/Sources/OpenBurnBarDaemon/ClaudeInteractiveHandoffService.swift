import Darwin
import Foundation
import OpenBurnBarCore

// MARK: - ClaudeInteractiveHandoffService (Part B1)

/// Orchestrates handoff of a task into a **genuine interactive** Claude Code
/// session that a human drives in a real terminal window — the lowest-brittleness
/// option in the Part B plan and the closest thing to legitimately "interactive"
/// usage.
///
/// Unlike `claude -p`/`--print` (the explicitly-metered programmatic path) or the
/// resident PTY executor (B2, full-auto), this opens a visible terminal running
/// `claude` with the briefing pre-loaded as the first message. OpenBurnBar then
/// acts as a **companion**: it snapshots the local JSONL ledger when the session
/// is dispatched and reconciles the token delta on demand, attributing the cost
/// to the user's own subscription window rather than re-billing through the
/// gateway.
///
/// ## Why a `.command` launcher
///
/// To run a command in a *new* window of the user's terminal of choice, the most
/// portable mechanism on macOS is an executable `.command` script opened via
/// `open -a <App>`. Terminal.app and iTerm both execute `.command` files in a
/// fresh window; the script `cd`s to the working directory and `exec`s an
/// interactive `claude` (no `-p`). Reading the prompt/system text from sidecar
/// files avoids all shell-quoting hazards.
///
/// AUDIT(@unchecked Sendable): all stored properties are immutable and Sendable
/// except `fileManager: FileManager`, which Foundation does not yet mark Sendable.
/// `FileManager` is documented as safe for concurrent use, so sharing the value is
/// safe; drop this conformance once Foundation annotates `FileManager: Sendable`.
public final class ClaudeInteractiveHandoffService: @unchecked Sendable {

    public enum TerminalApp: String, Codable, Sendable, CaseIterable {
        case terminal
        case iterm
        case warp

        var applicationName: String {
            switch self {
            case .terminal: return "Terminal"
            case .iterm: return "iTerm"
            case .warp: return "Warp"
            }
        }
    }

    public struct Request: Sendable {
        public var briefing: String
        public var workingDirectory: String?
        public var model: String?
        public var terminal: TerminalApp

        public init(
            briefing: String,
            workingDirectory: String? = nil,
            model: String? = nil,
            terminal: TerminalApp = .terminal
        ) {
            self.briefing = briefing
            self.workingDirectory = workingDirectory
            self.model = model
            self.terminal = terminal
        }
    }

    public struct CompanionSession: Codable, Sendable, Equatable {
        public let id: String
        public let createdAt: Date
        public let workingDirectory: String?
        public let model: String?
        public let terminal: String
        public let baselineTokens: Int
        public var reconciledAt: Date?
        public var observedTokenDelta: Int?
        public var changedSessions: [String]?
    }

    public struct DispatchResult: Sendable {
        public let session: CompanionSession
        public let launcherPath: String
    }

    public struct ReconcileResult: Sendable {
        public let session: CompanionSession
        public let tokenDelta: Int
        public let changedSessions: [String]
    }

    public enum HandoffError: Error, LocalizedError, Equatable {
        case claudeNotFound
        case launchFailed(String)
        case sessionNotFound(String)
        case emptyBriefing

        public var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "The `claude` executable was not found on PATH or common install locations."
            case .launchFailed(let message):
                return "Failed to launch the interactive Claude session: \(message)."
            case .sessionNotFound(let id):
                return "No companion session found with id \(id)."
            case .emptyBriefing:
                return "A non-empty briefing is required to dispatch an interactive handoff."
            }
        }
    }

    private let storeURL: URL
    private let launcherDirectory: URL
    private let fileManager: FileManager
    private let claudeExecutableURL: URL?
    private let openExecutableURL: URL
    private let lock = NSLock()
    private let logger: BurnBarDaemonLogger

    public init(
        storeURL: URL = BurnBarDaemonPaths.defaultClaudeHandoffSessionsURL,
        launcherDirectory: URL? = nil,
        claudeExecutableURL: URL? = nil,
        openExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/open"),
        fileManager: FileManager = .default,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "claude-handoff")
    ) {
        self.storeURL = storeURL
        self.launcherDirectory = launcherDirectory
            ?? storeURL.deletingLastPathComponent().appendingPathComponent("claude-handoff-launchers", isDirectory: true)
        self.claudeExecutableURL = claudeExecutableURL
        self.openExecutableURL = openExecutableURL
        self.fileManager = fileManager
        self.logger = logger
    }

    // MARK: - Dispatch

    /// Writes a launcher, opens it in the requested terminal, and records a
    /// companion session whose baseline is the current JSONL token total scoped
    /// to the working directory's Claude project.
    public func dispatch(_ request: Request) throws -> DispatchResult {
        let briefing = request.briefing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !briefing.isEmpty else { throw HandoffError.emptyBriefing }

        let claudeURL = try claudeExecutableURL ?? Self.resolveClaude()
        let sessionID = UUID().uuidString
        let launcherURL = try writeLauncher(
            sessionID: sessionID,
            claudeURL: claudeURL,
            briefing: briefing,
            request: request
        )

        try launch(launcherURL: launcherURL, terminal: request.terminal)

        let snapshot = jsonlProbe.snapshot()
        let baseline = Self.scopedTotal(
            snapshot: snapshot,
            projectDirectory: Self.claudeProjectDirectory(for: request.workingDirectory)
        )
        let session = CompanionSession(
            id: sessionID,
            createdAt: Date(),
            workingDirectory: request.workingDirectory,
            model: request.model,
            terminal: request.terminal.rawValue,
            baselineTokens: baseline,
            reconciledAt: nil,
            observedTokenDelta: nil,
            changedSessions: nil
        )
        appendSession(session)
        logger.notice("claude_handoff_dispatched", metadata: [
            "session": sessionID,
            "terminal": request.terminal.rawValue,
            "baseline_tokens": "\(baseline)"
        ])
        return DispatchResult(session: session, launcherPath: launcherURL.path)
    }

    // MARK: - Reconcile

    /// Re-snapshots the JSONL ledger for a companion session and records the
    /// observed token delta. Safe to call repeatedly; each call refreshes the
    /// observed delta against the original baseline.
    public func reconcile(sessionID: String) throws -> ReconcileResult {
        var sessions = loadSessions()
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw HandoffError.sessionNotFound(sessionID)
        }
        var session = sessions[index]
        let projectDirectory = Self.claudeProjectDirectory(for: session.workingDirectory)
        let snapshot = jsonlProbe.snapshot()
        let scopedTotal = Self.scopedTotal(snapshot: snapshot, projectDirectory: projectDirectory)
        let delta = max(0, scopedTotal - session.baselineTokens)
        let changed = Self.scopedFileNames(snapshot: snapshot, projectDirectory: projectDirectory)
        session.reconciledAt = Date()
        session.observedTokenDelta = delta
        session.changedSessions = changed
        sessions[index] = session
        saveSessions(sessions)
        return ReconcileResult(session: session, tokenDelta: delta, changedSessions: changed)
    }

    public func listSessions() -> [CompanionSession] {
        loadSessions().sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Launcher generation

    private func writeLauncher(
        sessionID: String,
        claudeURL: URL,
        briefing: String,
        request: Request
    ) throws -> URL {
        try fileManager.createDirectory(
            at: launcherDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessionDirectory = launcherDirectory.appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let promptURL = sessionDirectory.appendingPathComponent("prompt.txt", isDirectory: false)
        let systemURL = sessionDirectory.appendingPathComponent("system.txt", isDirectory: false)
        try briefing.write(to: promptURL, atomically: true, encoding: .utf8)
        try Self.systemPrompt.write(to: systemURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: systemURL.path)

        let workingDirectory = request.workingDirectory.flatMap { dir -> String? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return dir
        }

        var modelFlag = ""
        if let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            modelFlag = "--model \(Self.shellSingleQuote(model)) "
        }

        let cdLine = workingDirectory.map { "cd \(Self.shellSingleQuote($0))" } ?? "true"
        // Sidecar files are read at runtime so the briefing never has to be
        // escaped into the script body. Our generated paths contain no single
        // quotes, so single-quoting them is safe.
        let script = """
        #!/bin/bash
        # OpenBurnBar interactive Claude handoff (companion mode) — session \(sessionID)
        # Genuine interactive session you drive (no programmatic print flag).
        \(cdLine)
        PROMPT="$(cat \(Self.shellSingleQuote(promptURL.path)))"
        SYSTEM="$(cat \(Self.shellSingleQuote(systemURL.path)))"
        echo "OpenBurnBar handoff session \(sessionID) — interactive Claude Code."
        echo "Reconcile usage later with: openburnbar-cli claude-handoff reconcile \(sessionID)"
        echo
        exec \(Self.shellSingleQuote(claudeURL.path)) \(modelFlag)--append-system-prompt "$SYSTEM" "$PROMPT"
        """

        let launcherURL = sessionDirectory.appendingPathComponent("launch.command", isDirectory: false)
        try script.write(to: launcherURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
        return launcherURL
    }

    private func launch(launcherURL: URL, terminal: TerminalApp) throws {
        let process = Process()
        process.executableURL = openExecutableURL
        process.arguments = ["-a", terminal.applicationName, launcherURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw HandoffError.launchFailed(error.localizedDescription)
        }
        if process.terminationStatus != 0 {
            throw HandoffError.launchFailed("`open -a \(terminal.applicationName)` exited with status \(process.terminationStatus)")
        }
    }

    // MARK: - JSONL probe scoping

    /// A single global probe with a generous recency window. Per-project
    /// attribution is achieved by filtering the snapshot's per-file totals to
    /// the working directory's encoded Claude project path — the probe itself
    /// scans `~/.claude/projects/<each project>/*.jsonl`, so filtering by path
    /// prefix is both correct and precise.
    private var jsonlProbe: ClaudeCodeJSONLUsageProbe {
        ClaudeCodeJSONLUsageProbe(recencyCutoff: 12 * 60 * 60)
    }

    /// Sums tokens across the snapshot, restricted to files under
    /// `projectDirectory` when known; otherwise the global recent total.
    static func scopedTotal(
        snapshot: ClaudeCodeJSONLUsageProbe.Snapshot,
        projectDirectory: URL?
    ) -> Int {
        guard let prefix = projectDirectory?.standardizedFileURL.path else {
            return snapshot.totalTokens
        }
        return snapshot.perFileTokens.reduce(0) { partial, entry in
            entry.key.hasPrefix(prefix) ? partial + entry.value : partial
        }
    }

    static func scopedFileNames(
        snapshot: ClaudeCodeJSONLUsageProbe.Snapshot,
        projectDirectory: URL?
    ) -> [String] {
        let prefix = projectDirectory?.standardizedFileURL.path
        return snapshot.perFileTokens.keys
            .filter { prefix == nil || $0.hasPrefix(prefix!) }
            .map { ($0 as NSString).lastPathComponent }
            .sorted()
    }

    /// Claude Code encodes a project's session directory as the absolute working
    /// directory path with `/` replaced by `-` (e.g. `/Users/me/p` →
    /// `-Users-me-p`). Returns the expected `~/.claude/projects/<encoded>` URL,
    /// or `nil` when no working directory is known (global scope).
    static func claudeProjectDirectory(for workingDirectory: String?) -> URL? {
        guard let workingDirectory else { return nil }
        let standardized = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        guard standardized.hasPrefix("/") else { return nil }
        let encoded = standardized.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
    }

    // MARK: - Persistence

    private func appendSession(_ session: CompanionSession) {
        var sessions = loadSessions()
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        // Bound the store to a reasonable history.
        if sessions.count > 200 {
            sessions = Array(sessions.suffix(200))
        }
        saveSessions(sessions)
    }

    func loadSessions() -> [CompanionSession] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CompanionSession].self, from: data)) ?? []
    }

    private func saveSessions(_ sessions: [CompanionSession]) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: storeURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        }
    }

    // MARK: - Helpers

    static func resolveClaude() throws -> URL {
        do {
            return try ClaudeInteractiveMeterExperiment.resolveClaudeExecutable()
        } catch {
            throw HandoffError.claudeNotFound
        }
    }

    /// Wraps a value in single quotes for safe shell interpolation, escaping any
    /// embedded single quotes via the `'\''` idiom.
    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let systemPrompt = """
    You are continuing an OpenBurnBar handoff in a genuine interactive Claude Code session. \
    Treat the first user message as the canonical task briefing. Work on the user's machine \
    as a normal interactive session; the human is driving and will approve actions.
    """
}
