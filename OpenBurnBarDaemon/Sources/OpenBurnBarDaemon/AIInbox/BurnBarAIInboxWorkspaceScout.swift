import Foundation
import OpenBurnBarEngine

/// A snapshot of one workspace's git reality at tick time.
///
/// This is the "does the code agree with the conversation?" evidence. An agent
/// claiming "committed and pushed the fix" against a tree with 14 uncommitted
/// files and an unchanged HEAD is exactly the signal the inbox exists to catch.
struct BurnBarAIInboxWorkspaceSnapshot: Sendable, Hashable {
    let path: String
    let isGitRepository: Bool
    let branch: String?
    let headSHA: String?
    let headSubject: String?
    let headCommittedAt: Date?
    /// Paths with staged/unstaged modifications (bounded).
    let dirtyFiles: [String]
    let untrackedCount: Int
    /// Commits on this branch not present on its upstream.
    let aheadCount: Int
    let behindCount: Int
    /// `owner/repo` derived from `remote.origin.url`, when it is a GitHub remote.
    let githubSlug: String?
    /// Subjects of the most recent commits — cheap "did the promised work land?"
    /// evidence without fetching from the network.
    let recentCommitSubjects: [String]

    var isDirty: Bool { dirtyFiles.isEmpty == false || untrackedCount > 0 }

    /// Compact identity used by the change gate.
    var gateSignature: String {
        BurnBarAIInboxStableHasher.hash([
            path,
            headSHA ?? "-",
            branch ?? "-",
            String(dirtyFiles.count),
            String(untrackedCount),
            String(aheadCount)
        ])
    }
}

/// Reads git state for the workspaces the recent conversations touched.
///
/// Deliberately read-only and bounded: `status --porcelain`, `log`, `rev-list`,
/// `config --get`. It never fetches, never writes, and never runs a hook.
struct BurnBarAIInboxWorkspaceScout: Sendable {
    private let runner: any BurnBarAIInboxProcessRunning
    private let logger: BurnBarDaemonLogger

    /// Bounds per tick — the scout must stay cheap enough to run every 5 minutes
    /// without being noticeable.
    static let maxWorkspaces = 12
    static let maxDirtyFilesRecorded = 40
    static let maxRecentCommits = 15
    static let gitTimeout: TimeInterval = 8

    init(runner: any BurnBarAIInboxProcessRunning, logger: BurnBarDaemonLogger) {
        self.runner = runner
        self.logger = logger
    }

    /// Cheap filesystem-only fingerprint of the workspaces, used by the change
    /// gate.
    ///
    /// This exists because the gate is on the hot path of EVERY tick — 288 a day —
    /// and calling `snapshots(for:)` there would spawn ~6 git subprocesses per
    /// workspace on every wake, including the ~95% of wakes that end in "nothing
    /// changed". That would make the supposedly-free path the most expensive
    /// thing the daemon does.
    ///
    /// Instead we `stat` the handful of files git itself mutates:
    ///   • `.git/HEAD` — branch switches
    ///   • `.git/refs` + `.git/packed-refs` — commits, fetches, resets
    ///   • `.git/index` — staging, and (crucially) any `git status` that
    ///     refreshes stat info, which is what moves after an edit
    ///
    /// Missing an edit here is acceptable: the conversation watermark and agent
    /// log mtimes in the same signature already move when work is happening, and
    /// the full snapshot runs the moment the gate opens.
    func gateFingerprint(for workspacePaths: [String]) -> String {
        var hasher = BurnBarAIInboxStableHasher()
        let manager = FileManager.default
        for path in Self.normalizedWorkspaces(workspacePaths).prefix(Self.maxWorkspaces) {
            hasher.combine(path)
            let gitDirectory = (path as NSString).appendingPathComponent(".git")
            for component in ["HEAD", "index", "packed-refs", "refs"] {
                let target = (gitDirectory as NSString).appendingPathComponent(component)
                guard let attributes = try? manager.attributesOfItem(atPath: target),
                      let modified = attributes[.modificationDate] as? Date else {
                    hasher.combine("-")
                    continue
                }
                hasher.combine(BurnBarAIInboxTimestamp.string(from: modified))
            }
        }
        return hasher.finalize()
    }

    /// Snapshots each distinct workspace, skipping non-repositories.
    /// Failures degrade to "no snapshot" rather than failing the tick — a
    /// missing git binary must never stop the inbox.
    func snapshots(for workspacePaths: [String]) async -> [BurnBarAIInboxWorkspaceSnapshot] {
        let unique = Self.normalizedWorkspaces(workspacePaths).prefix(Self.maxWorkspaces)
        var results: [BurnBarAIInboxWorkspaceSnapshot] = []
        for path in unique {
            if let snapshot = await snapshot(for: path) {
                results.append(snapshot)
            }
        }
        return results
    }

    func snapshot(for path: String) async -> BurnBarAIInboxWorkspaceSnapshot? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let inside = try? await git(["rev-parse", "--is-inside-work-tree"], at: path),
              inside.succeeded,
              inside.standardOutput.trimmed == "true" else {
            return nil
        }

