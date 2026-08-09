import Foundation
import OpenBurnBarEngine

struct BurnBarAIInboxVerificationResult: Sendable {
    /// Findings that survived. Refuted ones are absent by construction.
    let findings: [BurnBarAIInboxFinding]
    let calls: [BurnBarAIInboxModelCall]
    /// Fingerprints of refuted findings — recorded so the same wrong claim does
    /// not get re-proposed and re-verified on every subsequent tick.
    let suppressedFingerprints: [String]
}

/// The adversarial second opinion.
///
/// Why a second model at all: the analyst is a cheap, fast model reading
/// partially-truncated logs, and its most likely failure is a *fluent* wrong
/// conclusion — exactly the failure a confident inbox would amplify. So every
/// model-authored claim faces a verifier that is instructed to refute it, run on
/// a **different provider** so correlated model-family blind spots do not cancel
/// out.
///
/// Order matters: deterministic re-checks run FIRST and can settle a claim for
/// free. The model is only consulted for claims that arithmetic cannot resolve.
struct BurnBarAIInboxVerifier: Sendable {
    private let executor: any BurnBarProviderExecuting
    private let router: BurnBarProviderRouter
    private let workspaceScout: BurnBarAIInboxWorkspaceScout
    private let logger: BurnBarDaemonLogger

    init(
        executor: any BurnBarProviderExecuting,
        router: BurnBarProviderRouter,
        workspaceScout: BurnBarAIInboxWorkspaceScout,
        logger: BurnBarDaemonLogger
    ) {
        self.executor = executor
        self.router = router
        self.workspaceScout = workspaceScout
        self.logger = logger
    }

    func verify(
        findings: [BurnBarAIInboxFinding],
        pack: BurnBarAIInboxEvidencePack,
        config: BurnBarInboxConfig,
        now: Date
    ) async -> BurnBarAIInboxVerificationResult {
        var survivors: [BurnBarAIInboxFinding] = []
        var calls: [BurnBarAIInboxModelCall] = []
        var suppressed: [String] = []
        var modelCallsUsed = 0

        // Route once, outside the loop. A missing OpenAI credential is a normal
        // state (cloud egress may be on with only one provider configured), and
        // it must degrade to "published unverified" rather than losing findings.
        var route: BurnBarProviderRoute?
        do {
            let resolved = try await router.route(
                modelName: config.verifierModel,
                preferredProviderID: config.verifierProviderID
            )
            // Same egress promise as the analyst. A refusal here is not fatal:
            // findings publish marked unverified rather than being sent anyway.
            let decision = BurnBarAIInboxEgressGuard.evaluate(
                baseURL: resolved.baseURL,
                mode: config.egressMode
            )
            if case .refused(let reason) = decision {
                logger.warning("ai_inbox_verifier_egress_refused", metadata: ["reason": reason])
                route = nil
            } else {
                route = resolved
            }
        } catch {
            logger.debug("ai_inbox_verifier_route_unavailable", metadata: ["error": "\(error)"])
            route = nil
        }

        for finding in findings {
            // Detector findings that already carry a deterministic verdict pass
            // straight through — re-litigating arithmetic with a model would be
            // both wasteful and less reliable.
            guard finding.needsVerification else {
                survivors.append(finding)
                continue
            }

            let checks = await deterministicChecks(for: finding, pack: pack)
            if let settled = Self.settleDeterministically(finding: finding, checks: checks, now: now) {
                if settled.verdict == .refuted {
                    suppressed.append(finding.fingerprint)
                    logger.debug(
                        "ai_inbox_finding_refuted_deterministically",
                        metadata: ["kind": finding.kind.rawValue]
                    )
                } else {
                    survivors.append(Self.applying(settled, to: finding))
                }
                continue
            }

            guard let route, modelCallsUsed < config.maxVerifierCallsPerTick else {
                survivors.append(
                    Self.applying(
                        BurnBarInboxVerification(
                            verdict: .unverified,
                            reason: route == nil
                                ? "No verifier model is configured, so this was published unverified."
                                : "The per-tick verification budget was reached.",
                            checkedAt: now
                        ),
                        to: finding
                    )
                )
                continue
            }

            modelCallsUsed += 1
            do {
                let request = BurnBarStructuredPromptRequest(
                    systemPrompt: BurnBarAIInboxPromptBuilder.verifierSystemPrompt,
                    userPrompt: BurnBarAIInboxPromptBuilder.verifierUserPrompt(
                        finding: finding,
                        pack: pack,
                        deterministicChecks: checks.map(\.description)
                    ),
                    jsonOnly: true
                )
                let result = try await executor.completeStructured(request, route: route)
                calls.append(
                    BurnBarAIInboxAnalyst.makeCall(role: "verifier", route: route, result: result)
                )

                let verdict = Self.decodeVerdict(
                    result.outputText,
                    verifierModel: "\(route.providerID):\(route.resolvedModelID)",
                    now: now
                )
                switch verdict.verification.verdict {
                case .refuted:
                    suppressed.append(finding.fingerprint)
                case .confirmed, .unclear, .unverified, .deterministic:
                    var updated = Self.applying(verdict.verification, to: finding)
                    if let revised = verdict.revisedSummary, revised.isEmpty == false {
                        updated = Self.replacingSummary(updated, with: BurnBarAIInboxRedactor.redact(revised))
                    }
                    // An "unclear" verdict is not a pass: demote it so an
                    // unresolved claim cannot interrupt the user.
                    if verdict.verification.verdict == .unclear {
                        updated = Self.demoted(updated)
                    }
                    survivors.append(updated)
                }
            } catch {
                logger.debug("ai_inbox_verifier_call_failed", metadata: ["error": "\(error)"])
                survivors.append(
                    Self.applying(
                        BurnBarInboxVerification(
                            verdict: .unverified,
                            reason: "The verification pass could not complete.",
                            checkedAt: now
                        ),
                        to: finding
                    )
                )
            }
        }

        return BurnBarAIInboxVerificationResult(
            findings: survivors,
            calls: calls,
            suppressedFingerprints: suppressed
        )
    }

