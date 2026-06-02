import Foundation
import OSLog
import SwiftUI
@preconcurrency import FirebaseAuth
import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Data Control Center view model
//
// The callable hub for the macOS Data & Privacy Control Center (governance
// workbench). Mirrors `AccountManager`'s callable conventions
// (`Functions.functions(region: "us-central1").httpsCallable(...).call(...)`,
// `result.data as? [String: Any]`) and the CloudStore "user-facing error"
// distillation so the workbench never leaks a raw Functions error string.
//
// The domain inventory is built from the generated registry
// (gen/DataDomains.swift) merged with the live `getDataDomainUsage` snapshot —
// the registry is the source of truth for the *shape* (tier, paths, retention,
// actions) and the callable supplies live `count` / `bytes`. A domain whose
// usage row is missing renders count/bytes 0 rather than dropping the row, so
// the inventory always covers all 12 registry domains.

@Observable
@MainActor
final class DataControlCenterViewModel {

    // MARK: Inventory row

    /// One row in the inventory Table: a registry domain decorated with its
    /// live usage snapshot. Identifiable by the registry id so selection and
    /// sorting are stable across refreshes.
    struct DomainRow: Identifiable, Hashable {
        let domain: DataDomain
        var count: Int
        var bytes: Int64

        var id: String { domain.id }
        var title: String { domain.title }
        var tier: EncryptionTier { domain.encryptionTier }
        var retention: String { domain.retention }

        static func == (lhs: DomainRow, rhs: DomainRow) -> Bool {
            lhs.id == rhs.id && lhs.count == rhs.count && lhs.bytes == rhs.bytes
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(count)
            hasher.combine(bytes)
        }
    }

    /// Tiered Pensieve caps echoed from `getDataDomainUsage` (sources / chunks /
    /// bytes), used to draw the Pensieve usage meters against a hard ceiling.
    struct PensieveLimits: Equatable {
        var sources: Int
        var chunks: Int
        var bytes: Int64
    }

    enum Tier: String { case ultra, pro, free }

    // MARK: Recovery method (listRecovery)

    struct RecoveryMethod: Identifiable, Hashable {
        let recoveryId: String
        let kind: String
        let createdAt: Date?
        let confirmed: Bool
        var id: String { recoveryId }
    }

    // MARK: Audit event (getAuditLog)

    struct AuditEvent: Identifiable, Hashable {
        let seq: Int
        let ts: Date?
        let actor: String
        let action: String
        let domain: String
        let prevHash: String
        let hash: String
        var id: Int { seq }
    }

    // MARK: Published state

    private(set) var rows: [DomainRow] = []
    private(set) var tier: Tier = .free
    private(set) var pensieveLimits = PensieveLimits(sources: 0, chunks: 0, bytes: 0)
    private(set) var isLoadingUsage = false
    private(set) var usageError: String?

    private(set) var recoveryMethods: [RecoveryMethod] = []
    private(set) var isLoadingRecovery = false

    private(set) var auditEvents: [AuditEvent] = []
    private(set) var auditNextCursor: String?
    private(set) var isLoadingAudit = false
    private(set) var auditVerification: AuditVerification?

    private(set) var isExporting = false
    private(set) var isMutating = false
    private(set) var actionError: String?

    struct AuditVerification: Equatable {
        let valid: Bool
        let brokenAt: Int?
    }

    // MARK: Dependencies

