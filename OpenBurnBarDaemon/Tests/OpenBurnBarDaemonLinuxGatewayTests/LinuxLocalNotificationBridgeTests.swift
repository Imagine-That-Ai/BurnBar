#if os(Linux)
import Foundation
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxLocalNotificationBridgeTests: XCTestCase {
    func testDeliveryUsesFixedNotifySendArgumentsWithoutActions() async throws {
        let recorder = NotificationCommandRecorder()
        let adapter = LinuxLocalNotificationAdapter(
            executableAvailability: { _ in true },
            runCommand: { path, arguments in
                recorder.record(path: path, arguments: arguments)
                return LinuxLocalNotificationAdapter.CommandResult(exitCode: 0)
            }
        )
        let bridge = BurnBarLocalNotificationBridge(linuxAdapter: adapter)

        try await bridge.deliver(title: "New question", body: "Choose a path.\nOpenBurnBar")

        XCTAssertEqual(recorder.path, LinuxLocalNotificationAdapter.notifySendPath)
        XCTAssertEqual(
            recorder.arguments,
            [
                "--app-name=OpenBurnBar",
                "--urgency=normal",
                "--",
                "New question",
                "Choose a path.\nOpenBurnBar"
            ]
        )
        XCTAssertFalse(recorder.arguments.contains(where: { $0 == "--action" || $0.hasPrefix("x-openburnbar:") }))
    }

    func testMissingNotifySendIsReportedAsUnavailableAndDoesNotRunCommand() async {
        let recorder = NotificationCommandRecorder()
        let adapter = LinuxLocalNotificationAdapter(
            executableAvailability: { _ in false },
            runCommand: { path, arguments in
                recorder.record(path: path, arguments: arguments)
                return LinuxLocalNotificationAdapter.CommandResult(exitCode: 0)
            }
        )
        let bridge = BurnBarLocalNotificationBridge(linuxAdapter: adapter)

        XCTAssertEqual(adapter.availability(), .unavailable)
        do {
            try await bridge.deliver(title: "Title", body: "Body")
            XCTFail("delivery must fail closed when notify-send is unavailable")
        } catch let error as LinuxLocalNotificationAdapter.AdapterError {
            guard case .unavailable(let path) = error else {
                XCTFail("expected unavailable error, got \(error)")
                return
            }
            XCTAssertEqual(path, LinuxLocalNotificationAdapter.notifySendPath)
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(recorder.path)
    }

    func testValidationBoundsAndControlCharactersBeforeLaunching() {
        let invalidRecorder = NotificationCommandRecorder()
        let adapter = LinuxLocalNotificationAdapter(
            executableAvailability: { _ in true },
            runCommand: { path, arguments in
                invalidRecorder.record(path: path, arguments: arguments)
                return LinuxLocalNotificationAdapter.CommandResult(exitCode: 0)
            }
        )

        assertAdapterError(.emptyTitle) {
            try adapter.deliver(title: " \n\t ", body: "Body")
        }
        assertAdapterError(.emptyBody) {
            try adapter.deliver(title: "Title", body: " \n\t ")
        }
        assertAdapterError(.titleTooLong(maximumBytes: LinuxLocalNotificationAdapter.maximumTitleUTF8Bytes)) {
            try adapter.deliver(
                title: String(repeating: "t", count: LinuxLocalNotificationAdapter.maximumTitleUTF8Bytes + 1),
                body: "Body"
            )
        }
        assertAdapterError(.bodyTooLong(maximumBytes: LinuxLocalNotificationAdapter.maximumBodyUTF8Bytes)) {
            try adapter.deliver(
                title: "Title",
                body: String(repeating: "b", count: LinuxLocalNotificationAdapter.maximumBodyUTF8Bytes + 1)
            )
        }
        assertAdapterError(.titleContainsControlCharacter) {
            try adapter.deliver(title: "Title\u{0000}", body: "Body")
        }
        assertAdapterError(.bodyContainsControlCharacter) {
            try adapter.deliver(title: "Title", body: "Body\u{000B}")
        }
        XCTAssertNil(invalidRecorder.path)

        let validAdapter = LinuxLocalNotificationAdapter(
            executableAvailability: { _ in true },
            runCommand: { _, _ in LinuxLocalNotificationAdapter.CommandResult(exitCode: 0) }
        )
        XCTAssertNoThrow(try validAdapter.deliver(title: "Title", body: "First line\nSecond line"))
    }

    func testCommandFailureAndLaunchFailureAreSurfaced() {
        let commandFailure = LinuxLocalNotificationAdapter(
            executableAvailability: { _ in true },
            runCommand: { _, _ in
                LinuxLocalNotificationAdapter.CommandResult(exitCode: 2, stderr: "No notification service")
            }
        )
        assertAdapterError(.commandFailed(exitCode: 2, stderr: "No notification service")) {
            try commandFailure.deliver(title: "Title", body: "Body")
        }

        let launchFailure = LinuxLocalNotificationAdapter(
            executableAvailability: { _ in true },
            runCommand: { _, _ in
                throw NSError(
                    domain: "LinuxLocalNotificationBridgeTests",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "spawn failed"]
                )
            }
        )
        assertAdapterError(.launchFailed("spawn failed")) {
            try launchFailure.deliver(title: "Title", body: "Body")
        }
    }

    func testProcessRunnerTerminatesStalledNotifySendWithinBoundedTimeout() {
        assertAdapterError(.commandTimedOut(timeoutSeconds: 1)) {
            try LinuxLocalNotificationAdapter.runProcess(
                path: "/usr/bin/sleep",
                arguments: ["5"],
                timeout: 0.01,
                terminationGrace: 0.05
            )
        }
    }

    private func assertAdapterError(
        _ expected: LinuxLocalNotificationAdapter.AdapterError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("expected \(expected), but delivery succeeded", file: file, line: line)
        } catch let error as LinuxLocalNotificationAdapter.AdapterError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class NotificationCommandRecorder: @unchecked Sendable {
    private(set) var path: String?
    private(set) var arguments: [String] = []

    func record(path: String, arguments: [String]) {
        self.path = path
        self.arguments = arguments
    }
}
#endif
