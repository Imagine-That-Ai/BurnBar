import Foundation
import OpenBurnBarEngine

/// One conversation, redacted and byte-capped, ready to be quoted into a prompt.
struct BurnBarAIInboxConversationExcerpt: Sendable, Hashable {
    let evidenceID: String
    let conversationID: String
    let provider: String
    let projectName: String?
    let workspacePath: String?
    let title: String
    let endedAt: Date?
    let messageCount: Int
    /// Redacted, truncated body. Never the raw transcript.
    let body: String
    let keyFiles: [String]
    let keyCommands: [String]
    let wasTruncated: Bool
}

/// Everything one tick knows, assembled deterministically.
///
/// Two rules govern this type:
///   1. **Redaction happens on the way in, not on the way out.** By the time text
///      is in a pack it has already been through `MemorySecretPIIGate` and the
///      regex scrubber, so no downstream path can leak by forgetting to redact.
///   2. **Every section is byte-budgeted.** A pack is bounded regardless of how
///      much the user worked, so prompt cost has a hard ceiling.
struct BurnBarAIInboxEvidencePack: Sendable {
    let tickID: String
    let generatedAt: Date
    let windowStart: Date
    let conversations: [BurnBarAIInboxConversationExcerpt]
    let workspaces: [BurnBarAIInboxWorkspaceSnapshot]
    let repositories: [BurnBarGitHubRepositorySnapshot]
    let usage: [BurnBarAIInboxUsageAggregate]
    let openItems: [BurnBarInboxItemSummary]
    let githubAvailability: BurnBarGitHubAvailability
    /// Bytes dropped by budgeting; surfaced so a truncated analysis is honest.
    let droppedConversationCount: Int
    let estimatedPromptTokens: Int
    /// How far behind reality the index is, measured as the gap between the
    /// newest agent-log write on disk and the newest indexed conversation.
    ///
    /// The app's parser refresh runs on its own ~10-minute cadence, so a brief
    /// can legitimately describe a world that is a few minutes old. Rather than
    /// hide that, the pack measures it and the brief says so.
    let indexLagSeconds: TimeInterval?

    /// Lag worth mentioning to the user. Below this, the difference is not
    /// something a person would notice or act on.
    static let notableIndexLag: TimeInterval = 6 * 60

    var hasNotableIndexLag: Bool {
        (indexLagSeconds ?? 0) >= Self.notableIndexLag
    }

    var isEmpty: Bool {
        conversations.isEmpty && workspaces.isEmpty && repositories.isEmpty && usage.isEmpty
    }

    /// Valid citation ids. The analyst may only reference these; anything else is
    /// a fabrication and its finding is dropped.
    var validEvidenceIDs: Set<String> {
        var ids = Set(conversations.map(\.evidenceID))
        for repository in repositories {
            for pullRequest in repository.openPullRequests + repository.recentlyMergedPullRequests {
                ids.insert("pr:\(repository.slug)#\(pullRequest.number)")
            }
            for issue in repository.openIssues {
                ids.insert("issue:\(repository.slug)#\(issue.number)")
            }
            for run in repository.recentRuns {
                ids.insert("run:\(repository.slug)#\(run.id)")
            }
        }
        for workspace in workspaces {
            ids.insert("workspace:\(workspace.path)")
        }
        for aggregate in usage {
            ids.insert("usage:\(aggregate.projectName):\(aggregate.model)")
        }
        return ids
    }
}

/// Assembles evidence packs.
struct BurnBarAIInboxEvidencePackBuilder: Sendable {
    private let store: BurnBarAIInboxStore
    private let workspaceScout: BurnBarAIInboxWorkspaceScout
    private let github: BurnBarGitHubCLIClient
    private let logger: BurnBarDaemonLogger

    /// Per-conversation body cap. Mirrors `BurnBarResumeService`'s
    /// `activityHistoryMaxBodyBytes` so the two features agree on what "a
    /// reasonable slice of a session" means.
    static let maxConversationBodyBytes = 8 * 1024
    static let maxConversations = 25
    static let maxUsageAggregates = 25
    /// Workflow-run lookback for the CI detectors. Wider than the conversation
    /// window because CI waste is a *pattern*, and a pattern needs history.
    static let workflowRunLookback: TimeInterval = 3 * 24 * 60 * 60