    private let functionsRegion = "us-central1"
    private let accountManager: AccountManager
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.openburnbar.app",
        category: "DataControlCenter"
    )

    init(accountManager: AccountManager = .shared) {
        self.accountManager = accountManager
        // Seed the inventory from the registry immediately so the workbench
        // renders all 12 domains before the network call lands.
        rows = DataDomains.all.map { DomainRow(domain: $0, count: 0, bytes: 0) }
    }

    private func functions() -> Functions {
        Functions.functions(region: functionsRegion)
    }

    private var isSignedIn: Bool {
        accountManager.isSignedIn && accountManager.isAnonymousUser == false
    }

    // MARK: - Usage (getDataDomainUsage)

    func refreshUsage() async {
        guard isSignedIn else {
            usageError = "Sign in to OpenBurnBar to view your data."
            return
        }
        isLoadingUsage = true
        usageError = nil
        defer { isLoadingUsage = false }
        do {
            let result = try await functions().httpsCallable("getDataDomainUsage").call()
            guard let dict = result.data as? [String: Any] else {
                throw DataControlError.malformedResponse
            }
            applyUsage(dict)
        } catch {
            usageError = Self.userFacing(error)
            Self.logger.error("getDataDomainUsage failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyUsage(_ dict: [String: Any]) {
        if let rawTier = dict["tier"] as? String, let parsed = Tier(rawValue: rawTier) {
            tier = parsed
        }
        if let limits = dict["limits"] as? [String: Any],
           let pensieve = limits["pensieve"] as? [String: Any] {
            pensieveLimits = PensieveLimits(
                sources: intValue(pensieve["sources"]),
                chunks: intValue(pensieve["chunks"]),
                bytes: int64Value(pensieve["bytes"])
            )
        }
        var usageByID: [String: (count: Int, bytes: Int64)] = [:]
        if let domains = dict["domains"] as? [[String: Any]] {
            for entry in domains {
                guard let id = entry["id"] as? String else { continue }
                usageByID[id] = (intValue(entry["count"]), int64Value(entry["bytes"]))
            }
        }
        // Re-build from the registry so every domain row is present and ordered
        // exactly as the registry declares it.
        rows = DataDomains.all.map { domain in
            let usage = usageByID[domain.id]
            return DomainRow(domain: domain, count: usage?.count ?? 0, bytes: usage?.bytes ?? 0)
        }
    }

    func row(for id: String) -> DomainRow? {
        rows.first { $0.id == id }
    }

    /// The Basin "substance level": fraction of the user's data that is sealed
    /// (zero-access + end-to-end) by byte weight, falling back to row count when
    /// no byte sources report. Drives the mercury swirl fill height.
    var sealedFraction: Double {
        let sealedBytes = rows
            .filter { $0.tier != .serverReadable }
            .reduce(Int64(0)) { $0 + $1.bytes }
        let totalBytes = rows.reduce(Int64(0)) { $0 + $1.bytes }
        if totalBytes > 0 {
            return Double(sealedBytes) / Double(totalBytes)
        }
        let sealedCount = rows.filter { $0.tier != .serverReadable }.reduce(0) { $0 + $1.count }
        let totalCount = rows.reduce(0) { $0 + $1.count }
        return totalCount > 0 ? Double(sealedCount) / Double(totalCount) : 0
    }

    // MARK: - Export (exportUserData)

    /// Returns the pretty-printed export JSON for `domains` (nil = all). The
    /// caller writes it to disk via the macOS save panel (matching the repo's
    /// `NSSavePanel` export convention).
    func exportData(domains: [String]?) async -> Data? {
        guard isSignedIn else {
            actionError = "Sign in to OpenBurnBar to export your data."
            return nil
        }
        isExporting = true
        actionError = nil
        defer { isExporting = false }
        do {
            var payload: [String: Any] = [:]
            if let domains, domains.isEmpty == false { payload["domains"] = domains }
            let result = try await functions().httpsCallable("exportUserData").call(payload)
            guard let dict = result.data as? [String: Any] else {
                throw DataControlError.malformedResponse
            }
            return try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("exportUserData failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Surfaces a local file-write failure (from the macOS save panel path)
    /// using the same calm copy as the network errors.
    func setExportWriteError(_ error: Error) {
        actionError = Self.userFacing(error)
        Self.logger.error("export write failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Delete (deleteDomainData)

    struct DeleteResult: Equatable {
        let firestoreDocs: Int
        let storageObjects: Int
    }

    @discardableResult
    func deleteDomain(_ domainId: String) async -> DeleteResult? {
        guard isSignedIn else {
            actionError = "Sign in to OpenBurnBar to delete your data."
            return nil
        }
        isMutating = true
        actionError = nil
        defer { isMutating = false }
        do {
            let result = try await functions().httpsCallable("deleteDomainData").call([
                "domainId": domainId,
                "confirm": true
            ])
            guard let dict = result.data as? [String: Any] else {
                throw DataControlError.malformedResponse
            }
            let deleted = dict["deleted"] as? [String: Any]
            let outcome = DeleteResult(
                firestoreDocs: intValue(deleted?["firestoreDocs"]),
                storageObjects: intValue(deleted?["storageObjects"])
            )
            await refreshUsage()
            return outcome
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("deleteDomainData failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Recovery (setupRecovery / confirmRecovery / listRecovery)

    func refreshRecovery() async {
        guard isSignedIn else { return }
        isLoadingRecovery = true
        defer { isLoadingRecovery = false }
        do {
            let result = try await functions().httpsCallable("listRecovery").call()
            guard let dict = result.data as? [String: Any],
                  let methods = dict["methods"] as? [[String: Any]] else { return }
            recoveryMethods = methods.compactMap { entry in
                guard let recoveryId = entry["recoveryId"] as? String,
                      let kind = entry["kind"] as? String else { return nil }
                return RecoveryMethod(
                    recoveryId: recoveryId,
                    kind: kind,
                    createdAt: Self.parseDate(entry["createdAt"]),
                    confirmed: entry["confirmed"] as? Bool ?? false
                )
            }
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("listRecovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum RecoveryKind: String { case recoveryKey = "recovery_key", recoveryContact = "recovery_contact" }

    @discardableResult
    func setupRecovery(method: RecoveryKind, payload: [String: Any]) async -> String? {
        guard isSignedIn else {
            actionError = "Sign in to OpenBurnBar to set up recovery."
            return nil
        }
        isMutating = true
        actionError = nil
        defer { isMutating = false }
        do {
            let result = try await functions().httpsCallable("setupRecovery").call([
                "method": method.rawValue,
                "payload": payload
            ])
            guard let dict = result.data as? [String: Any],
                  let recoveryId = dict["recoveryId"] as? String else {
                throw DataControlError.malformedResponse
            }
            await refreshRecovery()
            return recoveryId
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("setupRecovery failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func confirmRecovery(recoveryId: String) async -> Bool {
        guard isSignedIn else { return false }
        isMutating = true
        actionError = nil
        defer { isMutating = false }
        do {
            _ = try await functions().httpsCallable("confirmRecovery").call(["recoveryId": recoveryId])
            await refreshRecovery()
            return true
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("confirmRecovery failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Panic (revokeAllAccess)

    struct RevokeResult: Equatable {
        let mcpClients: Int
        let devices: Int
        let escrowDevices: Int
        let providers: Int
    }

    enum RevokeScope: String { case sync, all }

    @discardableResult
    func revokeAllAccess(scope: RevokeScope) async -> RevokeResult? {
        guard isSignedIn else {
            actionError = "Sign in to OpenBurnBar to revoke access."
            return nil
        }
        isMutating = true
        actionError = nil
        defer { isMutating = false }
        do {
            let result = try await functions().httpsCallable("revokeAllAccess").call(["scope": scope.rawValue])
            guard let dict = result.data as? [String: Any] else {
                throw DataControlError.malformedResponse
            }
            let revoked = dict["revoked"] as? [String: Any]
            let outcome = RevokeResult(
                mcpClients: intValue(revoked?["mcpClients"]),
                devices: intValue(revoked?["devices"]),
                escrowDevices: intValue(revoked?["escrowDevices"]),
                providers: intValue(revoked?["providers"])
            )
            await refreshUsage()
            return outcome
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("revokeAllAccess failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Audit (getAuditLog / verifyAuditLog)

    func refreshAuditLog(reset: Bool = true) async {
        guard isSignedIn else { return }
        isLoadingAudit = true
        defer { isLoadingAudit = false }
        do {
            var payload: [String: Any] = ["limit": 100]
            if reset == false, let cursor = auditNextCursor { payload["cursor"] = cursor }
            let result = try await functions().httpsCallable("getAuditLog").call(payload)
            guard let dict = result.data as? [String: Any],
                  let events = dict["events"] as? [[String: Any]] else { return }
            let parsed = events.compactMap { Self.parseAuditEvent($0) }
            if reset { auditEvents = parsed } else { auditEvents.append(contentsOf: parsed) }
            auditNextCursor = dict["nextCursor"] as? String
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("getAuditLog failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func verifyAuditLog() async {
        guard isSignedIn else { return }
        isMutating = true
        actionError = nil
        defer { isMutating = false }
        do {
            let result = try await functions().httpsCallable("verifyAuditLog").call()
            guard let dict = result.data as? [String: Any] else {
                throw DataControlError.malformedResponse
            }
            auditVerification = AuditVerification(
                valid: dict["valid"] as? Bool ?? false,
                brokenAt: intValueOptional(dict["brokenAt"])
            )
        } catch {
            actionError = Self.userFacing(error)
            Self.logger.error("verifyAuditLog failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parsing helpers

    private func intValue(_ raw: Any?) -> Int {
        intValueOptional(raw) ?? 0
    }

    private func intValueOptional(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    private func int64Value(_ raw: Any?) -> Int64 {
        if let n = raw as? Int64 { return n }
        if let n = raw as? Int { return Int64(n) }
        if let n = raw as? Double { return Int64(n) }
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String, let n = Int64(s) { return n }
        return 0
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let iso = raw as? String {
            return iso8601.date(from: iso) ?? iso8601NoFraction.date(from: iso)
        }
        if let ms = raw as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = raw as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return nil
    }

    private static func parseAuditEvent(_ entry: [String: Any]) -> AuditEvent? {
        guard let seq = (entry["seq"] as? Int) ?? (entry["seq"] as? NSNumber)?.intValue else { return nil }
        return AuditEvent(
            seq: seq,
            ts: parseDate(entry["ts"]),
            actor: entry["actor"] as? String ?? "—",
            action: entry["action"] as? String ?? "—",
            domain: entry["domain"] as? String ?? "—",
            prevHash: entry["prevHash"] as? String ?? "",
            hash: entry["hash"] as? String ?? ""
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - User-facing error distillation
    //
    // Mirrors `CloudStoreSettingsView.userFacingBackupError` so the workbench
    // surfaces the same calm language for the same underlying Functions failures
    // instead of a raw `code=internal` string.

    static func userFacing(_ error: Error) -> String {
        let raw = (error as NSError).localizedDescription
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "Something went wrong. Try again." }
        let lower = trimmed.lowercased()
        if lower == "internal"
            || lower.contains("code=internal")
            || lower.contains("error 13")
            || lower.contains("signblob")
            || lower.contains("signed url") {
            return "We couldn't complete that securely. Try again in a minute."
        }
        if lower.contains("unauthenticated") || (lower.contains("auth") && lower.contains("expired")) {
            return "Sign in again to manage your data."
        }
        if lower.contains("permission") || lower.contains("denied") {
            return "This action isn't available for your account yet."
        }
        if lower.contains("network") || lower.contains("offline") || lower.contains("timed out") {
            return "Network connection failed. Try again when you're online."
        }
        return trimmed
    }
}

enum DataControlError: LocalizedError {
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "The server returned an unexpected response."
        }
    }
}
