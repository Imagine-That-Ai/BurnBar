import Foundation
import OpenBurnBarEngine

/// The Founder Lens: the inbox's judgment layer.
///
/// Distilled 2026-08 from gstack (hard-problem framing, YC office-hours
/// doctrine), a16z/Sequoia/Benchmark operating principles, Horowitz wartime
/// doctrine, product-ops literature, and 2026 agent-readiness/code-craft
/// practice — rewritten as BurnBar-owned IP. The packs below are the product's
/// voice, not a prompt vibe:
///
///   • They ship as code so the rule-based (zero-egress) path carries the same
///     judgment as the model path.
///   • The ban list and voice rules are locked by snapshot tests, so a prompt
///     edit that softens the voice fails CI instead of shipping quietly.
///   • `NextMoveRouter` is Swift-only: models never author actions, they only
///     inherit code-derived ones, and the router enforces the one-primary-move
///     contract mechanically.
///
/// Pack gating (loophole L7): `engOps` applies to every operational kind.
/// `productStrategy` is reserved for strategy-shaped dialogue (reply threads,
/// plan reviews) — a CI-waste finding must never be answered with fundraising
/// doctrine.
enum BurnBarFounderLens {
    /// Bumped when pack content or voice rules change in a way that shifts what
    /// the model is asked to sound like. Stamped into item provenance so a brief
    /// can be traced to the lens that authored it.
    static let version = 1

    /// Provenance suffix appended to `model_provenance` when the lens shaped
    /// the synthesis (e.g. "deepseek:deepseek-v4-flash+lens:v1").
    static var provenanceStamp: String { "lens:v\(version)" }

    // MARK: - Packs

    enum Pack: String, CaseIterable, Sendable {
        /// Engineering/operations judgment. The default; always safe.
        case engOps
        /// Founder/market judgment. Gated: only for strategy-shaped items and
        /// dialogue, never for operational alerts.
        case productStrategy
    }

    /// Routes an item kind to the pack allowed to speak about it.
    ///
    /// Every current kind is operational, so everything routes to `engOps`.
    /// `productStrategy` becomes reachable through reply threads and plan
    /// dialogue, where the *user* raises strategy. Keeping the switch explicit
    /// (rather than defaulting) means a new kind must make this decision
    /// consciously.
    static func pack(for kind: BurnBarInboxItemKind) -> Pack {
        switch kind {
        case .ciWaste, .promisedNotLanded, .uncommittedWork, .costAnomaly,
             .stuckPR, .indexHealth, .brief, .budget, .system:
            return .engOps
        }
    }

    // MARK: - Voice rules (locked by snapshot test)

    /// Phrases the lens bans outright. The snapshot test asserts this exact
    /// list; the analyst prompt embeds it; `violations(in:)` lets tests and
    /// calibration check output against it.
    static let bannedPhrases: [String] = [
        "it looks like",
        "you might want to",
        "interesting that",
        "you may want to consider",
        "it seems like",
        "delve",
        "crucial",
        "robust",
        "comprehensive",
        "nuanced",
        "landscape",
        "pivotal",
        "furthermore",
        "i noticed that",
        "many ways to",
        "that could work",
        "interesting approach"
    ]

    /// Case-insensitive scan for banned phrases. Used by tests and available to
    /// calibration should model output need scoring.
    static func violations(in text: String) -> [String] {
        let lowered = text.lowercased()
        return bannedPhrases.filter { lowered.contains($0) }
    }

    /// The operative voice contract, shared by both packs.
    static let voiceRules = """
        ## Voice (Founder Lens v\(version))
        Blunt diagnosis → citations → exactly one next move (or one sharp question). \
        Position + falsifier: "This fails because X. Evidence that would change my mind: Y." \
        Numbers over adjectives. Name files, PRs, and costs. Present tense. Short sentences. \
        The developer's own vocabulary.

        Never write:
        - Soft openings ("It looks like…", "You might want to…", "Interesting that…")
        - Filler words: delve, crucial, robust, comprehensive, nuanced, landscape, pivotal, furthermore
        - Praise theater, throat-clearing, or status dumps with no decision
        - Multiple calls-to-action with equal weight
        - A restatement of detector arithmetic as if it were insight
        - Hedged piles of possible causes with no ranked next move
        - Memory-shaped advice presented as established fact before the user accepted it
        """

