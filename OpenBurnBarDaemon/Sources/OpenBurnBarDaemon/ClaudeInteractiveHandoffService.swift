#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
public final class ClaudeInteractiveHandoffService: Sendable {

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
    private let fileSystem: any SendableFileSystem
    private let claudeExecutableURL: URL?
    private let openExecutableURL: URL
    private let lock = NSLock()
    private let logger: BurnBarDaemonLogger

    public init(
        storeURL: URL = BurnBarDaemonPaths.defaultClaudeHandoffSessionsURL,
        launcherDirectory: URL? = nil,
        claudeExecutableURL: URL? = nil,
        openExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/open"),
        fileSystem: any SendableFileSystem = DefaultSendableFileSystem(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "claude-handoff")
    ) {
        self.storeURL = storeURL
        self.launcherDirectory = launcherDirectory
            ?? storeURL.deletingLastPathComponent().appendingPathComponent("claude-handoff-launchers", isDirectory: true)
        self.claudeExecutableURL = claudeExecutableURL
        self.openExecutableURL = openExecutableURL
        self.fileSystem = fileSystem
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
        try fileSystem.createDirectory(
            at: launcherDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessionDirectory = launcherDirectory.appendingPathComponent(sessionID, isDirectory: true)
        try fileSystem.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let promptURL = sessionDirectory.appendingPathComponent("prompt.txt", isDirectory: false)
        let systemURL = sessionDirectory.appendingPathComponent("system.txt", isDirectory: false)
        try briefing.write(to: promptURL, atomically: true, encoding: .utf8)
        try Self.systemPrompt.write(to: systemURL, atomically: true, encoding: .utf8)
        try fileSystem.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)
        try fileSystem.setAttributes([.posixPermissions: 0o600], ofItemAtPath: systemURL.path)

        let workingDirectory = request.workingDirectory.flatMap { dir -> String? in
            var isDirectory: ObjCBool = false
            guard fileSystem.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
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
        try fileSystem.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
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
        try? fileSystem.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) {
            try? data.write(to: storeURL, options: [.atomic])
            try? fileSystem.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        }
    }

    // MARK: - Helpers

    static func resolveClaude() throws -> URL {
        do {
            return try Self.resolveClaudeExecutable()
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

// MARK: - Claude executable discovery

extension ClaudeInteractiveHandoffService {

    /// Resolves the `claude` CLI the handoff will drive. Searches common install
    /// locations (Homebrew, `.local/bin`, `.bun/bin`, nvm-managed Node versions)
    /// plus `$PATH`, returning the first executable match.
    static func resolveClaudeExecutable() throws -> URL {
        let candidates = claudeExecutableCandidatePaths()
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw PTYInteractiveSessionError.executableNotFound("claude (not found on PATH or common install locations)")
    }

    static func claudeExecutableCandidatePaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        var candidates = [
            homeDirectory.appendingPathComponent(".local/bin/claude").path,
            homeDirectory.appendingPathComponent(".homebrew/bin/claude").path,
            homeDirectory.appendingPathComponent(".bun/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        candidates.append(contentsOf: nvmClaudeCandidatePaths(homeDirectory: homeDirectory, fileManager: fileManager))
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path }
        candidates.append(contentsOf: pathEntries)
        return Self.dedupe(candidates)
    }

    private static func nvmClaudeCandidatePaths(homeDirectory: URL, fileManager: FileManager) -> [String] {
        let nodeVersions = homeDirectory
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let versionNames = try? fileManager.contentsOfDirectory(atPath: nodeVersions.path) else {
            return []
        }
        return versionNames
            .filter { !$0.hasPrefix(".") }
            .map { nodeVersions.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("claude").path }
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return false }
            seen.insert(trimmed)
            return true
        }
    }
}

// MARK: - ClaudeCodeJSONLUsageProbe

/// Lean reader of `~/.claude/projects/*.jsonl` that sums token usage across
/// recently-modified session files. Used by the handoff (B1) to snapshot and
/// reconcile a companion session's token delta against the user's own
/// subscription window. Bounded by an mtime cutoff so it never walks a huge
/// history.
struct ClaudeCodeJSONLUsageProbe: Sendable {
    let projectsDirectory: URL
    let recencyCutoff: TimeInterval

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        recencyCutoff: TimeInterval = 6 * 60 * 60
    ) {
        self.projectsDirectory = projectsDirectory
        self.recencyCutoff = recencyCutoff
    }

    struct Snapshot: Sendable {
        /// Per-session-file token sums (path → tokens).
        let perFileTokens: [String: Int]
        var totalTokens: Int { perFileTokens.values.reduce(0, +) }
    }

    func snapshot() -> Snapshot {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return Snapshot(perFileTokens: [:])
        }
        let cutoff = Date().addingTimeInterval(-recencyCutoff)
        var perFile: [String: Int] = [:]
        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard modified >= cutoff else { continue }
                perFile[file.path] = Self.sumTokens(in: file)
            }
        }
        return Snapshot(perFileTokens: perFile)
    }

    /// Session file paths whose token sum changed (or appeared) between snapshots.
    static func changedSessions(before: Snapshot, after: Snapshot) -> [String] {
        var changed: [String] = []
        for (path, afterTokens) in after.perFileTokens where before.perFileTokens[path] != afterTokens {
            changed.append((path as NSString).lastPathComponent)
        }
        return changed.sorted()
    }

    private static func sumTokens(in file: URL) -> Int {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        var total = 0
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            guard let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                return
            }
            for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                if let v = usage[key] as? Int { total += v } else if let v = usage[key] as? Double { total += Int(v) }
            }
        }
        return total
    }
}
