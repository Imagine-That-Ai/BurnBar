import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Focused coverage for the error-handling that was previously swallowed by
/// `try?` in `SwitcherDiscoveryService`. Each test pins a behavior that a silent
/// swallow would have hidden:
///
/// 1. First-profile auto-activation must be driven by the *real* profile count,
///    never a defaulted `0` — so a later add never steals the user's active
///    profile (the former `(try? fetchAllProfiles().count) ?? 0` fail-open).
/// 2. A credential write that fails must fail the whole add closed: no profile
///    is left advertising authentication it cannot back with a stored secret.
/// 3. A failed read of existing profiles in `addDifferentCLIAccount` must abort
///    (and report) rather than silently proceed without duplicate detection.
@MainActor
final class SwitcherDiscoveryServiceMattersTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(
            databaseQueue: queue,
            runMigrations: true,
            refreshOnInit: false
        )
    }

    /// A `SwitcherDiscoveryService` whose credential store is backed by a
    /// Keychain that always throws on write — exercising the fail-closed path.
    private func makeServiceWithFailingKeychain() -> SwitcherDiscoveryService {
        SwitcherDiscoveryService(makeAuthStore: {
            SwitcherAuthStore(
                keychain: KeychainStore(
                    service: "tests.switcher-discovery.\(UUID().uuidString)",
                    legacyServices: [],
                    backend: FailingWriteKeychainBackend()
                )
            )
        })
    }

    private func makeCLIIdentity(_ id: String = "cli.opencode") -> DiscoveredIdentity {
        DiscoveredIdentity(
            id: id,
            source: .opencode(executablePath: "/usr/bin/opencode"),
            displayTitle: "OpenCode",
            subtitle: "OpenCode CLI",
            quotaSummary: nil,
            authState: .notAuthenticated,
            isAlreadyAdded: false
        )
    }

    @discardableResult
    private func seedProfile(
        _ dataStore: DataStore,
        cliType: SwitcherCLIProfileType = .droid,
        label: String
    ) throws -> SwitcherProfileRecord {
        try dataStore.switcherStore.create(
            SwitcherProfileRecord(
                targetKind: .cli,
                cliType: cliType,
                cliMetadata: SwitcherCLIProfileMetadata(displayLabel: label),
                sortKey: 0
            )
        )
    }

    private func activeProfileID(_ dataStore: DataStore) throws -> String? {
        try dataStore.switcherStore.fetchActiveProfileState().activeProfileID
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - First-profile activation (formerly `(try? …count) ?? 0`)

    func test_addIdentity_firstProfile_becomesActive() throws {
        let service = SwitcherDiscoveryService()
        let dataStore = try makeTestDataStore()

        let saved = try XCTUnwrap(service.addIdentity(makeCLIIdentity(), dataStore: dataStore))

        XCTAssertEqual(try activeProfileID(dataStore), saved.id,
                       "The very first profile must be auto-activated.")
    }

    /// The core fail-open fix: a swallowed count read used to default to `0`,
    /// making `count <= 1` true and *stealing* the active profile. With the real
    /// count, a later add must never disturb the existing active selection.
    func test_addIdentity_laterProfile_doesNotStealActive() throws {
        let service = SwitcherDiscoveryService()
        let dataStore = try makeTestDataStore()

        let first = try seedProfile(dataStore, cliType: .droid, label: "Droid")
        _ = try seedProfile(dataStore, cliType: .forge, label: "Forge")
        try dataStore.switcherStore.setActiveProfile(first.id)
        XCTAssertEqual(try activeProfileID(dataStore), first.id)

        let added = try XCTUnwrap(service.addIdentity(makeCLIIdentity(), dataStore: dataStore))

        XCTAssertNotEqual(added.id, first.id)
        XCTAssertEqual(try activeProfileID(dataStore), first.id,
                       "Adding a non-first profile must not steal the active pointer.")
    }

    // MARK: - addCLIWithAPIKey credential fail-closed

    func test_addCLIWithAPIKey_success_storesKeyAndActivatesFirst() throws {
        let service = SwitcherDiscoveryService()
        let dataStore = try makeTestDataStore()

        let saved = try XCTUnwrap(
            service.addCLIWithAPIKey(
                cliType: .codex,
                apiKey: "sk-test-key",
                label: "Codex Key",
                dataStore: dataStore
            )
        )

        XCTAssertEqual(try activeProfileID(dataStore), saved.id)
        XCTAssertEqual(try dataStore.switcherStore.fetchAllProfiles().count, 1)
        XCTAssertTrue(service.scanErrors.isEmpty)
        XCTAssertTrue(service.discoveredIdentities.contains { $0.id == "cli.apikey.\(saved.id)" })
    }

    /// A locked Keychain must fail the add closed: nil return, surfaced error,
    /// and — critically — no orphaned profile claiming `apiKeyPresent` with no
    /// key behind it.
    func test_addCLIWithAPIKey_keychainFailure_failsClosedAndRollsBack() throws {
        let service = makeServiceWithFailingKeychain()
        let dataStore = try makeTestDataStore()

        let result = service.addCLIWithAPIKey(
            cliType: .codex,
            apiKey: "sk-test-key",
            label: "Codex Key",
            dataStore: dataStore
        )

        XCTAssertNil(result, "A failed credential write must fail the add closed.")
        XCTAssertFalse(service.scanErrors.isEmpty, "The failure must be surfaced to the UI.")
        XCTAssertEqual(
            try dataStore.switcherStore.fetchAllProfiles().count, 0,
            "The orphaned credential-less profile must be rolled back."
        )
        XCTAssertNil(try activeProfileID(dataStore),
                     "No profile should be active after a failed add.")
        XCTAssertFalse(
            service.discoveredIdentities.contains { $0.authState == .apiKeyPresent },
            "No identity may advertise a key it does not have."
        )
    }

    /// Even when the credential write fails, the count read still backs
    /// activation. Pre-seeding an active profile proves the failed add never
    /// touches it.
    func test_addCLIWithAPIKey_keychainFailure_preservesExistingActive() throws {
        let service = makeServiceWithFailingKeychain()
        let dataStore = try makeTestDataStore()

        let existing = try seedProfile(dataStore, cliType: .droid, label: "Droid")
        try dataStore.switcherStore.setActiveProfile(existing.id)

        let result = service.addCLIWithAPIKey(
            cliType: .codex,
            apiKey: "sk-test-key",
            label: "Codex Key",
            dataStore: dataStore
        )

        XCTAssertNil(result)
        XCTAssertEqual(try activeProfileID(dataStore), existing.id)
        XCTAssertEqual(try dataStore.switcherStore.fetchAllProfiles().count, 1,
                       "Only the pre-existing profile should remain.")
    }

    // MARK: - addDifferentCLIAccount existing-profiles read fail-closed

    /// If the existing-profiles read throws, the add must abort with a surfaced
    /// error rather than silently treating the store as empty (which would defeat
    /// duplicate detection). Dropping the table forces the read to throw before
    /// any UI / coordinator is involved.
    func test_addDifferentCLIAccount_existingProfilesReadFailure_failsClosed() async throws {
        let service = SwitcherDiscoveryService()
        let dataStore = try makeTestDataStore()

        try await dataStore.actor.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE switcher_profiles")
        }

        let result = await service.addDifferentCLIAccount(cliType: .codex, dataStore: dataStore)

        XCTAssertNil(result, "A failed existing-profiles read must abort the add.")
        XCTAssertFalse(service.scanErrors.isEmpty, "The read failure must be surfaced.")
    }

    func test_addDifferentCLIAccount_accessDeniedMessageSurvivesRescan_sourceGuard() throws {
        let source = try repositorySource("AgentLens/Services/SwitcherDiscoveryService.swift")

        let captureDeclaration = try XCTUnwrap(source.range(of: "var aclDeniedMessage: String?"))
        let captureAssignment = try XCTUnwrap(source.range(of: "aclDeniedMessage = snapshotError.localizedDescription"))
        let rescan = try XCTUnwrap(source.range(of: "await scan(dataStore: dataStore)"))
        let postScanAppend = try XCTUnwrap(source.range(of: "scanErrors.append(aclDeniedMessage)"))

        XCTAssertLessThan(captureDeclaration.lowerBound, captureAssignment.lowerBound)
        XCTAssertLessThan(captureAssignment.lowerBound, rescan.lowerBound)
        XCTAssertLessThan(rescan.lowerBound, postScanAppend.lowerBound)
    }

    func test_connectionsReconnect_accessDeniedMessageWinsOverGenericConfirmation_sourceGuard() throws {
        let source = try repositorySource("AgentLens/Views/Settings/ConnectionsSettingsView.swift")

        let reconnectBranch = try XCTUnwrap(source.range(of: "case .readyToPersist"))
        let captureDeclaration = try XCTUnwrap(source.range(of: "var captureMessage: String?", options: [], range: reconnectBranch.lowerBound..<source.endIndex))
        let captureAssignment = try XCTUnwrap(source.range(of: "captureMessage = snapshotError.localizedDescription", range: captureDeclaration.lowerBound..<source.endIndex))
        let genericProgress = try XCTUnwrap(source.range(of: "externalCredentialMessages[account.id] = \"Credential refreshed. Updating quota...\"", range: captureAssignment.lowerBound..<source.endIndex))
        let finalMessage = try XCTUnwrap(source.range(of: "externalCredentialMessages[account.id] = captureMessage ?? refreshConfirmationMessage(for: account)", range: genericProgress.lowerBound..<source.endIndex))

        XCTAssertLessThan(captureDeclaration.lowerBound, captureAssignment.lowerBound)
        XCTAssertLessThan(captureAssignment.lowerBound, genericProgress.lowerBound)
        XCTAssertLessThan(genericProgress.lowerBound, finalMessage.lowerBound)
    }

    func test_accountSwitcherReconnect_snapshotsCredentialAfterReadyToPersist_sourceGuard() throws {
        let source = try repositorySource("AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSettingsView+DataOperations.swift")

        let reconnectMethod = try XCTUnwrap(source.range(of: "func reconnectCLIProfile"))
        let readyBranch = try XCTUnwrap(source.range(
            of: "case .readyToPersist(let updatedProfile)",
            range: reconnectMethod.lowerBound..<source.endIndex
        ))
        let snapshotUpdate = try XCTUnwrap(source.range(
            of: "persistCLIProfileUpdate(updatedProfile, persistCredentialAfterLogin: true)",
            range: readyBranch.lowerBound..<source.endIndex
        ))

        XCTAssertLessThan(readyBranch.lowerBound, snapshotUpdate.lowerBound)
    }

    func test_discoveryScan_doesNotBlockOnLiveQuotaHTTP_sourceGuard() throws {
        let source = try repositorySource("AgentLens/Services/SwitcherDiscoveryService.swift")

        XCTAssertTrue(source.contains("let quotaSummaries = loadCLIQuotaSummaries(for: cliAuthInfos)"))
        XCTAssertFalse(source.contains("await loadCLIQuotaSummaries(for: cliAuthInfos"))
        XCTAssertFalse(source.contains("await quotaService.refresh(provider: provider, dataStore: dataStore)"))
        XCTAssertTrue(source.contains("quota refresh") && source.contains("deferred until after setup"))
    }
}
