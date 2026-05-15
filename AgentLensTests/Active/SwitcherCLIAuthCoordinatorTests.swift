import AppKit
import Foundation
import GRDB
import Security
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - SwitcherCLIAuthCoordinator Tests

@MainActor
final class SwitcherCLIAuthCoordinatorTests: XCTestCase {

    // MARK: - Test Isolation

    private var tempDirectories: [URL] = []

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Reconnect Result Tests

    func test_reconnectResult_equatable() {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "Test"),
            sortKey: 0
        )

        let result1: SwitcherCLIAuthCoordinator.ReconnectResult = .readyToPersist(profile)
        let result2: SwitcherCLIAuthCoordinator.ReconnectResult = .readyToPersist(profile)
        XCTAssertEqual(result1, result2)

        let result3: SwitcherCLIAuthCoordinator.ReconnectResult = .cancelled
        XCTAssertNotEqual(result1, result3)
    }

    func test_reconnectResult_requiresConfirmation_case() {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "Test"),
            sortKey: 0
        )

        let result: SwitcherCLIAuthCoordinator.ReconnectResult = .requiresConfirmation(
            updatedProfile: profile,
            previousAccount: "old@example.com",
            detectedAccount: "new@example.com"
        )

        switch result {
        case .requiresConfirmation(let updatedProfile, let previous, let detected):
            XCTAssertEqual(updatedProfile.id, profile.id)
            XCTAssertEqual(previous, "old@example.com")
            XCTAssertEqual(detected, "new@example.com")
        default:
            XCTFail("Expected requiresConfirmation case")
        }
    }

    // MARK: - Dependencies Tests

    func test_dependencies_haveSensibleDefaults() {
        let deps = SwitcherCLIAuthCoordinator.Dependencies()
        XCTAssertNotNil(deps.openScriptInTerminal)
        XCTAssertNotNil(deps.discoverAuthState)
        XCTAssertNotNil(deps.fileManager)
    }

    // MARK: - Non-CLI Profile Rejection

    func test_reconnect_rejectsNonCLIProfile() async {
        let coordinator = SwitcherCLIAuthCoordinator()
        let browserProfile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "Default",
                displayLabel: "Chrome"
            ),
            sortKey: 0
        )

        let result = await coordinator.reconnect(profile: browserProfile)

        if case .failed(let message) = result {
            XCTAssertTrue(message.contains("Only Codex and Claude Code CLI profiles"))
        } else {
            XCTFail("Expected failed result for browser profile")
        }
    }

    func test_reconnect_rejectsOpencodeCLI() async {
        let coordinator = SwitcherCLIAuthCoordinator()
        let opencodeProfile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .opencode,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "OpenCode"),
            sortKey: 0
        )

        let result = await coordinator.reconnect(profile: opencodeProfile)

        if case .failed(let message) = result {
            XCTAssertTrue(message.contains("does not support account reconnect"))
        } else {
            XCTFail("Expected failed result for opencode profile")
        }
    }

    // MARK: - Missing Executable Path

    func test_reconnect_returnsFailedWhenExecutableNotFound() async {
        let coordinator = SwitcherCLIAuthCoordinator()
        let codexProfile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "Codex"),
            sortKey: 0
        )

        let deps = SwitcherCLIAuthCoordinator.Dependencies(
            discoverAuthState: { _, _ in
                CLIAuthInfo(
                    cliType: .codex,
                    authState: .notAuthenticated,
                    isInstalled: false,
                    accountDescription: nil,
                    configDirectory: nil,
                    executablePath: nil
                )
            },
            executablePathResolver: { _ in nil }
        )

        let customCoordinator = SwitcherCLIAuthCoordinator(dependencies: deps)
        let result = await customCoordinator.reconnect(profile: codexProfile)

        if case .failed(let message) = result {
            XCTAssertTrue(message.contains("not installed"))
        } else {
            XCTFail("Expected failed result when executable not found")
        }
    }

    // MARK: - Auth State Detection

    func test_isConnected_forCodex_authenticated() {
        let coordinator = SwitcherCLIAuthCoordinator()

        let authInfo = CLIAuthInfo(
            cliType: .codex,
            authState: .authenticated(lastRefresh: nil),
            isInstalled: true,
            accountDescription: "test@example.com",
            configDirectory: "/path/to/config",
            executablePath: "/usr/local/bin/codex"
        )

        XCTAssertTrue(coordinator.isConnected(authInfo))
    }

    func test_isConnected_forCodex_apiKeyPresent() {
        let coordinator = SwitcherCLIAuthCoordinator()

        let authInfo = CLIAuthInfo(
            cliType: .codex,
            authState: .apiKeyPresent,
            isInstalled: true,
            accountDescription: nil,
            configDirectory: nil,
            executablePath: "/usr/local/bin/codex"
        )

        XCTAssertTrue(coordinator.isConnected(authInfo))
    }

    func test_isConnected_forCodex_notAuthenticated() {
        let coordinator = SwitcherCLIAuthCoordinator()

        let authInfo = CLIAuthInfo(
            cliType: .codex,
            authState: .notAuthenticated,
            isInstalled: true,
            accountDescription: nil,
            configDirectory: nil,
            executablePath: "/usr/local/bin/codex"
        )

        XCTAssertFalse(coordinator.isConnected(authInfo))
    }

    func test_isConnected_forClaude_authenticated() {
        let coordinator = SwitcherCLIAuthCoordinator()

        let authInfo = CLIAuthInfo(
            cliType: .claude,
            authState: .authenticated(lastRefresh: nil),
            isInstalled: true,
            accountDescription: "test@example.com",
            configDirectory: "/path/to/config",
            executablePath: "/usr/local/bin/claude"
        )

        XCTAssertTrue(coordinator.isConnected(authInfo))
    }

    func test_isConnected_forClaude_notAuthenticated() {
        let coordinator = SwitcherCLIAuthCoordinator()

        let authInfo = CLIAuthInfo(
            cliType: .claude,
            authState: .notAuthenticated,
            isInstalled: true,
            accountDescription: nil,
            configDirectory: nil,
            executablePath: "/usr/local/bin/claude"
        )

        XCTAssertFalse(coordinator.isConnected(authInfo))
    }

    func test_isConnected_forOpencode_alwaysFalse() {
        let coordinator = SwitcherCLIAuthCoordinator()

        let authInfo = CLIAuthInfo(
            cliType: .opencode,
            authState: .authenticated(lastRefresh: nil),
            isInstalled: true,
            accountDescription: nil,
            configDirectory: nil,
            executablePath: "/usr/local/bin/opencode"
        )

        XCTAssertFalse(coordinator.isConnected(authInfo))
    }

    // MARK: - Config Directory Resolution

    func test_resolvedConfigDirectory_preservesExistingAccount() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Test",
                configDirectory: "/existing/config/path",
                accountDescription: "test@example.com"
            ),
            sortKey: 0
        )

        let resolved = coordinator.resolvedConfigDirectory(
            for: profile,
            cliType: .codex,
            preservesExistingAccount: true
        )

        XCTAssertNotEqual(resolved, "/existing/config/path")
        XCTAssertTrue(resolved.contains("Library/Application Support/OpenBurnBar/SwitcherCLIProfiles"))
    }

    func test_resolvedConfigDirectory_usesExistingWhenNotPreserving() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Test",
                configDirectory: "/existing/config/path"
            ),
            sortKey: 0
        )

        let resolved = coordinator.resolvedConfigDirectory(
            for: profile,
            cliType: .claude,
            preservesExistingAccount: false
        )

        XCTAssertEqual(resolved, "/existing/config/path")
    }

    func test_resolvedConfigDirectory_usesProfileIDAsFallback() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let profile = SwitcherProfileRecord(
            id: "profile-12345",
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "Test"),
            sortKey: 0
        )

        let resolved = coordinator.resolvedConfigDirectory(
            for: profile,
            cliType: .codex,
            preservesExistingAccount: false
        )

        XCTAssertTrue(resolved.contains("profile-12345"))
    }

    // MARK: - Profile Record Update

    func test_updatedProfileRecord_preservesMetadata() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let exhaustedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let exhaustedUntil = Date(timeIntervalSince1970: 1_700_018_000)
        let originalProfile = SwitcherProfileRecord(
            id: "test-profile-id",
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/workspace",
                additionalArgs: ["--verbose"],
                envKeysToPass: ["PATH", "HOME"],
                displayLabel: "Work Account",
                configDirectory: "/old/config",
                accountDescription: "old@example.com",
                providerID: .anthropic,
                runtimeAccountID: "acct_123",
                subscriptionTierID: "claude-max",
                modelCapabilityClassID: "anthropic:sonnet",
                linkedHarnessIDs: ["claude", "droid"],
                neverAutoSwitch: true,
                lastQuotaExhaustedAt: exhaustedAt,
                exhaustedUntil: exhaustedUntil,
                lastQuotaExhaustionDetail: "5-hour quota exhausted",
                isDisabled: true
            ),
            sortKey: 5,
            createdAt: Date().addingTimeInterval(-3600)
        )

        let updated = coordinator.updatedProfileRecord(
            from: originalProfile,
            cliType: .claude,
            configDirectory: "/new/config/path",
            detectedAccountDescription: "new@example.com"
        )

        XCTAssertEqual(updated.id, "test-profile-id")
        XCTAssertEqual(updated.targetKind, .cli)
        XCTAssertEqual(updated.cliType, .claude)
        XCTAssertEqual(updated.sortKey, 5)
        XCTAssertEqual(updated.createdAt, originalProfile.createdAt)

        guard let metadata = updated.cliMetadata else {
            XCTFail("Expected metadata to be present")
            return
        }

        XCTAssertEqual(metadata.workingDirectory, "/workspace")
        XCTAssertEqual(metadata.additionalArgs, ["--verbose"])
        XCTAssertEqual(metadata.envKeysToPass, ["PATH", "HOME"])
        XCTAssertEqual(metadata.displayLabel, "Work Account")
        XCTAssertEqual(metadata.configDirectory, "/new/config/path")
        XCTAssertEqual(metadata.accountDescription, "new@example.com")
        XCTAssertEqual(metadata.providerID, .anthropic)
        XCTAssertEqual(metadata.runtimeAccountID, "acct_123")
        XCTAssertEqual(metadata.subscriptionTierID, "claude-max")
        XCTAssertEqual(metadata.modelCapabilityClassID, "anthropic:sonnet")
        XCTAssertEqual(metadata.linkedHarnessIDs, ["claude", "droid"])
        XCTAssertTrue(metadata.neverAutoSwitch)
        XCTAssertEqual(metadata.lastQuotaExhaustedAt, exhaustedAt)
        XCTAssertEqual(metadata.exhaustedUntil, exhaustedUntil)
        XCTAssertEqual(metadata.lastQuotaExhaustionDetail, "5-hour quota exhausted")
        XCTAssertEqual(metadata.isDisabled, true)
    }

    func test_updatedProfileRecord_usesNormalizedDetectedAccount() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let originalProfile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "Test"),
            sortKey: 0
        )

        let updated = coordinator.updatedProfileRecord(
            from: originalProfile,
            cliType: .codex,
            configDirectory: "/config",
            detectedAccountDescription: "  test@example.com  "
        )

        XCTAssertEqual(updated.cliMetadata?.accountDescription, "test@example.com")
    }

    // MARK: - Shell Escape

    func test_shellEscape_escapesSingleQuotes() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let escaped = coordinator.shellEscape("test'value")
        XCTAssertEqual(escaped, "'test'\"'\"'value'")
    }

    func test_shellEscape_preservesSimpleString() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let escaped = coordinator.shellEscape("simple")
        XCTAssertEqual(escaped, "'simple'")
    }

    func test_shellEscape_handlesEmptyString() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let escaped = coordinator.shellEscape("")
        XCTAssertEqual(escaped, "''")
    }

    // MARK: - Normalize Helper

    func test_normalized_returnsNilForNil() {
        let coordinator = SwitcherCLIAuthCoordinator()
        XCTAssertNil(coordinator.normalized(nil))
    }

    func test_normalized_returnsNilForWhitespaceOnly() {
        let coordinator = SwitcherCLIAuthCoordinator()
        XCTAssertNil(coordinator.normalized("   "))
        XCTAssertNil(coordinator.normalized("\t\n"))
    }

    func test_normalized_trimsAndReturns() {
        let coordinator = SwitcherCLIAuthCoordinator()
        XCTAssertEqual(coordinator.normalized("  value  "), "value")
        XCTAssertEqual(coordinator.normalized("\tvalue\n"), "value")
    }

    // MARK: - Login Commands

    func test_loginCommands_forCodex() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let commands = coordinator.loginCommands(for: .codex, executablePath: "/usr/bin/codex")

        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.contains { $0.contains("login") })
    }

    func test_loginCommands_forClaude() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let commands = coordinator.loginCommands(for: .claude, executablePath: "/usr/bin/claude")

        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.contains { $0.contains("auth") && $0.contains("login") })
    }

    func test_loginCommands_forOpencode() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let commands = coordinator.loginCommands(for: .opencode, executablePath: "/usr/bin/opencode")
        XCTAssertTrue(commands.isEmpty)
    }

    // MARK: - Config Environment Keys

    func test_configEnvironmentKeys_forCodex() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let keys = coordinator.configEnvironmentKeys(for: .codex)

        XCTAssertTrue(keys.contains("CODEX_HOME"))
        XCTAssertTrue(keys.contains("CODEX_CONFIG_PATH"))
    }

    func test_configEnvironmentKeys_forClaude() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let keys = coordinator.configEnvironmentKeys(for: .claude)

        XCTAssertTrue(keys.contains("CLAUDE_CONFIG_PATH"))
    }

    func test_configEnvironmentKeys_forOpencode() {
        let coordinator = SwitcherCLIAuthCoordinator()
        let keys = coordinator.configEnvironmentKeys(for: .opencode)
        XCTAssertTrue(keys.isEmpty)
    }
}

