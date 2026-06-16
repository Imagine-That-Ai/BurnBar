import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

// Shared-artifact + memory sync boundary types and Firestore codecs used by `CloudSyncService`.

enum OpenBurnBarMemorySyncMode: String, Equatable, Sendable {
    case localFirstOptionalCloud = "local_first_optional_cloud"
    case cloudCanonical = "cloud_canonical"
}

enum OpenBurnBarMemoryAuthority: String, Equatable, Sendable {
    case localSQLite = "local_sqlite"
    case cloudReplica = "cloud_replica"
}

struct OpenBurnBarMemorySyncBoundarySnapshot: Equatable, Sendable {
    let mode: OpenBurnBarMemorySyncMode
    let canonicalAuthority: OpenBurnBarMemoryAuthority
    let cloudMetadataBackupEnabled: Bool
    let cloudSessionLogBackupEnabled: Bool
    let iCloudMirrorEnabled: Bool
    let collaborationUsesCloudHead: Bool
    let notes: [String]
}

struct SharedArtifactScope: Equatable, Sendable {
    let workspaceID: String
    let teamID: String
    let ownerUserID: String?

    static func defaultScope(for uid: String) -> SharedArtifactScope {
        SharedArtifactScope(
            workspaceID: "workspace-\(uid)",
            teamID: "team-default",
            ownerUserID: uid
        )
    }
}

struct SharedArtifactCloudRecord: Equatable, Sendable {
    let artifactID: String
    let workspaceID: String
    let teamID: String
    let ownerUserID: String?
    let visibility: SharedArtifactVisibility
    let revisionID: String
    let baseRevisionID: String?
    let title: String
    let body: String
    let contentHash: String
    let relativePath: String?
    let isDeleted: Bool
    let updatedByUserID: String?
    let updatedByDeviceID: String?
    let resolvedConflictRevisionID: String?
    let updatedAt: Date?

    init(
        artifactID: String,
        workspaceID: String,
        teamID: String,
        ownerUserID: String?,
        visibility: SharedArtifactVisibility = .team,
        revisionID: String,
        baseRevisionID: String? = nil,
        title: String,
        body: String,
        contentHash: String,
        relativePath: String?,
        isDeleted: Bool,
        updatedByUserID: String? = nil,
        updatedByDeviceID: String? = nil,
        resolvedConflictRevisionID: String? = nil,
        updatedAt: Date?
    ) {
        self.artifactID = artifactID
        self.workspaceID = workspaceID
        self.teamID = teamID
        self.ownerUserID = ownerUserID
        self.visibility = visibility
        self.revisionID = revisionID
        self.baseRevisionID = baseRevisionID
        self.title = title
        self.body = body
        self.contentHash = contentHash
        self.relativePath = relativePath
        self.isDeleted = isDeleted
        self.updatedByUserID = updatedByUserID
        self.updatedByDeviceID = updatedByDeviceID
        self.resolvedConflictRevisionID = resolvedConflictRevisionID
        self.updatedAt = updatedAt
    }
}

enum SharedArtifactCloudCodecError: LocalizedError {
    case missingField(String)
    case invalidFieldType(String)
    case sealedContentRequiresKey
    case sealedContentMalformed
    case missingOwnerForSealedContent

    var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "Shared artifact cloud payload is missing required field: \(field)."
        case .invalidFieldType(let field):
            return "Shared artifact cloud payload has an invalid field type for: \(field)."
        case .sealedContentRequiresKey:
            return "Shared artifact document is sealed but no CloudVault key was provided to open it."
        case .sealedContentMalformed:
            return "Shared artifact sealed content could not be decoded after opening the CloudVault envelope."
        case .missingOwnerForSealedContent:
            return "Shared artifact document is sealed but carries no owner identity to derive its path-bound AAD."
        }
    }
}

enum SharedArtifactMergeDecision: Equatable, Sendable {
    case noChange
    case pushLocal
    case pullRemote
    case conflict
}

