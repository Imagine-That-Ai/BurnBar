import XCTest
import SwiftUI
@testable import OpenBurnBar
import OpenBurnBarCore

/// Pins the persisted → rendered mapping for proxy-route final statuses on the
/// macOS surface (ProxyRouteLogViews). `interrupted` must be first-class:
/// its own label, its own icon, and a warning tone that is visually distinct
/// from `failed`'s error tone — the stream broke after delivery began, the
/// route stayed healthy, and the request is retryable.
final class ProxyRouteLogPresentationTests: XCTestCase {

    func testEveryStatusHasDedicatedPresentation() {
        // Exhaustive over the contract: a new status that reuses another
        // status's label or icon (or falls through to a default) fails here.
        var seenLabels: Set<String> = []
        var seenImages: Set<String> = []
        for status in BurnBarProxyRouteFinalStatus.allCases {
            let presentation = ProxyRouteStatusPresentation(status: status)
            XCTAssertFalse(presentation.label.isEmpty, "\(status) needs a label")
            XCTAssertFalse(presentation.systemImage.isEmpty, "\(status) needs an icon")
            XCTAssertTrue(seenLabels.insert(presentation.label).inserted, "\(status) reuses label \(presentation.label)")
            XCTAssertTrue(seenImages.insert(presentation.systemImage).inserted, "\(status) reuses icon \(presentation.systemImage)")
        }
    }

    func testInterruptedRendersDistinctFromFailed() {
        let interrupted = ProxyRouteStatusPresentation(status: .interrupted)
        let failed = ProxyRouteStatusPresentation(status: .failed)

        XCTAssertEqual(interrupted.label, "Interrupted")
        XCTAssertEqual(interrupted.systemImage, "waveform.path.ecg")
        XCTAssertEqual(interrupted.tone, .warning, "interrupted is retryable, not a failure — amber, never error red")

        XCTAssertEqual(failed.tone, .error)
        XCTAssertNotEqual(interrupted.tone, failed.tone, "interrupted must not share failed's tone")
        XCTAssertNotEqual(interrupted.label, failed.label)
        XCTAssertNotEqual(interrupted.systemImage, failed.systemImage)
    }

    func testTonesMatchStatusSemantics() {
        let expectedTones: [BurnBarProxyRouteFinalStatus: ProxyRouteStatusPresentation.Tone] = [
            .exact: .success,
            .sameModelFailover: .warning,
            .crossVendorFallback: .error,
            .failed: .error,
            .rejected: .muted,
            .interrupted: .warning
        ]
        XCTAssertEqual(
            Set(expectedTones.keys),
            Set(BurnBarProxyRouteFinalStatus.allCases),
            "new statuses must be added to this expectation table"
        )
        for (status, tone) in expectedTones {
            XCTAssertEqual(ProxyRouteStatusPresentation(status: status).tone, tone, "\(status) tone drifted")
        }
    }

    func testTonesResolveToTheirDesignSystemTokens() {
        // The tone → token hop is where an "amber" decision could still land on
        // error red. Pin each tone to the exact `DesignSystem` color it renders.
        XCTAssertEqual(ProxyRouteStatusPresentation.Tone.success.color, DesignSystem.Colors.success)
        XCTAssertEqual(ProxyRouteStatusPresentation.Tone.warning.color, DesignSystem.Colors.warning)
        XCTAssertEqual(ProxyRouteStatusPresentation.Tone.error.color, DesignSystem.Colors.error)
        XCTAssertEqual(ProxyRouteStatusPresentation.Tone.muted.color, DesignSystem.Colors.textMuted)
    }

    func testInterruptedStatusRendersAmberEndToEnd() {
        // Status → tone → color, the whole hop the chip actually takes.
        XCTAssertEqual(
            ProxyRouteStatusPresentation(status: .interrupted).tone.color,
            DesignSystem.Colors.warning
        )
        XCTAssertNotEqual(
            ProxyRouteStatusPresentation(status: .interrupted).tone.color,
            ProxyRouteStatusPresentation(status: .failed).tone.color,
            "interrupted must never resolve to failed's error red"
        )
    }

    func testAttemptTintSeparatesInterruptedFromFailed() {
        // The per-attempt list in the expanded row: only `failed` is red, only
        // `interrupted` is amber, everything else stays neutral secondary.
        XCTAssertEqual(ProxyRouteStatusPresentation.attemptTint(for: .failed), DesignSystem.Colors.error)
        XCTAssertEqual(ProxyRouteStatusPresentation.attemptTint(for: .interrupted), DesignSystem.Colors.warning)
        XCTAssertEqual(ProxyRouteStatusPresentation.attemptTint(for: .exact), DesignSystem.Colors.textSecondary)
        XCTAssertEqual(ProxyRouteStatusPresentation.attemptTint(for: .sameModelFailover), DesignSystem.Colors.textSecondary)
        XCTAssertEqual(ProxyRouteStatusPresentation.attemptTint(for: .crossVendorFallback), DesignSystem.Colors.textSecondary)
        XCTAssertEqual(ProxyRouteStatusPresentation.attemptTint(for: .rejected), DesignSystem.Colors.textSecondary)
        XCTAssertNotEqual(
            ProxyRouteStatusPresentation.attemptTint(for: .interrupted),
            ProxyRouteStatusPresentation.attemptTint(for: .failed),
            "an interrupted attempt is not a failed attempt"
        )
    }

    func testEveryStatusHasAnAttemptTint() {
        // Exhaustive: a new status must be given an explicit attempt tint here
        // rather than inheriting the neutral default by accident.
        for status in BurnBarProxyRouteFinalStatus.allCases {
            let tint = ProxyRouteStatusPresentation.attemptTint(for: status)
            let expected: Color
            switch status {
            case .failed: expected = DesignSystem.Colors.error
            case .interrupted: expected = DesignSystem.Colors.warning
            case .exact, .sameModelFailover, .crossVendorFallback, .rejected:
                expected = DesignSystem.Colors.textSecondary
            }
            XCTAssertEqual(tint, expected, "\(status) attempt tint drifted")
        }
    }

    func testContractSemanticsBackTheRendering() {
        // The renderer's amber treatment leans on the contract's semantics:
        // interrupted never strikes route health and may carry partial usage.
        XCTAssertTrue(BurnBarProxyRouteFinalStatus.interrupted.isInterruption)
        XCTAssertFalse(BurnBarProxyRouteFinalStatus.interrupted.countsAgainstRouteHealth)
        XCTAssertTrue(BurnBarProxyRouteFinalStatus.interrupted.mayCarryPartialUsage)
        XCTAssertEqual(BurnBarProxyRouteFinalStatus.streamRelayOutcome(interrupted: true), .interrupted)
        XCTAssertEqual(BurnBarProxyRouteFinalStatus.streamRelayOutcome(interrupted: false), .exact)
    }
}
