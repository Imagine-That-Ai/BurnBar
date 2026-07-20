import Foundation
import OpenBurnBarEngine
import OpenBurnBarLinuxSecurity

/// Daemon-owned encrypted persistence for Linux in-app text expansion.
///
/// The renderer receives typed snapshots over the authenticated daemon socket;
/// it never owns a durable snippet file. The file envelope is AES-GCM sealed
/// and its 256-bit key is held by an approved Linux native secret backend.
// AUDIT(@unchecked Sendable): persistence state is guarded by `lock`; the Linux
// engine lifecycle is isolated in an actor. sendable-allowlist: internal-lock-snapshot-store
public final class BurnBarTextExpansionService: @unchecked Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let sealedBase64: String
    }

    public enum ServiceError: Error, LocalizedError, Equatable {
        case unsupportedPlatform
        case keyStorageUnavailable
        case invalidKey
        case corruptStore
        case invalidSnippet(String)
        case duplicateTrigger
        case invalidConsent
        case invalidRuntimeRequest
        case tooManySnippets
        case snapshotTooLarge
        case invalidIdentifier

        public var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return "Native text expansion storage is unavailable on this platform."
            case .keyStorageUnavailable:
                return "Linux Secret Service or KWallet is required for encrypted text expansion storage."
            case .invalidKey:
                return "The native text expansion encryption key is invalid."
            case .corruptStore:
                return "The encrypted text expansion store is corrupt or cannot be authenticated."
            case .invalidSnippet(let detail):
                return detail
            case .duplicateTrigger:
                return "An enabled text expansion snippet already uses this trigger."
            case .invalidConsent:
                return "Text expansion consent must explicitly allow in-app use and decline global capture."
            case .invalidRuntimeRequest:
                return "Text expansion engine lifecycle timeout is outside the supported range."
            case .tooManySnippets:
                return "Text expansion has reached its 500-snippet limit."
            case .snapshotTooLarge:
                return "The encrypted text expansion store exceeds its size limit."
            case .invalidIdentifier:
                return "The text expansion snippet identifier is invalid."
            }
        }
    }

    private static let envelopeSchemaVersion = 1
    private static let snapshotSchemaVersion = 1
    private static let keyID = "text-expansion-v1"
    private static let aad = Data("OpenBurnBar.text-expansion.v1".utf8)
    private static let maximumSnippets = 500
    private static let maximumTitleBytes = 256
    private static let maximumTriggerBytes = 64
    private static let maximumBodyBytes = 128 * 1024
    private static let maximumStoreBytes = 4 * 1024 * 1024
    private static let inAppSurface = "in_app_thread"
    private static let staticMode = "static"
    private static let llmRewriteMode = "llm_rewrite"
    private static let triggerPrefix = "&&"
    private static let minimumTriggerLength = 2