// MARK: - SwitcherCLIFallbackPlanner Tests

@MainActor
final class SwitcherCLIFallbackPlannerTests: XCTestCase {
    func testOrderedCandidates_staysWithinSameProviderAndCapabilityClass() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }
        let requested = makeCLIProfile(
            id: "requested",
            cliType: .codex,
            label: "Requested",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )
        let sameClass = makeCLIProfile(
            id: "same-class",
            cliType: .codex,
            label: "Same Class",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )
        let differentClass = makeCLIProfile(
            id: "different-class",
            cliType: .codex,
            label: "Different Class",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-base",
            subscriptionTierID: "openai-gpt-base"
        )
        let differentProvider = makeCLIProfile(
            id: "different-provider",
            cliType: .codex,
            label: "Different Provider",
            providerID: .anthropic,
            capabilityClassID: "anthropic:sonnet",
            subscriptionTierID: "claude-max"
        )

        let ordered = await planner.orderedCandidates(
            for: requested,
            allProfiles: [requested, sameClass, differentClass, differentProvider]
        )

        XCTAssertEqual(ordered.map(\.id), ["requested", "same-class"])
    }

    func testOrderedCandidates_skipsNeverAutoSwitchFallbackProfiles() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }
        let requested = makeCLIProfile(
            id: "requested",
            cliType: .codex,
            label: "Requested",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )
        let noAutoSwitch = makeCLIProfile(
            id: "no-auto-switch",
            cliType: .codex,
            label: "No Auto",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro",
            neverAutoSwitch: true
        )

        let ordered = await planner.orderedCandidates(
            for: requested,
            allProfiles: [requested, noAutoSwitch]
        )

        XCTAssertEqual(ordered.map(\.id), ["requested"])
    }

    func testEligibility_marksExhaustedWhenProfileIsInExhaustionWindow() async {
        let planner = SwitcherCLIFallbackPlanner { _ in nil }
        let profile = makeCLIProfile(
            id: "exhausted",
            cliType: .codex,
            label: "Exhausted",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro",
            exhaustedUntil: Date().addingTimeInterval(60),
            lastQuotaExhaustionDetail: "5-hour limit reached"
        )

        let eligibility = await planner.eligibility(for: profile)
        XCTAssertEqual(eligibility, .quotaExhausted(reason: "5-hour limit reached"))
    }

    func testEligibility_usesQuotaLookupWhenRemainingPercentIsZero() async {
        let planner = SwitcherCLIFallbackPlanner { _ in
            CLIFallbackQuotaStatus(
                fiveHourRemainingPercent: 0,
                weeklyRemainingPercent: 5,
                statusMessage: "No quota remaining."
            )
        }
        let profile = makeCLIProfile(
            id: "quota-lookup",
            cliType: .codex,
            label: "Quota lookup",
            providerID: .openAI,
            capabilityClassID: "openai:gpt-pro",
            subscriptionTierID: "openai-gpt-pro"
        )

        let eligibility = await planner.eligibility(for: profile)
        XCTAssertEqual(eligibility, .quotaExhausted(reason: "No quota remaining."))
    }

    private func makeCLIProfile(
        id: String,
        cliType: SwitcherCLIProfileType,
        label: String,
        providerID: ProviderID,
        capabilityClassID: String,
        subscriptionTierID: String,
        neverAutoSwitch: Bool = false,
        exhaustedUntil: Date? = nil,
        lastQuotaExhaustionDetail: String? = nil
    ) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: label,
                providerID: providerID,
                subscriptionTierID: subscriptionTierID,
                modelCapabilityClassID: capabilityClassID,
                neverAutoSwitch: neverAutoSwitch,
                exhaustedUntil: exhaustedUntil,
                lastQuotaExhaustionDetail: lastQuotaExhaustionDetail
            ),
            sortKey: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

