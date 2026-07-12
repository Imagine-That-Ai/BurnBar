import XCTest
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