    init(
        store: BurnBarAIInboxStore,
        workspaceScout: BurnBarAIInboxWorkspaceScout,
        github: BurnBarGitHubCLIClient,
        logger: BurnBarDaemonLogger
    ) {
        self.store = store
        self.workspaceScout = workspaceScout
        self.github = github
        self.logger = logger
    }

    func build(
        tickID: String,
        config: BurnBarInboxConfig,
        includeRemote: Bool,
        now: Date
    ) async -> BurnBarAIInboxEvidencePack {
        let windowStart = now.addingTimeInterval(-Double(config.lookbackMinutes) * 60)

        let rows = (try? store.recentConversations(since: windowStart, limit: Self.maxConversations)) ?? []
        let excerpts = rows.map { makeExcerpt(from: $0) }

        // Workspaces come from the conversations themselves — the inbox only
        // looks at repositories the user is actually working in.
        let workspacePaths = rows.compactMap(\.workingDirectory)
        let snapshots = await workspaceScout.snapshots(for: workspacePaths)

        var repositories: [BurnBarGitHubRepositorySnapshot] = []
        var availability = BurnBarGitHubAvailability.available
        if config.githubEnabled, includeRemote {
            availability = await github.availability()
            if availability.isAvailable {
                let slugs = Array(Set(snapshots.compactMap(\.githubSlug))).sorted()
                for slug in slugs.prefix(4) {
                    if let snapshot = await github.snapshot(slug: slug, runLookback: Self.workflowRunLookback) {
                        repositories.append(snapshot)
                    }
                }
            }
        } else if config.githubEnabled == false {
            availability = .failed("GitHub checks are turned off in settings.")
        }

        let usage = (try? store.usageAggregates(since: windowStart)) ?? []
        let openItems = (try? store.openItems()) ?? []

        let pack = BurnBarAIInboxEvidencePack(
            tickID: tickID,
            generatedAt: now,
            windowStart: windowStart,
            conversations: excerpts,
            workspaces: snapshots,
            repositories: repositories,
            usage: Array(usage.prefix(Self.maxUsageAggregates)),
            openItems: openItems,
            githubAvailability: availability,
            droppedConversationCount: max(0, rows.count - excerpts.count),
            estimatedPromptTokens: 0,
            indexLagSeconds: Self.indexLag(rows: rows, now: now)
        )
        return Self.budgeted(pack, tokenCap: config.perTickPromptTokenCap)
    }

    private func makeExcerpt(from row: BurnBarAIInboxConversationRow) -> BurnBarAIInboxConversationExcerpt {
        // Read a little more than the cap so truncation is detectable, then
        // redact, then cut to the cap. Redacting first matters: a secret that
        // straddles the cut must still be caught.
        let raw = (try? store.conversationBody(
            id: row.id,
            maxBytes: Self.maxConversationBodyBytes * 2
        )) ?? nil
        let redacted = BurnBarAIInboxRedactor.redact(raw ?? row.summary ?? row.lastAssistantMessage ?? "")
        let clipped = BurnBarAIInboxRedactor.clip(redacted, maxBytes: Self.maxConversationBodyBytes)

        return BurnBarAIInboxConversationExcerpt(
            evidenceID: row.evidenceID,
            conversationID: row.id,
            provider: row.provider,
            projectName: row.projectName,
            workspacePath: row.workingDirectory,
            title: BurnBarAIInboxRedactor.redact(row.displayTitle),
            endedAt: row.endTime ?? row.startTime,
            messageCount: row.messageCount,
            body: clipped.text,
            // Redacted like keyCommands: a path can embed a token
            // (`/tmp/build-ghp_.../out`) and is interpolated into the prompt.
            keyFiles: row.keyFiles.prefix(12).map(BurnBarAIInboxRedactor.redact),
            keyCommands: row.keyCommands.prefix(12).map(BurnBarAIInboxRedactor.redact),
            wasTruncated: clipped.wasTruncated || (row.fullTextByteCount > Self.maxConversationBodyBytes * 2)
        )
    }

