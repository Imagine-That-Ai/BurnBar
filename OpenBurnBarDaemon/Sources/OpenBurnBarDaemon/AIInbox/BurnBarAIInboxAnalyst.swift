import Foundation
import OpenBurnBarEngine

/// One model call's usage, so the publisher can record spend per sub-call.
struct BurnBarAIInboxModelCall: Sendable, Hashable {
    let providerID: String
    let modelID: String
    let role: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let costUSD: Double

    var provenance: String { "\(providerID):\(modelID)" }
}

struct BurnBarAIInboxAnalystResult: Sendable {
    let briefMarkdown: String
    let findings: [BurnBarAIInboxFinding]
    let calls: [BurnBarAIInboxModelCall]
    /// Populated when the model cited evidence that does not exist — surfaced in
    /// telemetry because a spike is a signal the prompt or model regressed.
    let rejectedFindingCount: Int
    let rejectedMemoryCandidateCount: Int
    /// Surviving action hints, carried out so the publisher can apply them to
    /// the brief item the same way the analyst applies them to its findings.
    let actionHints: [BurnBarAIInboxActionHint]

    init(
        briefMarkdown: String,
        findings: [BurnBarAIInboxFinding],
        calls: [BurnBarAIInboxModelCall],
        rejectedFindingCount: Int,
        rejectedMemoryCandidateCount: Int,
        actionHints: [BurnBarAIInboxActionHint] = []
    ) {
        self.briefMarkdown = briefMarkdown
        self.findings = findings
        self.calls = calls
        self.rejectedFindingCount = rejectedFindingCount
        self.rejectedMemoryCandidateCount = rejectedMemoryCandidateCount
        self.actionHints = actionHints
    }
}

/// Wraps the analyst model call: prompt → strict JSON → validated findings.
///
/// The validation here is the difference between "an LLM wrote something" and
/// "the inbox learned something". Anything that cites nothing real, restates a
/// deterministic finding, or smuggles a secret into a memory proposal is dropped
/// before it can reach the user.
struct BurnBarAIInboxAnalyst: Sendable {
    private let executor: any BurnBarProviderExecuting
    private let router: BurnBarProviderRouter
    private let logger: BurnBarDaemonLogger

    /// One repair attempt on malformed JSON, then give up and fall back to
    /// detector-only output. Retrying further would spend real money chasing a
    /// model that is not cooperating.
    static let maxRepairAttempts = 1

    init(
        executor: any BurnBarProviderExecuting,
        router: BurnBarProviderRouter,
        logger: BurnBarDaemonLogger
    ) {
        self.executor = executor
        self.router = router
        self.logger = logger
    }