        let branch = try? await git(["rev-parse", "--abbrev-ref", "HEAD"], at: path)
        // %H|%s|%cI in one call rather than three round trips.
        let head = try? await git(["log", "-1", "--pretty=format:%H%x1f%s%x1f%cI"], at: path)
        let status = try? await git(["status", "--porcelain=v1", "--untracked-files=normal"], at: path)
        let originURL = try? await git(["config", "--get", "remote.origin.url"], at: path)
        let recent = try? await git(
            ["log", "-\(Self.maxRecentCommits)", "--pretty=format:%s"],
            at: path
        )
        // `@{upstream}` fails loudly on a branch with no upstream; that is a
        // normal state, so a failure here just means "no divergence known".
        let divergence = try? await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], at: path)

        var dirty: [String] = []
        var untracked = 0
        if let status, status.succeeded {
            for line in status.standardOutput.split(separator: "\n") {
                guard line.count > 3 else { continue }
                let code = line.prefix(2)
                let file = String(line.dropFirst(3)).trimmed
                if code.hasPrefix("??") {
                    untracked += 1
                } else if dirty.count < Self.maxDirtyFilesRecorded {
                    dirty.append(file)
                }
            }
        }

        var ahead = 0
        var behind = 0
        if let divergence, divergence.succeeded {
            let parts = divergence.standardOutput.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }

        // Broken out of the initializer: a single large expression here made the
        // type checker time out.
        let headOutput: String = Self.output(of: head)
        let headFields: [String] = headOutput
            .split(separator: "\u{1f}", omittingEmptySubsequences: false)
            .map { String($0).trimmed }
        let headSHA: String? = headFields.isEmpty ? nil : Self.emptyToNil(headFields[0])
        let headSubject: String? = headFields.count > 1 ? Self.emptyToNil(headFields[1]) : nil
        let headCommittedAt: Date? = headFields.count > 2
            ? BurnBarAIInboxTimestamp.date(from: headFields[2])
            : nil
        let branchName: String? = Self.emptyToNil(Self.output(of: branch).trimmed)
        let originRemote: String? = Self.emptyToNil(Self.output(of: originURL).trimmed)
        let commitSubjects: [String] = Self.output(of: recent)
            .split(separator: "\n")
            .map { String($0).trimmed }
            .filter { $0.isEmpty == false }

        return BurnBarAIInboxWorkspaceSnapshot(
            path: path,
            isGitRepository: true,
            branch: branchName,
            headSHA: headSHA,
            headSubject: headSubject,
            headCommittedAt: headCommittedAt,
            dirtyFiles: dirty,
            untrackedCount: untracked,
            aheadCount: ahead,
            behindCount: behind,
            githubSlug: Self.githubSlug(fromRemoteURL: originRemote),
            recentCommitSubjects: commitSubjects
        )
    }

    /// stdout of a successful run, or "" for a failed/absent one. Keeps the
    /// optional-chaining out of the call sites above.
    private static func output(of result: BurnBarAIInboxProcessResult?) -> String {
        guard let result, result.succeeded else { return "" }
        return result.standardOutput
    }

    private static func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func git(_ arguments: [String], at path: String) async throws -> BurnBarAIInboxProcessResult {
        try await runner.run(
            executable: "git",
            arguments: [
                "-c", "core.fsmonitor=false",
                "-c", "core.hooksPath=/dev/null",
                "-c", "credential.helper=",
                "-C", path
            ] + arguments,
            workingDirectory: path,
            timeout: Self.gitTimeout,
            environmentOverrides: [:]
        )
    }

    /// De-duplicates and canonicalizes workspace paths. Conversations record
    /// working directories that may be nested, symlinked, or repeated.
    static func normalizedWorkspaces(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in paths {
            let trimmed = raw.trimmed
            guard trimmed.isEmpty == false, trimmed != "/" else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let canonical = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard seen.insert(canonical).inserted else { continue }
            ordered.append(canonical)
        }
        return ordered
    }

    /// Extracts `owner/repo` from any GitHub remote form:
    /// `git@github.com:o/r.git`, `https://github.com/o/r`, `ssh://git@github.com/o/r.git`.
    /// Returns nil for non-GitHub hosts so the inbox never points a `gh` query
    /// at a GitLab or Bitbucket remote.
    static func githubSlug(fromRemoteURL remoteURL: String?) -> String? {
        guard var url = remoteURL?.trimmed, url.isEmpty == false else { return nil }
        guard url.lowercased().contains("github.com") else { return nil }
        if url.hasSuffix(".git") { url = String(url.dropLast(4)) }

        let afterHost: String
        if let range = url.range(of: "github.com") {
            afterHost = String(url[range.upperBound...])
        } else {
            return nil
        }
        let path = afterHost.drop { $0 == ":" || $0 == "/" }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        let repo = components[1]
        guard owner.isEmpty == false, repo.isEmpty == false else { return nil }
        // Reject anything that is not a plain path segment — this string is
        // interpolated into a `gh api` path.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard owner.unicodeScalars.allSatisfy(allowed.contains),
              repo.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return "\(owner)/\(repo)"
    }
}

private extension String {
    /// Local convenience for the inbox's parsing paths. (`nilIfEmpty` already
    /// exists elsewhere in this module, so it is deliberately not redefined.
    /// Kept file-private: the Linux credential authority declares its own
    /// `trimmed: String?`, and an internal one would collide on Linux.)
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
