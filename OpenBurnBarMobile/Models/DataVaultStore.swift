import Foundation
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Data Vault Callable Seam
//
// The Data & Privacy Control Center binds entirely to the documented Firebase
// onCall contract (region us-central1, App Check enforced, auth-gated). Every
// mutation goes through a callable; the client never writes the user tree
// directly. The seam is a protocol so previews/tests can inject a fake.

/// Per-domain usage snapshot from `getDataDomainUsage`.
struct DataDomainUsageRow: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let count: Int
    let bytes: Int
}

/// Pensieve per-tier hard caps from `getDataDomainUsage().limits.pensieve`.
struct PensieveLimitsDTO: Decodable, Hashable, Sendable {
    let sources: Int
    let chunks: Int
    let bytes: Int
}

struct DataDomainUsageResponse: Decodable, Sendable {
    let ok: Bool
    let tier: String
    let limits: Limits
    let domains: [DataDomainUsageRow]
    let schemaVersion: Int

    struct Limits: Decodable, Sendable { let pensieve: PensieveLimitsDTO }
}

/// One audit-log event from `getAuditLog` (tamper-evident hash chain).
struct AuditLogEvent: Decodable, Identifiable, Hashable, Sendable {
    let seq: Int
    let ts: String
    let actor: String
    let action: String
    let domain: String?
    let prevHash: String?
    let hash: String

    var id: Int { seq }
}

struct AuditLogPage: Decodable, Sendable {
    let ok: Bool
    let events: [AuditLogEvent]
    let nextCursor: String?
}

/// One configured recovery method from `listRecovery`.
struct RecoveryMethod: Decodable, Identifiable, Hashable, Sendable {
    let recoveryId: String
    let kind: String
    let createdAt: String
    let confirmed: Bool

    var id: String { recoveryId }
}

/// Aggregate counts returned by `revokeAllAccess` (PANIC).
struct RevokeAllResult: Decodable, Sendable {
    let mcpClients: Int
    let devices: Int
    let escrowDevices: Int
    let providers: Int
}

enum DataVaultError: LocalizedError {
    case malformedResponse
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .malformedResponse: return "The server returned an unexpected response."
        case .notSignedIn: return "Sign in to manage your data and privacy."
        }
    }
}

@MainActor
protocol DataVaultServicing: AnyObject {
    func getDataDomainUsage() async throws -> DataDomainUsageResponse
    func deleteDomainData(domainId: String) async throws -> (firestoreDocs: Int, storageObjects: Int)
    func getAuditLog(cursor: String?, limit: Int) async throws -> AuditLogPage
    func verifyAuditLog() async throws -> (valid: Bool, brokenAt: Int?)
    func listRecovery() async throws -> [RecoveryMethod]
    func setupRecovery(method: String, payload: [String: Any]) async throws -> String
    // recovery_key confirmation requires the re-entered key's verificationHash
    // (Apple ADP delayed re-verify); recovery_contact passes nil.
    func confirmRecovery(recoveryId: String, verificationHash: String?) async throws
    func revokeAllAccess(scope: String) async throws -> RevokeAllResult
    /// Drains locally-prepared Pensieve knowledge into the cloud (the documented
    /// "Sync now" action). Returns the number of chunks written, or nil if there
    /// was nothing to sync.
    func syncKnowledgeNow() async throws -> Int?
}

// MARK: - Live Functions adapter

@MainActor
final class FunctionsDataVaultService: DataVaultServicing {
    static let shared = FunctionsDataVaultService()

    private let functions = Functions.functions(region: "us-central1")
    private let preparedPayloadProvider: () -> [[String: Any]]

    /// `preparedPayloadProvider` supplies already-cloaked/sealed Pensieve
    /// batches for the "Sync now" action. Mobile commits prepared payloads only;
    /// desktop source ingestion lives in the Mac app/daemon target.
    init(preparedPayloadProvider: @escaping () -> [[String: Any]] = PensieveCommitQueueDrainer.readPreparedBatchPayloads) {
        self.preparedPayloadProvider = preparedPayloadProvider
    }

    func getDataDomainUsage() async throws -> DataDomainUsageResponse {
        let result = try await functions.httpsCallable("getDataDomainUsage").call([:])
        return try Self.decode(DataDomainUsageResponse.self, from: result.data)
    }

    func deleteDomainData(domainId: String) async throws -> (firestoreDocs: Int, storageObjects: Int) {
        let result = try await functions.httpsCallable("deleteDomainData").call([
            "domainId": domainId,
            "confirm": true,
        ])
        guard let dict = result.data as? [String: Any],
              let deleted = dict["deleted"] as? [String: Any] else {
            throw DataVaultError.malformedResponse
        }
        let docs = (deleted["firestoreDocs"] as? NSNumber)?.intValue ?? 0
        let objects = (deleted["storageObjects"] as? NSNumber)?.intValue ?? 0
        return (docs, objects)
    }

