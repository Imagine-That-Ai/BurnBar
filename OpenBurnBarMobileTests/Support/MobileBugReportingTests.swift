import XCTest
@testable import OpenBurnBarMobile

final class MobileBugReportingTests: XCTestCase {
    func testMobileDiagnosticsCollectorCapturesValidSnapshot() {
        let snapshot = MobileDiagnosticsCollector.capture()

        XCTAssertFalse(snapshot.osVersion.isEmpty)
        XCTAssertFalse(snapshot.deviceModel.isEmpty)
        XCTAssertFalse(snapshot.appVersion.isEmpty)
        XCTAssertFalse(snapshot.appBuild.isEmpty)
        XCTAssertFalse(snapshot.timestamp.isEmpty)

        let dict = snapshot.asDictionary
        XCTAssertEqual(dict["osVersion"], snapshot.osVersion)
        XCTAssertEqual(dict["deviceModel"], snapshot.deviceModel)
    }

    func testMobileBugReportSubmissionModel() {
        let submission = MobileBugReportSubmission(
            title: "[Bug] App froze on chat",
            description: "Chat screen stopped responding to taps",
            platform: "iOS",
            appVersion: "1.4.0",
            osVersion: "iOS 18.2",
            deviceModel: "iPhone 16 Pro",
            diagnostics: ["battery": "0.85"],
            autoDispenseCLI: true,
            requestedRuntime: "claude"
        )

        XCTAssertEqual(submission.title, "[Bug] App froze on chat")
        XCTAssertEqual(submission.platform, "iOS")
        XCTAssertEqual(submission.appVersion, "1.4.0")
        XCTAssertEqual(submission.requestedRuntime, "claude")
        XCTAssertTrue(submission.autoDispenseCLI)
    }

    func testMobileBugReportSubmissionResultModel() {
        let result = MobileBugReportSubmissionResult(
            reportId: "rep_12345",
            linearIdentifier: "BB-55",
            linearUrl: "https://linear.app/openburnbar/issue/BB-55",
            isMock: true,
            missionId: "mission_bug_rep_12345"
        )

        XCTAssertEqual(result.reportId, "rep_12345")
        XCTAssertEqual(result.linearIdentifier, "BB-55")
        XCTAssertEqual(result.linearUrl, "https://linear.app/openburnbar/issue/BB-55")
        XCTAssertTrue(result.isMock)
        XCTAssertEqual(result.missionId, "mission_bug_rep_12345")
    }
}
