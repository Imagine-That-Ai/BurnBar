import Foundation
import XCTest
@testable import OpenBurnBar

final class ProviderCredentialCustodyMigrationTests: XCTestCase {
    private let slot = ProviderCredentialCustodySlot(
        providerID: "zai",
        slotID: "primary",
        label: "Primary",
        isEnabled: true,
        status: .ready,
        endpointProfileID: nil,
        region: nil,
        tokenPlanTier: nil,
        tokenPlanBillingCycle: nil,
        authMethodID: nil
    )

    func test_aclBoundCredentialIsRecoveredRewrittenAndVerifiedExactly() async {
        let secret = Data("test-secret-value".utf8)
        let store = ProviderCredentialCustodyStoreSpy(
            legacy: [slot.account: .init(data: secret, service: "legacy")]
        )
        var daemonValues: [String] = []

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, credential in daemonValues.append(credential) }

        XCTAssertEqual(results, [
            .init(providerID: "zai", slotID: "primary", disposition: .migrated, failureClass: nil)
        ])
        XCTAssertEqual(store.events, [
            .currentRead(slot.account),
            .interactiveRead(slot.account),
            .stageAndReplace(slot.account),
            .finish(slot.account, "legacy")
        ])
        XCTAssertEqual(store.current[slot.account], secret)
        XCTAssertEqual(daemonValues, ["test-secret-value"])
        XCTAssertFalse(String(describing: results).contains("test-secret-value"))
    }

    func test_userCancellationRetainsLegacyCredential() async {
        let secret = Data("cancelled-secret".utf8)
        let store = ProviderCredentialCustodyStoreSpy(
            legacy: [slot.account: .init(data: secret, service: "legacy")]
        )
        store.interactiveReadError = CancellationError()

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, _ in XCTFail("daemon must not be called") }

        XCTAssertEqual(results.first?.disposition, .failed)
        XCTAssertEqual(store.legacy[slot.account]?.data, secret)
        XCTAssertNil(store.current[slot.account])
        XCTAssertFalse(String(describing: results).contains("cancelled-secret"))
    }

    func test_unexpectedCanonicalReadFailureDoesNotOverwriteFromLegacy() async {
        let secret = Data("legacy-secret".utf8)
        let store = ProviderCredentialCustodyStoreSpy(
            legacy: [slot.account: .init(data: secret, service: "legacy")]
        )
        store.currentReadError = TestFailure.unexpectedRead

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, _ in XCTFail("daemon must not be called") }

        XCTAssertEqual(results.first?.disposition, .failed)
        XCTAssertEqual(store.legacy[slot.account]?.data, secret)
        XCTAssertNil(store.current[slot.account])
        XCTAssertEqual(store.events, [.currentRead(slot.account)])
    }

    func test_replacementFailureRetainsRecoveredCredential() async {
        let secret = Data("write-failure-secret".utf8)
        let store = ProviderCredentialCustodyStoreSpy(
            legacy: [slot.account: .init(data: secret, service: "legacy")]
        )
        store.stageError = TestFailure.replacement

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, _ in XCTFail("daemon must not be called") }

        XCTAssertEqual(results.first?.disposition, .failed)
        XCTAssertEqual(store.legacy[slot.account]?.data, secret)
        XCTAssertNil(store.current[slot.account])
    }

    func test_daemonVerificationFailureKeepsReplacementAndBackup() async {
        let secret = Data("daemon-failure-secret".utf8)
        let store = ProviderCredentialCustodyStoreSpy(
            legacy: [slot.account: .init(data: secret, service: "legacy")]
        )

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, _ in throw TestFailure.daemon }

        XCTAssertEqual(results.first?.disposition, .failed)
        XCTAssertEqual(store.current[slot.account], secret)
        XCTAssertEqual(store.legacy[slot.account]?.data, secret)
        XCTAssertFalse(store.events.contains(.finish(slot.account, "legacy")))
    }

    func test_currentCredentialIsIdempotentlyVerifiedWithoutPromptOrRewrite() async {
        let store = ProviderCredentialCustodyStoreSpy(
            current: [slot.account: Data("current-secret".utf8)]
        )
        var verificationCount = 0

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, credential in
                XCTAssertEqual(credential, "current-secret")
                verificationCount += 1
            }

        XCTAssertEqual(results.first?.disposition, .alreadyCurrent)
        XCTAssertEqual(store.events, [
            .currentRead(slot.account),
            .finish(slot.account, nil)
        ])
        XCTAssertEqual(verificationCount, 1)
    }

    func test_alreadyCurrentKeychainCredentialDoesNotPromptForLegacyCleanup() throws {
        let backend = CredentialServiceRecordingBackend()
        let secret = Data("current-secret".utf8)
        let legacyService = OpenBurnBarIdentity.providerAPIKeychainService
        backend.storage[OpenBurnBarIdentity.daemonProviderSecretKeychainService] = [
            slot.account: secret
        ]
        backend.storage[legacyService] = [slot.account: secret]
        let store = KeychainProviderCredentialCustodyStore(
            backend: backend,
            legacyServices: [legacyService]
        )

        try store.finishVerifiedCredential(
            secret,
            for: slot.account,
            recoveredFromService: nil
        )

        XCTAssertEqual(backend.storage[legacyService]?[slot.account], secret)
        XCTAssertTrue(backend.deletes.isEmpty)
        XCTAssertEqual(backend.reads, [
            .init(
                service: OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService,
                account: slot.account,
                interactive: false
            )
        ])
    }

    func test_interactiveRecoveryPrefersCanonicalCredentialOverStaleBackup() throws {
        let backend = CredentialServiceRecordingBackend()
        let canonical = Data("newer-canonical".utf8)
        let staleBackup = Data("older-backup".utf8)
        backend.storage[OpenBurnBarIdentity.daemonProviderSecretKeychainService] = [
            slot.account: canonical
        ]
        backend.storage[OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService] = [
            slot.account: staleBackup
        ]
        let store = KeychainProviderCredentialCustodyStore(
            backend: backend,
            legacyServices: []
        )

        let recovered = try XCTUnwrap(
            store.recoverLegacyCredentialInteractively(for: slot.account)
        )

        XCTAssertEqual(recovered.service, OpenBurnBarIdentity.daemonProviderSecretKeychainService)
        XCTAssertEqual(recovered.data, canonical)
        XCTAssertEqual(backend.reads, [
            .init(
                service: OpenBurnBarIdentity.daemonProviderSecretKeychainService,
                account: slot.account,
                interactive: true
            )
        ])
    }

    func test_verifiedCurrentCredentialRemovesMismatchedStaleBackupWithoutPromptingLegacy() throws {
        let backend = CredentialServiceRecordingBackend()
        let canonical = Data("newer-canonical".utf8)
        let staleBackup = Data("older-backup".utf8)
        let legacyService = OpenBurnBarIdentity.providerAPIKeychainService
        backend.storage[legacyService] = [slot.account: staleBackup]
        backend.storage[OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService] = [
            slot.account: staleBackup
        ]
        let store = KeychainProviderCredentialCustodyStore(
            backend: backend,
            legacyServices: [legacyService]
        )

        try store.finishVerifiedCredential(
            canonical,
            for: slot.account,
            recoveredFromService: nil
        )

        XCTAssertNil(
            backend.storage[OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService]?[slot.account]
        )
        XCTAssertEqual(backend.storage[legacyService]?[slot.account], staleBackup)
        XCTAssertEqual(backend.deletes, [
            .init(
                service: OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService,
                account: slot.account,
                interactive: false
            )
        ])
    }

    func test_partialFailureDoesNotBlockRemainingSlots() async {
        let second = ProviderCredentialCustodySlot(
            providerID: "minimax",
            slotID: "backup",
            label: "Backup",
            isEnabled: true,
            status: .ready,
            endpointProfileID: nil,
            region: nil,
            tokenPlanTier: nil,
            tokenPlanBillingCycle: nil,
            authMethodID: nil
        )
        let store = ProviderCredentialCustodyStoreSpy(legacy: [
            slot.account: .init(data: Data("first-secret".utf8), service: "legacy"),
            second.account: .init(data: Data("second-secret".utf8), service: "legacy")
        ])

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot, second]) { candidate, _ in
                if candidate == slot { throw TestFailure.daemon }
            }

        XCTAssertEqual(results.map(\.disposition), [.failed, .migrated])
        XCTAssertEqual(store.current[second.account], Data("second-secret".utf8))
        XCTAssertTrue(store.events.contains(.finish(second.account, "legacy")))
    }

    func test_absentCredentialDoesNotCallDaemon() async {
        let store = ProviderCredentialCustodyStoreSpy()
        var daemonCalled = false

        let missingSlot = ProviderCredentialCustodySlot(
            providerID: slot.providerID,
            slotID: slot.slotID,
            label: slot.label,
            isEnabled: slot.isEnabled,
            status: .missingSecret,
            endpointProfileID: slot.endpointProfileID,
            region: slot.region,
            tokenPlanTier: slot.tokenPlanTier,
            tokenPlanBillingCycle: slot.tokenPlanBillingCycle,
            authMethodID: slot.authMethodID
        )
        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [missingSlot]) { _, _ in daemonCalled = true }

        XCTAssertEqual(results.first?.disposition, .noCredential)
        XCTAssertFalse(daemonCalled)
    }

    func test_readySlotWithoutRecoverableCredentialFailsClosed() async {
        let store = ProviderCredentialCustodyStoreSpy()

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, _ in XCTFail("daemon must not be called") }

        XCTAssertEqual(results.first?.disposition, .failed)
        XCTAssertEqual(
            results.first?.failureClass,
            "ProviderCredentialCustodyMigrationError"
        )
    }

    func test_recoveredCredentialIsCanonicalizedOnceBeforeEveryWriteAndVerification() async {
        let original = Data("  séc-ret\n".utf8)
        let canonical = Data("séc-ret".utf8)
        let store = ProviderCredentialCustodyStoreSpy(
            legacy: [slot.account: .init(data: original, service: "legacy")]
        )
        var daemonCredential: String?

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, credential in daemonCredential = credential }

        XCTAssertEqual(results.first?.disposition, .migrated)
        XCTAssertEqual(store.current[slot.account], canonical)
        XCTAssertEqual(daemonCredential, "séc-ret")
    }

    func test_nonCanonicalCurrentCredentialFailsClosedWithoutDestructiveRewrite() async {
        let original = Data(" current-secret\n".utf8)
        let store = ProviderCredentialCustodyStoreSpy(
            current: [slot.account: original]
        )

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, _ in XCTFail("daemon must not be called") }

        XCTAssertEqual(results.first?.disposition, .failed)
        XCTAssertEqual(store.current[slot.account], original)
        XCTAssertEqual(store.events, [.currentRead(slot.account)])
    }

    @MainActor
    func test_lifecycleValidationFailsClosedAfterCollectingPerSlotFailures() {
        let results = [
            ProviderCredentialCustodyMigrationResult(
                providerID: "zai",
                slotID: "primary",
                disposition: .failed,
                failureClass: "TestFailure"
            ),
            ProviderCredentialCustodyMigrationResult(
                providerID: "minimax",
                slotID: "backup",
                disposition: .migrated,
                failureClass: nil
            )
        ]

        XCTAssertThrowsError(
            try OpenBurnBarDaemonManager.requireSuccessfulProviderCredentialCustodyMigration(results)
        )
    }

    func test_keychainStoreSearchesCanonicalThenLegacyAppServicesInteractively() throws {
        let backend = CredentialServiceRecordingBackend()
        let legacyService = OpenBurnBarIdentity.providerAPIKeychainService
        backend.storage[legacyService] = [slot.account: Data("legacy-app-secret".utf8)]
        let store = KeychainProviderCredentialCustodyStore(
            backend: backend,
            legacyServices: [legacyService]
        )

        let recovered = try XCTUnwrap(
            store.recoverLegacyCredentialInteractively(for: slot.account)
        )

        XCTAssertEqual(recovered.service, legacyService)
        XCTAssertEqual(recovered.data, Data("legacy-app-secret".utf8))
        XCTAssertEqual(backend.reads, [
            .init(
                service: OpenBurnBarIdentity.daemonProviderSecretKeychainService,
                account: slot.account,
                interactive: true
            ),
            .init(
                service: OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService,
                account: slot.account,
                interactive: true
            ),
            .init(service: legacyService, account: slot.account, interactive: true)
        ])
    }

    func test_verifiedRetryRemovesMatchingLegacyAndBackupCopies() throws {
        let backend = CredentialServiceRecordingBackend()
        let secret = Data("retry-secret".utf8)
        let legacyService = OpenBurnBarIdentity.providerAPIKeychainService
        backend.storage[legacyService] = [slot.account: secret]
        backend.storage[OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService] = [
            slot.account: secret
        ]
        let store = KeychainProviderCredentialCustodyStore(
            backend: backend,
            legacyServices: [legacyService]
        )

        try store.finishVerifiedCredential(
            secret,
            for: slot.account,
            recoveredFromService: nil
        )

        XCTAssertNil(backend.storage[legacyService]?[slot.account])
        XCTAssertNil(
            backend.storage[OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService]?[slot.account]
        )
        XCTAssertEqual(backend.deletes, [
            .init(service: legacyService, account: slot.account, interactive: true),
            .init(
                service: OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService,
                account: slot.account,
                interactive: false
            )
        ])
    }

    func test_backupIsRecoveredAfterInterruptedCanonicalRewrite() async {
        let backend = CredentialServiceRecordingBackend()
        let secret = Data("backup-only-secret".utf8)
        let matchingLegacyService = OpenBurnBarIdentity.providerAPIKeychainService
        let nonmatchingLegacyService = "com.openburnbar.unrelated-provider-secret"
        backend.storage[OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService] = [
            slot.account: secret
        ]
        backend.storage[matchingLegacyService] = [slot.account: secret]
        backend.storage[nonmatchingLegacyService] = [slot.account: Data("different-secret".utf8)]
        let store = KeychainProviderCredentialCustodyStore(
            backend: backend,
            legacyServices: [matchingLegacyService, nonmatchingLegacyService]
        )
        var daemonCredential: String?

        let results = await ProviderCredentialCustodyMigrator(store: store)
            .migrate(slots: [slot]) { _, credential in daemonCredential = credential }

        XCTAssertEqual(results.first?.disposition, .migrated)
        XCTAssertEqual(daemonCredential, "backup-only-secret")
        XCTAssertEqual(
            backend.storage[OpenBurnBarIdentity.daemonProviderSecretKeychainService]?[slot.account],
            secret
        )
        XCTAssertNil(
            backend.storage[OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService]?[slot.account]
        )
        XCTAssertNil(backend.storage[matchingLegacyService]?[slot.account])
        XCTAssertEqual(
            backend.storage[nonmatchingLegacyService]?[slot.account],
            Data("different-secret".utf8)
        )
    }

    func test_disabledReadySlotWithoutRecoverableCredentialFailsClosed() async {
        let disabledReadySlot = ProviderCredentialCustodySlot(
            providerID: slot.providerID,
            slotID: slot.slotID,
            label: slot.label,
            isEnabled: false,
            status: .ready,
            endpointProfileID: slot.endpointProfileID,
            region: slot.region,
            tokenPlanTier: slot.tokenPlanTier,
            tokenPlanBillingCycle: slot.tokenPlanBillingCycle,
            authMethodID: slot.authMethodID
        )

        let results = await ProviderCredentialCustodyMigrator(
            store: ProviderCredentialCustodyStoreSpy()
        ).migrate(slots: [disabledReadySlot]) { _, _ in
            XCTFail("daemon must not be called")
        }

        XCTAssertEqual(results.first?.disposition, .failed)
    }
}