// MARK: - SwitcherDiscoveryService Tests

@MainActor
final class SwitcherDiscoveryServiceTests: XCTestCase {

    // MARK: - Test Isolation

    private var tempDirectories: [URL] = []

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Discovery Source Tests

    func test_discoverySource_equatable() {
        let source1 = DiscoverySource.chromeProfile(
            folderKey: "Default",
            email: "test@example.com",
            gaiaName: "Test User",
            serviceIdentities: []
        )
        let source2 = DiscoverySource.chromeProfile(
            folderKey: "Default",
            email: "test@example.com",
            gaiaName: "Test User",
            serviceIdentities: []
        )
        XCTAssertEqual(source1, source2)

        let source3 = DiscoverySource.chromeProfile(
            folderKey: "Profile 1",
            email: nil,
            gaiaName: nil,
            serviceIdentities: []
        )
        XCTAssertNotEqual(source1, source3)
    }

    func test_discoverySource_safari() {
        let source = DiscoverySource.safari
        XCTAssertEqual(source, DiscoverySource.safari)
    }

    func test_discoverySource_codex() {
        let source = DiscoverySource.codex(
            executablePath: "/usr/bin/codex",
            hasAPIKey: true,
            lastRefresh: Date(),
            accountDescription: "test@example.com",
            configDirectory: "/config/path"
        )
        XCTAssertEqual(source, source)
    }

