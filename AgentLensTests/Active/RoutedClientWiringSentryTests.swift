import XCTest
@testable import OpenBurnBar

/// Coverage for the durability sentry that keeps Claude Code / Codex / Forge
/// / OpenCode / Droid wired through the local BurnBar gateway when external
/// tools (Claude Code's atomic settings.json rewrite, plugin installs, dotfile
/// syncs) strip the env block.
///
/// Every test runs against an isolated temp "home" and an isolated
/// `UserDefaults` suite so we never touch the developer's real config files
/// or app preferences.
final class RoutedClientWiringSentryTests: XCTestCase {

    private var tempHome: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: SettingsManager!
    private var sentry: RoutedClientWiringSentry!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-sentry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        suiteName = "openburnbar.sentry.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        await MainActor.run {
            self.settings = SettingsManager(defaults: self.defaults, flushDelayNanoseconds: 0)
            self.settings.gateway.gatewayHost = "127.0.0.1"
            self.settings.gateway.gatewayPort = 8317
            self.settings.gateway.gatewayAuthToken = ""
            self.settings.gateway.gatewayEnabled = true
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            self.sentry?.stop()
            self.sentry = nil
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
        defaults = nil
        settings = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Initial repair on start

    @MainActor
    func test_start_repairsEnrolledTargetWhenEnvBlockMissing() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stripped: [String: Any] = ["theme": "dark"]
        let strippedData = try JSONSerialization.data(withJSONObject: stripped)
        try strippedData.write(to: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertTrue(wiring.isWired(target: .claudeCode))
        let root = try loadJSONObject(at: url)
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:8317")
        XCTAssertEqual(env["OPENBURNBAR_WIRED"] as? String, "1")
        XCTAssertEqual(root["theme"] as? String, "dark", "non-BurnBar keys must survive repair")
        XCTAssertNotNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))
    }

    @MainActor
    func test_start_doesNotRepairWhenTargetNotEnrolled() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)

        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
    }

    @MainActor
    func test_start_doesNotRepairWhenAutoRepairDisabled() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        settings.routedClientWiring.autoRepairEnabled = false
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
    }

    @MainActor
    func test_start_doesNotRepairWhenGatewayDisabled() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        settings.gateway.gatewayEnabled = false
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
    }

    @MainActor
    func test_start_isNoOpWhenAlreadyWired() async throws {
        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .claudeCode,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        )
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        let preRepairData = try Data(contentsOf: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let postRepairData = try Data(contentsOf: url)
        XCTAssertEqual(preRepairData, postRepairData, "wired file must not be touched")
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))
    }

    // MARK: - Repair after external rewrite

    @MainActor
    func test_externalStripTriggersRepairViaSweep() async throws {
        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .claudeCode,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        )
        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let url = tempHome.appendingPathComponent(".claude/settings.json")
        let stripped: [String: Any] = ["theme": "dracula", "permissions": ["allow": ["Read"]]]
        let strippedData = try JSONSerialization.data(withJSONObject: stripped)
        try strippedData.write(to: url, options: [.atomic])
        XCTAssertFalse(makeWiring().isWired(target: .claudeCode))

        await sentry.sweepNow().value

        XCTAssertTrue(makeWiring().isWired(target: .claudeCode))
        let root = try loadJSONObject(at: url)
        XCTAssertEqual(root["theme"] as? String, "dracula", "user keys preserved after repair")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual((permissions["allow"] as? [String])?.first, "Read")
    }

    // MARK: - Enrollment changes

    @MainActor
    func test_unenrollViaSettingsRemovesAuditState() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value
        XCTAssertNotNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))

        settings.routedClientWiring.unenroll(targetRawValue: "claudeCode")
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))
        XCTAssertFalse(settings.routedClientWiring.enrolledTargets.contains("claudeCode"))
    }

    @MainActor
    func test_enrollmentNotificationRefreshesWatchers() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)

        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value
        XCTAssertFalse(makeWiring().isWired(target: .claudeCode), "no enrollment yet")

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        await Task.yield()
        await sentry.sweepNow().value

        XCTAssertTrue(makeWiring().isWired(target: .claudeCode))
    }

    // MARK: - Persistence

    @MainActor
    func test_enrollmentSurvivesAcrossInstances() async {
        settings.routedClientWiring.enroll(targetRawValue: "claudeCode")
        settings.routedClientWiring.enroll(targetRawValue: "codex")

        let secondInstance = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        XCTAssertTrue(secondInstance.routedClientWiring.enrolledTargets.contains("claudeCode"))
        XCTAssertTrue(secondInstance.routedClientWiring.enrolledTargets.contains("codex"))
        XCTAssertTrue(secondInstance.routedClientWiring.autoRepairEnabled)
    }

    @MainActor
    func test_autoRepairTogglePersists() async {
        settings.routedClientWiring.autoRepairEnabled = false
        let secondInstance = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        XCTAssertFalse(secondInstance.routedClientWiring.autoRepairEnabled)
    }

    // MARK: - Helpers

    @MainActor
    private func makeSentry() -> RoutedClientWiringSentry {
        let home = tempHome!
        return RoutedClientWiringSentry(
            configuration: RoutedClientWiringSentry.Configuration(
                debounceNanoseconds: 1_000_000,
                periodicSweepSeconds: 0,
                reopenBackoffNanoseconds: 1_000_000,
                monitoredEvents: [.write, .extend, .rename, .delete, .attrib, .link]
            ),
            wiringFactory: {
                RoutingClientWiring(
                    fileManager: .default,
                    home: home,
                    now: { Date(timeIntervalSince1970: 1_700_000_000) }
                )
            }
        )
    }

    private func makeWiring() -> RoutingClientWiring {
        RoutingClientWiring(
            fileManager: .default,
            home: tempHome,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