private enum TestFailure: Error {
    case unexpectedRead
    case replacement
    case daemon
}

private final class CredentialServiceRecordingBackend: KeychainStoreBackend, @unchecked Sendable {
    struct Read: Equatable {
        let service: String
        let account: String
        let interactive: Bool
    }

    var storage: [String: [String: Data]] = [:]
    private(set) var reads: [Read] = []
    private(set) var deletes: [Read] = []

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        reads.append(.init(service: service, account: account, interactive: allowUserInteraction))
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        deletes.append(.init(service: service, account: account, interactive: false))
        storage[service]?[account] = nil
    }

    func delete(service: String, account: String, allowUserInteraction: Bool) throws {
        deletes.append(.init(
            service: service,
            account: account,
            interactive: allowUserInteraction
        ))
        storage[service]?[account] = nil
    }
}

private final class ProviderCredentialCustodyStoreSpy:
    ProviderCredentialCustodyStoring,
    @unchecked Sendable {
    enum Event: Equatable {
        case currentRead(String)
        case interactiveRead(String)
        case stageAndReplace(String)
        case finish(String, String?)
    }

    var current: [String: Data]
    var legacy: [String: RecoveredProviderCredential]
    var currentReadError: Error?
    var interactiveReadError: Error?
    var stageError: Error?
    private(set) var events: [Event] = []

    init(
        current: [String: Data] = [:],
        legacy: [String: RecoveredProviderCredential] = [:]
    ) {
        self.current = current
        self.legacy = legacy
    }

    func currentCredential(for account: String) throws -> Data? {
        events.append(.currentRead(account))
        if let currentReadError { throw currentReadError }
        return current[account]
    }

    func recoverLegacyCredentialInteractively(for account: String) throws -> RecoveredProviderCredential? {
        events.append(.interactiveRead(account))
        if let interactiveReadError { throw interactiveReadError }
        return legacy[account]
    }

    func stageAndReplaceCredential(_ credential: Data, for account: String) throws {
        events.append(.stageAndReplace(account))
        if let stageError { throw stageError }
        current[account] = credential
    }

    func finishVerifiedCredential(
        _ credential: Data,
        for account: String,
        recoveredFromService: String?
    ) throws {
        events.append(.finish(account, recoveredFromService))
        if recoveredFromService != nil {
            legacy[account] = nil
        }
    }
}
