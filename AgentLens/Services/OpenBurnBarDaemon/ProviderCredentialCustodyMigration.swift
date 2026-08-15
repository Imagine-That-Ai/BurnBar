import Foundation
import OpenBurnBarKernel

struct ProviderCredentialCustodySlot: Hashable, Sendable {
    let providerID: String
    let slotID: String
    let label: String
    let isEnabled: Bool
    let status: BurnBarProviderCredentialSlotStatus
    let endpointProfileID: String?
    let region: ProviderEndpointRegion?
    let tokenPlanTier: MimoTokenPlanTier?
    let tokenPlanBillingCycle: MimoTokenPlanBillingCycle?
    let authMethodID: String?

    var account: String {
        "provider.\(providerID).slot.\(slotID).apiKey"
    }
}

enum ProviderCredentialCustodyMigrationDisposition: String, Equatable, Sendable {
    case alreadyCurrent
    case migrated
    case noCredential
    case failed
}

struct ProviderCredentialCustodyMigrationResult: Equatable, Sendable {
    let providerID: String
    let slotID: String
    let disposition: ProviderCredentialCustodyMigrationDisposition
    let failureClass: String?
}

protocol ProviderCredentialCustodyStoring: Sendable {
    func currentCredential(for account: String) throws -> Data?
    func recoverLegacyCredentialInteractively(for account: String) throws -> RecoveredProviderCredential?
    func stageAndReplaceCredential(_ credential: Data, for account: String) throws
    func finishVerifiedCredential(
        _ credential: Data,
        for account: String,
        recoveredFromService: String?
    ) throws
}

struct RecoveredProviderCredential: Equatable, Sendable {
    let data: Data
    let service: String
}

enum ProviderCredentialCustodyMigrationError: Error {
    case backupVerificationFailed
    case replacementVerificationFailed
    case invalidCredentialEncoding
    case nonCanonicalCurrentCredential
    case missingExpectedCredential
}

/// Rewrites an ACL-bound provider credential without ever making its only
/// recoverable copy disappear.
///
/// The daemon is intentionally a bare, entitlement-free helper. The host and
/// daemon are signed with the same designated requirement, so the durable
/// destination remains the ordinary login-Keychain service both processes
/// already use. A one-time interactive read recovers an item bound to an older
/// code signature. The value is then staged in a separate backup row, verified,
/// and recreated at the canonical service/account under the current designated
/// requirement. The backup is removed only after the daemon has independently
/// written and read back the exact value through its authenticated RPC.
struct KeychainProviderCredentialCustodyStore: ProviderCredentialCustodyStoring {
    private let backend: any KeychainStoreBackend
    private let service: String
    private let backupService: String
    private let legacyServices: [String]

    init(
        backend: any KeychainStoreBackend = SecurityKeychainStoreBackend(),
        service: String = OpenBurnBarIdentity.daemonProviderSecretKeychainService,
        backupService: String = OpenBurnBarIdentity.daemonProviderSecretMigrationBackupKeychainService,
        legacyServices: [String] = [
            OpenBurnBarIdentity.cursorConnectorKeychainService
        ] + OpenBurnBarIdentity.legacyCursorConnectorKeychainServices
            + [OpenBurnBarIdentity.providerAPIKeychainService]
            + OpenBurnBarIdentity.legacyProviderAPIKeychainServices
    ) {
        self.backend = backend
        self.service = service
        self.backupService = backupService
        self.legacyServices = legacyServices
    }

    func currentCredential(for account: String) throws -> Data? {
        try backend.data(for: service, account: account, allowUserInteraction: false)
    }

    func recoverLegacyCredentialInteractively(for account: String) throws -> RecoveredProviderCredential? {
        // The canonical row may be present but unreadable without user
        // authorization. It must win over an older interrupted-transaction
        // backup so repair can never roll a newer credential back.
        for candidateService in [service, backupService] + legacyServices {
            if let data = try backend.data(
                for: candidateService,
                account: account,
                allowUserInteraction: true
            ) {
                return RecoveredProviderCredential(data: data, service: candidateService)
            }
        }
        return nil
    }