    func test_discoverySource_claudeCode() {
        let source = DiscoverySource.claudeCode(
            executablePath: "/usr/bin/claude",
            isAuthenticated: true,
            accountDescription: "test@example.com",
            configDirectory: "/config/path"
        )
        XCTAssertEqual(source, source)
    }

    func test_discoverySource_opencode() {
        let source = DiscoverySource.opencode(executablePath: "/usr/bin/opencode")
        XCTAssertEqual(source, source)
    }

    // MARK: - Identity Auth State Tests

    func test_identityAuthState_equatable() {
        XCTAssertEqual(IdentityAuthState.authenticated, .authenticated)
        XCTAssertEqual(IdentityAuthState.apiKeyPresent, .apiKeyPresent)
        XCTAssertEqual(IdentityAuthState.notAuthenticated, .notAuthenticated)
        XCTAssertEqual(IdentityAuthState.notInstalled, .notInstalled)

        XCTAssertNotEqual(IdentityAuthState.authenticated, .notAuthenticated)
    }

    // MARK: - Identity Quota Summary Tests

    func test_identityQuotaSummary_equatable() {
        let summary1 = IdentityQuotaSummary(fiveHourRemaining: "78%", weeklyRemaining: "80%")
        let summary2 = IdentityQuotaSummary(fiveHourRemaining: "78%", weeklyRemaining: "80%")
        XCTAssertEqual(summary1, summary2)

        let summary3 = IdentityQuotaSummary(fiveHourRemaining: "90%", weeklyRemaining: "80%")
        XCTAssertNotEqual(summary1, summary3)
    }