#if os(Linux)
    /// Serializes engine lifecycle transitions without holding the persistence
    /// lock across an async process launch or shutdown.
    private actor LinuxTextExpansionEngineRuntime {
        private let adapter: BurnBarLinuxTextExpansionAdapter
        private var session: BurnBarLinuxTextExpansionAdapter.ExternalEngineSession?
        private var nativeStatus: BurnBarLinuxTextExpansionAdapter.Status?
        private var lastStatus: BurnBarTextExpansionEngineRuntimeStatus?

        init(adapter: BurnBarLinuxTextExpansionAdapter) {
            self.adapter = adapter
        }

        func status() async -> BurnBarTextExpansionEngineRuntimeStatus {
            if let session {
                let runtime = await session.status()
                let status = Self.map(runtime: runtime, native: nativeStatus ?? adapter.typedStatus())
                lastStatus = status
                return status
            }
            if let lastStatus { return lastStatus }
            let native = adapter.typedStatus()
            nativeStatus = native
            return Self.map(native: native)
        }

        func start(timeoutMillis: Int) async throws -> BurnBarTextExpansionEngineRuntimeStatus {
            let native = adapter.typedStatus()
            nativeStatus = native
            if let current = session {
                _ = await current.stop(timeoutMillis: 500)
                session = nil
            }
            let killSwitch: @Sendable () -> Bool = {
                LinuxPrivilegedInputKillFlag.isActive()
                    || LinuxPrivilegedInputKillFlag.environmentKillSwitchActive()
            }
            let started = try await adapter.startExternalEngine(
                timeoutMillis: timeoutMillis,
                killSwitch: killSwitch
            )
            let runtime = await started.status()
            session = started
            let status = Self.map(runtime: runtime, native: native)
            lastStatus = status
            return status
        }

        func stop(timeoutMillis: Int) async -> BurnBarTextExpansionEngineRuntimeStatus {
            guard let current = session else {
                return await status()
            }
            let runtime = await current.stop(timeoutMillis: timeoutMillis)
            session = nil
            let status = Self.map(runtime: runtime, native: nativeStatus ?? adapter.typedStatus())
            lastStatus = status
            return status
        }

        func expand(
            trigger: String,
            context: BurnBarLinuxTextExpansionAdapter.SecureFieldContext,
            timeoutMillis: Int,
            requestID: String
        ) async throws -> String? {
            guard let session else {
                throw BurnBarLinuxTextExpansionAdapter.EngineRuntimeError.sessionStopped
            }
            let replacement = try await session.expand(
                trigger: trigger,
                context: context,
                timeoutMillis: timeoutMillis,
                requestID: requestID
            )
            let runtime = await session.status()
            let status = Self.map(runtime: runtime, native: nativeStatus ?? adapter.typedStatus())
            lastStatus = status
            return replacement
        }

        private static func map(
            runtime: BurnBarLinuxTextExpansionAdapter.EngineRuntimeStatus,
            native: BurnBarLinuxTextExpansionAdapter.Status
        ) -> BurnBarTextExpansionEngineRuntimeStatus {
            BurnBarTextExpansionEngineRuntimeStatus(
                state: runtime.state.rawValue,
                engineID: runtime.engineID,
                executablePath: runtime.executablePath,
                registration: native.registration.rawValue,
                supportsExternalExpansion: native.supportsExternalExpansion,
                detail: runtime.detail,
                checkedAt: runtime.checkedAt
            )
        }

        private static func map(
            native: BurnBarLinuxTextExpansionAdapter.Status
        ) -> BurnBarTextExpansionEngineRuntimeStatus {
            BurnBarTextExpansionEngineRuntimeStatus(
                state: "not_running",
                registration: native.registration.rawValue,
                supportsExternalExpansion: native.supportsExternalExpansion,
                detail: native.detail,
                checkedAt: native.checkedAt
            )
        }
    }

    private let linuxTextExpansionAdapter: BurnBarLinuxTextExpansionAdapter
    private let linuxEngineRuntime: LinuxTextExpansionEngineRuntime
#endif

    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let logger: BurnBarDaemonLogger
#if os(Linux)
    private let secretStore: LinuxSecretCustodian
#endif

#if os(Linux)
    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultTextExpansionURL,
        secretStore: LinuxSecretCustodian = LinuxSecretStoreFactory.production(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "text-expansion"),
        textExpansionAdapter: BurnBarLinuxTextExpansionAdapter = BurnBarLinuxTextExpansionAdapter()
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        self.logger = logger
        self.encoder = Self.makeEncoder()
        self.linuxTextExpansionAdapter = textExpansionAdapter
        self.linuxEngineRuntime = LinuxTextExpansionEngineRuntime(adapter: textExpansionAdapter)
    }
#else
    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultTextExpansionURL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "text-expansion")
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.encoder = Self.makeEncoder()
    }
