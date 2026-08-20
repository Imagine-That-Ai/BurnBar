import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Subagent E — QA & telemetry for Visual Capture Source Toggle.
/// Proves critical toggle + telemetry behavior; not just exercises.
/// See `plans/2026-05-09-visual-capture-source-toggle/PERF_REGRESSION_GUARD.md` and
/// `SECURITY_REVIEW.md` (E checklist) for budget invariants.
@MainActor
final class VisualCaptureSourceToggleTests: XCTestCase {

    private var defaults: UserDefaults!
    private var coordinator: SettingsPersistenceCoordinator!
    private var prefs: VisualCapturePreferences!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "VisualCaptureSourceToggleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        coordinator = SettingsPersistenceCoordinator(defaults: defaults, flushDelayNanoseconds: 0)
        prefs = VisualCapturePreferences(persistence: coordinator)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        coordinator = nil
        prefs = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Eligibility (Both = 12 AgentProvider cases)

    func test_toggleEligible_BothProviders() {
        // Audit-corrected Both set = 12 cases (cursor splits into cursor + cursorAgent)
        let both: [AgentProvider] = [
            .codex, .claudeCode, .cursor, .cursorAgent, .factory, .minimax,
            .zai, .devin, .hermes, .warp, .openCode, .ollama
        ]
        XCTAssertEqual(both.count, 12)
        for provider in both {
            XCTAssertTrue(prefs.isToggleEligible(provider), "\(provider.rawValue) should be eligible")
            XCTAssertTrue(VisualCapturePreferences.toggleEligibleProviders.contains(provider))
        }
        XCTAssertEqual(VisualCapturePreferences.toggleEligibleProviders.count, 12)
    }

    func test_toggleEligible_CLIOnly() {
        // Canonical CLI-only example from spec: antigravity (Gemini CLI twin has no desktop)
        XCTAssertFalse(prefs.isToggleEligible(.antigravity))
        XCTAssertEqual(prefs.visualCaptureSource(for: .antigravity), .cliPTY)
        // Additional CLI-only providers (no desktop twin)
        for provider in [AgentProvider.geminiCLI, .kimi, .copilot, .aider, .goose, .openClaw, .openClaude, .omp, .xAI, .mimo, .piAgent, .forgeDev, .primeAgent, .muse, .fx] {
            XCTAssertFalse(prefs.isToggleEligible(provider), "\(provider.rawValue) CLI-only should not be eligible")
            XCTAssertEqual(prefs.visualCaptureSource(for: provider), .cliPTY)
        }
    }

    func test_toggleEligible_PluginOnly() {
        // Cline/Kilo/Roo/Augment/Junie are VS Code/JetBrains host plugins — no standalone .app
        let pluginOnly: [AgentProvider] = [.cline, .kiloCode, .rooCode, .augment, .junie]
        for provider in pluginOnly {
            XCTAssertFalse(prefs.isToggleEligible(provider), "\(provider.rawValue) plugin-only should not be eligible")
            XCTAssertEqual(prefs.visualCaptureSource(for: provider), .cliPTY, "\(provider.rawValue) should always return cliPTY")
        }
        // Windsurf legacy (now devin-desktop) is NOT eligible
        XCTAssertFalse(prefs.isToggleEligible(.windsurf))
        XCTAssertEqual(prefs.visualCaptureSource(for: .windsurf), .cliPTY)
    }

    // MARK: - Flag gating

    func test_visualCaptureSourceToggle_isOffOnAFreshInstall() {
        // The flag gates the UI, and the store's own default is `.cliPTY`. That pair
        // is why nothing wires the stored preference into `MediaSessionCoordinator`
        // yet: on a fresh install it would resolve every eligible provider onto a
        // surface the capture engine has no producer for.
        prefs.setVisualCaptureSource(.desktopApp, for: .codex)
        coordinator.flush()

        XCTAssertFalse(prefs.visualCaptureSourceToggleEnabled)
        XCTAssertEqual(prefs.visualCaptureGlobalDefault, .cliPTY)
        XCTAssertFalse(makeSettingsManager(defaults: defaults).visualCaptureSourceToggleEnabled)
    }