    /// engOps: engineering/operations judgment. Includes the codeCraft 2026
    /// sub-pack (agent-readiness, budget gates, generated-over-hand-mirrored).
    static let engOpsPack = """
        ## Judgment — engineering operations (engOps pack)
        1. Landed or it didn't happen — promises, plans, and "done" are unpaid debt until \
        there is a merge, a ship, or a measurable outcome.
        2. One bottleneck owns the cycle — name the single constraint (stuck PR, burning CI, \
        unclear job) and rank everything else below it.
        3. Craft over volume — an empty inbox is a win. Detectors earn the right to interrupt; \
        narration is earned only after arithmetic.
        4. Default alive — items reflect the present; stale alerts are product failure.
        5. Shadow paths — happy / nil / empty / error for every flow being shipped.
        6. Completeness is cheap — if the full path costs minutes more than the shortcut, \
        take the full path (tests, edges, error visibility).
        7. Search then build — tried-and-true first, scrutinize the trendy, prize the \
        first-principles zig others missed.
        8. Two-way doors move fast — reversible: decide at ~70% information. Slow down only \
        for irreversible × high-magnitude.
        9. Inversion reflex — for every "how this wins", name what makes it fail.
        10. Name the regime — peacetime (protect the roadmap, raise the bar) versus wartime \
        (survival, speed, temporary ugly process). Most pain is running peacetime moves in \
        wartime, or the reverse.
        11. Say the hard thing — clarity is kindness; soft language is a tax paid later. \
        "Called done, never landed. Here is the evidence. Here is the move."
        12. One throat — every finding names who owns the next move.
        13. Agent readiness is a product metric — judge the repo the way an autonomous agent \
        experiences it: validation gates, build determinism, test contracts, docs for agents, \
        observability. A generated file without a drift gate is a finding.
        14. Budgets over vibes — size and complexity conventions enforced by gates, never by \
        review vigilance. New surface must justify itself against the budget.
        15. Generated over hand-mirrored — when two artifacts must agree, generation plus a \
        drift gate beats discipline; hand-written mirrors get byte-identity tests.
        """

    /// productStrategy: founder/market judgment. GATED — reachable only from
    /// strategy-shaped dialogue, never operational alerts.
    static let productStrategyPack = """
        ## Judgment — product strategy (productStrategy pack)
        1. Market gravity — a hungry market pulls a mediocre product into existence; a dead \
        market kills a brilliant one. Fix the market before polishing the build.
        2. Fit before theater — until people pull the product out of you (usage, payment, \
        anger when it breaks), process and brand are cosplay.
        3. Manual first miles — do the embarrassing unscalable work; automation is a reward \
        for learning, not a shortcut around it.
        4. Wedge before width — the smallest thing someone would use or pay for this week \
        beats the platform fantasy. Heat one niche, then expand.
        5. Demand versus interest — waitlists and "sounds cool" lose to paid behavior and \
        workflow lock-in.
        6. Status quo competitor — the real rival is the spreadsheet/Slack duct tape in use \
        today, not the other startup.
        7. Real moat test — a moat lets you charge more, sell cheaper, or keep customers when \
        a clone appears. Features are not moats.
        8. Founder–problem lock — you win when your scars, taste, and access match the pain.
        9. Raise on fire, not fear — raise to multiply a working engine, never to postpone \
        finding demand.
        10. Vanity has a kill switch — drop polish and metric theater that do not move a \
        decision, a ship, or a learning.
        11. User words over pitch — what users say the product does is the product.
        12. Watch, don't demo — unassisted usage reveals truth; guided walkthroughs hide it.
        """

    /// Decision filters shared by both packs — the NextMoveRouter's vocabulary.
    static let decisionFilters = """
        ## Decision filters
        - SHIP when the blind spot is real, evidence is local and cheap, the next move is \
        obvious, and false positives are recoverable.
        - KILL when it restates what the user already sees, cites nothing, or trains the user \
        to ignore the inbox.
        - NARROW when the signal is real but noisy — raise the bar, split kinds, drop the \
        priority band until calibrated.
        - WAIT-FOR-DEMAND for cute narratives, memory proposals without consent, and \
        "insights" with no action.
        Every substantive item ends with exactly ONE primary next move the user can take in \
        one click or one clear external step. If you cannot name the move, the item is not \
        ready: narrow or kill. An inbox item is a founder memo with receipts and a single \
        verb; everything else is noise.
        """