    func getAuditLog(cursor: String?, limit: Int) async throws -> AuditLogPage {
        var payload: [String: Any] = ["limit": max(1, min(limit, 200))]
        if let cursor, !cursor.isEmpty { payload["cursor"] = cursor }
        let result = try await functions.httpsCallable("getAuditLog").call(payload)
        return try Self.decode(AuditLogPage.self, from: result.data)
    }

    func verifyAuditLog() async throws -> (valid: Bool, brokenAt: Int?) {
        let result = try await functions.httpsCallable("verifyAuditLog").call([:])
        guard let dict = result.data as? [String: Any] else { throw DataVaultError.malformedResponse }
        let valid = dict["valid"] as? Bool ?? false
        let brokenAt = (dict["brokenAt"] as? NSNumber)?.intValue
        return (valid, brokenAt)
    }

    func listRecovery() async throws -> [RecoveryMethod] {
        let result = try await functions.httpsCallable("listRecovery").call([:])
        guard let dict = result.data as? [String: Any],
              let methods = dict["methods"] else { throw DataVaultError.malformedResponse }
        return try Self.decode([RecoveryMethod].self, from: methods)
    }

    func setupRecovery(method: String, payload: [String: Any]) async throws -> String {
        let result = try await functions.httpsCallable("setupRecovery").call([
            "method": method,
            "payload": payload,
        ])
        guard let dict = result.data as? [String: Any],
              let recoveryId = dict["recoveryId"] as? String, !recoveryId.isEmpty else {
            throw DataVaultError.malformedResponse
        }
        return recoveryId
    }

    func confirmRecovery(recoveryId: String, verificationHash: String?) async throws {
        var payload: [String: Any] = ["recoveryId": recoveryId]
        if let verificationHash { payload["verificationHash"] = verificationHash }
        _ = try await functions.httpsCallable("confirmRecovery").call(payload)
    }

    func revokeAllAccess(scope: String) async throws -> RevokeAllResult {
        let result = try await functions.httpsCallable("revokeAllAccess").call(["scope": scope])
        guard let dict = result.data as? [String: Any],
              let revoked = dict["revoked"] else { throw DataVaultError.malformedResponse }
        return try Self.decode(RevokeAllResult.self, from: revoked)
    }

    func syncKnowledgeNow() async throws -> Int? {
        guard AuthRepository.shared.isSignedIn else { throw DataVaultError.notSignedIn }
        let preparedPayloads = preparedPayloadProvider()
        guard !preparedPayloads.isEmpty else { return 0 }

        var written = 0
        for payload in preparedPayloads {
            written += try await commitPreparedKnowledgeBatch(payload)
        }
        return written
    }

    private func commitPreparedKnowledgeBatch(_ payload: [String: Any]) async throws -> Int {
        let result = try await functions.httpsCallable("commitKnowledgeBatch").call(payload)
        guard let dict = result.data as? [String: Any],
              dict["ok"] as? Bool != false else {
            throw DataVaultError.malformedResponse
        }
        return (dict["written"] as? NSNumber)?.intValue ?? 0
    }

    private static func decode<T: Decodable>(_ type: T.Type, from raw: Any?) throws -> T {
        guard let raw else { throw DataVaultError.malformedResponse }
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(raw)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Reads prepared, already-cloaked/sealed Pensieve commit payloads from the
/// app container. The Mac daemon normally owns the real queue, so this returns
/// an empty list on ordinary iOS installs unless app wiring injects payloads.
enum PensieveCommitQueueDrainer {
    static func readPreparedBatchPayloads() -> [[String: Any]] {
        guard let queueURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("pensieve-queue", isDirectory: true)
        else { return [] }

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: queueURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["sourceSlug"] is String,
                  payload["vectors"] is [[String: Any]] else {
                return nil
            }
            return payload
        }
    }
}

// MARK: - Store

/// Observable view-model for the Data & Privacy Control Center. Holds the usage
/// snapshot, recovery methods, audit page, and the in-flight action flags the
/// SwiftUI surfaces bind to.
@Observable
@MainActor
final class DataVaultStore {
    private let service: any DataVaultServicing

    private(set) var tier: String = "free"
    private(set) var pensieveLimits: PensieveLimitsDTO?
    private(set) var usageByDomain: [String: DataDomainUsageRow] = [:]
    private(set) var recoveryMethods: [RecoveryMethod] = []
    private(set) var auditEvents: [AuditLogEvent] = []
    private(set) var auditCursor: String?
    private(set) var auditVerified: Bool?
    private(set) var auditBrokenAt: Int?

    private(set) var isLoading = false
    private(set) var isSyncingKnowledge = false
    private(set) var deletingDomainID: String?
    private(set) var isRevoking = false
    private(set) var error: String?
    private(set) var lastKnowledgeSyncWritten: Int?