    /// Drops the oldest conversations until the estimated prompt fits the cap.
    ///
    /// Estimation is the standard ~4 bytes/token heuristic — the same one
    /// `daemon.usage.insights` uses for its context budget report. It only needs
    /// to be right enough to bound cost, and it errs high.
    /// Gap between the newest agent-log write on disk and the newest indexed
    /// conversation.
    ///
    /// Returns nil when there is nothing to compare — no logs, or an index that
    /// is ahead of the files (which happens when a session ends mid-tick).
    static func indexLag(rows: [BurnBarAIInboxConversationRow], now: Date) -> TimeInterval? {
        guard let newestLogWrite = newestAgentLogWrite() else { return nil }
        let newestIndexed = rows.compactMap { $0.endTime ?? $0.startTime }.max()
        guard let newestIndexed else {
            // Logs exist but nothing is indexed in the window: the lag is at
            // least how old the newest write is.
            return max(0, now.timeIntervalSince(newestLogWrite))
        }
        return max(0, newestLogWrite.timeIntervalSince(newestIndexed))
    }

    /// Newest modification time across the watched agent-log roots. Bounded the
    /// same way the change gate bounds its sweep.
    static func newestAgentLogWrite() -> Date? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let manager = FileManager.default
        var newest: Date?
        var inspected = 0

        for root in BurnBarAIInboxChangeGate.watchedLogRoots {
            let rootURL = home.appendingPathComponent(root, isDirectory: true)
            guard manager.fileExists(atPath: rootURL.path) else { continue }
            guard let enumerator = manager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                inspected += 1
                if inspected > 4_000 { break }
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                ), values.isRegularFile == true, let modified = values.contentModificationDate else {
                    continue
                }
                if newest == nil || modified > newest! { newest = modified }
            }
        }
        return newest
    }

    static func budgeted(_ pack: BurnBarAIInboxEvidencePack, tokenCap: Int) -> BurnBarAIInboxEvidencePack {
        var conversations = pack.conversations
        var dropped = pack.droppedConversationCount

        func estimate(_ items: [BurnBarAIInboxConversationExcerpt]) -> Int {
            let conversationBytes = items.reduce(0) { $0 + $1.body.utf8.count + $1.title.utf8.count + 128 }
            let structuralBytes = (pack.workspaces.count * 512)
                + pack.repositories.reduce(0) { partial, repository in
                    partial + (repository.openPullRequests.count * 160)
                        + (repository.recentlyMergedPullRequests.count * 160)
                        + (repository.openIssues.count * 120)
                        + (repository.recentRuns.count * 110)
                }
                + (pack.usage.count * 96)
                + (pack.openItems.count * 140)
            return (conversationBytes + structuralBytes) / 4
        }

        // Newest-first: recency is what the brief is about, so the tail goes first.
        conversations.sort { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        while conversations.count > 1, estimate(conversations) > tokenCap {
            conversations.removeLast()
            dropped += 1
        }

        return BurnBarAIInboxEvidencePack(
            tickID: pack.tickID,
            generatedAt: pack.generatedAt,
            windowStart: pack.windowStart,
            conversations: conversations,
            workspaces: pack.workspaces,
            repositories: pack.repositories,
            usage: pack.usage,
            openItems: pack.openItems,
            githubAvailability: pack.githubAvailability,
            droppedConversationCount: dropped,
            estimatedPromptTokens: estimate(conversations),
            indexLagSeconds: pack.indexLagSeconds
        )
    }
}

