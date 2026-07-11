import Foundation
import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseLocalQuotaLedgerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("computer-use-ledger-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultDirectoryUsesApplicationSupportHierarchy() {
        let directory = ComputerUseLocalQuotaLedger.defaultDirectory(environment: [:])

        #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        XCTAssertEqual(
            directory,
            applicationSupport
                .appendingPathComponent("OpenBurnBar", isDirectory: true)
                .appendingPathComponent("computer-use", isDirectory: true)
                .appendingPathComponent("quota-ledger", isDirectory: true)
        )
        #else
        XCTAssertEqual(Array(directory.pathComponents.suffix(3)), ["OpenBurnBar", "computer-use", "quota-ledger"])
        #endif
    }

    func testSupportDirectoryOverrideTakesPrecedence() {
        let directory = ComputerUseLocalQuotaLedger.defaultDirectory(environment: [
            "OPENBURNBAR_DAEMON_SUPPORT_DIR": "/custom/openburnbar"
        ])

        XCTAssertEqual(
            directory,
            URL(fileURLWithPath: "/custom/openburnbar", isDirectory: true)
                .appendingPathComponent("computer-use", isDirectory: true)
                .appendingPathComponent("quota-ledger", isDirectory: true)
        )
    }

    func testActionReservationIsDurableAndIdempotent() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let first = ComputerUseLocalQuotaLedger(directory: directory)
        let inserted = try first.reserveAction(
            idempotencyKey: "session-1|call-1",
            actionClass: .browser,
            originatedFromPhone: true,
            recordedAt: date
        )
        XCTAssertTrue(inserted.inserted)
        XCTAssertEqual(inserted.usage.browserActionsExecuted, 1)
        XCTAssertEqual(inserted.usage.phoneControlIntentsExecuted, 1)

        let afterRestart = ComputerUseLocalQuotaLedger(directory: directory)
        let replay = try afterRestart.reserveAction(
            idempotencyKey: "session-1|call-1",
            actionClass: .browser,
            originatedFromPhone: true,
            recordedAt: date
        )
        XCTAssertFalse(replay.inserted)
        XCTAssertEqual(replay.usage.browserActionsExecuted, 1)
        XCTAssertEqual(replay.usage.phoneControlIntentsExecuted, 1)
    }

    func testSessionReservationsAreIndependentlyIdempotent() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let endedAt = date.addingTimeInterval(42)
        let ledger = ComputerUseLocalQuotaLedger(directory: directory)
        XCTAssertTrue(try ledger.reserveSession(idempotencyKey: "session-1", startedAt: date).inserted)
        XCTAssertFalse(try ledger.reserveSession(idempotencyKey: "session-1", startedAt: date).inserted)
        XCTAssertTrue(try ledger.completeSession(
            idempotencyKey: "session-1",
            startedAt: date,
            endedAt: endedAt
        ).inserted)
        XCTAssertFalse(try ledger.completeSession(
            idempotencyKey: "session-1",
            startedAt: date,
            endedAt: endedAt
        ).inserted)
        let usage = try ledger.usage(dayKey: ComputerUseLocalQuotaLedger.dayKeyUTC(for: endedAt))
        XCTAssertEqual(usage.sessionsStarted, 1)
        XCTAssertEqual(usage.sessionsCompleted, 1)
        XCTAssertEqual(usage.totalSessionSeconds, 42)
    }

    func testReservationReconcilesServerUsageAndEnforcesCapsAtomically() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let dayKey = ComputerUseLocalQuotaLedger.dayKeyUTC(for: date)
        let ledger = ComputerUseLocalQuotaLedger(directory: directory)
        let serverUsage = ComputerUseQuotaUsage(
            dayKey: dayKey,
            browserActionsExecuted: 2,
            sessionsStarted: 1
        )

        XCTAssertThrowsError(try ledger.reserveAction(
            idempotencyKey: "action-over-cap",
            actionClass: .browser,
            originatedFromPhone: false,
            authoritativeUsage: serverUsage,
            maximumMeteredActions: 2,
            recordedAt: date
        )) { error in
            XCTAssertEqual(error as? ComputerUseLocalQuotaLedger.LedgerError, .quotaExceeded)
        }
        XCTAssertThrowsError(try ledger.reserveSession(
            idempotencyKey: "session-over-cap",
            authoritativeUsage: serverUsage,
            maximumSessions: 1,
            startedAt: date
        )) { error in
            XCTAssertEqual(error as? ComputerUseLocalQuotaLedger.LedgerError, .quotaExceeded)
        }
        XCTAssertEqual(try ledger.usage(dayKey: dayKey), serverUsage)
    }

    func testDirectPhoneActionsAreTrackedButDoNotConsumeMeteredCap() throws {
        let date = Date(timeIntervalSince1970: 1_784_000_000)
        let ledger = ComputerUseLocalQuotaLedger(directory: directory)

        let reservation = try ledger.reserveAction(
            idempotencyKey: "phone-action",
            actionClass: .system,
            originatedFromPhone: true,
            maximumMeteredActions: 0,
            recordedAt: date
        )

        XCTAssertTrue(reservation.inserted)
        XCTAssertEqual(reservation.usage.systemActionsExecuted, 1)
        XCTAssertEqual(reservation.usage.phoneControlIntentsExecuted, 1)
        XCTAssertEqual(reservation.usage.totalMeteredActionsExecuted, 0)
    }

    func testCorruptLedgerFailsClosed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dayKey = "2026-07-10"
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("\(dayKey).json"))
        let ledger = ComputerUseLocalQuotaLedger(directory: directory)
        XCTAssertThrowsError(try ledger.usage(dayKey: dayKey)) { error in
            XCTAssertEqual(error as? ComputerUseLocalQuotaLedger.LedgerError, .corruptLedger)
        }
    }

    func testMonotonicMaximumCannotLaunderLocalUsage() {
        let local = ComputerUseQuotaUsage(
            dayKey: "2026-07-10",
            browserActionsExecuted: 8,
            systemActionsExecuted: 3,
            sessionsStarted: 2,
            visionModelSpendUSD: 1.5
        )
        let delayedServer = ComputerUseQuotaUsage(
            dayKey: "2026-07-10",
            browserActionsExecuted: 2,
            systemActionsExecuted: 5,
            sessionsStarted: 1,
            visionModelSpendUSD: 0.5
        )
        let merged = delayedServer.monotonicMaximum(with: local)
        XCTAssertEqual(merged.browserActionsExecuted, 8)
        XCTAssertEqual(merged.systemActionsExecuted, 5)
        XCTAssertEqual(merged.sessionsStarted, 2)
        XCTAssertEqual(merged.visionModelSpendUSD, 1.5)
    }

    func testInvalidDayKeyCannotEscapeLedgerDirectory() {
        let ledger = ComputerUseLocalQuotaLedger(directory: directory)
        XCTAssertThrowsError(try ledger.usage(dayKey: "../../secrets")) { error in
            XCTAssertEqual(error as? ComputerUseLocalQuotaLedger.LedgerError, .invalidDayKey)
        }
    }
}
