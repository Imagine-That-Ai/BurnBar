import XCTest
@testable import OpenBurnBarCore

final class MissionConsoleForecastTests: XCTestCase {
    func test_lightDepth_dropsCostBelowStandard() {
        let runtime = MissionConsoleRuntime(
            id: "claude", displayName: "Claude", callSign: "CLD",
            provider: .claudeCode, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, pricingFactor: 1.0
        )
        let light = MissionConsoleForecastComputer.forecast(
            for: draft(depth: .light, runtime: runtime.id),
            runtime: runtime
        )
        let standard = MissionConsoleForecastComputer.forecast(
            for: draft(depth: .standard, runtime: runtime.id),
            runtime: runtime
        )
        XCTAssertLessThan(light.costHighUSD, standard.costHighUSD)
        XCTAssertLessThan(light.tokensHigh, standard.tokensHigh)
    }

    func test_deepDepth_widensCostBand() {
        let runtime = MissionConsoleRuntime(
            id: "codex", displayName: "Codex", callSign: "CDX",
            provider: .codex, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, pricingFactor: 0.9
        )
        let standard = MissionConsoleForecastComputer.forecast(
            for: draft(depth: .standard, runtime: runtime.id),
            runtime: runtime
        )
        let deep = MissionConsoleForecastComputer.forecast(
            for: draft(depth: .deep, runtime: runtime.id),
            runtime: runtime
        )
        // Deep should both raise cost and widen the band.
        XCTAssertGreaterThan(deep.costHighUSD, standard.costHighUSD)
        let standardBand = standard.costHighUSD - standard.costLowUSD
        let deepBand = deep.costHighUSD - deep.costLowUSD
        XCTAssertGreaterThan(deepBand, standardBand)
    }

    func test_runtimeMedianBlendsForecastWhenPresent() {
        let withoutHistory = MissionConsoleRuntime(
            id: "hermes", displayName: "Hermes", callSign: "HRM",
            provider: .hermes, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, pricingFactor: 0.4
        )
        let withHistory = MissionConsoleRuntime(
            id: "hermes", displayName: "Hermes", callSign: "HRM",
            provider: .hermes, availability: .online,
            recentMedianBurnUSD: 12.0, recentSampleSize: 8, pricingFactor: 0.4
        )
        let noBlend = MissionConsoleForecastComputer.forecast(
            for: draft(depth: .standard, runtime: "hermes"),
            runtime: withoutHistory
        )
        let blended = MissionConsoleForecastComputer.forecast(
            for: draft(depth: .standard, runtime: "hermes"),
            runtime: withHistory
        )
        // Median is huge (12 USD), should pull the forecast upward.
        XCTAssertGreaterThan(blended.costHighUSD, noBlend.costHighUSD)
    }

    func test_costNeverNegative() {
        let runtime = MissionConsoleRuntime(
            id: "pi", displayName: "Pi", callSign: "PI",
            provider: .piAgent, availability: .online,
            recentMedianBurnUSD: nil, recentSampleSize: 0, pricingFactor: 0.0
        )
        let forecast = MissionConsoleForecastComputer.forecast(
            for: draft(depth: .light, runtime: runtime.id),
            runtime: runtime
        )
        XCTAssertGreaterThanOrEqual(forecast.costLowUSD, 0)
        XCTAssertGreaterThanOrEqual(forecast.tokensLow, 0)
    }

    // MARK: helper

    private func draft(
        depth: MissionConsoleDepth,
        runtime: MissionConsoleRuntime.ID
    ) -> MissionConsoleDispatchRequest {
        MissionConsoleDispatchRequest(
            title: "Forecast test",
            prompt: "Trace the call path through InsightProviderGatewayRegistry.",
            kind: .diligence,
            runtimeID: runtime,
            targetProject: nil,
            depth: depth,
            approvalMode: .existingPolicy,
            commandsAllowed: false,
            fileEditsAllowed: false
        )
    }
}

final class MissionConsoleKindTests: XCTestCase {
    func test_eachKindHasNonEmptyMetadata() {
        for kind in MissionConsoleKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) missing displayName")
            XCTAssertFalse(kind.tagline.isEmpty, "\(kind) missing tagline")
            XCTAssertFalse(kind.glyph.isEmpty, "\(kind) missing glyph")
            XCTAssertFalse(kind.preferredRuntimes.isEmpty, "\(kind) missing runtime preference")
            XCTAssertGreaterThan(kind.tokenMultiplier, 0)
        }
    }

    func test_diligencePreferredRuntimeIsClaude() {
        XCTAssertEqual(MissionConsoleKind.diligence.preferredRuntimes.first, "claude")
    }

    func test_creativePreferredRuntimeIsOpenClaw() {
        XCTAssertEqual(MissionConsoleKind.creative.preferredRuntimes.first, "openclaw")
    }

    func test_debtPreferredRuntimeIsCodex() {
        XCTAssertEqual(MissionConsoleKind.debt.preferredRuntimes.first, "codex")
    }

    func test_costEfficiencyMultiplierIsLowestAmongKinds() {
        let minMul = MissionConsoleKind.allCases.map(\.tokenMultiplier).min()
        XCTAssertEqual(minMul, MissionConsoleKind.costEfficiency.tokenMultiplier)
    }
}