    func stageAndReplaceCredential(_ credential: Data, for account: String) throws {
        try backend.set(credential, service: backupService, account: account)
        guard try backend.data(
            for: backupService,
            account: account,
            allowUserInteraction: false
        ) == credential else {
            throw ProviderCredentialCustodyMigrationError.backupVerificationFailed
        }

        // The stale ACL can require the same explicit user authorization as
        // the recovery read. This is the only interactive delete in the app;
        // routine/background cleanup remains prompt-free.
        try backend.delete(service: service, account: account, allowUserInteraction: true)
        try backend.set(credential, service: service, account: account)
        guard try backend.data(
            for: service,
            account: account,
            allowUserInteraction: false
        ) == credential else {
            // The verified backup deliberately remains intact. Do not perform
            // an unrecorded second rewrite or claim the original ACL was
            // restored after its row was removed.
            throw ProviderCredentialCustodyMigrationError.replacementVerificationFailed
        }
    }

    func finishVerifiedCredential(
        _ credential: Data,
        for account: String,
        recoveredFromService: String?
    ) throws {
        let backup = try backend.data(
            for: backupService,
            account: account,
            allowUserInteraction: false
        )
        let completedMigration = recoveredFromService != nil || backup == credential
        if completedMigration {
            for legacyService in legacyServices {
                let legacy = try backend.data(
                    for: legacyService,
                    account: account,
                    allowUserInteraction: true
                )
                if legacy == credential {
                    try backend.delete(
                        service: legacyService,
                        account: account,
                        allowUserInteraction: true
                    )
                }
            }
        }
        // Once the canonical value has been verified through the daemon, any
        // remaining backup is obsolete—even if it contains different bytes.
        // Keeping it would create a future rollback source if canonical access
        // later requires interaction.
        if backup != nil {
            try backend.delete(service: backupService, account: account)
        }
    }
}

struct ProviderCredentialCustodyMigrator: Sendable {
    typealias DaemonVerifier = @Sendable (
        _ slot: ProviderCredentialCustodySlot,
        _ credential: String
    ) async throws -> Void

    private let store: any ProviderCredentialCustodyStoring

    init(store: any ProviderCredentialCustodyStoring = KeychainProviderCredentialCustodyStore()) {
        self.store = store
    }

    func migrate(
        slots: [ProviderCredentialCustodySlot],
        verifyWithDaemon: DaemonVerifier
    ) async -> [ProviderCredentialCustodyMigrationResult] {
        var results: [ProviderCredentialCustodyMigrationResult] = []
        results.reserveCapacity(slots.count)

        for slot in slots {
            do {
                let current = try store.currentCredential(for: slot.account)
                let recovered: RecoveredProviderCredential?
                let credentialData: Data
                var requiresReplacement: Bool
                if let current {
                    credentialData = current
                    requiresReplacement = false
                    recovered = nil
                } else if let legacy = try store.recoverLegacyCredentialInteractively(for: slot.account) {
                    credentialData = legacy.data
                    requiresReplacement = true
                    recovered = legacy
                } else {
                    if (slot.isEnabled || slot.status == .ready) && slot.status != .missingSecret {
                        throw ProviderCredentialCustodyMigrationError.missingExpectedCredential
                    }
                    results.append(.init(
                        providerID: slot.providerID,
                        slotID: slot.slotID,
                        disposition: .noCredential,
                        failureClass: nil
                    ))
                    continue
                }

                guard let decodedCredential = String(data: credentialData, encoding: .utf8) else {
                    throw ProviderCredentialCustodyMigrationError.invalidCredentialEncoding
                }
                let credential = decodedCredential.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !credential.isEmpty else {
                    throw ProviderCredentialCustodyMigrationError.invalidCredentialEncoding
                }
                let canonicalCredentialData = Data(credential.utf8)
                if current != nil && credentialData != canonicalCredentialData {
                    throw ProviderCredentialCustodyMigrationError.nonCanonicalCurrentCredential
                }

                if requiresReplacement {
                    try store.stageAndReplaceCredential(canonicalCredentialData, for: slot.account)
                }

                try await verifyWithDaemon(slot, credential)

                try store.finishVerifiedCredential(
                    canonicalCredentialData,
                    for: slot.account,
                    recoveredFromService: recovered?.service
                )
                results.append(.init(
                    providerID: slot.providerID,
                    slotID: slot.slotID,
                    disposition: requiresReplacement ? .migrated : .alreadyCurrent,
                    failureClass: nil
                ))
            } catch {
                results.append(.init(
                    providerID: slot.providerID,
                    slotID: slot.slotID,
                    disposition: .failed,
                    failureClass: String(describing: type(of: error))
                ))
            }
        }

        return results
    }
}