    // MARK: - Deterministic checks

    /// A machine-checked fact about the claim, gathered fresh at verification
    /// time rather than trusted from the pack.
    struct DeterministicCheck: Sendable, Hashable {
        enum Outcome: String, Sendable { case supports, contradicts, neutral }
        let description: String
        let outcome: Outcome
    }

    func deterministicChecks(
        for finding: BurnBarAIInboxFinding,
        pack: BurnBarAIInboxEvidencePack
    ) async -> [DeterministicCheck] {
        var checks: [DeterministicCheck] = []

        switch finding.kind {
        case .promisedNotLanded:
            // Re-read git RIGHT NOW. The pack may be seconds-to-minutes old, and
            // the user may have committed in the meantime — in which case the
            // claim is already false and no model call is needed.
            for workspace in pack.workspaces where finding.evidenceIDs.contains("workspace:\(workspace.path)") {
                guard let fresh = await workspaceScout.snapshot(for: workspace.path) else { continue }
                if fresh.headSHA != workspace.headSHA {
                    checks.append(
                        DeterministicCheck(
                            description: "A new commit landed in \(BurnBarAIInboxDetectors.displayPath(workspace.path)) since this was flagged (HEAD moved to \(fresh.headSHA?.prefix(8) ?? "?")).",
                            outcome: .contradicts
                        )
                    )
                }
                if fresh.isDirty == false && workspace.isDirty {
                    checks.append(
                        DeterministicCheck(
                            description: "The worktree is now clean; the changes were committed or discarded.",
                            outcome: .contradicts
                        )
                    )
                } else if fresh.isDirty {
                    checks.append(
                        DeterministicCheck(
                            description: "The worktree still has \(fresh.dirtyFiles.count) modified and \(fresh.untrackedCount) untracked file(s).",
                            outcome: .supports
                        )
                    )
                }
            }

        case .stuckPR:
            for repository in pack.repositories {
                for pullRequest in repository.recentlyMergedPullRequests
                where finding.evidenceIDs.contains("pr:\(repository.slug)#\(pullRequest.number)") {
                    checks.append(
                        DeterministicCheck(
                            description: "PR #\(pullRequest.number) is merged, so it is not stuck.",
                            outcome: .contradicts
                        )
                    )
                }
            }

        case .ciWaste, .uncommittedWork, .unpushedCommits, .pushedNotMerged,
             .costAnomaly, .indexHealth, .brief, .budget, .system:
            break
        }

        return checks
    }

    /// Resolves a claim without a model when the evidence is unambiguous.
    static func settleDeterministically(
        finding: BurnBarAIInboxFinding,
        checks: [DeterministicCheck],
        now: Date
    ) -> BurnBarInboxVerification? {
        guard checks.isEmpty == false else { return nil }
        if checks.contains(where: { $0.outcome == .contradicts }) {
            return BurnBarInboxVerification(
                verdict: .refuted,
                reason: checks.first { $0.outcome == .contradicts }?.description,
                checkedAt: now
            )
        }
        return nil
    }

