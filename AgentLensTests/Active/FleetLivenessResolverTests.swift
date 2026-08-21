import XCTest
@testable import OpenBurnBar

/// The fleet resolver's contract.
///
/// The **negative** invariants below are the point of this suite, and of the
/// feature: a fleet panel that renders a confident "running" for an agent it
/// cannot see, or prints "idle" for one that simply wasn't watched, is worse
/// than no panel at all. Those assertions should be the last thing anyone
/// weakens.
///
/// Every case runs on a fixed clock — `resolve(_:now:)` takes its `now` — so
/// there is no sleeping anywhere in this file.
final class FleetLivenessResolverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Negative invariants

    func test_neverReportsRunningWithoutAnInAppController() {
        // Every combination of external evidence we can produce.
        let externalSources: [FleetEvidenceSource] = [
            .statuslineSnapshot,
            .sessionLogWrite("projects/BurnBar/session.jsonl"),
            .processLatch("~/.junie/processes/1.json"),
            .parsedUsageRow
        ]

        for source in externalSources {
            for age in [0.0, 1.0, 30.0, 89.0, 91.0, 3_600.0] {
                var evidence = FleetLivenessResolver.Evidence()
                evidence.lastWrite = (now.addingTimeInterval(-age), source)
                let liveness = FleetLivenessResolver.resolve(evidence, now: now)

                if case .workingHere = liveness {
                    XCTFail("External evidence (\(source), age \(age)) must never resolve to .workingHere")
                }
            }
        }
    }

    func test_missingEvidenceIsUnobservableNotQuiet() {
        let liveness = FleetLivenessResolver.resolve(FleetLivenessResolver.Evidence(), now: now)

        guard case .unobservable = liveness else {
            XCTFail("No evidence must resolve to .unobservable, got \(liveness)")
            return
        }
    }

    func test_noStateEverRendersTheWordIdle() {
        // Exhaustive over every state the resolver can produce.
        let states: [FleetLiveness] = [
            .workingHere(.streaming(since: now), location: "Tab 2"),
            .workingHere(.thinking(since: now), location: nil),
            .wroteRecently(at: now, source: .parsedUsageRow),
            .quietSince(now.addingTimeInterval(-600), source: .parsedUsageRow),
            .standingBy,
            .blocked(.needsAuth(.cliConsent)),
            .blocked(.exhausted),
            .blocked(.notInstalled),
            .blocked(.offline),
            .unobservable(reason: "Not watched")
        ]

        for state in states {
            let phrase = FleetCopy.phrase(for: state, now: now).lowercased()
            XCTAssertFalse(phrase.contains("idle"), "\(state) rendered as \"\(phrase)\" — the panel must never say idle")
        }
    }

    func test_unobservableWinsOverStaleWrites() {
        // The display-sleep case: a timestamp from before the machine stopped
        // watching must not be rendered as if it were current.
        var evidence = FleetLivenessResolver.Evidence()
        evidence.lastWrite = (now.addingTimeInterval(-30), .sessionLogWrite("a.jsonl"))
        evidence.unobservableReason = "Not watched while asleep"

        guard case .unobservable(let reason) = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("A sleep gap must suppress a stale write")
            return
        }
        XCTAssertEqual(reason, "Not watched while asleep")
    }

    func test_liveInAppTurnSurvivesASleepGap() {
        // A turn this app is driving is observed directly, so it stays true
        // even while the watchers are torn down.
        var evidence = FleetLivenessResolver.Evidence()
        evidence.presence = .streaming(since: now.addingTimeInterval(-5))
        evidence.unobservableReason = "Not watched while asleep"

        guard case .workingHere = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("An in-app turn must outrank a sleep gap")
            return
        }
    }

    // MARK: - Classification

    func test_writeInsideActiveWindowIsRecent() {
        var evidence = FleetLivenessResolver.Evidence()
        evidence.lastWrite = (
            now.addingTimeInterval(-(FleetWindow.active - 1)),
            .sessionLogWrite("session.jsonl")
        )

        guard case .wroteRecently = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("A write inside the active window is recent")
            return
        }
    }

    func test_writeOutsideActiveWindowIsQuiet() {
        var evidence = FleetLivenessResolver.Evidence()
        evidence.lastWrite = (
            now.addingTimeInterval(-(FleetWindow.active + 1)),
            .sessionLogWrite("session.jsonl")
        )

        guard case .quietSince = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("A write outside the active window is quiet — but still not idle")
            return
        }
    }

    func test_parsedUsageIsNeverWroteRecently() {
        var evidence = FleetLivenessResolver.Evidence()
        evidence.lastWrite = (now.addingTimeInterval(-5), .parsedUsageRow)

        guard case .quietSince = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("Gateway/API usage rows must not light a row as wrote")
            return
        }
    }

    func test_blockedBeatsActivityEvidence() {
        // "Needs sign-in" is actionable and stays true; "wrote 4m ago" is not.
        var evidence = FleetLivenessResolver.Evidence()
        evidence.presence = .needsAuth(.cliConsent)
        evidence.lastWrite = (now.addingTimeInterval(-10), .sessionLogWrite("a.jsonl"))

        guard case .blocked = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("A blocked agent must report the block, not the write")
            return
        }
    }

    func test_clockSkewDoesNotProduceAFutureWrite() {
        // An NTP correction can move `now` behind a recorded mtime.
        var evidence = FleetLivenessResolver.Evidence()
        evidence.lastWrite = (now.addingTimeInterval(120), .sessionLogWrite("a.jsonl"))

        guard case .wroteRecently = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("A future-dated write must degrade to recent, not to quiet")
            return
        }
    }

    func test_readyWithNoWritesIsStandingBy() {
        var evidence = FleetLivenessResolver.Evidence()
        evidence.presence = .ready

        guard case .standingBy = FleetLivenessResolver.resolve(evidence, now: now) else {
            XCTFail("A reachable agent we have simply not seen yet is standing by")
            return
        }
    }

    // MARK: - Copy

    func test_unobservableSaysNotWatched() {
        let phrase = FleetCopy.phrase(for: .unobservable(reason: "x"), now: now)
        XCTAssertEqual(phrase, "Not watched")
    }

    func test_footerNamesTheEvidenceFloor() {
        let live = FleetCopy.footer(hasRealTimeCoverage: true, sleepGapReason: nil, lastScanAt: now, now: now)
        XCTAssertTrue(live.contains("watched live"))

        let scanned = FleetCopy.footer(
            hasRealTimeCoverage: false,
            sleepGapReason: nil,
            lastScanAt: now.addingTimeInterval(-41),
            now: now
        )
        XCTAssertTrue(scanned.contains("last scan"), "Without watchers the footer must say the number is as of a scan")

        let asleep = FleetCopy.footer(
            hasRealTimeCoverage: true,
            sleepGapReason: "Not watched while asleep",
            lastScanAt: now,
            now: now
        )
        XCTAssertEqual(asleep, "Not watched while asleep")
    }

    func test_elapsedPhrasing() {
        XCTAssertEqual(FleetCopy.elapsed(since: now.addingTimeInterval(-12), now: now), "12s")
        XCTAssertEqual(FleetCopy.elapsed(since: now.addingTimeInterval(-360), now: now), "6m")
        XCTAssertEqual(FleetCopy.elapsed(since: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(FleetCopy.elapsed(since: now.addingTimeInterval(-172_800), now: now), "2d")
    }
}
