#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import UserNotifications
@testable import OpenBurnBar

/// Fences the "first launch asks for nothing" invariant.
///
/// These are cheap tests guarding an expensive-to-notice regression: a single new
/// `requestAuthorization` or `NWListener` on the startup path is invisible in review,
/// invisible in a normal build, and only shows up as a scary dialog on someone else's
/// clean Mac after they install the app.
@MainActor
final class LaunchPermissionQuietnessTests: XCTestCase {

    // MARK: Notifications

    /// Records whether macOS was asked, without ever asking it.
    private final class RecordingAuthorizer: NotificationAuthorizing, @unchecked Sendable {
        var status: UNAuthorizationStatus
        private(set) var requestCount = 0
        private(set) var statusReadCount = 0

        init(status: UNAuthorizationStatus) { self.status = status }

        func currentStatus() async -> UNAuthorizationStatus {
            statusReadCount += 1
            return status
        }

        func requestAuthorization() async -> Bool {
            requestCount += 1
            status = .authorized
            return true
        }
    }

    func test_notDeterminedPromptsExactlyOnce() async {
        let authorizer = RecordingAuthorizer(status: .notDetermined)
        let granted = await Self.ensure(authorizer)
        XCTAssertTrue(granted)
        XCTAssertEqual(authorizer.requestCount, 1)
    }

    /// A user who already said no must never be asked again. Re-asking is how apps
    /// teach people to distrust them.
    func test_deniedIsNeverReAsked() async {
        let authorizer = RecordingAuthorizer(status: .denied)
        let granted = await Self.ensure(authorizer)
        XCTAssertFalse(granted)
        XCTAssertEqual(authorizer.requestCount, 0, "a prior denial must be respected silently")
    }

    func test_alreadyAuthorizedDoesNotPrompt() async {
        let authorizer = RecordingAuthorizer(status: .authorized)
        let granted = await Self.ensure(authorizer)
        XCTAssertTrue(granted)
        XCTAssertEqual(authorizer.requestCount, 0)
    }

    /// Mirrors `MacAgentReplyNotificationListener.ensureNotificationAuthorization`.
    /// Kept in the test rather than exposing the private method, so the test asserts
    /// the *policy* (only `.notDetermined` prompts) rather than binding to internals.
    private static func ensure(_ authorizer: NotificationAuthorizing) async -> Bool {
        switch await authorizer.currentStatus() {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined: return await authorizer.requestAuthorization()
        @unknown default: return false
        }
    }

    // MARK: Source-level guards
    //
    // The startup path is a graph of singletons and Firebase listeners that cannot be
    // stood up in a unit test. Asserting on the source is blunt, but it catches the
    // exact regression that matters and it cannot silently rot: if someone reinstates
    // an eager request, this fails with a message explaining why.

    func test_notificationListenerDoesNotRequestAuthorizationDuringStart() throws {
        let source = try Self.appSource("Services/Chat/MacAgentReplyNotificationListener.swift")
        let start = try XCTUnwrap(Self.body(ofFunctionStartingWith: "func start(chatController:", in: source))
        XCTAssertFalse(
            start.contains("requestAuthorization") || start.contains("requestNotificationAuthorization"),
            """
            MacAgentReplyNotificationListener.start() must not ask for notification \
            authorization. Launching the app is not a reason to ask for anything -- the \
            request belongs in deliver(), where an actual agent reply exists to show.
            """
        )
    }

    func test_pixelClockDoesNotBindItsListenerUnconditionally() throws {
        let source = try Self.appSource("Services/SmartHub/PixelClockController.swift")
        let start = try XCTUnwrap(Self.body(ofFunctionStartingWith: "func start()", in: source))
        XCTAssertTrue(
            start.contains("settingsManager.pixelClockConfig.enabled"),
            """
            PixelClockController.start() must gate stockSimulator.start() on the feature \
            being enabled. An unconditional all-interfaces NWListener triggers the macOS \
            Local Network prompt for users who never touched Pixel Clock.
            """
        )
    }

    func test_textExpansionDoesNotPromptForAccessibilityOnTheLaunchPath() throws {
        let source = try Self.appSource("Services/TextExpansion/TextExpansionRuntimeController.swift")
        let reconcile = try XCTUnwrap(Self.body(ofFunctionStartingWith: "private func reconcileEventTap()", in: source))
        XCTAssertFalse(
            reconcile.contains("promptAndOpenSettings"),
            """
            reconcileEventTap() runs at launch. It must publish needsAccessibilityGrant \
            instead of firing the Accessibility prompt and force-opening System Settings.
            """
        )
    }

    // MARK: Helpers

    private static func appSource(_ relativePath: String) throws -> String {
        // AgentLensTests/Active/<this file> -> repo root -> AgentLens/<relativePath>
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Active
            .deletingLastPathComponent()   // AgentLensTests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("AgentLens").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Returns the brace-balanced body of the first function whose declaration starts
    /// with `prefix`, so a match inside a *different* function cannot pass or fail a test.
    private static func body(ofFunctionStartingWith prefix: String, in source: String) -> String? {
        guard let declRange = source.range(of: prefix) else { return nil }
        guard let openBrace = source[declRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[openBrace...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
#endif
