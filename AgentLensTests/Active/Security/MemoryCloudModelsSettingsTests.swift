import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Memory Pro cloud models: consent + user toggle + Remote Config kill switch,
/// all fail-closed, persisted through the settings coordinator, and turned into
/// the daemon's `BurnBarMemoryEgressPolicy` without touching the daemon.
///
/// Run via: `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/MemoryCloudModelsSettingsTests`.
@MainActor
final class MemoryCloudModelsSettingsTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "\(Self.self)-\(UUID().uuidString)"))
    }

    func testGateIsFailClosedAcrossTheMatrix() {
        for consent in [false, true] {
            for enabled in [false, true] {
                for remote in [false, true] {
                    XCTAssertEqual(
                        MemoryCloudModelsGate.isEnabled(
                            consentGranted: consent,
                            cloudModelsEnabled: enabled,
                            remoteConfigEnabled: remote
                        ),
                        consent && enabled && remote,
                        "consent=\(consent) enabled=\(enabled) remote=\(remote)"
                    )
                }
            }
        }
    }

    func testFreshSettingsAreDormant() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        XCTAssertFalse(manager.memoryCloudModelsEnabled)
        XCTAssertFalse(manager.memory.cloudModelsEnabled)
        XCTAssertFalse(manager.memory.cloudModelsConsentShown)
        XCTAssertTrue(manager.memory.cloudModelsRequireNoRetention)
        XCTAssertEqual(manager.memory.cloudModelsDailyCapUSD, 2.0)
        XCTAssertEqual(manager.memory.cloudModelsConsentedProviderIDs, [])
        XCTAssertTrue(manager.memory.remoteConfigCloudModelsEnabled)
        XCTAssertFalse(manager.memoryEgressPolicy().enabled)
    }

    func testSettingsPersistAcrossInstances() throws {
        let defaults = try makeDefaults()
        let first = makeSettingsManager(defaults: defaults)
        first.memoryConsentGranted = true
        first.memory.cloudModelsEnabled = true
        first.memory.cloudModelsConsentedProviderIDs = [.openrouter, .claudeCLI]
        first.memory.cloudModelsRequireNoRetention = false
        first.memory.cloudModelsDailyCapUSD = 5.5
        first.persistence.flush()

        let second = makeSettingsManager(defaults: defaults)
        XCTAssertTrue(second.memoryCloudModelsEnabled)
        XCTAssertTrue(second.memory.cloudModelsConsentShown, "granting the toggle implies the sheet was shown")
        XCTAssertEqual(second.memory.cloudModelsConsentedProviderIDs, [.openrouter, .claudeCLI])
        XCTAssertFalse(second.memory.cloudModelsRequireNoRetention)
        XCTAssertEqual(second.memory.cloudModelsDailyCapUSD, 5.5)
    }

    func testRemoteConfigKillSwitchClosesTheGateAndIsNotPersisted() throws {
        let defaults = try makeDefaults()
        let manager = makeSettingsManager(defaults: defaults)
        manager.memoryConsentGranted = true
        manager.memory.cloudModelsEnabled = true
        XCTAssertTrue(manager.memoryCloudModelsEnabled)
        manager.memory.remoteConfigCloudModelsEnabled = false
        XCTAssertFalse(manager.memoryCloudModelsEnabled)
        XCTAssertFalse(manager.memoryEgressPolicy().enabled, "the hand-off policy follows the gate, not the toggle")
        manager.persistence.flush()
        let persistedKeys = defaults.dictionaryRepresentation().keys.map { $0.lowercased() }
        XCTAssertFalse(persistedKeys.contains { $0.contains("remoteconfigcloudmodels") })
        XCTAssertTrue(persistedKeys.contains("memorycloudmodelsenabled"))
    }

    func testEnablingWithoutBaseMemoryConsentStaysClosed() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memory.cloudModelsEnabled = true
        XCTAssertFalse(manager.memoryConsentGranted)
        XCTAssertFalse(manager.memoryCloudModelsEnabled)
    }

    func testDailyCapIsClampedToTheDaemonCeiling() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memory.cloudModelsDailyCapUSD = -4
        XCTAssertEqual(manager.memory.cloudModelsDailyCapUSD, 0)
        manager.memory.cloudModelsDailyCapUSD = 10_000
        XCTAssertEqual(manager.memory.cloudModelsDailyCapUSD, BurnBarMemoryEgressPolicy.maxDailyCapUSD)
    }

    func testProviderCatalogRetentionAndDaemonIDs() {
        XCTAssertEqual(MemoryCloudProviderID.openrouter.retention, .deny)
        XCTAssertEqual(MemoryCloudProviderID.openrouter.retentionLabel, "No retention")
        XCTAssertEqual(MemoryCloudProviderID.vercelAIGateway.retention, .providerPolicy)
        XCTAssertEqual(MemoryCloudProviderID.claudeCLI.retention, .localQuota)
        XCTAssertEqual(MemoryCloudProviderID.claudeCLI.retentionLabel, "Your subscription")
        XCTAssertNil(MemoryCloudProviderID.codexCLI.daemonProviderID)
        XCTAssertTrue(MemoryCloudProviderID.codexCLI.requiresCLIConsent)
        XCTAssertEqual(MemoryCloudProviderID.vercelAIGateway.daemonProviderID, "vercel-ai-gateway")
        XCTAssertEqual(MemoryCloudProviderID.openrouter.daemonProviderID, "openrouter")
        for id in MemoryCloudProviderID.allCases {
            XCTAssertFalse(id.displayName.isEmpty)
            XCTAssertFalse(id.requirementDescription.isEmpty)
        }
        XCTAssertEqual(MemoryCloudProviderID.decodeList(#"["openrouter","bogus","claude_cli","openrouter"]"#), [.openrouter, .claudeCLI])
        XCTAssertEqual(MemoryCloudProviderID.decodeList("not json"), [])
    }

    func testEgressPolicyIsBuiltFromSettingsAndHonorsTheCLIConsent() throws {
        let manager = makeSettingsManager(defaults: try makeDefaults())
        manager.memoryConsentGranted = true
        manager.memory.cloudModelsEnabled = true
        manager.memory.cloudModelsConsentedProviderIDs = [.openrouter, .claudeCLI, .codexCLI, .anthropic]
        manager.memory.cloudModelsRequireNoRetention = true
        manager.memory.cloudModelsDailyCapUSD = 3.0
        manager.cliAssistantAllowed = true
        var policy = manager.memoryEgressPolicy()
        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.consentedProviderIDs, ["openrouter"], "no-retention only keeps zero-retention routes")
        XCTAssertEqual(policy.consentedCLIProviderIDs, [], "subscription CLIs are not no-retention routes")
        XCTAssertTrue(policy.requireNoRetention)
        XCTAssertEqual(policy.dailyCapUSD, 3.0)
        XCTAssertEqual(policy.allowedModelIDsByPurpose, [:])
        XCTAssertNotNil(policy.updatedAt)

        manager.memory.cloudModelsRequireNoRetention = false
        manager.cliAssistantAllowed = false
        policy = manager.memoryEgressPolicy()
        XCTAssertEqual(policy.consentedProviderIDs, ["openrouter", "anthropic"])
        XCTAssertEqual(policy.consentedCLIProviderIDs, [], "CLI providers need the Mac CLI agents consent too")

        manager.cliAssistantAllowed = true
        policy = manager.memoryEgressPolicy()
        XCTAssertEqual(policy.consentedCLIProviderIDs, ["claude_cli", "codex_cli"])

        manager.memory.cloudModelsEnabled = false
        policy = manager.memoryEgressPolicy()
        XCTAssertFalse(policy.enabled)
        XCTAssertEqual(policy.consentedProviderIDs, ["openrouter", "anthropic"], "disabling keeps the provider list")
    }

    func testUnavailableProvidersStayRevocable() {
        XCTAssertTrue(MemoryCloudModelsSection.providerToggleDisabled(reason: "no key", isSelected: false))
        XCTAssertFalse(MemoryCloudModelsSection.providerToggleDisabled(reason: "no key", isSelected: true), "a retained consent can always be revoked")
        XCTAssertFalse(MemoryCloudModelsSection.providerToggleDisabled(reason: nil, isSelected: false))
    }

    func testProviderAvailabilityReasons() {
        let locked = MemoryCloudProviderAvailability.snapshot(cliAssistantAllowed: false, installedCLIs: [], daemonSnapshot: nil)
        XCTAssertEqual(locked.reason(for: .claudeCLI), "Allow Mac CLI agents in Settings → Privacy first.")
        XCTAssertFalse(locked.isAvailable(.openrouter))
        XCTAssertEqual(locked.reason(for: .openrouter)?.contains("OpenRouter key"), true)

        let missingBinary = MemoryCloudProviderAvailability.snapshot(cliAssistantAllowed: true, installedCLIs: ["codex"], daemonSnapshot: nil)
        XCTAssertEqual(missingBinary.reason(for: .claudeCLI)?.contains("Install"), true)
        XCTAssertTrue(missingBinary.isAvailable(.codexCLI))
    }
}
