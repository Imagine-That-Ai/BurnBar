import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBar

/// The first 60 seconds, pinned.
///
/// The contract these tests defend is not "the screen renders" — it is that
/// **the screen can never show a percentage it did not measure.** A fabricated
/// ring on first run would be the single most expensive lie this product could
/// tell, because it is told to a stranger on the one screen whose whole job is
/// to earn belief that the numbers came off their own disk.
@MainActor
final class FirstRunRevealModelTests: XCTestCase {

    // MARK: Fixtures

    private func bucket(
        key: String = "weekly",
        label: String = "weekly",
        usedPercent: Double?,
        resetsAt: Date? = nil,
        isEstimated: Bool = false
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: .weekly,
            usedValue: nil,
            limitValue: nil,
            remainingValue: nil,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            unit: .percent,
            isEstimated: isEstimated
        )
    }

    private func snapshot(
        provider: String,
        buckets: [ProviderQuotaBucket],
        confidence: ProviderQuotaConfidence = .high
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: "snapshot-\(provider)",
            provider: provider,
            sourceKind: .localSession,
            sourceId: "source-\(provider)",
            fetchedAt: Date(),
            source: "test",
            confidence: confidence,
            managementURL: nil,
            statusMessage: nil,
            buckets: buckets,
            schemaVersion: 1,
            updatedAt: Date()
        )
    }

    // MARK: The honesty contract

    func test_coldInstall_tokenCountsWithoutCaps_neverProduceAPercentage() {
        // The real cold-install shape: Claude Code JSONL parsed fine, but with
        // no credentials there is no plan cap, so every bucket is capless.
        // This is the exact state the original spec's four-percentage hero
        // assumed away.
        let capless = snapshot(provider: "Claude Code", buckets: [bucket(usedPercent: nil)])
        XCTAssertNil(
            TightestQuotaWindow.tightest(across: [capless]),
            "A bucket with no real percentage must never be promoted to a window."
        )

        let model = FirstRunRevealModel(searchedPathCount: 32)
        model.ingest(
            snapshots: [capless],
            monthToDateUSD: 312.40,
            sessionCount: 1_284,
            detectedProviderDisplayNames: ["Claude Code", "Codex"]
        )

        guard case .spend(let hero) = model.phase else {
            XCTFail("Cold install with real usage must land on the spend hero, got \(model.phase)")
            return
        }
        XCTAssertEqual(hero.monthToDateUSD, 312.40, accuracy: 0.001)
        XCTAssertEqual(hero.sessionCount, 1_284)
        XCTAssertTrue(hero.expectsQuotaSignalSoon, "Detected agents mean the percentage is genuinely coming.")
    }

    func test_realBucket_landsOnQuotaHero() {
        let model = FirstRunRevealModel(searchedPathCount: 32)
        model.ingest(
            snapshots: [snapshot(provider: "Claude Code", buckets: [bucket(usedPercent: 62)])],
            monthToDateUSD: 312.40,
            sessionCount: 1_284,
            detectedProviderDisplayNames: ["Claude Code"]
        )

        guard case .quota(let window, _) = model.phase else {
            XCTFail("A real bucket must land on the quota hero, got \(model.phase)")
            return
        }
        XCTAssertEqual(window.displayPercent, 38, "100 − 62 used = 38 remaining.")
    }

    // MARK: Selection

    func test_tightest_picksLowestRemaining_acrossVendors() {
        let claude = snapshot(provider: "Claude Code", buckets: [bucket(usedPercent: 62)])   // 38 left
        let codex = snapshot(provider: "Codex", buckets: [bucket(usedPercent: 29)])          // 71 left
        let antigravity = snapshot(provider: "Antigravity", buckets: [bucket(usedPercent: 81)]) // 19 left

        let window = TightestQuotaWindow.tightest(across: [claude, codex, antigravity])
        XCTAssertEqual(window?.providerDisplayName, "Antigravity")
        XCTAssertEqual(window?.displayPercent, 19)
        XCTAssertEqual(window?.comparedProviderCount, 3, "The 'across N agents' claim must be counted, not asserted.")
    }

    func test_tightest_tieBreaksToTheWindowThatResetsSoonest() {
        let soon = Date().addingTimeInterval(30 * 60)
        let later = Date().addingTimeInterval(6 * 3600)
        let a = snapshot(provider: "A", buckets: [bucket(usedPercent: 60, resetsAt: later)])
        let b = snapshot(provider: "B", buckets: [bucket(usedPercent: 60, resetsAt: soon)])

        let window = TightestQuotaWindow.tightest(across: [a, b])
        XCTAssertEqual(
            window?.providerDisplayName, "B",
            "Equal pressure resolves to the window that constrains the next hour."
        )
    }

    func test_caplessProviderCannotWinAgainstAMeasuredOne() {
        // The dangerous case: an unmeasurable provider must be excluded, not
        // sorted last — otherwise a nil could ever win a comparison about
        // measurement.
        let measured = snapshot(provider: "Measured", buckets: [bucket(usedPercent: 95)]) // 5 left
        let capless = snapshot(provider: "Capless", buckets: [bucket(usedPercent: nil)])

        let window = TightestQuotaWindow.tightest(across: [measured, capless])
        XCTAssertEqual(window?.providerDisplayName, "Measured")
        XCTAssertEqual(window?.comparedProviderCount, 1, "Only providers with a real signal are compared.")
    }

    func test_estimatedFidelity_survivesIntoTheWindow() {
        let estimated = snapshot(provider: "Copilot", buckets: [bucket(usedPercent: 40, isEstimated: true)])
        XCTAssertEqual(TightestQuotaWindow.tightest(across: [estimated])?.isEstimated, true)

        // A stale snapshot is likewise not presentable as exact.
        let stale = snapshot(provider: "Warp", buckets: [bucket(usedPercent: 40)], confidence: .stale)
        XCTAssertEqual(TightestQuotaWindow.tightest(across: [stale])?.isEstimated, true)
    }

    func test_pressureBands() {
        func window(_ percent: Double) -> TightestQuotaWindow {
            TightestQuotaWindow(
                providerDisplayName: "P", windowLabel: "w",
                remainingPercent: percent, resetsAt: nil,
                isEstimated: false, comparedProviderCount: 1
            )
        }
        XCTAssertEqual(window(9).pressure, .critical)
        XCTAssertEqual(window(30).pressure, .tightening)
        XCTAssertEqual(window(80).pressure, .comfortable)
    }

    func test_displayPercent_floorsRatherThanRounding() {
        let window = TightestQuotaWindow(
            providerDisplayName: "P", windowLabel: "w",
            remainingPercent: 38.9, resetsAt: nil,
            isEstimated: false, comparedProviderCount: 1
        )
        XCTAssertEqual(window.displayPercent, 38, "Never round a remaining budget up.")
    }

    // MARK: Degrade + settling

    func test_emptyStore_degradesToTheReassuringScreen() {
        let model = FirstRunRevealModel(searchedPathCount: 32)
        model.ingest(snapshots: [], monthToDateUSD: 0, sessionCount: 0, detectedProviderDisplayNames: [])
        guard case .scanning = model.phase else {
            XCTFail("An empty store keeps scanning until the ceiling fires, got \(model.phase)")
            return
        }

        model.degrade()
        guard case .empty(let count) = model.phase else {
            XCTFail("Expected the empty reveal, got \(model.phase)")
            return
        }
        XCTAssertEqual(count, 32, "The 'I looked in N places' count is rendered live.")
    }

    func test_terminalPhase_neverRegresses() {
        let model = FirstRunRevealModel(searchedPathCount: 32)
        model.ingest(
            snapshots: [snapshot(provider: "Claude Code", buckets: [bucket(usedPercent: 62)])],
            monthToDateUSD: 10, sessionCount: 5, detectedProviderDisplayNames: ["Claude Code"]
        )

        // A late degrade timer, or more progress arriving, must not pull a
        // landed reveal back to a spinner or an empty state.
        model.degrade()
        model.reportProgress(fraction: 0.2)
        guard case .quota = model.phase else {
            XCTFail("A landed reveal must be terminal, got \(model.phase)")
            return
        }
    }

    func test_supportingRows_capAtThree_andNeverFabricateAPercent() {
        let hero = snapshot(provider: "Hero", buckets: [bucket(usedPercent: 90)]) // 10 left
        let others = (1...5).map { index in
            snapshot(provider: "P\(index)", buckets: [bucket(usedPercent: Double(index) * 5)])
        }
        let capless = snapshot(provider: "Capless", buckets: [bucket(usedPercent: nil)])

        let model = FirstRunRevealModel(searchedPathCount: 32)
        model.ingest(
            snapshots: [hero] + others + [capless],
            monthToDateUSD: 1, sessionCount: 1, detectedProviderDisplayNames: []
        )

        guard case .quota(_, let supporting) = model.phase else {
            XCTFail("Expected the quota hero, got \(model.phase)")
            return
        }
        XCTAssertLessThanOrEqual(supporting.count, 3, "A fourth row turns a glance into reading.")
        XCTAssertFalse(
            supporting.contains { $0.providerDisplayName == "Hero" },
            "The hero must not repeat itself in its own supporting list."
        )
    }
}