    init(service: any DataVaultServicing = FunctionsDataVaultService.shared) {
        self.service = service
    }

    /// Canonical domain list from the generated registry (no hardcoding).
    var domains: [DataDomain] { DataDomains.all }

    func usage(for domainID: String) -> DataDomainUsageRow? { usageByDomain[domainID] }

    /// Has the member crossed into a tier where Pensieve is usable?
    var isPensieveTier: Bool { tier == "pro" || tier == "ultra" }

    func load() async {
        guard AuthRepository.shared.isSignedIn else {
            error = DataVaultError.notSignedIn.localizedDescription
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let usage = try await service.getDataDomainUsage()
            tier = usage.tier
            pensieveLimits = usage.limits.pensieve
            usageByDomain = Dictionary(uniqueKeysWithValues: usage.domains.map { ($0.id, $0) })
            // Mirror the server-resolved tier so `subscriptionStore.isActiveUltra`
            // reflects the burnbar_ultra entitlement without re-plumbing the callable.
            UltraTierBridge.shared.tier = usage.tier
        } catch {
            self.error = error.localizedDescription
        }
        await loadRecovery()
    }

    func loadRecovery() async {
        guard AuthRepository.shared.isSignedIn else { return }
        recoveryMethods = (try? await service.listRecovery()) ?? recoveryMethods
    }

    /// The documented "Sync now" action — chunk → embed → cloak → seal →
    /// commitKnowledgeBatch, all on device.
    func syncKnowledgeNow() async {
        guard !isSyncingKnowledge else { return }
        isSyncingKnowledge = true
        error = nil
        defer { isSyncingKnowledge = false }
        do {
            lastKnowledgeSyncWritten = try await service.syncKnowledgeNow()
            await refreshPensieveUsage()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshPensieveUsage() async {
        guard let usage = try? await service.getDataDomainUsage() else { return }
        tier = usage.tier
        pensieveLimits = usage.limits.pensieve
        usageByDomain = Dictionary(uniqueKeysWithValues: usage.domains.map { ($0.id, $0) })
        UltraTierBridge.shared.tier = usage.tier
    }

    @discardableResult
    func deleteDomain(_ domainID: String) async -> Bool {
        guard deletingDomainID == nil else { return false }
        deletingDomainID = domainID
        error = nil
        defer { deletingDomainID = nil }
        do {
            _ = try await service.deleteDomainData(domainId: domainID)
            await refreshPensieveUsage()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func loadAudit(reset: Bool = false) async {
        if reset { auditEvents = []; auditCursor = nil }
        do {
            let page = try await service.getAuditLog(cursor: auditCursor, limit: 50)
            auditEvents.append(contentsOf: page.events)
            auditCursor = page.nextCursor
        } catch {
            self.error = error.localizedDescription
        }
    }

    func verifyAudit() async {
        do {
            let result = try await service.verifyAuditLog()
            auditVerified = result.valid
            auditBrokenAt = result.brokenAt
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func setupRecoveryKey(_ key: String) async -> Bool {
        do {
            guard let uid = Auth.auth().currentUser?.uid else { throw DataVaultError.notSignedIn }
            let vaultKey = try CloudVaultKeyStore().getOrCreateKey(uid: uid)
            let wrapped = try CloudVaultCrypto.wrapVaultKeyWithRecovery(vaultKey: vaultKey, recoveryKey: key)
            return await setupRecovery(method: "recovery_key", payload: [
                "algorithm": CloudVaultCrypto.aesGCMAlgorithm,
                "wrappedVaultKey": wrapped.wrappedVaultKeyBase64,
                "verificationHash": wrapped.verificationHash,
                "keyVersion": CloudVaultCrypto.currentKeyVersion,
            ])
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setupRecoveryContact(name: String, share: String) async -> Bool {
        await setupRecovery(method: "recovery_contact", payload: ["contactName": name, "share": share])
    }

    private func setupRecovery(method: String, payload: [String: Any]) async -> Bool {
        error = nil
        do {
            _ = try await service.setupRecovery(method: method, payload: payload)
            await loadRecovery()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func confirmRecovery(_ recoveryId: String, verificationHash: String? = nil) async {
        do {
            try await service.confirmRecovery(recoveryId: recoveryId, verificationHash: verificationHash)
            await loadRecovery()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func confirmRecoveryKey(_ recoveryId: String, recoveryKey: String) async {
        do {
            let verificationHash = try CloudVaultCrypto.recoveryVerificationHash(for: recoveryKey)
            await confirmRecovery(recoveryId, verificationHash: verificationHash)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func revokeAllAccess(scope: String) async -> RevokeAllResult? {
        guard !isRevoking else { return nil }
        isRevoking = true
        error = nil
        defer { isRevoking = false }
        do {
            return try await service.revokeAllAccess(scope: scope)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