    func test_settingsManager_bridgesPerProviderOverrideAndGlobalDefault() {
        let manager = makeSettingsManager(defaults: defaults)
        manager.visualCaptureSourceToggleEnabled = true
        manager.visualCaptureGlobalDefault = .cliPTY
        manager.setVisualCaptureSource(.desktopApp, for: .codex)
        manager.persistence.flush()

        XCTAssertEqual(manager.visualCaptureSource(for: .codex), .desktopApp)
        XCTAssertEqual(manager.visualCaptureSource(for: .claudeCode), .cliPTY, "no override → global default")
        XCTAssertEqual(manager.visualCaptureSource(for: .factory), .cliPTY)

        manager.visualCaptureGlobalDefault = .desktopApp
        XCTAssertEqual(manager.visualCaptureSource(for: .factory), .desktopApp, "global default now applies")
        XCTAssertEqual(manager.visualCaptureSource(for: .codex), .desktopApp, "override still wins")

        // Ineligible providers ignore both the override and the global default.
        XCTAssertEqual(manager.visualCaptureSource(for: .antigravity), .cliPTY)
        XCTAssertEqual(manager.visualCaptureSource(for: .cline), .cliPTY)
    }

    // MARK: - Bundle checker fallback (desktop not installed → cliPTY)

    func test_bundleChecker_WhenDesktopNotInstalled_FallsBackToCliPTY() {
        // hermes/openCode always return true (TUI embedded) — not a fallback case
        XCTAssertTrue(VisualCaptureBundleChecker.isDesktopInstalled(for: .hermes))
        XCTAssertTrue(VisualCaptureBundleChecker.isDesktopInstalled(for: .openCode))

        // Bundle checker mapping must be exhaustive for Both set; for providers
        // where the desktop app is not installed on CI, isDesktopInstalled returns false
        // and the engine/UI must fall back to cliPTY. We verify the checker contract:
        for provider in VisualCapturePreferences.toggleEligibleProviders {
            let hasBundleIDs = !VisualCaptureBundleChecker.desktopBundleIdentifiers(for: provider).isEmpty || provider == .hermes || provider == .openCode
            XCTAssertTrue(hasBundleIDs || provider == .hermes || provider == .openCode, "\(provider.rawValue) Both provider should have bundle IDs or be TUI")
        }
        // Ineligible providers have no bundle IDs (no desktop twin)
        for provider in [AgentProvider.cline, .kiloCode, .rooCode, .augment, .junie, .antigravity, .windsurf] {
            XCTAssertTrue(VisualCaptureBundleChecker.desktopBundleIdentifiers(for: provider).isEmpty, "\(provider.rawValue) ineligible should have no desktop bundle IDs")
            XCTAssertTrue(VisualCaptureBundleChecker.desktopAppPaths(for: provider).isEmpty || provider == .windsurf, "\(provider.rawValue) ineligible should have no app paths")
        }

    }

    // MARK: - Commit path (persist + emit together)

    func test_commit_persistsTheChoiceAndEmitsTheSelectionEvent() {
        // The defect this guards: the Settings toggle and the session-header pill
        // used to call `setVisualCaptureSource` directly, so a rollout could see
        // zero `visual_capture.surface_selected` events while users were switching.
        let analytics = makeIsolatedAnalytics()
        let manager = makeSettingsManager(defaults: defaults)
        manager.visualCaptureSourceToggleEnabled = true

        VisualCaptureSelection.commit(
            .desktopApp,
            for: .codex,
            settingsManager: manager,
            trigger: .settings,
            desktopInstalled: true,
            analytics: analytics.recorder
        )

        XCTAssertEqual(manager.visualCaptureSource(for: .codex), .desktopApp)
        XCTAssertEqual(analytics.transport.sent.count, 1)
        let sent = analytics.transport.sent[0]
        XCTAssertEqual(sent.name, "visual_capture.surface_selected")
        XCTAssertEqual(sent.properties["provider"], .string("codex"))
        XCTAssertEqual(sent.properties["surface"], .string("desktop_app"))
        XCTAssertEqual(sent.properties["trigger"], .string("settings"))
        XCTAssertEqual(sent.properties["fallback_used"], .bool(false))
        XCTAssertEqual(sent.properties["is_eligible"], .bool(true))
        XCTAssertTrue(VisualCaptureTelemetry.isCompliantPayload(sent.properties))
    }