    func test_identityQuotaSummary_withNilValues() {
        let summary = IdentityQuotaSummary(fiveHourRemaining: nil, weeklyRemaining: nil)
        XCTAssertNil(summary.fiveHourRemaining)
        XCTAssertNil(summary.weeklyRemaining)
    }

    // MARK: - Discovered Identity Tests

    func test_discoveredIdentity_equatable() {
        let identity1 = DiscoveredIdentity(
            id: "chrome.Default",
            source: .chromeProfile(
                folderKey: "Default",
                email: "test@example.com",
                gaiaName: "Test User",
                serviceIdentities: []
            ),
            displayTitle: "Test User",
            subtitle: "Chrome profile: Default",
            quotaSummary: nil,
            authState: .authenticated,
            isAlreadyAdded: false
        )

        let identity2 = DiscoveredIdentity(
            id: "chrome.Default",
            source: .chromeProfile(
                folderKey: "Default",
                email: "test@example.com",
                gaiaName: "Test User",
                serviceIdentities: []
            ),
            displayTitle: "Test User",
            subtitle: "Chrome profile: Default",
            quotaSummary: nil,
            authState: .authenticated,
            isAlreadyAdded: false
        )

        XCTAssertEqual(identity1, identity2)
    }

    func test_discoveredIdentity_idUniqueness() {
        let identity1 = DiscoveredIdentity(
            id: "chrome.Default",
            source: .chromeProfile(
                folderKey: "Default",
                email: "test@example.com",
                gaiaName: nil,
                serviceIdentities: []
            ),
            displayTitle: "Test",
            subtitle: "Chrome",
            quotaSummary: nil,
            authState: .notAuthenticated,
            isAlreadyAdded: false
        )

        let identity2 = DiscoveredIdentity(
            id: "chrome.Profile1",
            source: .chromeProfile(
                folderKey: "Profile1",
                email: nil,
                gaiaName: nil,
                serviceIdentities: []
            ),
            displayTitle: "Profile 1",
            subtitle: "Chrome",
            quotaSummary: nil,
            authState: .notAuthenticated,
            isAlreadyAdded: false
        )

        XCTAssertNotEqual(identity1.id, identity2.id)
    }

    // MARK: - Service Initialization

    func test_service_initializesWithEmptyState() {
        let service = SwitcherDiscoveryService()
        XCTAssertTrue(service.discoveredIdentities.isEmpty)
        XCTAssertFalse(service.isScanning)
        XCTAssertTrue(service.scanProgress.isEmpty)
        XCTAssertTrue(service.scanErrors.isEmpty)
    }

    // MARK: - Add Identity Tests

    func test_addIdentity_chromeProfile_validation() throws {
        let service = SwitcherDiscoveryService()
        let dataStore = try makeTestDataStore()

        let invalidIdentity = DiscoveredIdentity(
            id: "chrome.Invalid",
            source: .chromeProfile(
                folderKey: "Invalid/Path",
                email: nil,
                gaiaName: nil,
                serviceIdentities: []
            ),
            displayTitle: "Invalid",
            subtitle: "Invalid profile",
            quotaSummary: nil,
            authState: .notAuthenticated,
            isAlreadyAdded: false
        )

        let result = service.addIdentity(invalidIdentity, dataStore: dataStore)
        XCTAssertNil(result)
    }