    func analyze(
        pack: BurnBarAIInboxEvidencePack,
        detectorFindings: [BurnBarAIInboxFinding],
        config: BurnBarInboxConfig,
        now: Date,
        standingCommitments: [BurnBarFounderLens.StandingCommitment] = []
    ) async throws -> BurnBarAIInboxAnalystResult {
        let route = try await router.route(
            modelName: config.analystModel,
            // Pinning the provider is load-bearing: the router's cost dimension
            // would otherwise happily pick a $0-priced local route for the same
            // model name and silently change both behavior and accounting.
            preferredProviderID: config.analystProviderID
        )

        // The user's egress choice is enforced HERE, after the destination is
        // known and before any byte is sent. `.local` promises the transcript
        // stays on this machine or LAN; without this check that promise is copy,
        // not code.
        let decision = BurnBarAIInboxEgressGuard.evaluate(baseURL: route.baseURL, mode: config.egressMode)
        if case .refused(let reason) = decision {
            logger.warning("ai_inbox_analyst_egress_refused", metadata: ["reason": reason])
            throw BurnBarAIInboxAnalystError.egressRefused(reason)
        }

        let userPrompt = BurnBarAIInboxPromptBuilder.analystUserPrompt(
            pack: pack,
            detectorFindings: detectorFindings,
            now: now,
            standingCommitments: standingCommitments
        )

        var calls: [BurnBarAIInboxModelCall] = []
        var payload: AnalystPayload?
        var lastError: String?

        for attempt in 0...Self.maxRepairAttempts {
            let request = BurnBarStructuredPromptRequest(
                systemPrompt: BurnBarAIInboxPromptBuilder.analystSystemPrompt(
                    founderLens: config.founderLensEnabled,
                    // The register dial is the user's, and it is selected — never
                    // interpolated — so each combination stays byte-stable and
                    // provider prompt caching keeps applying.
                    detail: config.briefDetail,
                    register: config.briefRegister
                ),
                userPrompt: attempt == 0 ? userPrompt : Self.repairPrompt(original: userPrompt, error: lastError),
                jsonOnly: true
            )
            let result = try await executor.completeStructured(request, route: route)
            calls.append(Self.makeCall(role: "analyst", route: route, result: result))

            do {
                payload = try Self.decode(result.outputText)
                break
            } catch {
                lastError = error.localizedDescription
                logger.debug(
                    "ai_inbox_analyst_parse_failed",
                    metadata: ["attempt": "\(attempt)", "error": "\(error)"]
                )
            }
        }

        guard let payload else {
            // Degrade, don't fail: the tick still publishes detector findings.
            return BurnBarAIInboxAnalystResult(
                briefMarkdown: "",
                findings: [],
                calls: calls,
                rejectedFindingCount: 0,
                rejectedMemoryCandidateCount: 0
            )
        }

        let validation = Self.validate(
            payload: payload,
            pack: pack,
            detectorFindings: detectorFindings,
            provenance: "\(route.providerID):\(route.resolvedModelID)",
            now: now
        )

        if validation.rejectedFindings > 0 || validation.rejectedMemories > 0 {
            logger.info(
                "ai_inbox_analyst_output_filtered",
                metadata: [
                    "rejected_findings": "\(validation.rejectedFindings)",
                    "rejected_memories": "\(validation.rejectedMemories)"
                ]
            )
        }

        return BurnBarAIInboxAnalystResult(
            briefMarkdown: validation.briefMarkdown,
            findings: validation.findings,
            calls: calls,
            rejectedFindingCount: validation.rejectedFindings,
            rejectedMemoryCandidateCount: validation.rejectedMemories,
            actionHints: validation.actionHints
        )
    }

    // MARK: - Payload

    struct AnalystPayload: Decodable {
        struct Finding: Decodable {
            let kind: String?
            let title: String
            let summaryMD: String?
            let priority: Int?
            let confidence: Double?
            let evidenceIDs: [String]?
            let projectName: String?
            let needsVerification: Bool?

            enum CodingKeys: String, CodingKey {
                case kind, title, priority, confidence
                case summaryMD = "summary_md"
                case evidenceIDs = "evidence_ids"
                case projectName = "project_name"
                case needsVerification = "needs_verification"
            }
        }

        struct MemoryCandidate: Decodable {
            let text: String
            let kind: String?
            let confidence: Double?
            let citationConversationIDs: [String]?

            enum CodingKeys: String, CodingKey {
                case text, kind, confidence
                case citationConversationIDs = "citation_conversation_ids"
            }
        }

        /// A model's opinion about which citation deserves the button and what
        /// the button should say. Deliberately incapable: no url, no command,
        /// no value — only an evidence id that must already exist and two short
        /// strings. See `BurnBarAIInboxActionFactory`.
        struct ActionHint: Decodable {
            let evidenceID: String?
            let verb: String?
            let why: String?

            enum CodingKeys: String, CodingKey {
                case evidenceID = "evidence_id"
                case verb, why
            }
        }

        let briefMD: String?
        let findings: [Finding]?
        let memoryCandidates: [MemoryCandidate]?
        let actionHints: [ActionHint]?

        enum CodingKeys: String, CodingKey {
            case briefMD = "brief_md"
            case findings
            case memoryCandidates = "memory_candidates"
            case actionHints = "action_hints"
        }
    }

