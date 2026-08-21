import XCTest
@testable import OpenBurnBar

@MainActor
final class LiveFleetModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeModel() -> LiveFleetModel { LiveFleetModel() }

    // MARK: - Merge

    func test_watcherEvidenceBeatsParsedUsage() {
        // Both describe the same event, but the watcher saw it seconds ago and
        // the parser saw it at the last scan. Taking the *newer* of the two
        // would be wrong exactly when the parser is behind — its normal state.
        let model = makeModel()
        model.recordWrite(provider: .claudeCode, at: now.addingTimeInterval(-5), path: "a.jsonl")

        model.rebuild(
            providers: [.claudeCode],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 1,
            now: now
        )

        guard case .wroteRecently(_, let source) = model.rows.first?.liveness else {
            XCTFail("Expected a recent write, got \(String(describing: model.rows.first?.liveness))")
            return
        }
        if case .sessionLogWrite = source { } else {
            XCTFail("The watcher's evidence should win over the parsed row")
        }
    }

    func test_gatewayUsageDoesNotMarkApiBackedProvidersAsWrote() {
        let model = makeModel()
        let usage = TokenUsage(
            provider: .mimo,
            sessionId: "gateway-1",
            projectName: "OpenBurnBar Gateway",
            model: "mimo-v2",
            inputTokens: 10,
            outputTokens: 4,
            startTime: now.addingTimeInterval(-11),
            endTime: now.addingTimeInterval(-11)
        )

        model.rebuild(
            providers: [.mimo, .openAI, .deepSeek, .openBurnBar],
            presence: [:],
            busyLocation: [:],
            usages: [usage],
            usagesVersion: 1,
            now: now
        )

        for row in model.rows {
            if case .wroteRecently = row.liveness {
                XCTFail("\(row.provider.displayName) must not show wrote from a gateway usage row")
            }
            XCTAssertFalse(row.liveness.isActive)
        }
    }

    func test_unwatchableProviderReportsUnobservable() {
        let model = makeModel()
        model.recordUnwatchable(provider: .claudeCode, reason: "App Store build can't read agent logs")

        model.rebuild(
            providers: [.claudeCode],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 1,
            now: now
        )

        guard case .unobservable(let reason) = model.rows.first?.liveness else {
            XCTFail("An unwatchable provider must report why, not appear quiet")
            return
        }
        XCTAssertEqual(reason, "App Store build can't read agent logs")
    }

    // MARK: - Sleep gap

    func test_sleepGapSuppressesStaleTimestamps() {
        let model = makeModel()
        model.recordWrite(provider: .claudeCode, at: now.addingTimeInterval(-10), path: "a.jsonl")
        model.beginSleepGap()

        model.rebuild(
            providers: [.claudeCode],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 1,
            now: now
        )

        guard case .unobservable = model.rows.first?.liveness else {
            XCTFail("Pre-sleep timestamps must not render as current after a wake")
            return
        }
    }

    func test_firstPostWakeEventClearsTheSleepGap() {
        let model = makeModel()
        model.beginSleepGap()
        XCTAssertNotNil(model.sleepGapReason)

        model.recordWrite(provider: .claudeCode, at: now, path: "a.jsonl")
        XCTAssertNil(model.sleepGapReason, "Fresh evidence proves we are watching again")
    }

    // MARK: - Ordering

    func test_rowsRankByAttention() {
        let model = makeModel()
        model.recordWrite(provider: .codex, at: now, path: "b.jsonl")
        model.recordUnwatchable(provider: .cursorAgent, reason: "Not watched")

        model.rebuild(
            providers: [.cursorAgent, .codex, .claudeCode],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 1,
            now: now
        )

        // Active first, unobservable last.
        XCTAssertEqual(model.rows.first?.provider, .codex)
        XCTAssertEqual(model.rows.last?.provider, .cursorAgent)
    }

    func test_activeCountCountsOnlyRealActivity() {
        let model = makeModel()
        model.recordWrite(provider: .codex, at: now, path: "b.jsonl")
        model.recordUnwatchable(provider: .cursorAgent, reason: "Not watched")

        model.rebuild(
            providers: [.cursorAgent, .codex],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 1,
            now: now
        )

        XCTAssertEqual(model.activeCount, 1, "An unobservable agent is not an active agent")
    }

    // MARK: - Usage memo

    /// The O(n) usage scan must run once per `usagesVersion` tick, never per
    /// render — `dataStore.usages` can be six figures and this panel is on the
    /// launch surface.
    func test_usageScanIsMemoizedOnVersion() {
        let model = makeModel()
        model.rebuild(
            providers: [.claudeCode],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 7,
            now: now
        )
        let firstScan = model.lastScanAt

        model.rebuild(
            providers: [.claudeCode],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 7,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(model.lastScanAt, firstScan, "An unchanged version must not re-scan")

        model.rebuild(
            providers: [.claudeCode],
            presence: [:],
            busyLocation: [:],
            usages: [],
            usagesVersion: 8,
            now: now.addingTimeInterval(120)
        )
        XCTAssertNotEqual(model.lastScanAt, firstScan, "A new version must re-scan")
    }

    // MARK: - Backend mapping

    func test_backendMappingIsOneToOne() {
        let map = LiveFleetModel.backendsByProvider()
        XCTAssertEqual(map[.claudeCode], .claude)
        XCTAssertEqual(map[.codex], .codex)
    }

    // MARK: - Display paths

    func test_displayPathIsRelativeToTheWatchedRoot() {
        let root = URL(fileURLWithPath: "/Users/x/.claude/projects", isDirectory: true)
        let file = URL(fileURLWithPath: "/Users/x/.claude/projects/BurnBar/session.jsonl")

        XCTAssertEqual(
            ProviderSessionActivityWatcher.displayPath(for: file, root: root),
            "BurnBar/session.jsonl",
            "Tooltips must not leak an absolute home-directory path"
        )
    }

    func test_displayPathFallsBackToTheFilename() {
        let root = URL(fileURLWithPath: "/Users/x/.claude/projects", isDirectory: true)
        let file = URL(fileURLWithPath: "/elsewhere/session.jsonl")

        XCTAssertEqual(ProviderSessionActivityWatcher.displayPath(for: file, root: root), "session.jsonl")
    }
}