#endif

    public func snapshot() throws -> BurnBarTextExpansionSnapshot {
        try withLock {
            try responseSnapshot(from: readSnapshot())
        }
    }

    public func upsert(_ request: BurnBarTextExpansionUpsertRequest) throws -> BurnBarTextExpansionWireSnippet {
        try withLock {
            var snapshot = try readSnapshot()
            var snippets = snapshot.snippets
            let candidate = try validate(request.snippet)
            let now = Self.isoNow()
            let existingIndex = snippets.firstIndex { $0.id == candidate.id }
            let replacement: BurnBarTextExpansionWireSnippet
            if let existingIndex {
                let existing = snapshot.snippets[existingIndex]
                replacement = Self.copy(
                    candidate,
                    revision: max(existing.revision + 1, candidate.revision),
                    createdAt: existing.createdAt,
                    updatedAt: now,
                    deletedAt: nil
                )
                if snippets.enumerated().contains(where: {
                    $0.offset != existingIndex && $0.element.deletedAt == nil &&
                        $0.element.trigger == replacement.trigger
                }) {
                    throw ServiceError.duplicateTrigger
                }
                snippets[existingIndex] = replacement
            } else {
                guard snippets.count < Self.maximumSnippets else {
                    throw ServiceError.tooManySnippets
                }
                guard snippets.allSatisfy({
                    $0.deletedAt != nil || $0.trigger != candidate.trigger
                }) else {
                    throw ServiceError.duplicateTrigger
                }
                replacement = Self.copy(candidate, updatedAt: now, deletedAt: nil)
                snippets.append(replacement)
            }
            snapshot = BurnBarTextExpansionSnapshot(
                schemaVersion: snapshot.schemaVersion,
                exportedAt: snapshot.exportedAt,
                snippets: snippets,
                consent: snapshot.consent
            )
            try writeSnapshot(snapshot)
            logger.notice("text_expansion_upserted", metadata: ["snippet_id": replacement.id])
            return replacement
        }
    }

    public func delete(_ request: BurnBarTextExpansionDeleteRequest) throws -> BurnBarTextExpansionSnapshot {
        try withLock {
            guard request.id.utf8.count <= 128, request.id.contains("\0") == false else {
                throw ServiceError.invalidIdentifier
            }
            var snapshot = try readSnapshot()
            guard let index = snapshot.snippets.firstIndex(where: { $0.id == request.id }) else {
                return snapshot
            }
            let now = Self.isoNow()
            let existing = snapshot.snippets[index]
            var snippets = snapshot.snippets
            snippets[index] = Self.copy(
                existing,
                isEnabled: false,
                revision: existing.revision + 1,
                updatedAt: now,
                deletedAt: now
            )
            snapshot = BurnBarTextExpansionSnapshot(
                schemaVersion: snapshot.schemaVersion,
                exportedAt: snapshot.exportedAt,
                snippets: snippets,
                consent: snapshot.consent
            )
            try writeSnapshot(snapshot)
            logger.notice("text_expansion_deleted", metadata: ["snippet_id": request.id])
            return responseSnapshot(from: snapshot)
        }
    }

    public func updateConsent(
        _ request: BurnBarTextExpansionConsentUpdateRequest
    ) throws -> BurnBarTextExpansionConsentResponse {
        try withLock {
            guard request.declinedGlobalCapture else { throw ServiceError.invalidConsent }
            var snapshot = try readSnapshot()
            let consent = BurnBarTextExpansionConsent(
                inAppOnly: request.inAppOnly,
                acknowledgedAt: Self.isoNow(),
                declinedGlobalCapture: true
            )
            snapshot = BurnBarTextExpansionSnapshot(
                schemaVersion: snapshot.schemaVersion,
                exportedAt: snapshot.exportedAt,
                snippets: snapshot.snippets,
                consent: consent
            )
            try writeSnapshot(snapshot)
            return BurnBarTextExpansionConsentResponse(consent: consent)
        }
    }

    /// Returns daemon-authoritative external engine lifecycle state. No
    /// renderer-provided state is trusted and no text payload is involved.
    public func engineRuntimeStatus() async -> BurnBarTextExpansionEngineRuntimeStatus {
#if os(Linux)
        await linuxEngineRuntime.status()
#else
        BurnBarTextExpansionEngineRuntimeStatus(
            state: "unsupported",
            registration: "unsupported",
            supportsExternalExpansion: false,
            detail: ServiceError.unsupportedPlatform.localizedDescription,
            checkedAt: Self.isoNow()
        )
#endif
    }

    public func startExternalEngine(
        _ request: BurnBarTextExpansionEngineStartRequest
    ) async throws -> BurnBarTextExpansionEngineRuntimeStatus {
        guard request.consentAcknowledged else { throw ServiceError.invalidConsent }
        guard (100...30_000).contains(request.timeoutMillis) else {
            throw ServiceError.invalidRuntimeRequest
        }
        let consent = try withLock { try readSnapshot().consent }
        guard consent?.inAppOnly == true, consent?.declinedGlobalCapture == true else {
            throw ServiceError.invalidConsent
        }
#if os(Linux)
        guard LinuxPrivilegedInputKillFlag.isActive() == false,
              LinuxPrivilegedInputKillFlag.environmentKillSwitchActive() == false else {
            throw BurnBarLinuxTextExpansionAdapter.EngineRuntimeError.killSwitchActive
        }
        return try await linuxEngineRuntime.start(timeoutMillis: request.timeoutMillis)
#else
        throw ServiceError.unsupportedPlatform
#endif
    }

    public func stopExternalEngine(
        _ request: BurnBarTextExpansionEngineStopRequest
    ) async throws -> BurnBarTextExpansionEngineRuntimeStatus {
        guard (100...30_000).contains(request.timeoutMillis) else {
            throw ServiceError.invalidRuntimeRequest
        }
#if os(Linux)
        return await linuxEngineRuntime.stop(timeoutMillis: request.timeoutMillis)
#else
        throw ServiceError.unsupportedPlatform
#endif
    }

    /// Requests one trigger-only expansion from the signed external engine.
    /// Consent remains daemon-owned, secure-field metadata is evaluated here,
    /// and no keyboard, clipboard, surrounding-text, or field payload can be
    /// forwarded through this API.
    public func expandExternalEngine(
        _ request: BurnBarTextExpansionEngineExpandRequest
    ) async throws -> BurnBarTextExpansionEngineExpandResponse {
#if os(Linux)
        let context = BurnBarLinuxTextExpansionAdapter.SecureFieldContext(
            inspectable: request.context.inspectable,
            isSecureField: request.context.isSecureField,
            applicationID: request.context.applicationID,
            role: request.context.role,
            inputPurpose: request.context.inputPurpose
        )
        let replacement = try await expandExternalEngine(
            trigger: request.trigger,
            context: context,
            timeoutMillis: request.timeoutMillis,
            requestID: request.requestID
        )
        return BurnBarTextExpansionEngineExpandResponse(replacement: replacement)
#else
        throw ServiceError.unsupportedPlatform
#endif
    }