    // MARK: - Decoding

    struct VerdictPayload: Decodable {
        let verdict: String?
        let reason: String?
        let revisedSummaryMD: String?

        enum CodingKeys: String, CodingKey {
            case verdict, reason
            case revisedSummaryMD = "revised_summary_md"
        }
    }

    struct DecodedVerdict {
        let verification: BurnBarInboxVerification
        let revisedSummary: String?
    }

    /// Unparseable output is treated as `unclear`, never as a pass. A verifier
    /// that fails to answer must not silently approve.
    static func decodeVerdict(_ text: String, verifierModel: String, now: Date) -> DecodedVerdict {
        let json = BurnBarAIInboxAnalyst.extractJSONObject(from: text)
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(VerdictPayload.self, from: data) else {
            return DecodedVerdict(
                verification: BurnBarInboxVerification(
                    verdict: .unclear,
                    reason: "The verifier's response could not be parsed.",
                    checkedAt: now,
                    verifierModel: verifierModel
                ),
                revisedSummary: nil
            )
        }

        let verdict: BurnBarInboxVerification.Verdict = {
            switch payload.verdict?.lowercased() {
            case "confirm", "confirmed": return .confirmed
            case "refute", "refuted": return .refuted
            default: return .unclear
            }
        }()

        return DecodedVerdict(
            verification: BurnBarInboxVerification(
                verdict: verdict,
                reason: payload.reason.map { String($0.prefix(300)) },
                checkedAt: now,
                verifierModel: verifierModel
            ),
            revisedSummary: payload.revisedSummaryMD
        )
    }

    // MARK: - Finding mutation
    //
    // `BurnBarAIInboxFinding` is immutable by design (it crosses stages), so
    // these rebuild rather than mutate.

    static func applying(
        _ verification: BurnBarInboxVerification,
        to finding: BurnBarAIInboxFinding
    ) -> BurnBarAIInboxFinding {
        BurnBarAIInboxFinding(
            kind: finding.kind,
            title: finding.title,
            summaryMarkdown: finding.summaryMarkdown,
            priority: finding.priority,
            confidence: finding.confidence,
            evidenceIDs: finding.evidenceIDs,
            projectID: finding.projectID,
            projectName: finding.projectName,
            fingerprint: finding.fingerprint,
            metrics: finding.metrics,
            actions: finding.actions,
            memoryCandidates: finding.memoryCandidates,
            needsVerification: finding.needsVerification,
            deterministicVerification: verification,
            source: finding.source
        )
    }

    static func replacingSummary(
        _ finding: BurnBarAIInboxFinding,
        with summary: String
    ) -> BurnBarAIInboxFinding {
        BurnBarAIInboxFinding(
            kind: finding.kind,
            title: finding.title,
            summaryMarkdown: summary,
            priority: finding.priority,
            confidence: finding.confidence,
            evidenceIDs: finding.evidenceIDs,
            projectID: finding.projectID,
            projectName: finding.projectName,
            fingerprint: finding.fingerprint,
            metrics: finding.metrics,
            actions: finding.actions,
            memoryCandidates: finding.memoryCandidates,
            needsVerification: finding.needsVerification,
            deterministicVerification: finding.deterministicVerification,
            source: finding.source
        )
    }

    /// Drops an unresolved claim one priority band, floored at P4, so it is still
    /// available to browse but can never raise a notification.
    static func demoted(_ finding: BurnBarAIInboxFinding) -> BurnBarAIInboxFinding {
        BurnBarAIInboxFinding(
            kind: finding.kind,
            title: finding.title,
            summaryMarkdown: finding.summaryMarkdown,
            priority: BurnBarInboxPriority(clamping: finding.priority.rawValue + 1),
            confidence: finding.confidence * 0.7,
            evidenceIDs: finding.evidenceIDs,
            projectID: finding.projectID,
            projectName: finding.projectName,
            fingerprint: finding.fingerprint,
            metrics: finding.metrics,
            actions: finding.actions,
            memoryCandidates: finding.memoryCandidates,
            needsVerification: finding.needsVerification,
            deterministicVerification: finding.deterministicVerification,
            source: finding.source
        )
    }
}
