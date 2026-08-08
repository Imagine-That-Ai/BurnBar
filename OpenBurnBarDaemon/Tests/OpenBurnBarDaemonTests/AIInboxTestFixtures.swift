import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Shared fixture builders for the AI Inbox suites.
///
/// These live outside `XCTestCase` on purpose: SwiftLint's
/// `test_case_accessibility` rule requires non-test members of a test case to be
/// private, and these are genuinely shared across four suites. A plain enum is
/// the honest home for them.
enum AIInboxFixtures {
    // MARK: - Workflow runs

    /// Builds `total` completed runs of one workflow, the first `wasted` of
    /// which failed or were cancelled.
    static func runs(
        workflow: String,
        total: Int,
        wasted: Int,
        minutesEach: Double,
        now: Date,
        idOffset: Int = 0
    ) -> [BurnBarGitHubWorkflowRun] {
        (0..<total).map { index in
            run(
                id: idOffset + index,
                workflow: workflow,
                sha: "sha\(idOffset + index)",
                // Alternate the failure mode so the summary's breakdown is
                // exercised rather than always reading "N failure".
                conclusion: index < wasted ? (index % 3 == 0 ? "cancelled" : "failure") : "success",
                minutes: minutesEach,
                now: now
            )
        }
    }

    static func run(
        id: Int,
        workflow: String,
        sha: String,
        conclusion: String,
        minutes: Double,
        now: Date
    ) -> BurnBarGitHubWorkflowRun {
        let started = now.addingTimeInterval(-Double(id + 1) * 3_600)
        return BurnBarGitHubWorkflowRun(
            id: id,
            name: "Run \(id)",
            workflowName: workflow,
            headSHA: sha,
            headBranch: "main",
            status: "completed",
            conclusion: conclusion,
            event: "push",
            createdAt: started,
            updatedAt: started.addingTimeInterval(minutes * 60),
            runStartedAt: started,
            url: "https://github.com/Ajnunezg/BurnBar/actions/runs/\(id)"
        )
    }

    // MARK: - GitHub

    static func repository(
        slug: String,
        runs: [BurnBarGitHubWorkflowRun],
        openPullRequests: [BurnBarGitHubPullRequest] = [],
        mergedPullRequests: [BurnBarGitHubPullRequest] = []
    ) -> BurnBarGitHubRepositorySnapshot {
        BurnBarGitHubRepositorySnapshot(
            slug: slug,
            openPullRequests: openPullRequests,
            recentlyMergedPullRequests: mergedPullRequests,
            openIssues: [],
            recentRuns: runs,
            fetchedAt: Date()
        )
    }

    static func pullRequest(
        number: Int,
        state: String,
        updatedAt: Date,
        mergedAt: Date? = nil
    ) -> BurnBarGitHubPullRequest {
        BurnBarGitHubPullRequest(
            number: number,
            title: "Fix the routing wiring",
            state: state,
            isDraft: false,
            headRefName: "fix/routing",
            author: "alberto",
            url: "https://github.com/Ajnunezg/BurnBar/pull/\(number)",
            createdAt: updatedAt.addingTimeInterval(-86_400),
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            closedAt: nil,
            additions: 40,
            deletions: 3,
            reviewDecision: "APPROVED"
        )
    }

    // MARK: - Workspace

    static func workspace(dirty: Int, path: String = "/tmp/burnbar") -> BurnBarAIInboxWorkspaceSnapshot {
        BurnBarAIInboxWorkspaceSnapshot(
            path: path,
            isGitRepository: true,
            branch: "main",
            headSHA: "abc123",
            headSubject: "feat: something",
            headCommittedAt: Date(),
            dirtyFiles: (0..<dirty).map { "file\($0).swift" },
            untrackedCount: 0,
            aheadCount: 0,
            behindCount: 0,
            githubSlug: "Ajnunezg/BurnBar",
            recentCommitSubjects: ["feat: something"]
        )
    }