final class MissionFABGaugeConfigurationTests: XCTestCase {
    func test_burnSweepClamps() {
        let underflow = MissionFABGauge.Configuration(
            size: .standard, activeMissionCount: 0, approvalPendingCount: 0,
            blockedCount: 0, hasCompletedSinceLastOpen: false,
            burnSweep: -1.0, burnPerHourUSD: 0, macOnline: true
        )
        let overflow = MissionFABGauge.Configuration(
            size: .standard, activeMissionCount: 0, approvalPendingCount: 0,
            blockedCount: 0, hasCompletedSinceLastOpen: false,
            burnSweep: 2.5, burnPerHourUSD: 0, macOnline: true
        )
        XCTAssertEqual(underflow.burnSweep, 0)
        XCTAssertEqual(overflow.burnSweep, 1)
    }

    func test_idleConfigurationDefaults() {
        XCTAssertEqual(MissionFABGauge.Configuration.idle.activeMissionCount, 0)
        XCTAssertEqual(MissionFABGauge.Configuration.idle.approvalPendingCount, 0)
        XCTAssertEqual(MissionFABGauge.Configuration.idle.blockedCount, 0)
        XCTAssertTrue(MissionFABGauge.Configuration.idle.macOnline)
        XCTAssertEqual(MissionFABGauge.Configuration.idle.burnSweep, 0)
    }
}

final class MissionConsoleFormattingTests: XCTestCase {
    func test_costFormatsSubDollar() {
        XCTAssertEqual(MissionConsoleFormatting.cost(0.0473), "$0.0473")
    }

    func test_costFormatsDollarRange() {
        XCTAssertEqual(MissionConsoleFormatting.cost(2.5), "$2.50")
    }

    func test_costFormatsLargeAsRoundedDollar() {
        XCTAssertEqual(MissionConsoleFormatting.cost(123.4), "$123")
    }

    func test_tokenFormatting() {
        XCTAssertEqual(MissionConsoleFormatting.tokens(450), "450")
        XCTAssertEqual(MissionConsoleFormatting.tokens(1500), "1.5k")
        XCTAssertEqual(MissionConsoleFormatting.tokens(1_300_000), "1.3M")
    }

    func test_durationFormatting() {
        XCTAssertEqual(MissionConsoleFormatting.duration(45), "00:45")
        XCTAssertEqual(MissionConsoleFormatting.duration(125), "02:05")
        XCTAssertEqual(MissionConsoleFormatting.duration(3725), "1:02:05")
    }

    func test_relativeTimeBucketsExpectedly() {
        let now = Date()
        XCTAssertEqual(MissionConsoleFormatting.relativeTime(now, reference: now), "just now")
        XCTAssertEqual(MissionConsoleFormatting.relativeTime(now.addingTimeInterval(-90), reference: now), "1m ago")
        XCTAssertEqual(MissionConsoleFormatting.relativeTime(now.addingTimeInterval(-7_200), reference: now), "2h ago")
    }
}

final class MissionConsoleSnapshotTests: XCTestCase {
    func test_emptyDefault() {
        let snap = MissionConsoleSnapshot.empty
        XCTAssertTrue(snap.activeTiles.isEmpty)
        XCTAssertTrue(snap.recentTicker.isEmpty)
        XCTAssertEqual(snap.health.openMissions, 0)
    }

    func test_activeTilePhaseTriagesCorrectly() {
        let phases: [MissionConsoleActiveTile.Phase] = [
            .queued, .starting, .running, .tooling, .streaming, .completing,
            .awaitingApproval, .completed, .failed, .blocked, .macOffline, .cancelled
        ]
        for phase in phases {
            switch phase {
            case .completed, .failed, .blocked, .macOffline, .cancelled:
                XCTAssertFalse(phase.isLive, "\(phase) should not be live")
            default:
                XCTAssertTrue(phase.isLive, "\(phase) should be live")
            }
        }
        XCTAssertTrue(MissionConsoleActiveTile.Phase.failed.isProblem)
        XCTAssertTrue(MissionConsoleActiveTile.Phase.blocked.isProblem)
        XCTAssertFalse(MissionConsoleActiveTile.Phase.running.isProblem)
    }
}