    func test_addIdentity_opencode_createsProfile() throws {
        let service = SwitcherDiscoveryService()
        let dataStore = try makeTestDataStore()

        let identity = DiscoveredIdentity(
            id: "cli.opencode",
            source: .opencode(executablePath: "/usr/bin/opencode"),
            displayTitle: "OpenCode",
            subtitle: "OpenCode CLI",
            quotaSummary: nil,
            authState: .notAuthenticated,
            isAlreadyAdded: false
        )

        let result = service.addIdentity(identity, dataStore: dataStore)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.targetKind, .cli)
        XCTAssertEqual(result?.cliType, .opencode)
    }

    // MARK: - Helper

    private func makeTestDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(
            databaseQueue: queue,
            runMigrations: true,
            refreshOnInit: false
        )
    }
}

// MARK: - SwitcherAuthStore Tests

@MainActor
final class SwitcherAuthStoreTests: XCTestCase {

    // MARK: - Test Keychain Backend

    private var testBackend: SwitcherAuthStoreTestKeychainBackend!

    override func setUp() {
        super.setUp()
        testBackend = SwitcherAuthStoreTestKeychainBackend()
    }

    override func tearDown() {
        testBackend = nil
        super.tearDown()
    }

    // MARK: - API Key Storage Tests

    func test_storeAPIKey_persistsKey() throws {
        let store = makeStore()
        try store.storeAPIKey("sk-test-key-123", forProfileID: "profile-1", cliType: .codex)

        XCTAssertEqual(testBackend.storage["com.openburnbar.switcher-auth"]?["switcher.profile-1.codex.apiKey"], Data("sk-test-key-123".utf8))
    }

    func test_storeAPIKey_trimsWhitespace() throws {
        let store = makeStore()
        try store.storeAPIKey("  sk-test-key-123  ", forProfileID: "profile-1", cliType: .claude)

        XCTAssertEqual(
            String(data: testBackend.storage["com.openburnbar.switcher-auth"]?["switcher.profile-1.claude.apiKey"] ?? Data(), encoding: .utf8),
            "sk-test-key-123"
        )
    }

    func test_storeAPIKey_deletesWhenEmpty() throws {
        let store = makeStore()

        // First set a value
        try store.storeAPIKey("sk-test-key", forProfileID: "profile-1", cliType: .codex)
        XCTAssertNotNil(testBackend.storage["com.openburnbar.switcher-auth"]?["switcher.profile-1.codex.apiKey"])

        // Then set empty
        try store.storeAPIKey("   ", forProfileID: "profile-1", cliType: .codex)
        XCTAssertNil(testBackend.storage["com.openburnbar.switcher-auth"]?["switcher.profile-1.codex.apiKey"])
    }

    func test_apiKey_retrievesStoredKey() throws {
        let store = makeStore()
        try store.storeAPIKey("sk-retrieved-key", forProfileID: "profile-2", cliType: .claude)

        let retrieved = store.apiKey(forProfileID: "profile-2", cliType: .claude)
        XCTAssertEqual(retrieved, "sk-retrieved-key")
    }

    func test_apiKey_returnsNilWhenNotStored() throws {
        let store = makeStore()
        let retrieved = store.apiKey(forProfileID: "nonexistent", cliType: .codex)
        XCTAssertNil(retrieved)
    }

    // MARK: - OAuth Token Storage Tests

    func test_storeOAuthToken_persistsToken() throws {
        let store = makeStore()
        try store.storeOAuthToken("oauth-token-abc", forProfileID: "profile-1", provider: "google")

        XCTAssertEqual(
            String(data: testBackend.storage["com.openburnbar.switcher-auth"]?["switcher.profile-1.google.oauthToken"] ?? Data(), encoding: .utf8),
            "oauth-token-abc"
        )
    }

    func test_storeOAuthToken_trimsWhitespace() throws {
        let store = makeStore()
        try store.storeOAuthToken("  oauth-token  ", forProfileID: "profile-1", provider: "apple")

        XCTAssertEqual(
            String(data: testBackend.storage["com.openburnbar.switcher-auth"]?["switcher.profile-1.apple.oauthToken"] ?? Data(), encoding: .utf8),
            "oauth-token"
        )
    }

    func test_oauthToken_retrievesStoredToken() throws {
        let store = makeStore()
        try store.storeOAuthToken("stored-oauth", forProfileID: "profile-3", provider: "google")

        let retrieved = store.oauthToken(forProfileID: "profile-3", provider: "google")
        XCTAssertEqual(retrieved, "stored-oauth")
    }

    func test_oauthToken_returnsNilWhenNotStored() throws {
        let store = makeStore()
        let retrieved = store.oauthToken(forProfileID: "nonexistent", provider: "google")
        XCTAssertNil(retrieved)
    }

    // MARK: - Cleanup Tests