#if os(Linux)
    public func expandExternalEngine(
        trigger: String,
        context: BurnBarLinuxTextExpansionAdapter.SecureFieldContext,
        timeoutMillis: Int = 1_000,
        requestID: String = UUID().uuidString
    ) async throws -> String? {
        guard (100...30_000).contains(timeoutMillis) else {
            throw ServiceError.invalidRuntimeRequest
        }
        let consent = try withLock { try readSnapshot().consent }
        guard consent?.inAppOnly == true, consent?.declinedGlobalCapture == true else {
            throw ServiceError.invalidConsent
        }
        guard LinuxPrivilegedInputKillFlag.isActive() == false,
              LinuxPrivilegedInputKillFlag.environmentKillSwitchActive() == false else {
            throw BurnBarLinuxTextExpansionAdapter.EngineRuntimeError.killSwitchActive
        }
        return try await linuxEngineRuntime.expand(
            trigger: trigger,
            context: context,
            timeoutMillis: timeoutMillis,
            requestID: requestID
        )
    }
#endif

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func readSnapshot() throws -> BurnBarTextExpansionSnapshot {
#if os(Linux)
        let key = try encryptionKey()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Self.emptySnapshot()
        }
        guard isSafeStoreFile(fileURL),
              let bytes = try? Data(contentsOf: fileURL),
              bytes.count <= Self.maximumStoreBytes,
              let envelope = try? decoder.decode(Envelope.self, from: bytes),
              envelope.schemaVersion == Self.envelopeSchemaVersion,
              let sealed = Data(base64Encoded: envelope.sealedBase64),
              sealed.count > 28,
              let plaintext = try? PlatformCrypto.openAESGCM(
                  combined: sealed,
                  keyData: key,
                  authenticating: Self.aad
              ),
              let snapshot = try? decoder.decode(BurnBarTextExpansionSnapshot.self, from: plaintext)
        else {
            throw ServiceError.corruptStore
        }
        return try validate(snapshot)