    /// Tolerates a model that wraps JSON in a markdown fence or adds a preamble,
    /// which even strict-JSON-mode models occasionally do.
    static func decode(_ text: String) throws -> AnalystPayload {
        let cleaned = extractJSONObject(from: text)
        guard let data = cleaned.data(using: .utf8) else {
            throw BurnBarAIInboxAnalystError.invalidJSON("output was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(AnalystPayload.self, from: data)
        } catch {
            throw BurnBarAIInboxAnalystError.invalidJSON(error.localizedDescription)
        }
    }

    static func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") { return trimmed }
        // Take the outermost {...} span.
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    // MARK: - Validation

    struct ValidationResult {
        let briefMarkdown: String
        let findings: [BurnBarAIInboxFinding]
        let rejectedFindings: Int
        let rejectedMemories: Int
        let actionHints: [BurnBarAIInboxActionHint]

        init(
            briefMarkdown: String,
            findings: [BurnBarAIInboxFinding],
            rejectedFindings: Int,
            rejectedMemories: Int,
            actionHints: [BurnBarAIInboxActionHint] = []
        ) {
            self.briefMarkdown = briefMarkdown
            self.findings = findings
            self.rejectedFindings = rejectedFindings
            self.rejectedMemories = rejectedMemories
            self.actionHints = actionHints
        }
    }

    /// The gate between "model output" and "something the user sees".
    ///
    /// Rejects a finding when it cites no valid evidence (fabrication), has an
    /// empty title, or duplicates a deterministic finding. Rejects a memory
    /// candidate when it trips the secret/PII gate, is too short to be a fact, or
    /// cites a conversation that is not in the pack.
    static func validate(
        payload: AnalystPayload,
        pack: BurnBarAIInboxEvidencePack,
        detectorFindings: [BurnBarAIInboxFinding],
        provenance: String,
        now: Date
    ) -> ValidationResult {
        let validIDs = pack.validEvidenceIDs
        let validConversationIDs = Set(pack.conversations.map(\.conversationID))
        let detectorFingerprints = Set(detectorFindings.map(\.fingerprint))
        let detectorKinds = Set(detectorFindings.map(\.kind))
        // Hints are validated once, up front: the same surviving set shapes
        // every finding's buttons and, via the result, the brief's.
        let hints = Self.validatedHints(payload.actionHints ?? [], validIDs: validIDs)

        var rejectedFindings = 0
        var rejectedMemories = 0

        // Memory candidates are attached to findings below, so validate them first.
        var memoryCandidates: [BurnBarInboxMemoryCandidate] = []
        for (index, candidate) in (payload.memoryCandidates ?? []).enumerated() {
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 12, text.count <= 600 else { rejectedMemories += 1; continue }
            // A "fact" the model invented about a session that was not in the
            // pack is not grounded — drop it.
            let citations = (candidate.citationConversationIDs ?? []).filter(validConversationIDs.contains)
            guard citations.isEmpty == false else { rejectedMemories += 1; continue }
            // Never propose remembering a secret, even for human review.
            guard BurnBarAIInboxRedactor.containsSensitiveMaterial(text) == false else {
                rejectedMemories += 1
                continue
            }
            memoryCandidates.append(
                BurnBarInboxMemoryCandidate(
                    id: "mem_\(BurnBarAIInboxStableHasher.hash([text]))_\(index)",
                    text: BurnBarAIInboxRedactor.redact(text),
                    kind: candidate.kind ?? "context",
                    confidence: min(max(candidate.confidence ?? 0.5, 0), 1),
                    citationConversationIDs: citations
                )
            )
        }

        var findings: [BurnBarAIInboxFinding] = []
        for candidate in payload.findings ?? [] {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.isEmpty == false, title.count <= 200 else { rejectedFindings += 1; continue }

            // The voice contract is ENFORCED, not advisory: a model brief that
            // trips the snapshot-locked ban list never publishes. Rejected, not
            // scrubbed — a mechanical rewrite would fake the voice; rejection
            // leaves the next attempt to the analyst's own repair loop. This is
            // the production caller `violations(in:)` was always meant to have.
            let voiceViolations = BurnBarFounderLens.violations(
                in: title + "\n" + (candidate.summaryMD ?? "")
            )
            guard voiceViolations.isEmpty else {
                rejectedFindings += 1
                continue
            }

            let citedIDs = (candidate.evidenceIDs ?? []).filter(validIDs.contains)
            guard citedIDs.isEmpty == false else {
                // The single most important check: no real citation, no finding.
                rejectedFindings += 1
                continue
            }

            let kind = BurnBarInboxItemKind(rawValue: candidate.kind ?? "") ?? .brief
            // The detectors already own these kinds with exact arithmetic; a
            // model restating them adds noise and risks contradiction.
            if detectorKinds.contains(kind), kind != .brief {
                rejectedFindings += 1
                continue
            }

            let fingerprint = BurnBarAIInboxFinding.fingerprint(
                kind: kind,
                scope: candidate.projectName ?? "global",
                subject: Self.normalizedSubject(title)
            )
            guard detectorFingerprints.contains(fingerprint) == false else {
                rejectedFindings += 1
                continue
            }

            findings.append(
                BurnBarAIInboxFinding(
                    kind: kind,
                    title: BurnBarAIInboxRedactor.redact(title),
                    summaryMarkdown: BurnBarAIInboxRedactor.redact(
                        (candidate.summaryMD ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    priority: BurnBarInboxPriority(clamping: candidate.priority ?? 3),
                    confidence: min(max(candidate.confidence ?? 0.5, 0), 1),
                    evidenceIDs: citedIDs,
                    projectName: candidate.projectName,
                    fingerprint: fingerprint,
                    metrics: [:],
                    actions: Self.actions(for: citedIDs, pack: pack, hints: hints),
                    // Attach memory candidates to the first surviving finding so
                    // they arrive with context rather than floating free.
                    memoryCandidates: findings.isEmpty ? memoryCandidates : [],
                    // Model-authored claims default to needing verification.
                    needsVerification: candidate.needsVerification ?? true,
                    deterministicVerification: nil,
                    source: .analyst
                )
            )
        }

        // If every finding was rejected but memories survived, keep them by
        // attaching to the brief rather than silently discarding.
        let brief = BurnBarAIInboxRedactor.redact(
            (payload.briefMD ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )

        return ValidationResult(
            briefMarkdown: brief,
            findings: findings,
            rejectedFindings: rejectedFindings,
            rejectedMemories: rejectedMemories,
            actionHints: hints
        )
    }

    /// Title normalized for fingerprinting: lowercased, digits stripped, so
    /// "3 stale PRs" and "5 stale PRs" are the same condition.
    static func normalizedSubject(_ title: String) -> String {
        String(title.lowercased().filter { $0.isLetter || $0.isWhitespace })
            .split(separator: " ")
            .prefix(8)
            .joined(separator: " ")
    }

    /// Derives actions from citations so a model-authored finding still gets
    /// working buttons without the model inventing URLs.
    ///
    /// Delegates to `BurnBarAIInboxActionFactory`, which covers every evidence
    /// kind. This wrapper exists because the analyst is not the only caller —
    /// the publisher derives the brief's actions the same way.
    static func actions(
        for evidenceIDs: [String],
        pack: BurnBarAIInboxEvidencePack,
        hints: [BurnBarAIInboxActionHint] = []
    ) -> [BurnBarInboxAction] {
        BurnBarAIInboxActionFactory.actions(for: evidenceIDs, pack: pack, hints: hints)
    }

    /// Keeps only hints that name evidence the pack actually contains, then
    /// redacts and hard-caps their prose.
    ///
    /// Mirrors `BurnBarAIInboxReplyService.validatedCandidates`: the model
    /// proposes structure, Swift intersects every id against a known-good set,
    /// and anything unmatched disappears without comment. A hint carries no
    /// capability even when it survives — it can reorder buttons and rename
    /// them, nothing more.
    static func validatedHints(
        _ payloads: [AnalystPayload.ActionHint],
        validIDs: Set<String>
    ) -> [BurnBarAIInboxActionHint] {
        var seen = Set<String>()
        var hints: [BurnBarAIInboxActionHint] = []
        for payload in payloads.prefix(BurnBarAIInboxActionFactory.maxHints) {
            guard let evidenceID = payload.evidenceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  validIDs.contains(evidenceID) else { continue }
            guard seen.insert(evidenceID).inserted else { continue }

            let rawVerb = Self.singleLine(payload.verb ?? "")
            let rawWhy = Self.singleLine(payload.why ?? "")
            guard rawVerb.isEmpty == false else { continue }
            // A hint that trips the secret gate is dropped whole rather than
            // rewritten: a button labelled "(excerpt withheld…)" is worse than
            // the code-derived label it would have replaced.
            guard BurnBarAIInboxRedactor.containsSensitiveMaterial(rawVerb + " " + rawWhy) == false else { continue }

            hints.append(
                BurnBarAIInboxActionHint(
                    evidenceID: evidenceID,
                    verb: String(rawVerb.prefix(BurnBarAIInboxActionFactory.maxVerbCharacters)),
                    why: String(rawWhy.prefix(BurnBarAIInboxActionFactory.maxExplanationCharacters))
                )
            )
        }
        return hints
    }

    /// Collapses newlines and runs of whitespace so a hint cannot smuggle a
    /// multi-line block into a button label.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    static func makeCall(
        role: String,
        route: BurnBarProviderRoute,
        result: BurnBarProviderExecutionResult
    ) -> BurnBarAIInboxModelCall {
        let cost = (try? route.pricing.cost(
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            cacheCreationTokens: result.cacheCreationTokens,
            cacheReadTokens: result.cacheReadTokens
        )) ?? 0
        return BurnBarAIInboxModelCall(
            providerID: route.providerID,
            modelID: route.resolvedModelID,
            role: role,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            cacheCreationTokens: result.cacheCreationTokens,
            cacheReadTokens: result.cacheReadTokens,
            costUSD: cost
        )
    }

    static func repairPrompt(original: String, error: String?) -> String {
        """
        Your previous response was not valid JSON matching the required schema\
        \(error.map { " (\($0))" } ?? ""). Return ONLY the JSON object this time — no prose, no markdown \
        fence, no trailing commentary.

        \(original)
        """
    }
}

/// A validated model hint about one citation.
///
/// Carries no capability by construction: there is no url, no command, no
/// value, and no action kind. It can say "this PR is the move, call the button
/// *Unblock the release*" and nothing more; where that button points is decided
/// by `BurnBarAIInboxActionFactory` from the evidence record.
struct BurnBarAIInboxActionHint: Sendable, Hashable {
    /// Already intersected with `pack.validEvidenceIDs`.
    let evidenceID: String
    /// Redacted, single-line, <= 28 characters.
    let verb: String
    /// Redacted, single-line, <= 120 characters. May be empty.
    let why: String
}

/// Turns citations into working buttons.
///
/// The invariant this type exists to hold: **a model may never author an
/// action's URL, command, or value.** Every string a button acts on is built
/// here, in Swift, from a record that is already in the evidence pack. Models
/// produce ids and prose; this produces destinations.
///
/// Before this existed, only `conv:` and `pr:` citations produced anything, and
/// only the first three at that — so a finding citing an issue, a workflow run,
/// a workspace, or spend rendered with no "NEXT" section at all. Every evidence
/// kind now resolves to at least one genuinely useful move.
enum BurnBarAIInboxActionFactory {
    /// Buttons per item. Five is the point where a "next move" list stops
    /// reading as a next move; the one-primary rule does the rest.
    static let maxActions = 5
    /// Citations inspected. Higher than `maxActions` because a citation can
    /// resolve to zero actions (an unrecognized prefix) or two (a conversation).
    static let maxEvidenceConsidered = 8
    /// Hints accepted from one response.
    static let maxHints = 4
    static let maxVerbCharacters = 28
    static let maxExplanationCharacters = 120

    /// Settings anchor the app already dispatches. `open_settings` ignores the
    /// value on macOS and copies it on iOS, so this matches what ships today
    /// (`BurnBarAIInboxService.analystUnavailableFinding`) rather than inventing
    /// a route nothing can follow.
    static let settingsAnchor = "ai-inbox"

    // MARK: - Entry point

    /// Derives the button set for one finding's citations.
    ///
    /// Order of operations matters: hinted citations move to the front (that is
    /// the *only* way a hint changes what leads), then each citation resolves to
    /// code-built actions, then duplicates collapse, then the list is capped,
    /// then exactly one primary is stamped.
    static func actions(
        for evidenceIDs: [String],
        pack: BurnBarAIInboxEvidencePack,
        hints: [BurnBarAIInboxActionHint] = []
    ) -> [BurnBarInboxAction] {
        let hintsByID = Dictionary(hints.map { ($0.evidenceID, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = prioritized(evidenceIDs, hints: hints).prefix(maxEvidenceConsidered)

        var actions: [BurnBarInboxAction] = []
        var seen = Set<String>()

        for evidenceID in ordered {
            var derived = derive(evidenceID: evidenceID, pack: pack)
            guard derived.isEmpty == false else { continue }
            // A hint renames and explains the LEAD action for its citation. It
            // never reaches `value`, `kind`, or any secondary action.
            if let hint = hintsByID[evidenceID] {
                derived[0] = BurnBarInboxAction(
                    id: derived[0].id,
                    kind: derived[0].kind,
                    title: hint.verb,
                    value: derived[0].value,
                    isPrimary: false,
                    explanation: hint.why.isEmpty ? derived[0].explanation : hint.why
                )
            }
            for action in derived {
                // Two citations often point at the same place (a PR and the run
                // that built it, a workspace and a file inside it). One button.
                guard seen.insert("\(action.kind.rawValue)|\(action.value)").inserted else { continue }
                actions.append(action)
                if actions.count >= maxActions { break }
            }
            if actions.count >= maxActions { break }
        }

        return stampSinglePrimary(actions)
    }

    /// Hinted citations first (in hint order), then everything else in the order
    /// the finding cited it. Hints that name an uncited id are ignored here —
    /// they have already been intersected with the pack, but a hint about
    /// evidence *this* finding did not cite has no button to influence.
    static func prioritized(_ evidenceIDs: [String], hints: [BurnBarAIInboxActionHint]) -> [String] {
        let cited = Set(evidenceIDs)
        var ordered = hints.map(\.evidenceID).filter(cited.contains)
        var seen = Set(ordered)
        for id in evidenceIDs where seen.insert(id).inserted {
            ordered.append(id)
        }
        return ordered
    }

    /// Exactly one primary, and it is the first action. Multiple hints cannot
    /// produce multiple primaries because primacy is assigned here, after every
    /// hint has been applied — it is positional, not claimable.
    static func stampSinglePrimary(_ actions: [BurnBarInboxAction]) -> [BurnBarInboxAction] {
        actions.enumerated().map { index, action in
            BurnBarInboxAction(
                id: action.id,
                kind: action.kind,
                title: action.title,
                value: action.value,
                isPrimary: index == 0,
                explanation: action.explanation
            )
        }
    }

    // MARK: - Per-kind derivation

    /// Classifies a citation id. Mirrors how `BurnBarAIInboxPublisher.evidence`
    /// materializes the same ids, so a button and its citation row always agree
    /// about what they are pointing at.
    static func evidenceKind(for evidenceID: String) -> BurnBarInboxEvidence.Kind? {
        if evidenceID.hasPrefix("conv:") { return .conversation }
        if evidenceID.hasPrefix("pr:") { return .pullRequest }
        if evidenceID.hasPrefix("issue:") { return .issue }
        if evidenceID.hasPrefix("run:") { return .workflowRun }
        if evidenceID.hasPrefix("commit:") { return .commit }
        // A workspace citation renders as a `.file` evidence row.
        if evidenceID.hasPrefix("workspace:") || evidenceID.hasPrefix("file:") { return .file }
        if evidenceID.hasPrefix("usage:") { return .usage }
        if evidenceID.hasPrefix("metric:") { return .metric }
        return nil
    }

    /// All actions one citation earns, most useful first, none primary yet.
    static func derive(evidenceID: String, pack: BurnBarAIInboxEvidencePack) -> [BurnBarInboxAction] {
        switch evidenceKind(for: evidenceID) {
        case .conversation:
            return conversationActions(evidenceID: evidenceID, pack: pack)
        case .pullRequest:
            return gitHubReferenceActions(evidenceID: evidenceID, pack: pack, kind: .pullRequest)
        case .issue:
            return gitHubReferenceActions(evidenceID: evidenceID, pack: pack, kind: .issue)
        case .workflowRun:
            return gitHubReferenceActions(evidenceID: evidenceID, pack: pack, kind: .workflowRun)
        case .commit:
            return commitActions(evidenceID: evidenceID)
        case .file:
            return pathActions(evidenceID: evidenceID)
        case .usage, .metric:
            return spendActions(evidenceID: evidenceID)
        case .none:
            return []
        }
    }

    private static func conversationActions(
        evidenceID: String,
        pack: BurnBarAIInboxEvidencePack
    ) -> [BurnBarInboxAction] {
        // Prefer the pack's own record: a conversation id may itself contain a
        // colon, which the id-shape parse below would truncate.
        let conversationID = pack.conversations.first { $0.evidenceID == evidenceID }?.conversationID
            ?? String(evidenceID.dropFirst("conv:".count).split(separator: ":").first ?? "")
        guard conversationID.isEmpty == false else { return [] }
        return [
            BurnBarInboxAction(
                id: identifier("resume", evidenceID),
                kind: .resumeConversation,
                title: "Resume this session",
                value: conversationID,
                explanation: "Reopens the session where this was decided."
            ),
            BurnBarInboxAction(
                id: identifier("log", evidenceID),
                kind: .openSessionLog,
                title: "Read the session log",
                value: conversationID,
                explanation: "Shows the transcript behind this claim."
            )
        ]
    }

    /// PRs, issues, and workflow runs share a shape: `<prefix>:<owner/repo>#<n>`.
    /// The pack's own recorded URL wins; the canonical GitHub path is the
    /// fallback so a citation still opens when the snapshot is thin.
    private static func gitHubReferenceActions(
        evidenceID: String,
        pack: BurnBarAIInboxEvidencePack,
        kind: BurnBarInboxEvidence.Kind
    ) -> [BurnBarInboxAction] {
        let prefixLength: Int
        let pathSegment: String
        let title: (Int) -> String
        switch kind {
        case .pullRequest:
            prefixLength = "pr:".count
            pathSegment = "pull"
            title = { "Open PR #\($0)" }
        case .issue:
            prefixLength = "issue:".count
            pathSegment = "issues"
            title = { "Open issue #\($0)" }
        default:
            prefixLength = "run:".count
            pathSegment = "actions/runs"
            title = { _ in "Open the workflow run" }
        }

        let reference = String(evidenceID.dropFirst(prefixLength))
        let parts = reference.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]) else { return [] }
        let slug = String(parts[0])
        guard slug.isEmpty == false else { return [] }

        let recorded = recordedURL(slug: slug, number: number, kind: kind, pack: pack)
        let url = recorded ?? "https://github.com/\(slug)/\(pathSegment)/\(number)"
        return [
            BurnBarInboxAction(
                id: identifier("open", evidenceID),
                kind: .openURL,
                title: title(number),
                value: url,
                explanation: "Opens \(slug) on GitHub."
            )
        ]
    }

    /// The URL GitHub itself reported for this record, when the pack has it.
    private static func recordedURL(
        slug: String,
        number: Int,
        kind: BurnBarInboxEvidence.Kind,
        pack: BurnBarAIInboxEvidencePack
    ) -> String? {
        guard let repository = pack.repositories.first(where: { $0.slug == slug }) else { return nil }
        let recorded: String?
        switch kind {
        case .pullRequest:
            recorded = (repository.openPullRequests + repository.recentlyMergedPullRequests)
                .first { $0.number == number }?.url
        case .issue:
            recorded = repository.openIssues.first { $0.number == number }?.url
        default:
            recorded = repository.recentRuns.first { $0.id == number }?.url
        }
        guard let recorded, recorded.isEmpty == false else { return nil }
        return recorded
    }

    /// `commit:<owner/repo>@<sha>` opens on GitHub; a bare `commit:<sha>` has no
    /// remote to point at, so it becomes a copyable `git show` instead of a dead
    /// button.
    private static func commitActions(evidenceID: String) -> [BurnBarInboxAction] {
        let reference = String(evidenceID.dropFirst("commit:".count))
        guard reference.isEmpty == false else { return [] }
        let parts = reference.split(separator: "@", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].isEmpty == false, parts[1].isEmpty == false {
            return [
                BurnBarInboxAction(
                    id: identifier("open", evidenceID),
                    kind: .openURL,
                    title: "Open the commit",
                    value: "https://github.com/\(parts[0])/commit/\(parts[1])",
                    explanation: "Opens this commit on GitHub."
                )
            ]
        }
        return [
            BurnBarInboxAction(
                id: identifier("show", evidenceID),
                kind: .runCommand,
                title: "Copy `git show`",
                value: "git show \(reference)",
                explanation: "Copies the command that prints this commit. Nothing runs."
            )
        ]
    }

    /// `workspace:<path>` and `file:<path>`: reveal it, and hand over the one
    /// command a person actually types next.
    private static func pathActions(evidenceID: String) -> [BurnBarInboxAction] {
        let isWorkspace = evidenceID.hasPrefix("workspace:")
        let prefix = isWorkspace ? "workspace:" : "file:"
        let path = String(evidenceID.dropFirst(prefix.count))
        guard path.isEmpty == false else { return [] }

        let directory = isWorkspace ? path : (path as NSString).deletingLastPathComponent
        var actions = [
            BurnBarInboxAction(
                id: identifier("reveal", evidenceID),
                kind: .openProject,
                title: isWorkspace ? "Open the project" : "Show in Finder",
                value: path,
                explanation: "Reveals \((path as NSString).lastPathComponent) in Finder."
            )
        ]
        guard directory.isEmpty == false else { return actions }
        actions.append(
            BurnBarInboxAction(
                id: identifier("cd", evidenceID),
                kind: .runCommand,
                title: "Copy the path",
                value: isWorkspace
                    ? "cd \(shellQuoted(directory)) && git status --short"
                    : "cd \(shellQuoted(directory))",
                explanation: "Copies the command to your clipboard. Nothing runs."
            )
        )
        return actions
    }

    /// Spend and measured metrics have no deep link the app can dispatch: the
    /// only routable settings action ignores its value on macOS and copies it on
    /// iOS. So this points at the surface that can actually change the outcome —
    /// the inbox's own budget and model pins — rather than minting a URL scheme
    /// nothing handles.
    private static func spendActions(evidenceID: String) -> [BurnBarInboxAction] {
        // A bare `usage:` / `metric:` prefix names nothing. Same rule as every
        // other kind: a citation with no subject earns no button.
        let subject = evidenceID.drop { $0 != ":" }.dropFirst()
        guard subject.isEmpty == false else { return [] }
        return [
            BurnBarInboxAction(
                id: identifier("settings", evidenceID),
                kind: .openSettings,
                title: "Open Inbox spend settings",
                value: settingsAnchor,
                explanation: "Where the daily budget and model pins live."
            )
        ]
    }

    // MARK: - Helpers

    /// POSIX single-quoting, including the embedded-quote escape. A path with an
    /// apostrophe in it must not produce a command that silently means something
    /// else when pasted.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Stable, readable, collision-free action ids. Stable matters: the app keys
    /// accessibility identifiers off them.
    static func identifier(_ verb: String, _ evidenceID: String) -> String {
        var slug = ""
        var lastWasSeparator = false
        for character in evidenceID.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasSeparator = false
            } else if lastWasSeparator == false {
                slug.append("-")
                lastWasSeparator = true
            }
            if slug.count >= 48 { break }
        }
        return "\(verb)-\(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")))"
    }
}

enum BurnBarAIInboxAnalystError: Error, LocalizedError {
    case invalidJSON(String)
    /// The resolved route violated the configured egress mode. The tick degrades
    /// to the rule-based brief rather than sending anything.
    case egressRefused(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason):
            return "The analyst returned malformed JSON: \(reason)"
        case .egressRefused(let reason):
            return "Refused to send: \(reason)"
        }
    }
}