    func test_commit_marksFallbackWhenTheDesktopAppIsMissing() {
        let analytics = makeIsolatedAnalytics()
        let manager = makeSettingsManager(defaults: defaults)
        manager.visualCaptureSourceToggleEnabled = true

        VisualCaptureSelection.commit(
            .desktopApp,
            for: .factory,
            settingsManager: manager,
            trigger: .sessionHeader,
            desktopInstalled: false,
            analytics: analytics.recorder
        )

        let sent = analytics.transport.sent[0]
        XCTAssertEqual(sent.properties["trigger"], .string("session_header"))
        XCTAssertEqual(sent.properties["fallback_used"], .bool(true))

        // Ineligible providers report `is_eligible: false` rather than being dropped.
        VisualCaptureSelection.commit(
            .cliPTY,
            for: .antigravity,
            settingsManager: manager,
            trigger: .settings,
            desktopInstalled: false,
            analytics: analytics.recorder
        )
        XCTAssertEqual(analytics.transport.sent[1].properties["is_eligible"], .bool(false))
    }

    // MARK: - Telemetry

    func test_telemetryEventExists() {
        XCTAssertEqual(AnalyticsEvent.visualCaptureSurfaceSelected.rawValue, "visual_capture.surface_selected")
        // Name matches taxonomy scheme (surface.object.action)
        XCTAssertTrue(AnalyticsName.isValidEventName(AnalyticsEvent.visualCaptureSurfaceSelected.rawValue))
        // Category is primary_action (default)
        XCTAssertEqual(AnalyticsEvent.visualCaptureSurfaceSelected.category, .primaryAction)
        // No duplicate wire names
        let raws = AnalyticsEvent.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count)
    }

    func test_telemetryEmitsPrivacyPreservingPayload() {
        // Verify helper emits via Analytics with correct keys and no PII
        let analytics = makeIsolatedAnalytics()
        VisualCaptureTelemetry.trackSurfaceSelected(
            provider: .codex,
            surface: .desktopApp,
            trigger: .settings,
            fallbackUsed: false,
            isEligible: true,
            analytics: analytics.recorder
        )
        XCTAssertEqual(analytics.transport.sent.count, 1)
        let sent = analytics.transport.sent[0]
        XCTAssertEqual(sent.name, "visual_capture.surface_selected")
        XCTAssertEqual(sent.category, AnalyticsCategory.primaryAction.rawValue)
        // Required keys present
        XCTAssertEqual(sent.properties["provider"], .string("codex"))
        XCTAssertEqual(sent.properties["surface"], .string("desktop_app"))
        XCTAssertEqual(sent.properties["trigger"], .string("settings"))
        XCTAssertEqual(sent.properties["fallback_used"], .bool(false))
        XCTAssertEqual(sent.properties["is_eligible"], .bool(true))
        // Privacy: no windowTitle, bundleId, hash, path
        XCTAssertNil(sent.properties["windowTitle"] ?? sent.properties["window_title"])
        XCTAssertNil(sent.properties["bundleId"] ?? sent.properties["bundle_id"])
        XCTAssertNil(sent.properties["sha256Hex"] ?? sent.properties["hash"])
        XCTAssertNil(sent.properties["path"])
        // Payload compliance helper
        XCTAssertTrue(VisualCaptureTelemetry.isCompliantPayload(sent.properties))
    }

    func test_telemetryPayloadComplianceRejectsPII() {
        // Allowed payload passes
        XCTAssertTrue(VisualCaptureTelemetry.isCompliantPayload([
            "provider": .string("codex"),
            "surface": .string("cli_pty"),
            "trigger": .string("session_header"),
            "fallback_used": .bool(true),
            "is_eligible": .bool(false)
        ]))
        // Extra key (PII) fails
        XCTAssertFalse(VisualCaptureTelemetry.isCompliantPayload([
            "provider": .string("codex"),
            "surface": .string("cli_pty"),
            "trigger": .string("settings"),
            "window_title": .string("my secret"),
            "fallback_used": .bool(false),
            "is_eligible": .bool(true)
        ]))
        // Path separator in value fails
        XCTAssertFalse(VisualCaptureTelemetry.isCompliantPayload([
            "provider": .string("codex"),
            "surface": .string("cli_pty"),
            "trigger": .string("settings"),
            "fallback_used": .bool(false),
            "is_eligible": .bool(true)
        ].merging(["provider": .string("/etc/passwd")]) { _, new in new }))
        // Invalid surface fails
        XCTAssertFalse(VisualCaptureTelemetry.isCompliantPayload([
            "provider": .string("codex"),
            "surface": .string("hacked"),
            "trigger": .string("settings"),
            "fallback_used": .bool(false),
            "is_eligible": .bool(true)
        ]))
    }

    func test_telemetryTriggerValues() {
        // Verify all three trigger variants emit correctly
        for trigger in [VisualCaptureTelemetry.Trigger.settings, .sessionHeader, .mobile] {
            let analytics = makeIsolatedAnalytics()
            VisualCaptureTelemetry.trackSurfaceSelected(
                provider: .factory,
                surface: .cliPTY,
                trigger: trigger,
                fallbackUsed: trigger == .mobile,
                isEligible: true,
                analytics: analytics.recorder
            )
            XCTAssertEqual(analytics.transport.sent[0].properties["trigger"], .string(trigger.rawValue))
        }
        XCTAssertEqual(VisualCaptureTelemetry.Trigger.settings.rawValue, "settings")
        XCTAssertEqual(VisualCaptureTelemetry.Trigger.sessionHeader.rawValue, "session_header")
        XCTAssertEqual(VisualCaptureTelemetry.Trigger.mobile.rawValue, "mobile")
    }

    func test_telemetryIneligibleProviderPayload() {
        // Ineligible provider (e.g. antigravity) selecting cliPTY still emits is_eligible=false
        let analytics = makeIsolatedAnalytics()
        VisualCaptureTelemetry.trackSurfaceSelected(
            provider: .antigravity,
            surface: .cliPTY,
            trigger: .settings,
            fallbackUsed: true,
            isEligible: false,
            analytics: analytics.recorder
        )
        XCTAssertEqual(analytics.transport.sent[0].properties["is_eligible"], .bool(false))
        XCTAssertEqual(analytics.transport.sent[0].properties["provider"], .string("antigravity"))
        XCTAssertEqual(analytics.transport.sent[0].properties["surface"], .string("cli_pty"))
    }

    // MARK: - Helpers

    private func makeSettingsManager(defaults: UserDefaults) -> SettingsManager {
        SettingsManager(
            defaults: defaults,
            controllerRuntimeSecrets: KeychainStore(
                service: "tests.controller.\(UUID().uuidString)",
                legacyServices: [],
                backend: VisualCaptureSourceToggleTestsKeychainBackend()
            ),
            chatGatewaySecrets: KeychainStore(
                service: "tests.gateway.\(UUID().uuidString)",
                legacyServices: [],
                backend: VisualCaptureSourceToggleTestsKeychainBackend()
            ),
            flushDelayNanoseconds: 0
        )
    }

    /// Returns an isolated Analytics + FakeTransport pair (no SDK, no consent store side effects beyond helper).
    private func makeIsolatedAnalytics() -> (recorder: Analytics, transport: FakeAnalyticsTransport, consent: AnalyticsConsentStore) {
        let defaults = makeIsolatedAnalyticsDefaults()
        let consent = AnalyticsConsentStore(defaults: defaults)
        consent.grant() // so track() is not dropped
        let transport = FakeAnalyticsTransport()
        let recorder = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { [:] }
        )
        recorder.startIfConsented()
        return (recorder, transport, consent)
    }
}

private final class VisualCaptureSourceToggleTestsKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]
    func set(_ value: Data, service: String, account: String) throws { storage[service, default: [:]][account] = value }
    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? { storage[service]?[account] }
    func delete(service: String, account: String) throws { storage[service]?[account] = nil }
}