    // MARK: - Conversations

    static func conversation(
        id: String = "conv-1",
        messageCount: Int = 12,
        body: String = "Refactored the auth middleware. I have committed and pushed the fix.",
        workspacePath: String? = "/tmp/burnbar",
        endedAt: Date? = nil
    ) -> BurnBarAIInboxConversationExcerpt {
        BurnBarAIInboxConversationExcerpt(
            evidenceID: "conv:\(id):\(messageCount)",
            conversationID: id,
            provider: "Claude Code",
            projectName: "BurnBar",
            workspacePath: workspacePath,
            title: "Auth middleware refactor",
            endedAt: endedAt ?? Date().addingTimeInterval(-600),
            messageCount: messageCount,
            body: body,
            keyFiles: ["auth/middleware.ts"],
            keyCommands: ["npm test"],
            wasTruncated: false
        )
    }

    // MARK: - Packs

    static func pack(
        repositories: [BurnBarGitHubRepositorySnapshot] = [],
        conversations: [BurnBarAIInboxConversationExcerpt] = [],
        workspaces: [BurnBarAIInboxWorkspaceSnapshot] = [],
        usage: [BurnBarAIInboxUsageAggregate] = [],
        githubAvailability: BurnBarGitHubAvailability = .available,
        /// Defaults to a fresh index. Tests that exercise stale-index behaviour
        /// pass an explicit lag.
        indexLagSeconds: TimeInterval? = 0,
        now: Date
    ) -> BurnBarAIInboxEvidencePack {
        BurnBarAIInboxEvidencePack(
            tickID: "tick_test",
            generatedAt: now,
            windowStart: now.addingTimeInterval(-7_200),
            conversations: conversations,
            workspaces: workspaces,
            repositories: repositories,
            usage: usage,
            openItems: [],
            githubAvailability: githubAvailability,
            droppedConversationCount: 0,
            estimatedPromptTokens: 0,
            indexLagSeconds: indexLagSeconds
        )
    }

    static func emptyPack(now: Date) -> BurnBarAIInboxEvidencePack {
        pack(now: now)
    }

    /// A pack containing exactly one conversation, with a caller-supplied body so
    /// injection tests can plant hostile text.
    static func packWithConversation(
        body: String = "Refactored the auth middleware. I have committed and pushed the fix."
    ) -> BurnBarAIInboxEvidencePack {
        pack(conversations: [conversation(body: body)], now: Date())
    }

    // MARK: - Model calls

    static func modelCall(
        role: String,
        provider: String,
        model: String,
        cost: Double
    ) -> BurnBarAIInboxModelCall {
        BurnBarAIInboxModelCall(
            providerID: provider,
            modelID: model,
            role: role,
            inputTokens: 12_000,
            outputTokens: 800,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: cost
        )
    }

    // MARK: - Store writes

    static func itemWrite(
        fingerprint: String,
        title: String,
        kind: BurnBarInboxItemKind = .ciWaste,
        priority: BurnBarInboxPriority = .p2,
        payload: BurnBarInboxItemPayload = BurnBarInboxItemPayload()
    ) -> BurnBarAIInboxItemWrite {
        BurnBarAIInboxItemWrite(
            fingerprint: fingerprint,
            kind: kind,
            priority: priority,
            title: title,
            summaryMarkdown: "summary for \(title)",
            payload: payload,
            projectName: "TestProject",
            tickID: "tick_test"
        )
    }
}

/// Counts subprocess invocations so cost invariants ("this path must not shell
/// out") are directly assertable rather than assumed.
struct CountingProcessRunner: BurnBarAIInboxProcessRunning {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    let callCount = Counter()

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval,
        environmentOverrides: [String: String]
    ) async throws -> BurnBarAIInboxProcessResult {
        callCount.increment()
        return BurnBarAIInboxProcessResult(exitCode: 1, standardOutput: "", standardError: "counted")
    }
}