    func test_deleteCredentials_removesAllKnownPatterns() throws {
        let store = makeStore()

        // Store various credentials
        try store.storeAPIKey("codex-key", forProfileID: "profile-x", cliType: .codex)
        try store.storeAPIKey("claude-key", forProfileID: "profile-x", cliType: .claude)
        try store.storeOAuthToken("google-token", forProfileID: "profile-x", provider: "google")
        try store.storeOAuthToken("apple-token", forProfileID: "profile-x", provider: "apple")

        // Verify they're stored
        XCTAssertNotNil(store.apiKey(forProfileID: "profile-x", cliType: .codex))
        XCTAssertNotNil(store.apiKey(forProfileID: "profile-x", cliType: .claude))
        XCTAssertNotNil(store.oauthToken(forProfileID: "profile-x", provider: "google"))
        XCTAssertNotNil(store.oauthToken(forProfileID: "profile-x", provider: "apple"))

        // Delete all
        try store.deleteCredentials(forProfileID: "profile-x")

        // Verify they're gone
        XCTAssertNil(store.apiKey(forProfileID: "profile-x", cliType: .codex))
        XCTAssertNil(store.apiKey(forProfileID: "profile-x", cliType: .claude))
        XCTAssertNil(store.oauthToken(forProfileID: "profile-x", provider: "google"))
        XCTAssertNil(store.oauthToken(forProfileID: "profile-x", provider: "apple"))
    }

    func test_deleteCredentials_handlesMissingCredentials() throws {
        let store = makeStore()
        // Should not throw
        try store.deleteCredentials(forProfileID: "nonexistent-profile")
    }

    // MARK: - Helper

    private func makeStore() -> SwitcherAuthStore {
        SwitcherAuthStore(keychain: KeychainStore(
            service: "com.openburnbar.switcher-auth",
            legacyServices: [],
            backend: testBackend
        ))
    }
}

// MARK: - Test Keychain Backend

private final class SwitcherAuthStoreTestKeychainBackend: KeychainStoreBackend {
    var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

// MARK: - CLI Auth Info Tests

@MainActor
final class CLIAuthInfoTests: XCTestCase {

    func test_codex_authInfo_equatable() {
        let info1 = CLIAuthInfo(
            cliType: .codex,
            authState: .authenticated(lastRefresh: nil),
            isInstalled: true,
            accountDescription: "test@example.com",
            configDirectory: "/config",
            executablePath: "/bin/codex"
        )
        let info2 = CLIAuthInfo(
            cliType: .codex,
            authState: .authenticated(lastRefresh: nil),
            isInstalled: true,
            accountDescription: "test@example.com",
            configDirectory: "/config",
            executablePath: "/bin/codex"
        )
        XCTAssertEqual(info1, info2)
    }

    func test_codex_authInfo_authState() {
        let info = CLIAuthInfo(
            cliType: .codex,
            authState: .apiKeyPresent,
            isInstalled: true,
            accountDescription: nil,
            configDirectory: nil,
            executablePath: nil
        )

        XCTAssertEqual(info.cliType, .codex)
        XCTAssertEqual(info.authState, .apiKeyPresent)
        XCTAssertTrue(info.isInstalled)
        XCTAssertNil(info.accountDescription)
    }

    func test_claude_authInfo_authState() {
        let info = CLIAuthInfo(
            cliType: .claude,
            authState: .authenticated(lastRefresh: nil),
            isInstalled: true,
            accountDescription: "user@claude.ai",
            configDirectory: "/Users/user/.claude",
            executablePath: "/usr/local/bin/claude"
        )

        XCTAssertEqual(info.cliType, .claude)
        XCTAssertEqual(info.authState, .authenticated(lastRefresh: nil))
        XCTAssertEqual(info.accountDescription, "user@claude.ai")
        XCTAssertEqual(info.configDirectory, "/Users/user/.claude")
    }

    func test_opencode_authInfo() {
        let info = CLIAuthInfo(
            cliType: .opencode,
            authState: .notInstalled,
            isInstalled: false,
            accountDescription: nil,
            configDirectory: nil,
            executablePath: nil
        )

        XCTAssertEqual(info.cliType, .opencode)
        XCTAssertEqual(info.authState, .notInstalled)
        XCTAssertFalse(info.isInstalled)
    }
}

// MARK: - AccountManager Mock Tests

@MainActor
final class AccountManagerTests: XCTestCase {

    // MARK: - Device ID Tests

    func test_deviceId_loadsOrCreates() {
        // This tests the static loadOrCreateDeviceId logic
        // In production, deviceId is loaded on init
        let manager = AccountManager()
        XCTAssertFalse(manager.deviceId.isEmpty)
        XCTAssertEqual(manager.deviceId.count, 36) // UUID format
    }

    // MARK: - Firebase Availability Tests

    func test_isFirebaseAvailable_initialState() {
        let manager = AccountManager()
        // Without GoogleService-Info.plist, Firebase is not available
        XCTAssertFalse(manager.isFirebaseAvailable)
    }