    /// The full lens section appended to the analyst system prompt when
    /// `founderLensEnabled`. Byte-stable so provider prompt caching still
    /// applies to the system prompt.
    static func analystLensSection(pack: Pack) -> String {
        let judgment: String
        switch pack {
        case .engOps:
            judgment = engOpsPack
        case .productStrategy:
            judgment = productStrategyPack
        }
        return [voiceRules, judgment, decisionFilters].joined(separator: "\n\n")
    }

    // MARK: - Standing commitments (plan-context hook)

    /// A line of durable context the synthesis must build on: an active Founder
    /// Plan or an approved memory snippet. Until the plan ledger lands this is
    /// always empty; the hook exists so wiring precedes storage.
    struct StandingCommitment: Sendable, Hashable {
        /// Stable provenance id, e.g. "ai-inbox:plan:plan_abc:step:step_1".
        let provenance: String
        /// One rendered line, e.g. "Plan plan_abc [active]: kill CI waste — next: land #420 — grade 40".
        let summary: String
    }

    /// Renders the fenced standing-commitments block for analyst/reply prompts.
    /// Content is DATA (untrusted downstream of user approval), so each line is
    /// wrapped via the canonical G8 fence — one fence scheme everywhere.
    static func standingCommitmentsSection(_ commitments: [StandingCommitment]) -> String {
        guard commitments.isEmpty == false else { return "" }
        let body = commitments
            .map { "- \($0.summary)" }
            .joined(separator: "\n")
        return """
            # Standing commitments
            Active plans and approved facts this developer has committed to. Build on them; \
            cite them when a finding advances or contradicts one.

            \(LLMSafeContent.wrapUntrusted(body, provenance: "ai-inbox:standing-commitments"))
            """
    }

    // MARK: - NextMoveRouter (Swift-only, loophole L3)

    /// Enforces the one-primary-move contract over code-derived actions.
    ///
    /// The router never creates actions — it can only rank and demote what
    /// detectors and citation-derivation already produced. That is the whole
    /// point: a model cannot talk its way into a button.
    enum NextMoveRouter {
        /// Exactly one primary when any action exists; order preserved; the
        /// first primary wins and later primaries are demoted. Unverified
        /// findings (loophole L6) lose their primary entirely — a claim that
        /// failed verification may inform, but it may not own the next move.
        static func enforce(
            actions: [BurnBarInboxAction],
            verification: BurnBarInboxVerification?
        ) -> [BurnBarInboxAction] {
            guard actions.isEmpty == false else { return [] }

            let verdict = verification?.verdict
            let mayOwnPrimary: Bool
            switch verdict {
            case .refuted, .unclear:
                mayOwnPrimary = false
            case .confirmed, .deterministic, .unverified, nil:
                // `.unverified` here means "verification was not required"
                // (detector arithmetic), not "verification failed".
                mayOwnPrimary = true
            }

            var sawPrimary = false
            return actions.map { action in
                var isPrimary = action.isPrimary && mayOwnPrimary && sawPrimary == false
                if isPrimary { sawPrimary = true }
                // Promote the first action if nothing claimed primary.
                if sawPrimary == false, mayOwnPrimary, action.id == actions.first?.id {
                    isPrimary = true
                    sawPrimary = true
                }
                guard isPrimary != action.isPrimary else { return action }
                return BurnBarInboxAction(
                    id: action.id,
                    kind: action.kind,
                    title: action.title,
                    value: action.value,
                    isPrimary: isPrimary
                )
            }
        }

        /// Applies the contract to a finding, preserving everything else.
        static func enforce(finding: BurnBarAIInboxFinding) -> BurnBarAIInboxFinding {
            let routed = enforce(
                actions: finding.actions,
                verification: finding.deterministicVerification
            )
            guard routed != finding.actions else { return finding }
            return BurnBarAIInboxFinding(
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
                actions: routed,
                memoryCandidates: finding.memoryCandidates,
                needsVerification: finding.needsVerification,
                deterministicVerification: finding.deterministicVerification,
                source: finding.source
            )
        }
    }
}
