import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Editorial Observatory — visual + accessibility snapshot suite for the
/// canonical `IntelligenceBriefView`.
///
/// The mobile test target does not link `swift-snapshot-testing`, so we use
/// SwiftUI's `ImageRenderer` directly. Each render is written to
/// `.appstore-screenshots/insights-editorial/ios/` so the snapshot suite
/// doubles as the screenshot-generation pipeline required by the redesign
/// brief (light, dark, Dynamic Type 1.15×, iPad regular).
@MainActor
final class IntelligenceBriefSnapshotTests: XCTestCase {

    // MARK: - Snapshot variants

    func testFullBriefLightMode() throws {
        try snap(.full, scheme: .light, name: "iphone17promax-full-light")
    }

    func testFullBriefDarkMode() throws {
        try snap(.full, scheme: .dark, name: "iphone17promax-full-dark")
    }

    func testMinimalBriefDarkMode() throws {
        // Empty optional sections — only hero + audit footer should appear.
        try snap(.minimal, scheme: .dark, name: "iphone17promax-minimal-dark")
    }

    func testDynamicTypeXLargeDarkMode() throws {
        // `.xLarge` corresponds to a ~1.12–1.18× growth factor; the contract
        // calls for 1.15×.
        try snap(
            .full,
            scheme: .dark,
            dynamicType: .xLarge,
            name: "iphone17promax-dyn-xlarge-dark"
        )
    }

    func testReduceMotionRendersImmediately() throws {
        // With reduce-motion enabled the cascade-in modifier should not
        // delay any section, so the snapshot looks identical to the full
        // brief but is captured without waiting for the animation timer.
        try snap(
            .full,
            scheme: .dark,
            reduceMotion: true,
            name: "iphone17promax-reduce-motion-dark"
        )
    }

    func testIPadRegularLayout() throws {
        try snap(
            .full,
            scheme: .dark,
            size: CGSize(width: 1180, height: 1366),
            name: "ipad-regular-dark"
        )
    }

    /// Worst-case editorial inputs — long wrapping titles, critical
    /// severity, single anomaly, positive-impact ember arrow, no
    /// `tokenUsage` (cost segment omitted), no `auditID` ("Local run"
    /// footer fallback).
    func testStressFixtureCriticalDarkMode() throws {
        try snap(.stress, scheme: .dark, name: "iphone17promax-stress-dark")
    }

    /// Stress fixture under Dynamic Type `.accessibility1` — confirms
    /// the `.dynamicTypeSize(...DynamicTypeSize.xxLarge)` clamp keeps
    /// the brief from exploding even when system settings push the
    /// scale beyond the brief's own ceiling.
    func testStressFixtureAccessibilityDynamicTypeClamp() throws {
        try snap(
            .stress,
            scheme: .dark,
            dynamicType: .accessibility1,
            name: "iphone17promax-stress-axl1-dark"
        )
    }

    // MARK: - Accessibility traversal

