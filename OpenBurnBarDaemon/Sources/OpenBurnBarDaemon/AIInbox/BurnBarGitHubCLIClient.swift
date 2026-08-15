import Foundation
import OpenBurnBarEngine

// MARK: - Models

struct BurnBarGitHubPullRequest: Sendable, Hashable, Codable {
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let headRefName: String
    let author: String?
    let url: String
    let createdAt: Date?
    let updatedAt: Date?
    let mergedAt: Date?
    let closedAt: Date?
    let additions: Int
    let deletions: Int
    let reviewDecision: String?

    var isOpen: Bool { state.uppercased() == "OPEN" }
    var isMerged: Bool { mergedAt != nil || state.uppercased() == "MERGED" }
}

struct BurnBarGitHubIssue: Sendable, Hashable, Codable {
    let number: Int
    let title: String
    let state: String
    let url: String
    let createdAt: Date?
    let updatedAt: Date?
    let labels: [String]
}

struct BurnBarGitHubWorkflowRun: Sendable, Hashable, Codable {
    let id: Int
    let name: String
    let workflowName: String?
    let headSHA: String
    let headBranch: String?
    let status: String
    let conclusion: String?
    let event: String
    let createdAt: Date?
    let updatedAt: Date?
    let runStartedAt: Date?
    let url: String

    /// Wall-clock duration. Used as the proxy for burned CI minutes — the
    /// billable-minutes endpoint requires elevated scopes most tokens lack.
    var durationSeconds: Double {
        guard let start = runStartedAt ?? createdAt, let end = updatedAt else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }

    var isFinished: Bool { status.lowercased() == "completed" }

    /// A run that consumed compute and produced nothing actionable.
    var isWasted: Bool {
        guard let conclusion = conclusion?.lowercased() else { return false }
        return ["failure", "cancelled", "canceled", "timed_out", "startup_failure", "stale"].contains(conclusion)
    }

    var isSuccess: Bool { conclusion?.lowercased() == "success" }
}

/// What the inbox knows about one repository at tick time.
struct BurnBarGitHubRepositorySnapshot: Sendable, Hashable {
    let slug: String
    let openPullRequests: [BurnBarGitHubPullRequest]
    let recentlyMergedPullRequests: [BurnBarGitHubPullRequest]
    let openIssues: [BurnBarGitHubIssue]
    let recentRuns: [BurnBarGitHubWorkflowRun]
    let fetchedAt: Date
}

enum BurnBarGitHubAvailability: Sendable, Hashable {
    case available
    case binaryMissing
    case notAuthenticated
    case failed(String)

    var isAvailable: Bool { self == .available }

    /// One-line explanation surfaced as a `system` inbox item, so a silent
    /// capability gap becomes visible instead of looking like "nothing to report".
    var explanation: String? {
        switch self {
        case .available:
            return nil
        case .binaryMissing:
            return "The GitHub CLI (`gh`) was not found. Install it and run `gh auth login` to let the inbox verify whether promised work actually shipped."
        case .notAuthenticated:
            return "The GitHub CLI is installed but not authenticated. Run `gh auth login` so the inbox can read pull requests and workflow runs."
        case .failed(let reason):
            return "GitHub checks are unavailable: \(reason)"
        }
    }
}

// MARK: - Client

