import XCTest
import Foundation

@MainActor
final class RemoteMCPConnectedClientsUITests: XCTestCase {
    private struct LiveConfiguration: Decodable {
        let uid: String
        let customToken: String
        let clientID: String
        let clientName: String?
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSignedInCloudMemberCanSeeAndRevokeRemoteMCPClient() throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try liveConfiguration(environment: environment)
        let uid = configuration.uid
        let token = configuration.customToken
        let clientID = configuration.clientID
        let displayName = configuration.clientName ?? "OpenBurnBar MCP E2E Client"

        let app = XCUIApplication()
        app.launchEnvironment["OPENBURNBAR_E2E_FIREBASE_UID"] = uid
        app.launchEnvironment["OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN"] = token
        app.launchEnvironment["OPENBURNBAR_E2E_REMOTE_MCP_CLIENT_ID"] = clientID
        app.launchEnvironment["OPENBURNBAR_E2E_ROUTE"] = "cloud-store"
        app.launchEnvironment["OPENBURNBAR_USE_DEBUG_APP_CHECK"] = "1"
        forwardIfPresent("FirebaseAppCheckDebugToken", from: environment, to: app)
        forwardIfPresent("FIRAAppCheckDebugToken", from: environment, to: app)
        forwardIfPresent("FIREBASE_APP_CHECK_DEBUG_TOKEN", from: environment, to: app)
        app.launch()

        let connectedClientsTitle = app.staticTexts["cloudStore.remoteMCP.connectedClients.title"]
        XCTAssertTrue(
            waitForExistence(connectedClientsTitle, timeout: 75, scrollingIn: app),
            "The signed-in Cloud Store did not render the connected MCP clients section. \(app.debugDescription)"
        )

        let clientName = app.staticTexts["cloudStore.remoteMCP.client.\(clientID).displayName"]
        XCTAssertTrue(
            waitForExistence(clientName, timeout: 45, scrollingIn: app),
            "The seeded remote MCP client named \(displayName) did not appear for the signed-in user. \(app.debugDescription)"
        )

        let revokeButton = app.buttons["cloudStore.remoteMCP.client.\(clientID).revoke"]
        scrollUntilHittable(revokeButton, in: app)
        XCTAssertTrue(revokeButton.isHittable, "The revoke button for \(displayName) was not hittable.")
        revokeButton.tap()

        let confirmButton = app.buttons["cloudStore.remoteMCP.confirmRevoke"]
        let fallbackConfirmButton = app.buttons["Revoke \(displayName)"]
        if confirmButton.waitForExistence(timeout: 5) {
            confirmButton.tap()
        } else {
            XCTAssertTrue(
                fallbackConfirmButton.waitForExistence(timeout: 5),
                "The revoke confirmation action did not appear."
            )
            fallbackConfirmButton.tap()
        }

        XCTAssertTrue(
            app.staticTexts["Revoked"].waitForExistence(timeout: 30),
            "The connected MCP client row did not update to the revoked state."
        )
    }

    private func liveConfiguration(environment: [String: String]) throws -> LiveConfiguration {
        if let uid = trimmedValue("OPENBURNBAR_E2E_FIREBASE_UID", in: environment),
           let customToken = trimmedValue("OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN", in: environment),
           let clientID = trimmedValue("OPENBURNBAR_E2E_REMOTE_MCP_CLIENT_ID", in: environment) {
            return LiveConfiguration(
                uid: uid,
                customToken: customToken,
                clientID: clientID,
                clientName: trimmedValue("OPENBURNBAR_E2E_REMOTE_MCP_CLIENT_NAME", in: environment)
            )
        }

        let configPath = environment["OPENBURNBAR_E2E_CONFIG_PATH"]
            ?? "/Users/albertonunez/Documents/Windsurf/BurnBar/build/remote-mcp-mobile-e2e.json"
        let url = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Live Firebase Remote MCP UI proof requires E2E env vars or \(url.path).")
        }
        let data = try Data(contentsOf: url)
        let configuration = try JSONDecoder().decode(LiveConfiguration.self, from: data)
        guard !configuration.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.customToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("Live Firebase Remote MCP UI proof config is missing uid, customToken, or clientID.")
        }
        return configuration
    }

    private func trimmedValue(_ key: String, in environment: [String: String]) -> String? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<8 where !element.isHittable {
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
        }
    }

    private func waitForExistence(_ element: XCUIElement, timeout: TimeInterval, scrollingIn app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let scrollView = app.scrollViews.firstMatch
        while Date() < deadline {
            if element.exists { return true }
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        return element.exists
    }

    private func forwardIfPresent(_ key: String, from environment: [String: String], to app: XCUIApplication) {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return
        }
        switch key {
        case "FIREBASE_APP_CHECK_DEBUG_TOKEN":
            app.launchEnvironment["FirebaseAppCheckDebugToken"] = value
            app.launchEnvironment["FIRAAppCheckDebugToken"] = value
        default:
            app.launchEnvironment[key] = value
        }
    }
}