enum SharedArtifactSyncResolver {
    static func mergeDecision(
        localContentHash: String?,
        syncedContentHash: String?,
        remoteContentHash: String?
    ) -> SharedArtifactMergeDecision {
        switch (localContentHash, remoteContentHash) {
        case (nil, nil):
            return .noChange
        case (let local?, nil):
            return local.isEmpty ? .noChange : .pushLocal
        case (nil, let remote?):
            return remote.isEmpty ? .noChange : .pullRemote
        case (let local?, let remote?):
            guard local != remote else { return .noChange }

            guard let baseline = syncedContentHash, baseline.isEmpty == false else {
                return .conflict
            }

            let localChanged = local != baseline
            let remoteChanged = remote != baseline

            if localChanged && remoteChanged {
                return .conflict
            }
            if localChanged {
                return .pushLocal
            }
            if remoteChanged {
                return .pullRemote
            }
            return .noChange
        }
    }
}

enum SharedArtifactCollaborationNoticeKind: String, Equatable, Sendable {
    case remoteUpdateArrived = "remote_update_arrived"
    case editConflicted = "edit_conflicted"
    case resolvedVersionSaved = "resolved_version_saved"

    var title: String {
        switch self {
        case .remoteUpdateArrived:
            return "Remote update arrived"
        case .editConflicted:
            return "Your edit conflicted"
        case .resolvedVersionSaved:
            return "Resolved version saved"
        }
    }
}

struct SharedArtifactCollaborationNotice: Identifiable, Equatable, Sendable {
    let kind: SharedArtifactCollaborationNoticeKind
    let sourceArtifactID: String
    let remoteArtifactID: String
    let message: String
    let occurredAt: Date

    var id: String {
        "\(kind.rawValue)|\(sourceArtifactID)|\(remoteArtifactID)|\(occurredAt.timeIntervalSince1970)"
    }
}

struct SharedArtifactOptimisticWriteConflict: Equatable, Sendable {
    let expectedRevisionID: String?
    let observedRevisionID: String?
}

enum SharedArtifactOptimisticWriteGate {
    static let errorDomain = "CloudSyncService.SharedArtifactOptimisticWrite"
    static let staleWriteCode = 409

    private static let expectedRevisionKey = "expectedRevisionID"
    private static let observedRevisionKey = "observedRevisionID"

    static func validate(expectedRevisionID: String?, observedRevisionID: String?) throws {
        let normalizedExpected = normalizedRevisionID(expectedRevisionID)
        let normalizedObserved = normalizedRevisionID(observedRevisionID)
        guard normalizedExpected == normalizedObserved else {
            throw staleWriteError(expectedRevisionID: normalizedExpected, observedRevisionID: normalizedObserved)
        }
    }

    static func conflict(from error: Error) -> SharedArtifactOptimisticWriteConflict? {
        let nsError = error as NSError
        guard nsError.domain == errorDomain, nsError.code == staleWriteCode else { return nil }

        let expected = normalizedRevisionID(nsError.userInfo[expectedRevisionKey] as? String)
        let observed = normalizedRevisionID(nsError.userInfo[observedRevisionKey] as? String)
        return SharedArtifactOptimisticWriteConflict(
            expectedRevisionID: expected,
            observedRevisionID: observed
        )
    }

