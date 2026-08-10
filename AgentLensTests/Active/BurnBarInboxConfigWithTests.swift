import OpenBurnBarInboxModels
import XCTest

@testable import OpenBurnBar

/// A mechanical guard against the single most repeated bug in the AI Inbox
/// settings surface: adding a field to `BurnBarInboxConfig` and forgetting to
/// thread it through `BurnBarInboxConfig.with(...)`.
///
/// `BurnBarInboxConfig` is immutable and clamps in `init`, so the settings
/// screen edits it by rebuilding the whole value. Any field the rebuild does
/// not name is not "left alone" — it is reconstructed from the memberwise
/// default, so an unrelated toggle silently resets it. The failure is invisible
/// at the call site and invisible in review; it only shows up as a preference
/// that will not stay set.
///
/// This has now happened four times: `budgetCountsSubscriptionSpend`, the three
/// Founder Lens fields, and the two reading-register fields. Rather than fix it
/// a fifth time, this test walks the struct with `Mirror`, so a field added
/// tomorrow is covered without anyone remembering to cover it.
final class BurnBarInboxConfigWithTests: XCTestCase {

    /// A config in which **every** field is deliberately different from the
    /// memberwise default, so a dropped field shows up as a reverted value
    /// rather than coincidentally matching.
    ///
    /// Values stay inside the clamps `init` enforces; the point is to differ
    /// from the default, not to probe the clamps (which have their own tests).
    private func fullyNonDefaultConfig() -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: true,
            egressMode: .local,
            tickSeconds: 900,
            remotePhaseEveryNTicks: 5,
            dailyBudgetUSD: 7.25,
            maxVerifierCallsPerTick: 2,
            perTickPromptTokenCap: 24_000,
            analystProviderID: "deepseek",
            analystModel: "deepseek-chat",
            verifierProviderID: "openai",
            verifierModel: "gpt-5.6-luna",
            githubEnabled: true,
            notifyOnP1: false,
            lookbackMinutes: 240,
            founderLensEnabled: false,
            perReplyBudgetUSD: 0.12,
            maxThreadTurns: 9,
            budgetCountsSubscriptionSpend: true,
            briefDetail: .deep,
            briefRegister: .plainEnglish
        )
    }

    private func fields(of config: BurnBarInboxConfig) -> [String: String] {
        var result: [String: String] = [:]
        for child in Mirror(reflecting: config).children {
            guard let label = child.label else { continue }
            result[label] = String(describing: child.value)
        }
        return result
    }

    /// The load-bearing test. Change exactly one field; assert nothing else moved.
    func testWithPreservesEveryUnrelatedField() {
        let original = fullyNonDefaultConfig()
        let before = fields(of: original)

        XCTAssertFalse(
            before.isEmpty,
            "Mirror found no stored properties — this test would pass vacuously."
        )

        // `enabled` is the field being changed, so it is the only one allowed
        // to differ.
        let rebuilt = original.with(enabled: false)
        let after = fields(of: rebuilt)

        XCTAssertEqual(after["enabled"], "false", "the requested change did not apply")

        for (label, originalValue) in before where label != "enabled" {
            XCTAssertEqual(
                after[label],
                originalValue,
                """
                `BurnBarInboxConfig.with(...)` dropped `\(label)`: it was \
                \(originalValue) and became \(after[label] ?? "<missing>") after an \
                unrelated edit. Add `\(label): \(label),` to the \
                `BurnBarInboxConfig(...)` call inside `with(...)` in \
                AIInboxSettingsView.swift. If the field is user-editable, also give \
                `with(...)` an optional parameter for it.
                """
            )
        }
    }

    /// Every field the settings screen can actually set must round-trip, not
    /// just survive. A parameter that is accepted and then ignored is the same
    /// bug wearing a different hat.
    func testWithAppliesEveryEditableField() {
        let original = fullyNonDefaultConfig()

        XCTAssertFalse(original.with(enabled: false).enabled)
        XCTAssertEqual(original.with(egressMode: .off).egressMode, .off)
        XCTAssertEqual(original.with(tickSeconds: 600).tickSeconds, 600)
        XCTAssertEqual(original.with(dailyBudgetUSD: 3.5).dailyBudgetUSD, 3.5, accuracy: 0.0001)
        XCTAssertFalse(original.with(githubEnabled: false).githubEnabled)
        XCTAssertTrue(original.with(notifyOnP1: true).notifyOnP1)
        XCTAssertFalse(
            original.with(budgetCountsSubscriptionSpend: false).budgetCountsSubscriptionSpend
        )
        XCTAssertEqual(original.with(briefDetail: .brief).briefDetail, .brief)
        XCTAssertEqual(original.with(briefRegister: .expert).briefRegister, .expert)
    }

    /// Passing nothing must be the identity. If it is not, every call site that
    /// edits one field is silently rewriting the rest.
    func testWithNoArgumentsIsIdentity() {
        let original = fullyNonDefaultConfig()
        XCTAssertEqual(fields(of: original.with()), fields(of: original))
    }
}