/// Reads GitHub through the user's own authenticated `gh` CLI.
///
/// Why `gh` rather than a REST client with a stored token: the user already has
/// `gh` authenticated, `gh` already handles token refresh, enterprise hosts, and
/// SSO, and this way the inbox stores **no** GitHub credential of its own. The
/// daemon's threat surface does not grow to hold a new long-lived secret.
///
/// Every call is read-only (`gh api` GET / `gh pr list` / `gh run list`), bounded
/// by a timeout, and served from `gh`'s own HTTP cache where possible.
actor BurnBarGitHubCLIClient {
    private let runner: any BurnBarAIInboxProcessRunning
    private let logger: BurnBarDaemonLogger
    private var cachedAvailability: BurnBarGitHubAvailability?
    private var availabilityCheckedAt: Date?

    /// `gh`'s on-disk HTTP cache TTL. Matches the remote-phase cadence so a
    /// 5-minute tick loop makes at most one real request per endpoint per phase.
    static let httpCacheTTL = "300s"
    static let requestTimeout: TimeInterval = 20
    static let availabilityRecheckInterval: TimeInterval = 15 * 60
    static let maxPullRequests = 30
    static let maxIssues = 20
    static let maxRuns = 100

    init(runner: any BurnBarAIInboxProcessRunning, logger: BurnBarDaemonLogger) {
        self.runner = runner
        self.logger = logger
    }

    /// Probes once, then caches. A missing/unauthenticated `gh` must not cost a
    /// subprocess spawn on every tick.
    func availability() async -> BurnBarGitHubAvailability {
        if let cachedAvailability, let checkedAt = availabilityCheckedAt,
           Date().timeIntervalSince(checkedAt) < Self.availabilityRecheckInterval,
           cachedAvailability.isAvailable {
            return cachedAvailability
        }

        guard BurnBarAIInboxProcessRunner.locate("gh") != nil else {
            cachedAvailability = .binaryMissing
            availabilityCheckedAt = Date()
            return .binaryMissing
        }

        do {
            let result = try await runner.run(
                executable: "gh",
                arguments: ["auth", "status"],
                workingDirectory: nil,
                timeout: 10,
                environmentOverrides: [:]
            )
            let availability: BurnBarGitHubAvailability = result.succeeded ? .available : .notAuthenticated
            cachedAvailability = availability
            availabilityCheckedAt = Date()
            return availability
        } catch {
            let availability = BurnBarGitHubAvailability.failed(Self.redactedReason(error))
            cachedAvailability = availability
            availabilityCheckedAt = Date()
            return availability
        }
    }

    /// Fetches everything the detectors need for one repository.
    ///
    /// Partial failure is fine and expected: a repo may have Actions disabled,
    /// or the token may lack issue scope. Each section degrades independently.
    func snapshot(slug: String, runLookback: TimeInterval) async -> BurnBarGitHubRepositorySnapshot? {
        guard Self.isValidSlug(slug) else {
            logger.warning("ai_inbox_github_invalid_slug", metadata: ["slug_length": "\(slug.count)"])
            return nil
        }
        guard await availability().isAvailable else { return nil }

        async let openPRs = pullRequests(slug: slug, state: "open")
        async let mergedPRs = pullRequests(slug: slug, state: "merged")
        async let issues = openIssues(slug: slug)
        async let runs = workflowRuns(slug: slug, since: Date().addingTimeInterval(-runLookback))

        return BurnBarGitHubRepositorySnapshot(
            slug: slug,
            openPullRequests: await openPRs,
            recentlyMergedPullRequests: await mergedPRs,
            openIssues: await issues,
            recentRuns: await runs,
            fetchedAt: Date()
        )
    }

    // MARK: - Sections

    func pullRequests(slug: String, state: String) async -> [BurnBarGitHubPullRequest] {
        let fields = "number,title,state,isDraft,headRefName,author,url,createdAt,updatedAt,mergedAt,closedAt,additions,deletions,reviewDecision"
        guard let output = await json(
            arguments: [
                "pr", "list",
                "--repo", slug,
                "--state", state,
                "--limit", String(Self.maxPullRequests),
                "--json", fields
            ],
            context: "pr_list_\(state)"
        ) else { return [] }
        return Self.decodePullRequests(output)
    }

    func openIssues(slug: String) async -> [BurnBarGitHubIssue] {
        guard let output = await json(
            arguments: [
                "issue", "list",
                "--repo", slug,
                "--state", "open",
                "--limit", String(Self.maxIssues),
                "--json", "number,title,state,url,createdAt,updatedAt,labels"
            ],
            context: "issue_list"
        ) else { return [] }
        return Self.decodeIssues(output)
    }

    /// Workflow runs via the REST API (`gh api`), which — unlike `gh run list` —
    /// supports the shared HTTP cache and returns timing fields needed to
    /// estimate burned minutes.
    func workflowRuns(slug: String, since: Date) async -> [BurnBarGitHubWorkflowRun] {
        let createdFilter = ">=" + Self.dayFormatter.string(from: since)
        guard let output = await json(
            arguments: [
                "api",
                "--cache", Self.httpCacheTTL,
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2022-11-28",
                "repos/\(slug)/actions/runs?per_page=\(Self.maxRuns)&created=\(createdFilter)"
            ],
            context: "workflow_runs"
        ) else { return [] }
        return Self.decodeWorkflowRuns(output)
    }

    // MARK: - Plumbing

    private func json(arguments: [String], context: String) async -> String? {
        do {
            let result = try await runner.run(
                executable: "gh",
                arguments: arguments,
                workingDirectory: nil,
                timeout: Self.requestTimeout,
                environmentOverrides: [:]
            )
            guard result.succeeded else {
                // Rate limiting and permission gaps are normal operating states,
                // not errors worth alarming about; log at debug and degrade.
                logger.debug(
                    "ai_inbox_github_call_failed",
                    metadata: ["context": context, "exit_code": "\(result.exitCode)"]
                )
                if result.standardError.contains("rate limit") {
                    cachedAvailability = .failed("GitHub API rate limit reached")
                    availabilityCheckedAt = Date()
                }
                return nil
            }
            return result.standardOutput
        } catch {
            logger.debug(
                "ai_inbox_github_call_error",
                metadata: ["context": context, "error": Self.redactedReason(error)]
            )
            return nil
        }
    }

    /// Defends the `gh api` path interpolation. Anything but `owner/repo` of
    /// safe path characters is refused.
    static func isValidSlug(_ slug: String) -> Bool {
        let parts = slug.split(separator: "/")
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return parts.allSatisfy { part in
            part.isEmpty == false && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func redactedReason(_ error: Error) -> String {
        // Process errors can echo argv; keep only the error kind.
        if let processError = error as? BurnBarAIInboxProcessError {
            switch processError {
            case .executableNotFound: return "gh_not_found"
            case .timedOut: return "timeout"
            case .launchFailed: return "launch_failed"
            }
        }
        return "unavailable"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = BurnBarAIInboxTimestamp.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(raw)")
            }
            return date
        }
        return decoder
    }

    // MARK: - Decoding
    //
    // `gh` returns camelCase for `pr`/`issue` list and snake_case for `api`, and
    // nests author/labels. Hand-rolled DTOs keep the public models flat and stop
    // a schema tweak in `gh` from breaking the whole tick.

    private struct PullRequestDTO: Decodable {
        struct Author: Decodable { let login: String? }
        let number: Int
        let title: String
        let state: String
        let isDraft: Bool?
        let headRefName: String?
        let author: Author?
        let url: String?
        let createdAt: Date?
        let updatedAt: Date?
        let mergedAt: Date?
        let closedAt: Date?
        let additions: Int?
        let deletions: Int?
        let reviewDecision: String?
    }

    private struct IssueDTO: Decodable {
        struct Label: Decodable { let name: String? }
        let number: Int
        let title: String
        let state: String
        let url: String?
        let createdAt: Date?
        let updatedAt: Date?
        let labels: [Label]?
    }

    private struct WorkflowRunsEnvelope: Decodable {
        let workflowRuns: [WorkflowRunDTO]?

        enum CodingKeys: String, CodingKey { case workflowRuns = "workflow_runs" }
    }

    private struct WorkflowRunDTO: Decodable {
        let id: Int
        let name: String?
        let displayTitle: String?
        let headSha: String?
        let headBranch: String?
        let status: String?
        let conclusion: String?
        let event: String?
        let createdAt: Date?
        let updatedAt: Date?
        let runStartedAt: Date?
        let htmlURL: String?
        let path: String?

        enum CodingKeys: String, CodingKey {
            case id, name, conclusion, status, event, path
            case displayTitle = "display_title"
            case headSha = "head_sha"
            case headBranch = "head_branch"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case runStartedAt = "run_started_at"
            case htmlURL = "html_url"
        }
    }

    static func decodePullRequests(_ json: String) -> [BurnBarGitHubPullRequest] {
        guard let data = json.data(using: .utf8),
              let dtos = try? makeDecoder().decode([PullRequestDTO].self, from: data) else { return [] }
        return dtos.map {
            BurnBarGitHubPullRequest(
                number: $0.number,
                title: $0.title,
                state: $0.state,
                isDraft: $0.isDraft ?? false,
                headRefName: $0.headRefName ?? "",
                author: $0.author?.login,
                url: $0.url ?? "",
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                mergedAt: $0.mergedAt,
                closedAt: $0.closedAt,
                additions: $0.additions ?? 0,
                deletions: $0.deletions ?? 0,
                reviewDecision: $0.reviewDecision
            )
        }
    }

    static func decodeIssues(_ json: String) -> [BurnBarGitHubIssue] {
        guard let data = json.data(using: .utf8),
              let dtos = try? makeDecoder().decode([IssueDTO].self, from: data) else { return [] }
        return dtos.map {
            BurnBarGitHubIssue(
                number: $0.number,
                title: $0.title,
                state: $0.state,
                url: $0.url ?? "",
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                labels: ($0.labels ?? []).compactMap(\.name)
            )
        }
    }

    static func decodeWorkflowRuns(_ json: String) -> [BurnBarGitHubWorkflowRun] {
        guard let data = json.data(using: .utf8),
              let envelope = try? makeDecoder().decode(WorkflowRunsEnvelope.self, from: data),
              let dtos = envelope.workflowRuns else { return [] }
        return dtos.map {
            BurnBarGitHubWorkflowRun(
                id: $0.id,
                name: $0.displayTitle ?? $0.name ?? "workflow run",
                // `path` (".github/workflows/ci.yml") is the stable workflow
                // identity; `name` is display text an author can change.
                workflowName: $0.name ?? $0.path,
                headSHA: $0.headSha ?? "",
                headBranch: $0.headBranch,
                status: $0.status ?? "unknown",
                conclusion: $0.conclusion,
                event: $0.event ?? "unknown",
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                runStartedAt: $0.runStartedAt,
                url: $0.htmlURL ?? ""
            )
        }
    }
}