/// Redaction applied to every piece of text before it can enter a prompt, an
/// inbox item, or a memory candidate.
///
/// Two layers, deliberately:
///   • `MemorySecretPIIGate` — the repo-wide, fail-closed secret/PII corpus that
///     already gates memory writes. Reused here so the inbox cannot become a
///     side channel around a control the rest of the app enforces.
///   • Regex scrubbing — replaces the matched secret material in place, since the
///     gate detects but does not rewrite.
enum BurnBarAIInboxRedactor {
    /// Ordered (pattern, replacement) pairs. The first three mirror
    /// `BurnBarResumeService.redact`; the rest close formats that show up in
    /// agent transcripts specifically.
    private static let patterns: [(pattern: String, replacement: String)] = [
        // The value class is quote-AWARE, not quote-excluding. The original
        // `[^\s`'"<>]{8,}` matched only bare values, so every quoted form —
        // JSON (`"password": "hunter2hunter2"`), YAML, dotenv, Swift literals —
        // sailed through untouched. Optional surrounding quotes are consumed and
        // the floor is 6 characters, since a short secret is still a secret.
        // Key may be bare OR quoted (`"password":`), and the value may be bare
        // or quoted. `\b` before the key fails against a preceding `"`, which is
        // exactly how JSON writes it — so the boundary is an explicit
        // "start, or a non-key character" class instead.
        (#"(?i)(?:^|[^A-Za-z0-9_-])["'`]?((?:api|access|secret|session|refresh|auth)[_-]?token|api[_-]?key|password|passwd|secret)["'`]?\s*[:=]\s*["'`]?([^\s`'"<>,;}\])]{6,})["'`]?"#, " $1=[REDACTED]"),
        (#"\b(sk-[A-Za-z0-9_-]{20,})\b"#, "[REDACTED_KEY]"),
        (#"\b(gh[pousr]_[A-Za-z0-9_]{20,})\b"#, "[REDACTED_GITHUB_TOKEN]"),
        (#"\b(github_pat_[A-Za-z0-9_]{20,})\b"#, "[REDACTED_GITHUB_TOKEN]"),
        (#"\b(xox[baprs]-[A-Za-z0-9-]{10,})\b"#, "[REDACTED_SLACK_TOKEN]"),
        (#"\b(AKIA[0-9A-Z]{16})\b"#, "[REDACTED_AWS_KEY]"),
        (#"\bAIza[0-9A-Za-z_-]{35}\b"#, "[REDACTED_GOOGLE_KEY]"),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]"),
        (#"\bBearer\s+[A-Za-z0-9._~+/=-]{20,}"#, "Bearer [REDACTED]"),
        // Credentials embedded in URLs (`https://user:token@host`).
        (#"(?i)\b(https?://)([^/\s:@]+):([^/\s@]+)@"#, "$1$2:[REDACTED]@")
    ]

    static func redact(_ text: String) -> String {
        guard text.isEmpty == false else { return text }
        var output = text
        for entry in patterns {
            output = output.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression]
            )
        }
        // Fail-closed backstop: if the shared corpus still finds something the
        // regexes did not rewrite, refuse to emit the text at all. Losing an
        // excerpt is strictly better than leaking a credential.
        let labels = MemorySecretPIIGate.labels(in: output)
        if labels.isEmpty == false {
            return "[REDACTED — this excerpt was withheld because a secret/PII scan flagged it: \(labels.prefix(3).joined(separator: ", "))]"
        }
        return output
    }

    /// True when the text still trips the shared gate. Used to drop memory
    /// candidates before they are ever proposed to the user.
    static func containsSensitiveMaterial(_ text: String) -> Bool {
        MemorySecretPIIGate.labels(in: text).isEmpty == false
    }

    struct ClipResult: Sendable, Hashable {
        let text: String
        let wasTruncated: Bool
    }

    /// UTF-8-safe truncation with a head/tail split.
    ///
    /// Head and tail rather than a prefix, because a session's beginning states
    /// the goal and its end states the outcome — the middle is the least
    /// informative part for "what happened and did it land?".
    static func clip(_ text: String, maxBytes: Int) -> ClipResult {
        guard text.utf8.count > maxBytes else { return ClipResult(text: text, wasTruncated: false) }
        let headBytes = (maxBytes * 2) / 3
        let tailBytes = maxBytes - headBytes
        let head = String(decoding: Array(text.utf8.prefix(headBytes)), as: UTF8.self)
        let tail = String(decoding: Array(text.utf8.suffix(tailBytes)), as: UTF8.self)
        return ClipResult(
            text: head + "\n…[\(text.utf8.count - maxBytes) bytes omitted]…\n" + tail,
            wasTruncated: true
        )
    }
}