#else
        throw ServiceError.unsupportedPlatform
#endif
    }

    private func writeSnapshot(_ rawSnapshot: BurnBarTextExpansionSnapshot) throws {
#if os(Linux)
        let snapshot = try validate(rawSnapshot)
        let plaintext = try encoder.encode(snapshot)
        guard plaintext.count <= Self.maximumStoreBytes else { throw ServiceError.snapshotTooLarge }
        let sealed = try PlatformCrypto.sealAESGCM(
            plaintext: plaintext,
            keyData: try encryptionKey(),
            authenticating: Self.aad
        )
        let envelope = Envelope(
            schemaVersion: Self.envelopeSchemaVersion,
            sealedBase64: sealed.base64EncodedString()
        )
        let bytes = try encoder.encode(envelope)
        guard bytes.count <= Self.maximumStoreBytes else { throw ServiceError.snapshotTooLarge }
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let temporary = parent.appendingPathComponent(".text-expansion-v1.\(ProcessInfo.processInfo.processIdentifier).tmp")
        try bytes.write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: temporary, to: fileURL)
#else
        throw ServiceError.unsupportedPlatform
#endif
    }

    private func validate(_ snapshot: BurnBarTextExpansionSnapshot) throws -> BurnBarTextExpansionSnapshot {
        guard snapshot.schemaVersion == Self.snapshotSchemaVersion,
              snapshot.snippets.count <= Self.maximumSnippets else {
            throw ServiceError.tooManySnippets
        }
        var ids = Set<String>()
        var triggers = Set<String>()
        let snippets = try snapshot.snippets.map { snippet in
            let normalized = try validate(snippet)
            guard ids.insert(normalized.id).inserted else { throw ServiceError.invalidSnippet("Duplicate text expansion id.") }
            if normalized.deletedAt == nil {
                guard triggers.insert(normalized.trigger).inserted else { throw ServiceError.duplicateTrigger }
            }
            return normalized
        }
        if let consent = snapshot.consent, !consent.declinedGlobalCapture {
            throw ServiceError.invalidConsent
        }
        return BurnBarTextExpansionSnapshot(
            schemaVersion: Self.snapshotSchemaVersion,
            exportedAt: snapshot.exportedAt,
            snippets: snippets,
            consent: snapshot.consent,
            nativeStatus: nil
        )
    }

    private func responseSnapshot(from snapshot: BurnBarTextExpansionSnapshot) -> BurnBarTextExpansionSnapshot {
#if os(Linux)
        return BurnBarTextExpansionSnapshot(
            schemaVersion: snapshot.schemaVersion,
            exportedAt: snapshot.exportedAt,
            snippets: snapshot.snippets,
            consent: snapshot.consent,
            nativeStatus: linuxTextExpansionAdapter.status()
        )
#else
        return snapshot
#endif
    }

    private func validate(_ snippet: BurnBarTextExpansionWireSnippet) throws -> BurnBarTextExpansionWireSnippet {
        let id = snippet.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 128, id.contains("\0") == false else {
            throw ServiceError.invalidIdentifier
        }
        let title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= Self.maximumTitleBytes else {
            throw ServiceError.invalidSnippet("Text expansion title is empty or too long.")
        }
        let trigger = Self.canonicalTrigger(snippet.trigger)
        guard Self.isValidTrigger(trigger), trigger.utf8.count <= Self.maximumTriggerBytes else {
            throw ServiceError.invalidSnippet("Text expansion trigger must use 2-64 lowercase letters, numbers, '-' or '_'.")
        }
        guard snippet.body.utf8.count <= Self.maximumBodyBytes else {
            throw ServiceError.invalidSnippet("Text expansion body is too long.")
        }
        guard snippet.mode == Self.staticMode || snippet.mode == Self.llmRewriteMode else {
            throw ServiceError.invalidSnippet("Text expansion mode is unsupported.")
        }
        guard snippet.scope.surfaces == [Self.inAppSurface],
              snippet.scope.bundleIdentifiers.isEmpty,
              snippet.scope.threadIDs.isEmpty else {
            throw ServiceError.invalidSnippet("Linux text expansion storage only accepts the in-app surface.")
        }
        guard !snippet.createdAt.isEmpty, !snippet.updatedAt.isEmpty else {
            throw ServiceError.invalidSnippet("Text expansion timestamps are required.")
        }
        return Self.copy(
            snippet,
            id: id,
            title: title,
            trigger: trigger,
            scope: BurnBarTextExpansionScope(surfaces: [Self.inAppSurface]),
            revision: max(1, snippet.revision)
        )
    }

    private func encryptionKey() throws -> Data {
#if os(Linux)
        do {
            let record = try secretStore.requireHighValueSecret(
                id: Self.keyID,
                secretClass: .textExpansionKey
            )
            guard let key = Data(base64Encoded: record.secret), key.count == 32 else {
                throw ServiceError.invalidKey
            }
            return key
        } catch LinuxSecretStoreError.missingSecret {
            do {
                let key = try PlatformCrypto.secureRandomBytes(count: 32)
                try secretStore.storeHighValueSecret(
                    key.base64EncodedString(),
                    id: Self.keyID,
                    secretClass: .textExpansionKey
                )
                return key
            } catch {
                throw ServiceError.keyStorageUnavailable
            }
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.keyStorageUnavailable
        }
#else
        throw ServiceError.unsupportedPlatform
#endif
    }

    private func isSafeStoreFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
