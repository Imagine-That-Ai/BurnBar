#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import OpenBurnBarComputerUseCore

/// Reads the on-disk Computer Use audit chain and answers, in plain terms,
/// *what agents actually did on this Mac*.
///
/// The audit data has existed for a while and is genuinely good — a hash-linked,
/// tamper-evident chain per session. The only way to see it was Settings → Computer
/// Use → Forensics, which asks you to type a session id and press "Validate Chain".
/// That proves the data exists; it reassures nobody. A user who has just granted screen
/// and input access wants to know *what happened*, not to verify a Merkle chain.
///
/// This type is deliberately pure: `FileManager` and the base directory are injected,
/// nothing here touches SwiftUI, and every method is synchronous and total. That makes
/// the summarising logic testable against a temp directory instead of a live session,
/// which is the only reason the odd cases (a truncated chain, a session that never
/// finalised) are covered at all.
///
/// It never throws on a damaged session. A single corrupt manifest degrades that one
/// row rather than emptying the list: someone opening this screen because they feel
/// uneasy is the worst possible audience for "no activity found" when activity exists.
struct ComputerUseActivityIndex {

    /// One session, summarised for a human rather than for a verifier.
    struct SessionSummary: Identifiable, Hashable, Sendable {
        let sessionId: String
        let startedAt: Date?
        let lastActivityAt: Date?
        let trustMode: ComputerUseTrustMode?
        let actionCount: Int
        let approvedCount: Int
        let rejectedCount: Int
        let screenshotCount: Int
        let panicHalted: Bool
        /// True when the manifest could not be read. The row still lists whatever the
        /// chain yielded, flagged, rather than vanishing.
        let isDegraded: Bool

        var id: String { sessionId }

        /// Apps the agent touched, most recent first. Empty when the chain carried none.
        let touchedTargets: [String]
    }

    private let baseDirectory: URL
    private let fileManager: FileManager

