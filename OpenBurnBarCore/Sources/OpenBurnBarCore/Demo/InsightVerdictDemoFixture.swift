import Foundation

/// Anonymized but believable verdict shown on first launch.
///
/// Voice contract §3.6 — "first 500ms = headline + ring + trace." A
/// brand-new user who hasn't logged any data still sees a real verdict on
/// the surface, framed as a demo. The fixture is intentionally generic
/// enough that it could plausibly be the user's own first day — that's
/// what makes it inspirational rather than a placeholder.
public enum InsightVerdictDemoFixture {

    /// Produce a sample verdict for the given window with a fixed
    /// "demo" provenance chip the renderer treats as the first-run state.
    public static func sample(
        window: VerdictWindow = .today,
        anchored at: Date = Date()
    ) -> InsightVerdict {
        let provenance = InsightModelTag(
            providerKey: "burnbar-demo",
            modelID: "demo-fixture",
            displayName: "Demo",
            egressTier: .localOnly,
            stampedAt: at
        )

        let rings: [VerdictRing] = [
            VerdictRing(
                identity: .spend,
                label: "Spend",
                current: 4.12,
                target: 12.0,
                unit: .usd,
                valueLabel: "$4.12 / $12",
                delta: VerdictDelta(
                    value: -28,
                    unit: .percent,
                    baseline: "vs 4-week avg",
                    direction: .lowerIsBetter
                ),
                tint: .ember
            ),
            VerdictRing(
                identity: .cache,
                label: "Cache",
                current: 91,
                target: 85,
                unit: .percent,
                valueLabel: "91% / 85%",
                delta: VerdictDelta(
                    value: 6,
                    unit: .percent,
                    baseline: "vs 4-week avg",
                    direction: .higherIsBetter
                ),
                tint: .silver
            ),
            VerdictRing(
                identity: .sessions,
                label: "Sessions",
                current: 3,
                target: 2,
                unit: .sessions,
                valueLabel: "3 / 2",
                delta: VerdictDelta(
                    value: 50,
                    unit: .percent,
                    baseline: "vs 4-week avg",
                    direction: .higherIsBetter
                ),
                tint: .mercury
            )
        ]

        let keyNumbers: [VerdictNumber] = [
            VerdictNumber(
                id: "spend",
                label: "Spend",
                value: "$4.12",
                rawValue: 4.12,
                unit: .usd,
                delta: VerdictDelta(value: -28, unit: .percent, baseline: "vs 4-week", direction: .lowerIsBetter),
                sparkline: [5.1, 4.7, 6.2, 5.9, 5.3, 4.9, 4.12]
            ),
            VerdictNumber(
                id: "cache",
                label: "Cache hit",
                value: "91%",
                rawValue: 91,
                unit: .percent,
                delta: VerdictDelta(value: 6, unit: .percent, baseline: "vs 4-week", direction: .higherIsBetter),
                sparkline: [85, 86, 84, 87, 89, 90, 91]
            ),
            VerdictNumber(
                id: "sessions",
                label: "Sessions",
                value: "3",
                rawValue: 3,
                unit: .sessions,
                delta: VerdictDelta(value: 50, unit: .percent, baseline: "vs 4-week", direction: .higherIsBetter),
                sparkline: [2, 2, 3, 2, 2, 2, 3]
            ),
            VerdictNumber(
                id: "sonnet_calls",
                label: "Sonnet calls",
                value: "27",
                rawValue: 27,
                unit: .count,
                delta: VerdictDelta(value: -12, unit: .percent, baseline: "vs prior day", direction: .neutral)
            )
        ]

        let bullets: [VerdictBullet] = [
            VerdictBullet(
                type: .comparison,
                claim: "You spent $4.12 yesterday — 28% under your 4-week average, driven by 91% cache hit on the Atlas refactor.",
                citations: [
                    InsightCitation(kind: .day(date: "2026-05-15"), label: "yesterday"),
                    InsightCitation(kind: .session(id: "s_demo_atlas_01", provider: "anthropic"), label: "session #atlas-01")
                ],
                delta: VerdictDelta(value: -28, unit: .percent, baseline: "vs 4-week avg", direction: .lowerIsBetter),
                confidence: .high
            ),
            VerdictBullet(
                type: .recommendation,
                claim: "53% of your Sonnet calls were under 500 input tokens — Haiku would have saved $14 this week.",
                citations: [
                    InsightCitation(kind: .model(id: "claude-sonnet-4-6"), label: "claude-sonnet-4-6")
                ],
                delta: VerdictDelta(value: -14, unit: .usd, baseline: "this week", direction: .lowerIsBetter),
                acceptAction: VerdictAcceptAction(
                    label: "Switch default",
                    intent: .switchRouterRule,
                    payloadDict: [
                        "providerID": "anthropic",
                        "fromModel": "claude-sonnet-4-6",
                        "toModel": "claude-haiku-4-5"
                    ]
                ),
                confidence: .high
            ),
            VerdictBullet(
                type: .discovery,
                claim: "Your local Pi handled 38% of insights yesterday — saving $1.10 round-trip.",
                citations: [
                    InsightCitation(kind: .agent(provider: "pi"), label: "Local Pi")
                ],
                confidence: .high
            ),
            VerdictBullet(
                type: .pattern,
                claim: "Cache hit rate on agentlens-mobile dropped 27 points Thursday — likely a new branch without --cache.",
                citations: [
                    InsightCitation(kind: .project(name: "agentlens-mobile"), label: "agentlens-mobile"),
                    InsightCitation(kind: .day(date: "2026-05-14"), label: "Thursday")
                ],
                confidence: .medium
            )
        ]

        let trace = VerdictTraceStrip(
            sessionID: "s_demo_atlas_01",
            lanes: [
                TraceLane(kind: .prompt, label: "Prompt", startOffset: 0, duration: 1.2, tint: .ember),
                TraceLane(kind: .model, label: "claude-sonnet-4-6", startOffset: 1.2, duration: 9.4, costUSD: 0.97, tint: .ember),
                TraceLane(kind: .tool, label: "Read × 4", startOffset: 4.3, duration: 1.7, tint: .neutral),
                TraceLane(kind: .cache, label: "cache hit", startOffset: 6.0, duration: 0.8, tint: .silver),
                TraceLane(kind: .response, label: "Response", startOffset: 10.6, duration: 8.1, costUSD: 0.50, tint: .ember)
            ],
            ticks: [
                TraceTick(offset: 1.5, costUSD: 0.10),
                TraceTick(offset: 6.4, costUSD: 0.42, label: "tool burst"),
                TraceTick(offset: 14.0, costUSD: 0.95, label: "$0.95 / $1.47")
            ],
            startedAt: at.addingTimeInterval(-19 * 60),
            endedAt: at.addingTimeInterval(-37),
            summary: "Refactored 4 files; 3 cache hits; 1 retry.",
            costUSD: 1.47,
            didTimeout: false,
            tint: .ember
        )

        let recommendation = VerdictRecommendation(
            headline: "Make Haiku the default for short prompts",
            rationale: "Half your Sonnet calls are under 500 input tokens — Haiku would have produced identical answers for less.",
            expectedImpact: "Saves ~$14/week",
            acceptAction: VerdictAcceptAction(
                label: "Switch default",
                intent: .switchRouterRule,
                payloadDict: [
                    "providerID": "anthropic",
                    "fromModel": "claude-sonnet-4-6",
                    "toModel": "claude-haiku-4-5",
                    "rule": "shortPrompt"
                ]
            ),
            citations: [
                InsightCitation(kind: .model(id: "claude-sonnet-4-6"), label: "claude-sonnet-4-6"),
                InsightCitation(kind: .model(id: "claude-haiku-4-5"), label: "claude-haiku-4-5")
            ],
            confidence: .high
        )

        var verdict = InsightVerdict(
            generatedAt: at,
            window: window,
            headline: "You spent $4.12 yesterday — 28% under your 4-week average.",
            subhead: "Cache held at 91% across the Atlas refactor.",
            rings: rings,
            keyNumbers: keyNumbers,
            sessionTrace: trace,
            bullets: bullets,
            anomaly: nil,
            recommendation: recommendation,
            moodSwatch: .ember,
            provenance: provenance,
            confidence: .high,
            followUps: [
                "Why did Sonnet cost so much yesterday?",
                "Show me cache hits by project.",
                "What's my most expensive use case this month?"
            ],
            isRuleBased: false,
            contentHash: ""
        )
        verdict.contentHash = RuleBasedVerdictEngine.hash(of: verdict)
        return verdict
    }
}