    private static func staleWriteError(expectedRevisionID: String?, observedRevisionID: String?) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey:
                "Shared artifact write was rejected because the remote head changed from \(expectedRevisionID ?? "nil") to \(observedRevisionID ?? "nil")."
        ]
        userInfo[expectedRevisionKey] = expectedRevisionID
        userInfo[observedRevisionKey] = observedRevisionID
        return NSError(domain: errorDomain, code: staleWriteCode, userInfo: userInfo)
    }

    private static func normalizedRevisionID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SharedArtifactCloudCodec {
    static let provenancePrefix = "shared-sync:"

    /// Path-bound AAD `collection` segment for the head document
    /// (`workspaces/.../artifacts/{artifactID}`). The Firestore security rule
    /// binds the sealed envelope to `cloudVaultAADContext(uid, "artifacts",
    /// artifactID, "sealedPayload")`, so this MUST stay in lockstep with
    /// `firestore.rules`'s `sharedArtifactSealedOwnerWrite(... "artifacts" ...)`.
    static let headAADCollection = "artifacts"

    /// Path-bound AAD `collection` segment for the version history subdocument
    /// (`.../artifacts/{artifactID}/versions/{revisionID}`). Bound to
    /// `cloudVaultAADContext(uid, "artifact_versions", revisionID, "sealedPayload")`.
    static let versionAADCollection = "artifact_versions"

    /// The single sealed field name. Matches the rule's hardcoded
    /// `cloudVaultAADContext(..., "sealedPayload")`.
    static let sealedAADField = "sealedPayload"

    /// Private content of a shared artifact, sealed as ONE CloudVault payload
    /// before Firestore receives the document. Only non-content routing metadata
    /// (ids, visibility, revision, owner/device, timestamps) stays top-level; the
    /// source `body`, `title`, `relativePath`, and the (now in-envelope, no longer
    /// oracle-able) `contentHash` are E2EE-sealed with path-bound AAD. This brings
    /// shared/team artifacts to parity with chat threads, conversations, CLI
    /// sessions, and session logs, which all seal before Firestore.
    struct SealedContent: Codable, Equatable, Sendable {
        let title: String
        let body: String
        let contentHash: String
        let relativePath: String?
    }

    static var sealedContentEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var sealedContentDecoder: JSONDecoder {
        JSONDecoder()
    }

    /// Seal `title`/`body`/`relativePath`/`contentHash` into a single path-bound
    /// CloudVault envelope and emit a Firestore payload that carries ZERO source
    /// content in cleartext. `aadCollection`/`aadDocID` MUST identify the exact
    /// Firestore document being written (head → `headAADCollection` + artifactID;
    /// version → `versionAADCollection` + revisionID) so the envelope is bound to
    /// its location and cannot be relocated within the vault. Stale plaintext
    /// fields from any pre-seal document are explicitly deleted so a merge write
    /// can never leave cleartext behind.
    static func encodeSealed(
        _ record: SharedArtifactCloudRecord,
        vaultKey: Data,
        vaultKeyID: String,
        uid: String,
        aadCollection: String,
        aadDocID: String,
        useServerTimestamp: Bool
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "artifactID": record.artifactID,
            "workspaceID": record.workspaceID,
            "teamID": record.teamID,
            "visibility": record.visibility.rawValue,
            "revisionID": record.revisionID,
            "isDeleted": record.isDeleted,
            "contentSealed": true,
            "sealedSchemaVersion": CloudVaultCrypto.currentSealedPayloadSchemaVersion,
            "vaultKeyID": vaultKeyID
        ]
        if let ownerUserID = record.ownerUserID {
            payload["ownerUserID"] = ownerUserID
        }
        if let baseRevisionID = record.baseRevisionID {
            payload["baseRevisionID"] = baseRevisionID
        }
        if let updatedByUserID = record.updatedByUserID {
            payload["updatedByUserID"] = updatedByUserID
        }
        if let updatedByDeviceID = record.updatedByDeviceID {
            payload["updatedByDeviceID"] = updatedByDeviceID
        }
        if let resolvedConflictRevisionID = record.resolvedConflictRevisionID {
            payload["resolvedConflictRevisionID"] = resolvedConflictRevisionID
        }
        if useServerTimestamp {
            payload["updatedAt"] = FieldValue.serverTimestamp()
        } else if let updatedAt = record.updatedAt {
            payload["updatedAt"] = updatedAt
        }

        let content = SealedContent(
            title: record.title,
            body: record.body,
            contentHash: record.contentHash,
            relativePath: record.relativePath
        )
        let contentData = try sealedContentEncoder.encode(content)
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: aadCollection,
            docID: aadDocID,
            field: sealedAADField
        )
        let sealed = try CloudVaultCrypto.sealPayload(
            contentData,
            keyData: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
        payload["sealedPayload"] = CloudVaultCrypto.sealedPayloadDictionary(sealed)

        // Defense-in-depth for `setData(merge: true)` over a legacy plaintext
        // document: explicitly clear every cleartext content field so the sealed
        // write can never inherit stale source content. `FieldValue.delete()`
        // leaves these keys out of the resulting document, so the Firestore rule's
        // `forbidsSealedPlaintextContentFields()` still passes.
        payload["title"] = FieldValue.delete()
        payload["body"] = FieldValue.delete()
        payload["contentHash"] = FieldValue.delete()
        payload["relativePath"] = FieldValue.delete()
        return payload
    }

    static func encode(_ record: SharedArtifactCloudRecord, useServerTimestamp: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "artifactID": record.artifactID,
            "workspaceID": record.workspaceID,
            "teamID": record.teamID,
            "visibility": record.visibility.rawValue,
            "revisionID": record.revisionID,
            "title": record.title,
            "body": record.body,
            "contentHash": record.contentHash,
            "isDeleted": record.isDeleted
        ]
        if let ownerUserID = record.ownerUserID {
            payload["ownerUserID"] = ownerUserID
        }
        if let baseRevisionID = record.baseRevisionID {
            payload["baseRevisionID"] = baseRevisionID
        }
        if let relativePath = record.relativePath {
            payload["relativePath"] = relativePath
        }
        if let updatedByUserID = record.updatedByUserID {
            payload["updatedByUserID"] = updatedByUserID
        }
        if let updatedByDeviceID = record.updatedByDeviceID {
            payload["updatedByDeviceID"] = updatedByDeviceID
        }
        if let resolvedConflictRevisionID = record.resolvedConflictRevisionID {
            payload["resolvedConflictRevisionID"] = resolvedConflictRevisionID
        }
        if useServerTimestamp {
            payload["updatedAt"] = FieldValue.serverTimestamp()
        } else if let updatedAt = record.updatedAt {
            payload["updatedAt"] = updatedAt
        }
        return payload
    }

    /// Decode a shared-artifact head document. When the document is sealed
    /// (`sealedPayload` present) the CloudVault `vaultKey` (and the owner `uid`
    /// for path-bound AAD) MUST be supplied; the source content is opened from
    /// the envelope. Legacy plaintext documents (pre-seal, or unit-test fixtures)
    /// decode unchanged, so reads of not-yet-migrated documents keep working
    /// until their next write re-seals them.
    static func decode(
        documentID: String,
        data: [String: Any],
        uid: String? = nil,
        vaultKey: Data? = nil
    ) throws -> SharedArtifactCloudRecord {
        let artifactID = stringValue(data["artifactID"]) ?? stringValue(data["id"]) ?? documentID
        guard let workspaceID = stringValue(data["workspaceID"]) else {
            throw SharedArtifactCloudCodecError.missingField("workspaceID")
        }
        guard let teamID = stringValue(data["teamID"]) else {
            throw SharedArtifactCloudCodecError.missingField("teamID")
        }
        let visibility = stringValue(data["visibility"])
            .flatMap(SharedArtifactVisibility.init(rawValue:))
            ?? .team
        guard let revisionID = stringValue(data["revisionID"]) else {
            throw SharedArtifactCloudCodecError.missingField("revisionID")
        }
        let ownerUserID = stringValue(data["ownerUserID"])
        let isDeleted = boolValue(data["isDeleted"]) ?? false

        let title: String
        let body: String
        let contentHash: String
        let relativePath: String?

        if let sealedRaw = data["sealedPayload"],
           let envelope = CloudVaultCrypto.sealedPayload(from: sealedRaw) {
            guard let vaultKey else {
                throw SharedArtifactCloudCodecError.sealedContentRequiresKey
            }
            // Decode is only ever called on head documents, so the path-bound AAD
            // collection is always `headAADCollection` and the docID is the head id.
            let resolvedUID = uid
                ?? ownerUserID
                ?? Self.ownerUID(fromWorkspaceID: workspaceID)
            guard let resolvedUID else {
                throw SharedArtifactCloudCodecError.missingOwnerForSealedContent
            }
            let aadContext = try CloudVaultAADContext(
                uid: resolvedUID,
                collection: headAADCollection,
                docID: documentID,
                field: sealedAADField
            )
            let contentData = try CloudVaultCrypto.openPayload(
                envelope,
                keyData: vaultKey,
                aadContext: aadContext
            )
            guard let content = try? sealedContentDecoder.decode(SealedContent.self, from: contentData) else {
                throw SharedArtifactCloudCodecError.sealedContentMalformed
            }
            title = content.title
            body = content.body
            contentHash = content.contentHash
            relativePath = content.relativePath
        } else {
            guard let plaintextTitle = stringValue(data["title"]) else {
                throw SharedArtifactCloudCodecError.missingField("title")
            }
            guard let plaintextBody = stringValue(data["body"]) else {
                throw SharedArtifactCloudCodecError.missingField("body")
            }
            guard let plaintextHash = stringValue(data["contentHash"]) else {
                throw SharedArtifactCloudCodecError.missingField("contentHash")
            }
            title = plaintextTitle
            body = plaintextBody
            contentHash = plaintextHash
            relativePath = stringValue(data["relativePath"])
        }

        return SharedArtifactCloudRecord(
            artifactID: artifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            ownerUserID: ownerUserID,
            visibility: visibility,
            revisionID: revisionID,
            baseRevisionID: stringValue(data["baseRevisionID"]),
            title: title,
            body: body,
            contentHash: contentHash,
            relativePath: relativePath,
            isDeleted: isDeleted,
            updatedByUserID: stringValue(data["updatedByUserID"]),
            updatedByDeviceID: stringValue(data["updatedByDeviceID"]),
            resolvedConflictRevisionID: stringValue(data["resolvedConflictRevisionID"]),
            updatedAt: dateValue(data["updatedAt"])
        )
    }

    /// Derive the owner UID from a `workspace-{uid}` workspace identifier, used
    /// only as a last-resort fallback when neither an explicit uid nor an
    /// `ownerUserID` field is available to rebuild path-bound AAD.
    static func ownerUID(fromWorkspaceID workspaceID: String) -> String? {
        let prefix = "workspace-"
        guard workspaceID.hasPrefix(prefix) else { return nil }
        let candidate = String(workspaceID.dropFirst(prefix.count))
        return candidate.isEmpty ? nil : candidate
    }

    static func encodeProvenance(
        workspaceID: String,
        teamID: String,
        remoteArtifactID: String,
        ownerUserID: String?
    ) -> String {
        let owner = ownerUserID ?? ""
        return "\(provenancePrefix)\(workspaceID)|\(teamID)|\(remoteArtifactID)|\(owner)"
    }

    static func decodeProvenance(_ provenance: String) -> (workspaceID: String, teamID: String, remoteArtifactID: String, ownerUserID: String?)? {
        guard provenance.hasPrefix(provenancePrefix) else { return nil }
        let raw = String(provenance.dropFirst(provenancePrefix.count))
        let pieces = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 3 else { return nil }
        let owner = pieces.count > 3 ? pieces[3] : ""
        return (
            workspaceID: pieces[0],
            teamID: pieces[1],
            remoteArtifactID: pieces[2],
            ownerUserID: owner.isEmpty ? nil : owner
        )
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            switch text.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        if let timestamp = raw as? Timestamp {
            return timestamp.dateValue()
        }
        if let date = raw as? Date {
            return date
        }
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let text = raw as? String, let value = Double(text) {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }
}