    func test_isSignedIn_initialState() {
        let manager = AccountManager()
        XCTAssertFalse(manager.isSignedIn)
    }

    func test_userID_initialState() {
        let manager = AccountManager()
        XCTAssertNil(manager.userID)
    }

    func test_userEmail_initialState() {
        let manager = AccountManager()
        XCTAssertNil(manager.userEmail)
    }

    func test_isCloudSyncEnabled_defaultValue() {
        let manager = AccountManager()
        XCTAssertTrue(manager.isCloudSyncEnabled)
    }

    // MARK: - Cloud Sync Toggle Tests

    func test_setCloudSyncEnabled_updatesState() {
        let manager = AccountManager()
        manager.setCloudSyncEnabled(false)
        XCTAssertFalse(manager.isCloudSyncEnabled)

        manager.setCloudSyncEnabled(true)
        XCTAssertTrue(manager.isCloudSyncEnabled)
    }

    // MARK: - Sign Out Tests

    func test_signOut_clearsOAuthState() throws {
        let manager = AccountManager()
        // Initially should not throw
        try manager.signOut()
        // OAuth state should be cleared (already nil)
        XCTAssertNil(manager.lastOAuthProviderID)
        XCTAssertNil(manager.lastOAuthToken)
    }

    // MARK: - Firebase Auth Keychain Recovery Tests

    func test_isGoogleSignInKeychainError_detectsGoogleKeychainFailure() {
        let error = NSError(
            domain: "com.google.GIDSignIn",
            code: -2,
            userInfo: [
                NSLocalizedDescriptionKey: "keychain error"
            ]
        )

        XCTAssertTrue(AccountManager.isGoogleSignInKeychainErrorForTesting(error))
    }

    func test_isGoogleSignInKeychainError_detectsWrappedGoogleKeychainFailure() {
        let error = NSError(
            domain: "GIDSignInErrorDomain",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "The Google Sign-In auth state could not be saved.",
                NSUnderlyingErrorKey: NSError(
                    domain: "GTMAppAuth.KeychainStore",
                    code: -34018,
                    userInfo: [
                        NSLocalizedDescriptionKey: "keychain error"
                    ]
                )
            ]
        )

        XCTAssertTrue(AccountManager.isGoogleSignInKeychainErrorForTesting(error))
    }

    func test_isGoogleSignInKeychainError_ignoresOtherGoogleFailures() {
        let error = NSError(
            domain: "com.google.GIDSignIn",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey: "canceled"
            ]
        )

        XCTAssertFalse(AccountManager.isGoogleSignInKeychainErrorForTesting(error))
    }

    func test_isFirebaseAuthKeychainError_detectsNestedKeychainFailure() {
        let error = NSError(
            domain: "FIRAuthErrorDomain",
            code: 17995,
            userInfo: [
                NSLocalizedDescriptionKey: "An internal error occurred.",
                NSLocalizedFailureReasonErrorKey: "An error occurred when accessing the keychain."
            ]
        )

        XCTAssertTrue(AccountManager.isFirebaseAuthKeychainErrorForTesting(error))
    }

    func test_isFirebaseAuthKeychainError_ignoresNonKeychainFailure() {
        let error = NSError(
            domain: "FIRAuthErrorDomain",
            code: 17020,
            userInfo: [
                NSLocalizedDescriptionKey: "Network error."
            ]
        )

        XCTAssertFalse(AccountManager.isFirebaseAuthKeychainErrorForTesting(error))
    }

    func test_firebaseAuthStoredUserDeleteQuery_targetsFirebaseDataProtectionKeychainRow() {
        let query = AccountManager.firebaseAuthStoredUserDeleteQueryForTesting(
            accessGroup: "4Y367DF25B.com.openburnbar.app",
            service: "test-api-key",
            synchronizable: true
        )

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "4Y367DF25B.com.openburnbar.app")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "test-api-key")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "firebase_auth_firebase_user")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, true)
    }

    func test_recoverableFirebaseAuthKeychainDeleteStatus_isStrict() {
        XCTAssertTrue(AccountManager.isRecoverableFirebaseAuthKeychainDeleteStatusForTesting(errSecSuccess))
        XCTAssertTrue(AccountManager.isRecoverableFirebaseAuthKeychainDeleteStatusForTesting(errSecItemNotFound))
        XCTAssertFalse(AccountManager.isRecoverableFirebaseAuthKeychainDeleteStatusForTesting(errSecMissingEntitlement))
    }

    func test_googleAuthPresentationWindow_returnsVisibleWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Google Sign-In Presentation Test"
        window.orderFront(nil)
        defer { window.close() }

        let resolvedWindow = AccountManager.googleAuthPresentationWindowForTesting(from: window)

        XCTAssertTrue(resolvedWindow === window)
    }
}
