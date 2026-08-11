import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias ProviderQuotaBucket = OpenBurnBar.ProviderQuotaBucket
private typealias ProviderQuotaSnapshot = OpenBurnBar.ProviderQuotaSnapshot
private typealias ProviderQuotaWindowKind = OpenBurnBar.ProviderQuotaWindowKind
private typealias ProviderQuotaUnit = OpenBurnBar.ProviderQuotaUnit
private typealias ProviderQuotaSourceKind = OpenBurnBar.ProviderQuotaSourceKind
private typealias ProviderQuotaConfidence = OpenBurnBar.ProviderQuotaConfidence

@MainActor
final class ProviderQuotaChipTests: XCTestCase {

    // MARK: - Pressure tint thresholds

    func test_pressureTint_atOrAbove75Percent_isSuccess() {
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 1.0), DesignSystem.Colors.success)
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.90), DesignSystem.Colors.success)
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.75), DesignSystem.Colors.success)
    }

    func test_pressureTint_between25And75Percent_isAmber() {
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.7499), DesignSystem.Colors.amber)
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.50), DesignSystem.Colors.amber)
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.25), DesignSystem.Colors.amber)
    }

    func test_pressureTint_below25Percent_isWarning() {
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.2499), DesignSystem.Colors.warning)
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.10), DesignSystem.Colors.warning)
        XCTAssertEqual(ProviderQuotaChip.pressureTint(for: 0.0), DesignSystem.Colors.warning)
    }

    // MARK: - Text formatting

    func test_formatText_fullStyle_appendsPercentSymbol() {
        XCTAssertEqual(ProviderQuotaChip.formatText(intPercent: 82, style: .full), "82%")
        XCTAssertEqual(ProviderQuotaChip.formatText(intPercent: 0, style: .full), "0%")
        XCTAssertEqual(ProviderQuotaChip.formatText(intPercent: 100, style: .full), "100%")
    }

    func test_formatText_compactStyle_dropsPercentSymbol() {
        XCTAssertEqual(ProviderQuotaChip.formatText(intPercent: 82, style: .compact), "82")
        XCTAssertEqual(ProviderQuotaChip.formatText(intPercent: 100, style: .compact), "100")
    }

    func test_formatText_negativeInput_clampsToZero() {
        XCTAssertEqual(ProviderQuotaChip.formatText(intPercent: -5, style: .full), "0%")
        XCTAssertEqual(ProviderQuotaChip.formatText(intPercent: -100, style: .compact), "0")
    }

    // MARK: - resolve(...) — snapshot-driven

    func test_resolve_returnsNil_forNonQuotaSignalProviders() {
        let snapshot = Self.makeSnapshot(provider: .hermes, usedPercent: 18)
        for provider in [AgentProvider.hermes, .piAgent, .openClaw, .forgeDev] {
            XCTAssertNil(
                ProviderQuotaChip.resolve(
                    provider: provider,
                    style: .full,
                    displayName: nil,
                    snapshot: snapshot
                ),
                "Expected nil chip for non-quota-signal provider \(provider)"
            )
        }
    }

    func test_resolve_returnsNil_whenSnapshotIsMissing() {
        XCTAssertNil(
            ProviderQuotaChip.resolve(
                provider: .codex,
                style: .full,
                displayName: nil,
                snapshot: nil
            )
        )
    }

    func test_resolve_returnsNil_whenSnapshotHasNoDisplayableSignal() {
        // No buckets → hasDisplayableQuotaSignal == false
        let emptySnapshot = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: "no signal",
            buckets: []
        )
        XCTAssertNil(
            ProviderQuotaChip.resolve(
                provider: .codex,
                style: .full,
                displayName: nil,
                snapshot: emptySnapshot
            )
        )
    }

    func test_resolve_buildsExpectedResolution_forSinglePercentBucket() {
        let snapshot = Self.makeSnapshot(provider: .codex, usedPercent: 18) // → 82% remaining
        let resolved = ProviderQuotaChip.resolve(
            provider: .codex,
            style: .full,
            displayName: nil,
            snapshot: snapshot
        )
        XCTAssertEqual(resolved?.text, "82%")
        XCTAssertEqual(resolved?.tint, DesignSystem.Colors.success)
        XCTAssertEqual(resolved?.accessibilityLabel, "Codex quota 82 percent remaining")
        XCTAssertEqual(resolved?.tooltip, "Codex — 5h window: 82% left")
    }

    func test_resolve_tooltipPrefix_prefersDisplayNameOverride() {
        let snapshot = Self.makeSnapshot(provider: .factory, usedPercent: 60) // → 40% remaining
        let resolved = ProviderQuotaChip.resolve(
            provider: .factory,
            style: .full,
            displayName: "Droid",
            snapshot: snapshot
        )
        XCTAssertEqual(resolved?.text, "40%")
        XCTAssertEqual(resolved?.tint, DesignSystem.Colors.amber)
        XCTAssertEqual(resolved?.accessibilityLabel, "Droid quota 40 percent remaining")
        XCTAssertTrue(resolved?.tooltip.hasPrefix("Droid — ") ?? false,
                      "Expected tooltip to lead with overridden display name")
    }

    func test_resolve_compactStyle_dropsPercentSymbol() {
        let snapshot = Self.makeSnapshot(provider: .claudeCode, usedPercent: 18)
        let resolved = ProviderQuotaChip.resolve(
            provider: .claudeCode,
            style: .compact,
            displayName: nil,
            snapshot: snapshot
        )
        XCTAssertEqual(resolved?.text, "82")
    }

    // MARK: - remainingFraction (Agent Deck presence input)

    func test_resolve_exposesRemainingFraction_forPresenceResolution() {
        let snapshot = Self.makeSnapshot(provider: .codex, usedPercent: 18)
        let resolved = ProviderQuotaChip.resolve(
            provider: .codex,
            style: .full,
            displayName: nil,
            snapshot: snapshot
        )
        XCTAssertEqual(resolved?.remainingFraction ?? -1, 0.82, accuracy: 0.0001)
    }

    func test_resolve_remainingFraction_isZero_whenBucketIsSpent() {
        // `AgentPresence.exhausted` is defined as this fraction hitting 0, so it
        // has to be reachable rather than clamped away.
        let snapshot = Self.makeSnapshot(provider: .codex, usedPercent: 100)
        let resolved = ProviderQuotaChip.resolve(
            provider: .codex,
            style: .full,
            displayName: nil,
            snapshot: snapshot
        )
        XCTAssertEqual(resolved?.remainingFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(
            AgentPresenceResolver.resolve(
                AgentPresenceFacts(quotaRemainingFraction: resolved?.remainingFraction)
            ),
            .exhausted
        )
    }

    func test_resolve_remainingFraction_isNil_forTheSixAgentsWithoutAQuotaSignal() {
        // Quota honesty: only 6 of the 12 chat agents have a quota signal at
        // all. For the rest the meter must self-hide, not fabricate a number.
        let withoutSignal: [ChatBackendID] = [.hermes, .openclaw, .openClaude, .piAgent, .forge, .junie]
        for backend in withoutSignal {
            guard let provider = backend.agentProvider else {
                XCTFail("\(backend.rawValue) lost its agentProvider mapping")
                continue
            }
            XCTAssertNil(
                ProviderQuotaChip.resolve(
                    provider: provider,
                    style: .full,
                    displayName: backend.displayName,
                    snapshot: Self.makeSnapshot(provider: provider, usedPercent: 50)
                ),
                "\(backend.rawValue) has no quota signal — resolve() must stay nil so the meter self-hides"
            )
        }
    }

    // MARK: - Backend convenience init

    func test_backendInit_succeeds_forEveryChatBackendID() {
        // Today every ChatBackendID maps to a real AgentProvider; this test
        // future-proofs the failable init so adding a backend without a
        // provider mapping fails loudly.
        for backend in ChatBackendID.allCases {
            XCTAssertNotNil(
                ProviderQuotaChip(backend: backend),
                "ProviderQuotaChip(backend: .\(backend.rawValue)) returned nil — "
                + "did a new backend skip its agentProvider mapping?"
            )
        }
    }

    // MARK: - Helpers

    /// Builds a single-bucket snapshot whose `primaryDisplayableBucket`
    /// yields `remainingPercent = 100 - usedPercent`.
    private static func makeSnapshot(
        provider: AgentProvider,
        usedPercent: Double
    ) -> ProviderQuotaSnapshot {
        let bucket = ProviderQuotaBucket(
            key: "5h",
            label: "5h window",
            windowKind: .rollingHours,
            usedValue: nil,
            limitValue: nil,
            remainingValue: nil,
            usedPercent: usedPercent,
            resetsAt: Date().addingTimeInterval(60 * 60),
            unit: .percent,
            isEstimated: false
        )
        return ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "test",
            buckets: [bucket]
        )
    }
}