#if os(Linux)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0 else { return false }
#endif
        return true
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func emptySnapshot() -> BurnBarTextExpansionSnapshot {
        BurnBarTextExpansionSnapshot(exportedAt: isoNow(), snippets: [])
    }

    private static func canonicalTrigger(_ raw: String) -> String {
        var trigger = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trigger.hasPrefix(Self.triggerPrefix) {
            trigger.removeFirst(Self.triggerPrefix.count)
        }
        return trigger
    }

    private static func isValidTrigger(_ trigger: String) -> Bool {
        let length = trigger.utf8.count
        guard length >= Self.minimumTriggerLength, length <= Self.maximumTriggerBytes else { return false }
        return trigger.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
        }
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func copy(
        _ snippet: BurnBarTextExpansionWireSnippet,
        id: String? = nil,
        title: String? = nil,
        trigger: String? = nil,
        body: String? = nil,
        mode: String? = nil,
        isEnabled: Bool? = nil,
        scope: BurnBarTextExpansionScope? = nil,
        revision: Int? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        deletedAt: String?? = nil,
        syncedAt: String?? = nil,
        sourceDeviceID: String?? = nil
    ) -> BurnBarTextExpansionWireSnippet {
        BurnBarTextExpansionWireSnippet(
            id: id ?? snippet.id,
            title: title ?? snippet.title,
            trigger: trigger ?? snippet.trigger,
            body: body ?? snippet.body,
            mode: mode ?? snippet.mode,
            isEnabled: isEnabled ?? snippet.isEnabled,
            scope: scope ?? snippet.scope,
            revision: revision ?? snippet.revision,
            createdAt: createdAt ?? snippet.createdAt,
            updatedAt: updatedAt ?? snippet.updatedAt,
            deletedAt: deletedAt ?? snippet.deletedAt,
            syncedAt: syncedAt ?? snippet.syncedAt,
            sourceDeviceID: sourceDeviceID ?? snippet.sourceDeviceID
        )
    }
}