    init(
        baseDirectory: URL = OpenBurnBarAppPaths.live().supportDirectory
            .appendingPathComponent("computer-use-audit", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    /// Every session on disk, newest first.
    ///
    /// - Parameter limit: cap on rows returned. Passing a limit does **not** silently
    ///   hide older sessions — `totalSessionCount` reports the real number so the UI can
    ///   say so. A screen about trust must not quietly truncate.
    func sessions(limit: Int = 50) -> [SessionSummary] {
        Array(allSessions().prefix(max(0, limit)))
    }

    /// Total sessions on disk, ignoring any display limit.
    func totalSessionCount() -> Int {
        sessionDirectories().count
    }

    /// The individual actions for one session, oldest first.
    func entries(sessionId: String) -> [ComputerUseAuditEntry] {
        decodeChain(at: sessionDirectory(sessionId).appendingPathComponent(Self.chainFileName))
    }

    /// A single sentence for the top of the screen. Written to be true when there is
    /// nothing to report, which is the common and reassuring case.
    func plainLanguageSummary(_ sessions: [SessionSummary], now: Date = Date()) -> String {
        guard !sessions.isEmpty else {
            return "No agent has seen or touched this Mac yet. When one does, every action "
                + "it takes will be listed here."
        }

        let actions = sessions.reduce(0) { $0 + $1.actionCount }
        let rejected = sessions.reduce(0) { $0 + $1.rejectedCount }
        let screenshots = sessions.reduce(0) { $0 + $1.screenshotCount }

        var sentence = "\(count(sessions.count, "session")), \(count(actions, "action"))"
        if rejected > 0 {
            sentence += ", \(rejected) of them stopped by you"
        }
        if screenshots > 0 {
            sentence += ", \(count(screenshots, "screenshot"))"
        }
        sentence += "."

        if let last = sessions.compactMap(\.lastActivityAt).max() {
            sentence += " Nothing since \(relativeDescription(for: last, relativeTo: now))."
        }
        if sessions.contains(where: \.panicHalted) {
            sentence += " One or more sessions were halted early."
        }
        return sentence
    }

    // MARK: - Private

    private static let chainFileName = "chain.jsonl"
    private static let manifestFileName = "manifest.json"
    private static let screenshotsDirectoryName = "screenshots"

    /// Built per call rather than cached in a static: `RelativeDateTimeFormatter` is not
    /// `Sendable`, and reaching for `@unchecked` to keep a shared instance would spend the
    /// concurrency ratchet on a formatter used once per screen render.
    private func relativeDescription(for date: Date, relativeTo now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private func sessionDirectory(_ sessionId: String) -> URL {
        baseDirectory.appendingPathComponent(sessionId, isDirectory: true)
    }

    private func sessionDirectories() -> [URL] {
        // try?-ok(no audit directory yet is the normal state before any session runs)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter { url in
            // try?-ok(an unreadable entry is simply not a session directory)
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private func allSessions() -> [SessionSummary] {
        sessionDirectories()
            .map(summarise(directory:))
            .sorted { lhs, rhs in
                // Sessions that never wrote a timestamp sort last rather than randomly.
                switch (lhs.startedAt, rhs.startedAt) {
                case let (left?, right?): return left > right
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.sessionId > rhs.sessionId
                }
            }
    }

    private func summarise(directory: URL) -> SessionSummary {
        let sessionId = directory.lastPathComponent
        let manifest = decodeManifest(at: directory.appendingPathComponent(Self.manifestFileName))
        let entries = decodeChain(at: directory.appendingPathComponent(Self.chainFileName))

        // Screenshots are counted from the chain rather than the directory: a file left
        // behind by a crashed session would otherwise inflate the number a user is being
        // asked to trust.
        let screenshots = entries.reduce(0) { total, entry in
            total + (entry.beforeScreenshotHashHex == nil ? 0 : 1)
                + (entry.afterScreenshotHashHex == nil ? 0 : 1)
        }

        let rejected = entries.filter { $0.approvedBy == .denied }.count
        let panicked = entries.contains { $0.approvedBy == .panic }

        return SessionSummary(
            sessionId: sessionId,
            startedAt: manifest?.startedAt ?? entries.first?.timestamp,
            lastActivityAt: entries.last?.timestamp,
            trustMode: manifest?.trustMode,
            actionCount: entries.count,
            approvedCount: entries.filter { $0.approvedBy != .denied && $0.approvedBy != .panic }.count,
            rejectedCount: rejected,
            screenshotCount: screenshots,
            panicHalted: panicked,
            isDegraded: manifest == nil,
            touchedTargets: distinctTargets(in: entries)
        )
    }

    /// `actionSummary` is human text like "click Safari toolbar"; the first word is a
    /// reasonable proxy for what was operated. Kept deliberately dumb — a wrong guess
    /// here is cosmetic, and inventing structure the chain does not carry would not be.
    private func distinctTargets(in entries: [ComputerUseAuditEntry]) -> [String] {
        var seen = Set<String>()
        var targets: [String] = []
        for entry in entries.reversed() {
            let kind = entry.actionKind.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kind.isEmpty, seen.insert(kind).inserted else { continue }
            targets.append(kind)
            if targets.count == 6 { break }
        }
        return targets
    }

    private func decodeManifest(at url: URL) -> ComputerUseSessionManifest? {
        // try?-ok(a session killed before finalising has no manifest; the row degrades)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // try?-ok(a corrupt manifest degrades one row rather than emptying the list)
        return try? ComputerUseAuditHasher.canonicalJSONDecoder.decode(
            ComputerUseSessionManifest.self,
            from: data
        )
    }

    /// Decodes JSONL, skipping unreadable lines.
    ///
    /// A truncated final line is the expected shape of a session that was killed mid-write
    /// (panic stop, crash, power loss), so it must not discard the lines before it — those
    /// are exactly the actions a user wants to see after an abrupt halt.
    private func decodeChain(at url: URL) -> [ComputerUseAuditEntry] {
        // try?-ok(a session that recorded no actions has no chain file)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = ComputerUseAuditHasher.canonicalJSONDecoder
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                // A truncated final line is the expected shape of a killed session;
                // skipping it preserves every complete entry before it.
                // try?-ok(truncated tail of a session killed mid-write)
                return try? decoder.decode(ComputerUseAuditEntry.self, from: data)
            }
    }
}
#endif