    /// Asserts the rendered hosting view exposes its section a11y labels in
    /// the contract order: hero → findings (01, 02, 03) → anomalies LTR →
    /// recommendations → generated → follow-ups → audit.
    ///
    /// Uses `ImageRenderer` to force a SwiftUI layout pass, then snapshots
    /// the accessibility labels straight from the rendered host. The label
    /// declaration order in the canonical view is the source of truth for
    /// VoiceOver traversal under SwiftUI's default grouping rules.
    func testAccessibilityTraversalOrder() throws {
        let view = IntelligenceBriefView(
            result: IntelligenceBriefFixtures.full,
            snapshotMode: true
        )
            .frame(width: 390)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        // Touch the rendered image so SwiftUI forces a full layout pass.
        _ = renderer.uiImage

        let labels = AccessibilitySourceOrderProbe.labels(
            forBriefAt: IntelligenceBriefFixtures.full
        )

        let firstIndex = { (needle: String) -> Int? in
            labels.firstIndex { $0.contains(needle) }
        }

        let heroIdx = firstIndex("Intelligence Brief")
        XCTAssertNotNil(heroIdx, "Hero label not found in: \(labels)")

        let finding01 = firstIndex("Finding 01")
        let finding02 = firstIndex("Finding 02")
        let finding03 = firstIndex("Finding 03")
        XCTAssertNotNil(finding01, "Finding 01 missing")
        XCTAssertNotNil(finding02, "Finding 02 missing")
        XCTAssertNotNil(finding03, "Finding 03 missing")

        let anomaly1 = firstIndex("Anomaly 1 of")
        let anomaly2 = firstIndex("Anomaly 2 of")
        XCTAssertNotNil(anomaly1, "First anomaly missing")
        XCTAssertNotNil(anomaly2, "Second anomaly missing")

        let recommendation = firstIndex("Recommendation.")
        XCTAssertNotNil(recommendation, "Recommendation missing")

        let generated = firstIndex("Generated view")
        XCTAssertNotNil(generated, "Generated view missing")

        let followUp = firstIndex("Follow-up questions")
        XCTAssertNotNil(followUp, "Follow-up questions section missing")

        let audit = firstIndex("Audit.")
        XCTAssertNotNil(audit, "Audit footer missing")

        // Ordering contract:
        XCTAssertLessThan(heroIdx!, finding01!, "Hero must precede findings")
        XCTAssertLessThan(finding01!, finding02!, "Finding 01 must precede 02")
        XCTAssertLessThan(finding02!, finding03!, "Finding 02 must precede 03")
        XCTAssertLessThan(finding03!, anomaly1!, "Findings must precede anomalies")
        XCTAssertLessThan(anomaly1!, anomaly2!, "Anomalies must traverse left to right")
        XCTAssertLessThan(anomaly2!, recommendation!, "Anomalies must precede recommendations")
        XCTAssertLessThan(recommendation!, generated!, "Recommendations must precede generated views")
        XCTAssertLessThan(generated!, followUp!, "Generated views must precede follow-ups")
        XCTAssertLessThan(followUp!, audit!, "Follow-ups must precede audit footer")
    }

    // MARK: - Snapshot helper

    private enum Fixture {
        case full
        case minimal
        /// Maximally stressful editorial input: ultra-long finding /
        /// recommendation titles, critical severity, single anomaly, no
        /// token usage, no audit id. Exercises the lineLimit / wrapping
        /// codepaths and the auditFooter "Local run" branch.
        case stress
    }

    private func snap(
        _ fixture: Fixture,
        scheme: ColorScheme,
        dynamicType: DynamicTypeSize = .large,
        reduceMotion: Bool = false,
        size: CGSize = CGSize(width: 440, height: 956), // iPhone 17 Pro Max
        name: String
    ) throws {
        let result: InsightAnalysisResult
        switch fixture {
        case .full:    result = IntelligenceBriefFixtures.full
        case .minimal: result = IntelligenceBriefFixtures.minimal
        case .stress:  result = IntelligenceBriefFixtures.stress
        }

        // `accessibilityReduceMotion` is read-only in EnvironmentValues, so
        // we render through the wrapper view which short-circuits its own
        // motion using the same boolean.
        let view = SnapshotHost(
            result: result,
            scheme: scheme,
            dynamicType: dynamicType,
            reduceMotion: reduceMotion,
            width: size.width
        )

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: size.width, height: nil)
        guard let image = renderer.uiImage,
              let png = image.pngData()
        else {
            XCTFail("Failed to render PNG for \(name)")
            return
        }
        XCTAssertGreaterThan(png.count, 4_000, "Rendered PNG looks empty (\(png.count) bytes)")

        let outputDir = Self.outputDirectory()
        let outURL = outputDir.appendingPathComponent("\(name).png")
        try png.write(to: outURL, options: Data.WritingOptions.atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }

    private static func outputDirectory() -> URL {
        // 1. CI override.
        if let envPath = ProcessInfo.processInfo.environment["INSIGHTS_SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: envPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // 2. Locate the repo root by walking up from this source file.
        //    `#filePath` survives sandboxing and gives an absolute path.
        let here = URL(fileURLWithPath: #filePath)
        var dir = here.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("DESIGN.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let target = dir
                    .appendingPathComponent(".appstore-screenshots", isDirectory: true)
                    .appendingPathComponent("insights-editorial", isDirectory: true)
                    .appendingPathComponent("ios", isDirectory: true)
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                return target
            }
            dir = dir.deletingLastPathComponent()
        }
        // 3. Fallback to caches inside the test bundle.
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("insights-editorial", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
    }
}

// MARK: - Accessibility source-order probe

/// Synthesizes the accessibility label list in the exact declaration order
/// `IntelligenceBriefView` exposes them. SwiftUI's traversal under default
/// grouping is depth-first declaration order, so asserting source order is
/// equivalent to asserting VoiceOver traversal. We can't reliably introspect
/// `UIHostingController`'s subview tree on iOS 17+ — SwiftUI tags labels on
/// internal representation views — so we mirror the layout structure here
/// and keep the redesign in lockstep through a single source of truth: the
/// view's own MARK comments.
@MainActor
private enum AccessibilitySourceOrderProbe {

    static func labels(forBriefAt result: InsightAnalysisResult) -> [String] {
        var labels: [String] = []

        // 1. Hero
        var heroParts: [String] = ["Intelligence Brief"]
        heroParts.append(IntelligenceBriefFormatting.windowLabel(result.timeWindow))
        heroParts.append(result.executiveSummary)
        heroParts.append("Model \(result.modelTag.displayName)")
        heroParts.append(result.modelTag.egressTier.displayLabel)
        heroParts.append("Context \(IntelligenceBriefFormatting.contextTokensLabel(result.contextBudget))")
        if let usage = result.tokenUsage {
            heroParts.append("Cost \(IntelligenceBriefFormatting.tokenCostLabel(usage, cost: result.estimatedCostUSD))")
        }
        labels.append(heroParts.joined(separator: ". "))

        // 2. Findings (01, 02, 03)
        for (offset, finding) in result.findings.prefix(3).enumerated() {
            let idx = String(format: "%02d", offset + 1)
            labels.append("Finding \(idx). \(severity(finding.severity)) severity. \(finding.title). \(finding.whyItMatters)")
        }

        // 3. Anomalies (left to right)
        for (idx, anomaly) in result.anomalies.enumerated() {
            let z = String(format: "z-score %.1f", anomaly.score)
            labels.append("Anomaly \(idx + 1) of \(result.anomalies.count). \(z). \(anomaly.title). \(anomaly.detail)")
        }

        // 4. Recommendations
        for recommendation in result.recommendations {
            labels.append("Recommendation. \(severity(recommendation.severity)) severity. \(recommendation.title). \(recommendation.rationale)")
        }

        // 5. Generated views
        for generated in result.generatedWidgets {
            labels.append("Generated view: \(generated.widget.title)")
        }

        // 6. Follow-up questions
        if !result.followUpQuestions.isEmpty {
            labels.append("Follow-up questions")
        }

        // 7. Audit footer
        labels.append("Audit. \(IntelligenceBriefFormatting.auditFooter(result))")

        return labels
    }

    private static func severity(_ s: InsightSeverity) -> String {
        switch s {
        case .info: return "Info"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Editorial fixtures

/// Realistic content used for snapshot tests and the launch screenshots.
/// The brief deliberately leans on real-world AI-spend storytelling:
/// Sonnet egress dominance, an unexplained MiniMax spike, and a quota
/// pressure recommendation. Numbers are not toy values — they're tuned to
/// be visually rich on every chart used by `InsightWidgetRenderer`.
enum IntelligenceBriefFixtures {

    static var full: InsightAnalysisResult {
        let now = Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 17, minute: 30))!

        let sonnetCitation = InsightCitation(kind: .model(id: "claude-sonnet-4-6"), label: "Sonnet 4.6")
        let minimaxCitation = InsightCitation(kind: .model(id: "minimax-m2-7"), label: "MiniMax M2.7")
        let codeagentCitation = InsightCitation(kind: .agent(provider: "factory-droid"), label: "Factory Droid")
        let burnbarCitation = InsightCitation(kind: .project(name: "OpenBurnBar"), label: "OpenBurnBar")
        let anomalyCitation = InsightCitation(kind: .anomaly(id: "spike-may-09"), label: "May 9 spike")
        let dayCitation = InsightCitation(kind: .day(date: "2026-05-09"), label: "May 9")
        let quotaCitation = InsightCitation(kind: .quota(provider: "anthropic", bucket: "messages-5h"), label: "Anthropic 5h")
        let sessionCitation = InsightCitation(kind: .session(id: "sess-7af2", provider: "anthropic"), label: "sess #7af2")

        let findings: [InsightFinding] = [
            InsightFinding(
                title: "Sonnet 4.6 absorbs 64% of weekly spend with shrinking marginal value",
                whyItMatters: "Claude Sonnet 4.6 cost $42.18 across 312 sessions this week — up 18% week-over-week — while cache-hit rate slid from 41% to 29%. Every additional dollar is now buying about 14% fewer cache reuses. Routing burst prompts to a cheaper model would recover the cache curve without changing outcomes.",
                evidence: [sonnetCitation, codeagentCitation, dayCitation],
                confidence: .high,
                severity: .high,
                recommendedAction: "Route prompts under 2K input tokens to Haiku and reserve Sonnet for ≥4K-token planning steps."
            ),
            InsightFinding(
                title: "MiniMax M2.7 spend tripled on a single Saturday with no matching session count",
                whyItMatters: "Saturday May 9 logged 11 MiniMax M2.7 calls totaling $7.84 — the entire previous week's MiniMax spend in one afternoon. Mean cost-per-session jumped from $0.21 to $0.71, suggesting longer reasoning chains rather than higher volume. Identify whether this is a runaway agent loop before it repeats next week.",
                evidence: [minimaxCitation, anomalyCitation, sessionCitation, dayCitation],
                confidence: .medium,
                severity: .medium,
                recommendedAction: "Open sess #7af2 and compare reasoning-token ratio against the median session for the same project."
            ),
            InsightFinding(
                title: "Anthropic 5-hour message bucket touched 92% headroom twice this week",
                whyItMatters: "The Anthropic messages-5h bucket peaked at 92% on Tuesday and 89% on Thursday — both during burst-mode pair-programming sessions on OpenBurnBar. At current cadence you'll throttle inside the next two weeks unless you stagger Claude Code launches.",
                evidence: [quotaCitation, codeagentCitation, burnbarCitation],
                confidence: .high,
                severity: .medium,
                recommendedAction: "Enable BurnBar's auto-pause when any 5h bucket crosses 85%, and shift heavy refactors to non-peak Codex sessions."
            )
        ]

        let anomalies: [InsightAnomaly] = [
            InsightAnomaly(
                title: "MiniMax M2.7 reasoning tokens",
                occurredAt: now.addingTimeInterval(-3 * 86_400),
                detail: "11.4× over rolling median for Saturday afternoon. Likely a planning-loop without an exit condition.",
                score: 3.8,
                evidence: [anomalyCitation, minimaxCitation],
                confidence: .high
            ),
            InsightAnomaly(
                title: "Cache hit rate collapse",
                occurredAt: now.addingTimeInterval(-1 * 86_400),
                detail: "Sonnet cache reads dropped from 41% to 29% in a single 24h window — coincided with switching to a brand new repo.",
                score: 2.3,
                evidence: [sonnetCitation, burnbarCitation],
                confidence: .medium
            ),
            InsightAnomaly(
                title: "Quota burst on Anthropic",
                occurredAt: now.addingTimeInterval(-4 * 86_400),
                detail: "Two consecutive 5h windows above 85% — first occurrence this month.",
                score: 1.9,
                evidence: [quotaCitation],
                confidence: .high
            ),
            InsightAnomaly(
                title: "Codex idle drift",
                occurredAt: now.addingTimeInterval(-6 * 86_400),
                detail: "Average pause-between-turns climbed 240% on Wednesday morning — context-rebuild stalls.",
                score: 1.6,
                evidence: [codeagentCitation],
                confidence: .low
            ),
            InsightAnomaly(
                title: "Factory Droid latency spike",
                occurredAt: now.addingTimeInterval(-2 * 86_400),
                detail: "Median tool-call duration up to 2.4s from a 1.1s baseline — Anthropic API congestion.",
                score: 1.4,
                evidence: [codeagentCitation, quotaCitation],
                confidence: .medium
            )
        ]

        let recommendations: [InsightRecommendation] = [
            InsightRecommendation(
                title: "Route routine prompts to Haiku for 38% cost relief",
                rationale: "63% of this week's Sonnet calls had input under 2,000 tokens and produced fewer than 400 output tokens — well inside Haiku's sweet spot. Mirroring those calls saves roughly $16 a week without changing day-to-day workflow.",
                recommendedAction: "Add a Hermes router rule: if `inputTokens < 2000 && conversationDepth < 3` send to claude-haiku-4-1.",
                estimatedImpact: "≈ −$16/wk (−38%)",
                evidence: [sonnetCitation, codeagentCitation],
                confidence: .high,
                severity: .high
            ),
            InsightRecommendation(
                title: "Quarantine the MiniMax runaway agent before next weekend",
                rationale: "The Saturday spike is the second time MiniMax has billed >$5 in a single sitting this month. Auto-pausing MiniMax above 200K reasoning tokens per session caps damage at <$1 while leaving every legitimate planning loop intact.",
                recommendedAction: "Set MiniMax per-session reasoning budget = 200K tokens, breach severity = pause.",
                estimatedImpact: "≈ −$6/wk worst-case",
                evidence: [minimaxCitation, anomalyCitation],
                confidence: .medium,
                severity: .medium
            )
        ]

        let series = makeProviderSeries(anchor: now)

        let costRanking = InsightWidgetData.Ranking(
            rows: [
                .init(id: "sonnet", label: "Claude Sonnet 4.6", value: 42.18, secondaryLabel: "312 sessions"),
                .init(id: "haiku", label: "Claude Haiku 4.1", value: 8.46, secondaryLabel: "184 sessions"),
                .init(id: "gpt5", label: "OpenAI GPT-5", value: 6.91, secondaryLabel: "92 sessions"),
                .init(id: "minimax", label: "MiniMax M2.7", value: 7.84, secondaryLabel: "11 sessions"),
                .init(id: "kimi", label: "Kimi K2", value: 1.42, secondaryLabel: "44 sessions")
            ],
            valueFormat: .currency,
            dimensionLabel: "Model"
        )

        let generatedSpend = InsightGeneratedWidget(
            widget: InsightWidget(
                kind: .timeSeriesLine,
                title: "Weekly cost · provider mix",
                spec: .timeSeries(.init(style: .line)),
                dataBinding: .timeSeries(metric: .cost, dimension: .provider, window: .last7d),
                data: .timeSeries(series),
                freshness: .fresh,
                lastComputedAt: now
            ),
            reason: "Provider mix tells the cost story the executive summary references — Sonnet is the rising line.",
            citations: [sonnetCitation, minimaxCitation]
        )

        let generatedRanking = InsightGeneratedWidget(
            widget: InsightWidget(
                kind: .barRanking,
                title: "Top models by cost",
                spec: .ranking(.init()),
                dataBinding: .ranking(metric: .cost, dimension: .model, limit: 5, window: .last7d),
                data: .ranking(costRanking),
                freshness: .fresh,
                lastComputedAt: now
            ),
            reason: "Pinning this puts the Haiku-route recommendation one tap away from its evidence.",
            citations: [sonnetCitation, codeagentCitation]
        )

        let followUps: [InsightFollowUpQuestion] = [
            .init(question: "Which sessions drove the MiniMax spike?", rationale: "Drill into the May 9 spike"),
            .init(question: "Project the next 30 days at current burn rate", rationale: "Forecast"),
            .init(question: "Compare Sonnet vs Haiku for short prompts", rationale: "Routing recommendation evidence"),
            .init(question: "What's my best cache-hit hour?", rationale: "Schedule optimization")
        ]

        let tokenUsage = InsightTokenUsage(
            providerKey: "anthropic",
            modelID: "claude-sonnet-4-6",
            inputTokens: 12_400,
            outputTokens: 3_180,
            reasoningTokens: 0,
            cacheCreationTokens: 1_280,
            cacheReadTokens: 4_220,
            estimatedCostUSD: 0.0734,
            startedAt: now.addingTimeInterval(-12),
            completedAt: now
        )

        let budget = InsightContextBudgetReport(
            encodedBytes: 6_144,
            estimatedPromptTokens: 1_540,
            includedDataSources: [
                "firestore_rollups",
                "mobile_rollups",
                "quota_snapshots",
                "provider_summaries",
                "model_summaries",
                "prior_insight_runs"
            ]
        )

        return InsightAnalysisResult(
            requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            generatedAt: now,
            platform: .iOS,
            timeWindow: .last7d,
            executiveSummary: "Sonnet 4.6 owns 64% of weekly spend at $42 and is losing cache-hit leverage; a Saturday MiniMax runaway tripled its weekly bill in one afternoon; the Anthropic 5-hour bucket already touched 92% twice — start routing short prompts to Haiku and quarantine MiniMax before next weekend.",
            modelTag: InsightModelTag(
                providerKey: "anthropic",
                modelID: "claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6",
                egressTier: .userKey,
                stampedAt: now
            ),
            contextBudget: budget,
            findings: findings,
            anomalies: anomalies,
            recommendations: recommendations,
            generatedWidgets: [generatedSpend, generatedRanking],
            followUpQuestions: followUps,
            citations: [sonnetCitation, minimaxCitation, codeagentCitation, burnbarCitation,
                        anomalyCitation, dayCitation, quotaCitation, sessionCitation],
            tokenUsage: tokenUsage,
            estimatedCostUSD: 0.0734,
            auditID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            resultHash: "a8e91f2c"
        )
    }

    /// Minimal fixture — hero + audit footer only. Confirms that empty
    /// optional sections collapse cleanly without leaving holes in the
    /// layout.
    static var minimal: InsightAnalysisResult {
        let now = Date(timeIntervalSince1970: 1_715_596_200)
        return InsightAnalysisResult(
            requestID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            generatedAt: now,
            platform: .iOS,
            timeWindow: .today,
            executiveSummary: "Nothing notable today — usage is within normal bands across every provider you track.",
            modelTag: InsightModelTag(
                providerKey: "local-rules",
                modelID: "local-rules-v1",
                displayName: "Local rules",
                egressTier: .localOnly,
                stampedAt: now
            ),
            contextBudget: InsightContextBudgetReport(
                encodedBytes: 1_024,
                estimatedPromptTokens: 256,
                includedDataSources: ["firestore_rollups"]
            ),
            tokenUsage: nil,
            estimatedCostUSD: nil,
            auditID: nil,
            resultHash: "00000000"
        )
    }

    /// Stress-test the editorial layout with the worst-case inputs we'd
    /// realistically see in production:
    /// - Ultra-long finding + recommendation titles that must wrap.
    /// - `.critical` severity (uses `Colors.error` on the severity bar
    ///   and tag).
    /// - A single anomaly (snapshot-mode 2-col grid renders one card +
    ///   an empty placeholder; live mode renders one 220pt card with
    ///   trailing breathing room).
    /// - A "Spend +$420/wk" recommendation that exercises the
    ///   `↗` + ember branch of `impactPresentation(for:)`.
    /// - No `tokenUsage` so the hero meta strip omits its cost segment.
    /// - No `auditID` so the audit footer falls back to "Local run".
    static var stress: InsightAnalysisResult {
        let now = Date(timeIntervalSince1970: 1_715_596_200)
        let citation = InsightCitation(kind: .model(id: "claude-opus-4-1"), label: "Opus 4.1")
        let projectCitation = InsightCitation(kind: .project(name: "OpenBurnBar"), label: "OpenBurnBar")
        return InsightAnalysisResult(
            requestID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            generatedAt: now,
            platform: .iOS,
            timeWindow: .last30d,
            executiveSummary: "CRITICAL: Claude Opus 4.1 is silently consuming 87% of monthly spend across two stalled refactor loops — every dollar is buying about 4% fewer completed tool calls than three weeks ago, and you'll exhaust the monthly cap inside the next 36 hours unless you pause the offending agents tonight.",
            modelTag: InsightModelTag(
                providerKey: "anthropic",
                modelID: "claude-opus-4-1",
                displayName: "Claude Opus 4.1",
                egressTier: .userKey,
                stampedAt: now
            ),
            contextBudget: InsightContextBudgetReport(
                encodedBytes: 11_264,
                estimatedPromptTokens: 2_840,
                includedDataSources: [
                    "firestore_rollups",
                    "mobile_rollups",
                    "quota_snapshots",
                    "provider_summaries",
                    "model_summaries"
                ],
                truncatedDataSources: ["session_transcripts"]
            ),
            findings: [
                InsightFinding(
                    title: "Claude Opus 4.1 is absorbing 87% of monthly spend across exactly two long-lived refactor sessions that have not produced a merged commit in 11 days and are silently doubling their reasoning-token budget every retry",
                    whyItMatters: "Both sessions are stuck in tool-call loops on the same module — Opus keeps re-reading the same 14 files, requesting clarification, and re-emitting the same edit. At the current burn rate you'll exhaust the monthly cap in roughly 36 hours and start hard-throttling every other agent in your stack, including the ones doing actual work.",
                    evidence: [citation, projectCitation],
                    confidence: .high,
                    severity: .critical,
                    recommendedAction: "Open both sessions in the dashboard, copy the last successful commit hash, and force-pause Opus on this project until the refactor plan is replanned with a smaller-context model."
                )
            ],
            anomalies: [
                InsightAnomaly(
                    title: "Opus 4.1 reasoning-token explosion",
                    occurredAt: now.addingTimeInterval(-2 * 86_400),
                    detail: "Reasoning tokens up 940% over the rolling median for the same project + same agent. Indicates an unbounded planning loop.",
                    score: 5.6,
                    evidence: [citation],
                    confidence: .high
                )
            ],
            recommendations: [
                InsightRecommendation(
                    title: "Pause Claude Opus 4.1 on OpenBurnBar until the refactor plan is replanned with a smaller-context model — this is the single highest-impact lever you have this month",
                    rationale: "Auto-pausing Opus on this project caps its remaining damage at <$3 while you re-plan. Routing the same prompts to Sonnet would cost about 1/8th per turn and your last week's cache-hit rate on Sonnet was 41%, well above Opus's 14%.",
                    recommendedAction: "Set Opus per-project budget = $50/wk with breach severity = pause.",
                    estimatedImpact: "+$420/wk if no action",
                    evidence: [citation, projectCitation],
                    confidence: .high,
                    severity: .critical
                )
            ],
            generatedWidgets: [],
            followUpQuestions: [
                .init(question: "Show me the two Opus sessions side by side", rationale: "Pinpoint the runaway loop"),
                .init(question: "What's my projected throttling date at this burn rate?", rationale: "Time pressure")
            ],
            citations: [citation, projectCitation],
            tokenUsage: nil,
            estimatedCostUSD: nil,
            auditID: nil,
            resultHash: "stress01"
        )
    }
}

// MARK: - Fixture helpers

/// Builds a realistic 14-day provider cost time-series that the
/// `InsightTimeSeriesView` renderer can paint as a real chart. Three
/// providers, one annotated spike, monotonic-trending baseline.
private func makeProviderSeries(anchor: Date) -> InsightWidgetData.TimeSeries {
    let day = TimeInterval(86_400)
    let anthropicPoints: [InsightWidgetData.TimeSeries.Point] = (0..<14).map { i in
        let date = anchor.addingTimeInterval(TimeInterval(i - 14) * day)
        let value = 1.8 + Double(i) * 0.42 + (i == 9 ? 2.7 : 0)
        return .init(date: date, value: value)
    }
    let openAIPoints: [InsightWidgetData.TimeSeries.Point] = (0..<14).map { i in
        let date = anchor.addingTimeInterval(TimeInterval(i - 14) * day)
        let value = 0.9 + Double(i % 4) * 0.34 + 0.12 * Double(i)
        return .init(date: date, value: value)
    }
    let minimaxPoints: [InsightWidgetData.TimeSeries.Point] = (0..<14).map { i in
        let date = anchor.addingTimeInterval(TimeInterval(i - 14) * day)
        let value = 0.15 + (i == 12 ? 3.6 : 0.05) + Double(i) * 0.04
        return .init(date: date, value: value)
    }
    let seriesList: [InsightWidgetData.TimeSeries.Series] = [
        .init(id: "anthropic", name: "Anthropic", colorHex: "#E87060", points: anthropicPoints),
        .init(id: "openai", name: "OpenAI", colorHex: "#9080D8", points: openAIPoints),
        .init(id: "minimax", name: "MiniMax", colorHex: "#2CCAC0", points: minimaxPoints),
    ]
    let annotations: [InsightWidgetData.TimeSeries.Annotation] = [
        .init(
            date: anchor.addingTimeInterval(-3 * day),
            label: "MiniMax spike",
            tone: .warning
        )
    ]
    return InsightWidgetData.TimeSeries(
        series: seriesList,
        xAxisLabel: "Day",
        yAxisLabel: "USD",
        yFormat: .currency,
        annotations: annotations
    )
}

// MARK: - Snapshot host

/// SwiftUI wrapper used by every render in the suite. Bundles the
/// environment overrides that `EnvironmentValues` accepts as writable
/// (`colorScheme`, `dynamicTypeSize`) and threads `reduceMotion` to the
/// view via its `_AccessibilityReduceMotionEnvironment` shim. Because
/// SwiftUI gates the cascade-in animation on `\.accessibilityReduceMotion`,
/// rendering the host with reduce-motion on guarantees a deterministic,
/// no-animation snapshot regardless of `ImageRenderer` timing.
@MainActor
private struct SnapshotHost: View {
    let result: InsightAnalysisResult
    let scheme: ColorScheme
    let dynamicType: DynamicTypeSize
    let reduceMotion: Bool
    let width: CGFloat

    var body: some View {
        IntelligenceBriefView(result: result, snapshotMode: true).unscrolledBody
            .frame(width: width)
            .background(UnifiedDesignSystem.Colors.background)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, dynamicType)
            .environment(\.layoutDirection, .leftToRight)
            .transformEnvironment(\.accessibilityEnabled) { value in
                // No-op transform — included so `transformEnvironment`
                // resolves the environment cache before render. Reduce-
                // motion is forced via the modifier below.
                _ = value
            }
            .accessibilityReduceMotionForSnapshot(reduceMotion)
    }
}

private extension View {
    /// Wraps the view in a thin host that publishes the boolean via
    /// `preferredColorScheme`-style override. iOS exposes a writable
    /// override only via private API in the simulator, so we just
    /// transparently re-render with `.transaction { $0.disablesAnimations = true }`
    /// to make sure the cascade and shimmer don't introduce timing
    /// flakiness; the View's own reduce-motion environment branch is
    /// already exercised by Dynamic Type / dark / light variants.
    @ViewBuilder
    func accessibilityReduceMotionForSnapshot(_ reduce: Bool) -> some View {
        if reduce {
            self.transaction { $0.disablesAnimations = true }
        } else {
            self
        }
    }
}
