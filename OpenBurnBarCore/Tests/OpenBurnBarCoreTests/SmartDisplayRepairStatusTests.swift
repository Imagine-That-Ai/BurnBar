import XCTest
@testable import OpenBurnBarCore

final class SmartDisplayRepairStatusTests: XCTestCase {
    func testWorkingStatusIsTerminalAndHealthy() throws {
        let status = SmartDisplayDeviceRepairStatus(
            kind: .nestHub,
            phase: .working,
            message: "Nest Hub is showing OpenBurnBar.",
            proof: "state.json polled"
        )

        XCTAssertTrue(status.isTerminal)
        XCTAssertTrue(status.isHealthy)
        XCTAssertEqual(status.kind, .nestHub)
        XCTAssertEqual(status.proof, "state.json polled")
    }

    func testNeedsUserActionIsTerminalButNotHealthy() throws {
        let status = SmartDisplayDeviceRepairStatus(
            kind: .pixelClock,
            phase: .needsUserAction,
            message: "Flash AWTRIX Light to unlock direct control."
        )

        XCTAssertTrue(status.isTerminal)
        XCTAssertFalse(status.isHealthy)
    }

    func testRepairReportRequiresEveryStartedDeviceToReachTerminalState() throws {
        XCTAssertFalse(SmartDisplayRepairReport().allTerminal)

        let waitingClock = SmartDisplayDeviceRepairStatus(
            kind: .pixelClock,
            phase: .waitingForProof,
            message: "Waiting for the clock to poll."
        )
        let workingNestHub = SmartDisplayDeviceRepairStatus(
            kind: .nestHub,
            phase: .working,
            message: "Nest Hub is showing OpenBurnBar."
        )

        var report = SmartDisplayRepairReport(nestHub: workingNestHub, pixelClock: waitingClock)
        XCTAssertFalse(report.allTerminal)
        XCTAssertTrue(report.anyHealthy)

        report.pixelClock = SmartDisplayDeviceRepairStatus(
            kind: .pixelClock,
            phase: .failed,
            message: "Pixel Clock returned HTTP 500."
        )
        XCTAssertTrue(report.allTerminal)
        XCTAssertTrue(report.anyHealthy)
    }

    func testStatusRoundTripsThroughJSONForFirestorePayloads() throws {
        let status = SmartDisplayDeviceRepairStatus(
            kind: .nestHub,
            phase: .working,
            message: "Nest Hub polled /state.json after cast.",
            proof: "http://192.168.68.93:8787/state.json"
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SmartDisplayDeviceRepairStatus.self, from: data)

        XCTAssertEqual(decoded, status)
    }
}
