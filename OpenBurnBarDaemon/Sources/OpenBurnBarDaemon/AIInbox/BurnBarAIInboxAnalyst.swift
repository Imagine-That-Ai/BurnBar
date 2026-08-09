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
                    founderLens: config.founderLensEnabled
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
            rejectedMemoryCandidateCount: validation.rejectedMemories
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

        let briefMD: String?
        let findings: [Finding]?
        let memoryCandidates: [MemoryCandidate]?

        enum CodingKeys: String, CodingKey {
            case briefMD = "brief_md"
            case findings
            case memoryCandidates = "memory_candidates"
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
                    actions: Self.actions(for: citedIDs, pack: pack),
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
            rejectedMemories: rejectedMemories
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
    static func actions(for evidenceIDs: [String], pack: BurnBarAIInboxEvidencePack) -> [BurnBarInboxAction] {
        var actions: [BurnBarInboxAction] = []
        for id in evidenceIDs.prefix(3) {
            if id.hasPrefix("conv:") {
                let conversationID = String(id.dropFirst(5).split(separator: ":").first ?? "")
                guard conversationID.isEmpty == false else { continue }
                actions.append(
                    BurnBarInboxAction(
                        id: "resume-\(conversationID)",
                        kind: .resumeConversation,
                        title: "Resume this session",
                        value: conversationID,
                        isPrimary: actions.isEmpty
                    )
                )
            } else if id.hasPrefix("pr:") {
                let reference = String(id.dropFirst(3))
                let parts = reference.split(separator: "#")
                guard parts.count == 2 else { continue }
                actions.append(
                    BurnBarInboxAction(
                        id: "open-\(reference)",
                        kind: .openURL,
                        title: "Open PR #\(parts[1])",
                        value: "https://github.com/\(parts[0])/pull/\(parts[1])",
                        isPrimary: actions.isEmpty
                    )
                )
            }
        }
        return actions
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
