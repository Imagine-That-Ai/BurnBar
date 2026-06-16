import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - CloudSync Enums Tests

final class CloudSyncEnumsTests: XCTestCase {

    // MARK: - OpenBurnBarMemorySyncMode

    func test_memorySyncMode_localFirstOptionalCloud() {
        XCTAssertEqual(OpenBurnBarMemorySyncMode.localFirstOptionalCloud.rawValue, "local_first_optional_cloud")
    }

    func test_memorySyncMode_cloudCanonical() {
        XCTAssertEqual(OpenBurnBarMemorySyncMode.cloudCanonical.rawValue, "cloud_canonical")
    }

    func test_memorySyncMode_equatable() {
        XCTAssertEqual(OpenBurnBarMemorySyncMode.localFirstOptionalCloud, .localFirstOptionalCloud)
        XCTAssertNotEqual(OpenBurnBarMemorySyncMode.localFirstOptionalCloud, .cloudCanonical)
    }

    // MARK: - OpenBurnBarMemoryAuthority

    func test_memoryAuthority_localSQLite() {
        XCTAssertEqual(OpenBurnBarMemoryAuthority.localSQLite.rawValue, "local_sqlite")
    }

    func test_memoryAuthority_cloudReplica() {
        XCTAssertEqual(OpenBurnBarMemoryAuthority.cloudReplica.rawValue, "cloud_replica")
    }

    // MARK: - SharedArtifactScope

    func test_sharedArtifactScope_defaultScope() {
        let uid = "test-user-123"
        let scope = SharedArtifactScope.defaultScope(for: uid)

        XCTAssertEqual(scope.workspaceID, "workspace-\(uid)")
        XCTAssertEqual(scope.teamID, "team-default")
        XCTAssertEqual(scope.ownerUserID, uid)
    }

    func test_sharedArtifactScope_equatable() {
        let scope1 = SharedArtifactScope(
            workspaceID: "ws-1",
            teamID: "team-1",
            ownerUserID: "user-1"
        )
        let scope2 = SharedArtifactScope(
            workspaceID: "ws-1",
            teamID: "team-1",
            ownerUserID: "user-1"
        )
        let scope3 = SharedArtifactScope(
            workspaceID: "ws-2",
            teamID: "team-1",
            ownerUserID: "user-1"
        )

        XCTAssertEqual(scope1, scope2)
        XCTAssertNotEqual(scope1, scope3)
    }

    // MARK: - SharedArtifactCloudRecord

    func test_sharedArtifactCloudRecord_fullInit() {
        let record = SharedArtifactCloudRecord(
            artifactID: "artifact-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "user-1",
            visibility: .team,
            revisionID: "rev-1",
            baseRevisionID: "base-rev-1",
            title: "Test Artifact",
            body: "Test content",
            contentHash: "hash-123",
            relativePath: "path/to/file.md",
            isDeleted: false,
            updatedByUserID: "modifier-1",
            updatedByDeviceID: "device-1",
            resolvedConflictRevisionID: "resolved-rev-1",
            updatedAt: Date()
        )

        XCTAssertEqual(record.artifactID, "artifact-1")
        XCTAssertEqual(record.workspaceID, "workspace-1")
        XCTAssertEqual(record.teamID, "team-1")
        XCTAssertEqual(record.ownerUserID, "user-1")
        XCTAssertEqual(record.visibility, .team)
        XCTAssertEqual(record.revisionID, "rev-1")
        XCTAssertEqual(record.baseRevisionID, "base-rev-1")
        XCTAssertEqual(record.title, "Test Artifact")
        XCTAssertEqual(record.body, "Test content")
        XCTAssertEqual(record.contentHash, "hash-123")
        XCTAssertEqual(record.relativePath, "path/to/file.md")
        XCTAssertFalse(record.isDeleted)
        XCTAssertEqual(record.updatedByUserID, "modifier-1")
        XCTAssertEqual(record.updatedByDeviceID, "device-1")
        XCTAssertEqual(record.resolvedConflictRevisionID, "resolved-rev-1")
        XCTAssertNotNil(record.updatedAt)
    }

    func test_sharedArtifactCloudRecord_defaults() {
        let record = SharedArtifactCloudRecord(
            artifactID: "artifact-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: nil,
            revisionID: "rev-1",
            title: "Test",
            body: "Content",
            contentHash: "hash",
            relativePath: nil,
            isDeleted: false,
            updatedAt: nil
        )

        XCTAssertNil(record.ownerUserID)
        XCTAssertNil(record.baseRevisionID)
        XCTAssertNil(record.relativePath)
        XCTAssertNil(record.updatedByUserID)
        XCTAssertNil(record.updatedByDeviceID)
        XCTAssertNil(record.resolvedConflictRevisionID)
        XCTAssertNil(record.updatedAt)
    }

    func test_sharedArtifactCloudRecord_equatable() {
        let now = Date()
        let record1 = SharedArtifactCloudRecord(
            artifactID: "a1",
            workspaceID: "ws1",
            teamID: "t1",
            ownerUserID: nil,
            revisionID: "r1",
            title: "T",
            body: "B",
            contentHash: "h1",
            relativePath: nil,
            isDeleted: false,
            updatedAt: now
        )
        let record2 = SharedArtifactCloudRecord(
            artifactID: "a1",
            workspaceID: "ws1",
            teamID: "t1",
            ownerUserID: nil,
            revisionID: "r1",
            title: "T",
            body: "B",
            contentHash: "h1",
            relativePath: nil,
            isDeleted: false,
            updatedAt: now
        )
        let record3 = SharedArtifactCloudRecord(
            artifactID: "a2",
            workspaceID: "ws1",
            teamID: "t1",
            ownerUserID: nil,
            revisionID: "r1",
            title: "T",
            body: "B",
            contentHash: "h1",
            relativePath: nil,
            isDeleted: false,
            updatedAt: now
        )

        XCTAssertEqual(record1, record2)
        XCTAssertNotEqual(record1, record3)
    }

    // MARK: - SharedArtifactCloudCodecError

    func test_codecError_missingField() {
        let error = SharedArtifactCloudCodecError.missingField("workspaceID")
        XCTAssertEqual(error.errorDescription, "Shared artifact cloud payload is missing required field: workspaceID.")
    }

    func test_codecError_invalidFieldType() {
        let error = SharedArtifactCloudCodecError.invalidFieldType("revisionID")
        XCTAssertEqual(error.errorDescription, "Shared artifact cloud payload has an invalid field type for: revisionID.")
    }
}

// MARK: - SharedArtifactMergeDecision Tests

final class SharedArtifactMergeDecisionTests: XCTestCase {

    func test_mergeDecision_noChange_nilNil() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: nil,
            syncedContentHash: nil,
            remoteContentHash: nil
        )
        XCTAssertEqual(decision, .noChange)
    }

    func test_mergeDecision_noChange_emptyEmpty() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "",
            syncedContentHash: "",
            remoteContentHash: ""
        )
        XCTAssertEqual(decision, .noChange)
    }

    func test_mergeDecision_pushLocal_withLocal() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "localHash123",
            syncedContentHash: nil,
            remoteContentHash: nil
        )
        XCTAssertEqual(decision, .pushLocal)
    }

    func test_mergeDecision_pushLocal_emptyLocal() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "",
            syncedContentHash: nil,
            remoteContentHash: nil
        )
        XCTAssertEqual(decision, .noChange)
    }

    func test_mergeDecision_pullRemote_withRemote() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: nil,
            syncedContentHash: nil,
            remoteContentHash: "remoteHash456"
        )
        XCTAssertEqual(decision, .pullRemote)
    }

    func test_mergeDecision_pullRemote_emptyRemote() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: nil,
            syncedContentHash: nil,
            remoteContentHash: ""
        )
        XCTAssertEqual(decision, .noChange)
    }

    func test_mergeDecision_noChange_sameHashes() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "sameHash",
            syncedContentHash: "baselineHash",
            remoteContentHash: "sameHash"
        )
        XCTAssertEqual(decision, .noChange)
    }

    func test_mergeDecision_conflict_bothChanged() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "localChanged",
            syncedContentHash: "baseline",
            remoteContentHash: "remoteChanged"
        )
        XCTAssertEqual(decision, .conflict)
    }

    func test_mergeDecision_pushLocal_onlyLocalChanged() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "localChanged",
            syncedContentHash: "baseline",
            remoteContentHash: "baseline"
        )
        XCTAssertEqual(decision, .pushLocal)
    }

    func test_mergeDecision_pullRemote_onlyRemoteChanged() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "baseline",
            syncedContentHash: "baseline",
            remoteContentHash: "remoteChanged"
        )
        XCTAssertEqual(decision, .pullRemote)
    }

    func test_mergeDecision_conflict_noBaseline() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "local",
            syncedContentHash: nil,
            remoteContentHash: "remote"
        )
        XCTAssertEqual(decision, .conflict)
    }
}

// MARK: - SharedArtifactCollaborationNotice Tests

final class SharedArtifactCollaborationNoticeTests: XCTestCase {

    func test_noticeKind_remoteUpdateArrived() {
        let kind = SharedArtifactCollaborationNoticeKind.remoteUpdateArrived
        XCTAssertEqual(kind.title, "Remote update arrived")
        XCTAssertEqual(kind.rawValue, "remote_update_arrived")
    }

    func test_noticeKind_editConflicted() {
        let kind = SharedArtifactCollaborationNoticeKind.editConflicted
        XCTAssertEqual(kind.title, "Your edit conflicted")
        XCTAssertEqual(kind.rawValue, "edit_conflicted")
    }

    func test_noticeKind_resolvedVersionSaved() {
        let kind = SharedArtifactCollaborationNoticeKind.resolvedVersionSaved
        XCTAssertEqual(kind.title, "Resolved version saved")
        XCTAssertEqual(kind.rawValue, "resolved_version_saved")
    }

    func test_notice_idGeneration() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let notice = SharedArtifactCollaborationNotice(
            kind: .remoteUpdateArrived,
            sourceArtifactID: "src-1",
            remoteArtifactID: "remote-1",
            message: "Update received",
            occurredAt: date
        )

        let expectedID = "remote_update_arrived|src-1|remote-1|\(date.timeIntervalSince1970)"
        XCTAssertEqual(notice.id, expectedID)
    }

    func test_notice_equatable() {
        let date = Date()
        let notice1 = SharedArtifactCollaborationNotice(
            kind: .editConflicted,
            sourceArtifactID: "src-1",
            remoteArtifactID: "remote-1",
            message: "Conflict occurred",
            occurredAt: date
        )
        let notice2 = SharedArtifactCollaborationNotice(
            kind: .editConflicted,
            sourceArtifactID: "src-1",
            remoteArtifactID: "remote-1",
            message: "Conflict occurred",
            occurredAt: date
        )
        let notice3 = SharedArtifactCollaborationNotice(
            kind: .remoteUpdateArrived,
            sourceArtifactID: "src-1",
            remoteArtifactID: "remote-1",
            message: "Update",
            occurredAt: date
        )

        XCTAssertEqual(notice1, notice2)
        XCTAssertNotEqual(notice1, notice3)
    }
}

// MARK: - SharedArtifactOptimisticWriteGate Tests

final class SharedArtifactOptimisticWriteGateTests: XCTestCase {

    func test_validate_matchingRevisions() {
        XCTAssertNoThrow(try SharedArtifactOptimisticWriteGate.validate(
            expectedRevisionID: "rev-123",
            observedRevisionID: "rev-123"
        ))
    }

    func test_validate_bothNil() {
        XCTAssertNoThrow(try SharedArtifactOptimisticWriteGate.validate(
            expectedRevisionID: nil,
            observedRevisionID: nil
        ))
    }

    func test_validate_mismatchedRevisions() {
        XCTAssertThrowsError(try SharedArtifactOptimisticWriteGate.validate(
            expectedRevisionID: "rev-123",
            observedRevisionID: "rev-456"
        )) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, SharedArtifactOptimisticWriteGate.errorDomain)
            XCTAssertEqual(nsError.code, SharedArtifactOptimisticWriteGate.staleWriteCode)
        }
    }

    func test_validate_whitespaceNormalization() {
        // Should normalize whitespace and treat as matching
        XCTAssertNoThrow(try SharedArtifactOptimisticWriteGate.validate(
            expectedRevisionID: "  rev-123  ",
            observedRevisionID: "rev-123"
        ))
    }

    func test_validate_emptyNormalization() {
        // Empty strings should be normalized to nil
        XCTAssertNoThrow(try SharedArtifactOptimisticWriteGate.validate(
            expectedRevisionID: "   ",
            observedRevisionID: nil
        ))
    }

    func test_conflict_fromError_matchingDomain() {
        let error = NSError(
            domain: SharedArtifactOptimisticWriteGate.errorDomain,
            code: SharedArtifactOptimisticWriteGate.staleWriteCode,
            userInfo: [
                "expectedRevisionID": "rev-123",
                "observedRevisionID": "rev-456",
                NSLocalizedDescriptionKey: "Test error"
            ]
        )

        let conflict = SharedArtifactOptimisticWriteGate.conflict(from: error)
        XCTAssertNotNil(conflict)
        XCTAssertEqual(conflict?.expectedRevisionID, "rev-123")
        XCTAssertEqual(conflict?.observedRevisionID, "rev-456")
    }

    func test_conflict_fromError_wrongDomain() {
        let error = NSError(domain: "OtherDomain", code: 409, userInfo: [:])
        let conflict = SharedArtifactOptimisticWriteGate.conflict(from: error)
        XCTAssertNil(conflict)
    }

    func test_conflict_fromError_wrongCode() {
        let error = NSError(domain: SharedArtifactOptimisticWriteGate.errorDomain, code: 500, userInfo: [:])
        let conflict = SharedArtifactOptimisticWriteGate.conflict(from: error)
        XCTAssertNil(conflict)
    }

    func test_conflict_optimisticWriteConflict_equatable() {
        let conflict1 = SharedArtifactOptimisticWriteConflict(
            expectedRevisionID: "rev-1",
            observedRevisionID: "rev-2"
        )
        let conflict2 = SharedArtifactOptimisticWriteConflict(
            expectedRevisionID: "rev-1",
            observedRevisionID: "rev-2"
        )
        let conflict3 = SharedArtifactOptimisticWriteConflict(
            expectedRevisionID: "rev-1",
            observedRevisionID: "rev-3"
        )

        XCTAssertEqual(conflict1, conflict2)
        XCTAssertNotEqual(conflict1, conflict3)
    }
}

// MARK: - SharedArtifactCloudCodec Tests

final class SharedArtifactCloudCodecTests: XCTestCase {

    func test_encode_fullRecord() {
        let record = SharedArtifactCloudRecord(
            artifactID: "artifact-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "user-1",
            visibility: .team,
            revisionID: "rev-1",
            baseRevisionID: "base-rev-1",
            title: "Test",
            body: "Content",
            contentHash: "hash-123",
            relativePath: "path.md",
            isDeleted: false,
            updatedByUserID: "modifier-1",
            updatedByDeviceID: "device-1",
            resolvedConflictRevisionID: "resolved-1",
            updatedAt: Date(timeIntervalSince1970: 1700000000)
        )

        let payload = SharedArtifactCloudCodec.encode(record, useServerTimestamp: false)

        XCTAssertEqual(payload["artifactID"] as? String, "artifact-1")
        XCTAssertEqual(payload["workspaceID"] as? String, "workspace-1")
        XCTAssertEqual(payload["teamID"] as? String, "team-1")
        XCTAssertEqual(payload["visibility"] as? String, "team")
        XCTAssertEqual(payload["revisionID"] as? String, "rev-1")
        XCTAssertEqual(payload["baseRevisionID"] as? String, "base-rev-1")
        XCTAssertEqual(payload["title"] as? String, "Test")
        XCTAssertEqual(payload["body"] as? String, "Content")
        XCTAssertEqual(payload["contentHash"] as? String, "hash-123")
        XCTAssertEqual(payload["relativePath"] as? String, "path.md")
        XCTAssertEqual(payload["isDeleted"] as? Bool, false)
        XCTAssertEqual(payload["updatedByUserID"] as? String, "modifier-1")
        XCTAssertEqual(payload["updatedByDeviceID"] as? String, "device-1")
        XCTAssertEqual(payload["resolvedConflictRevisionID"] as? String, "resolved-1")
    }

    func test_encode_optionalFieldsOmitted() {
        let record = SharedArtifactCloudRecord(
            artifactID: "artifact-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: nil,
            visibility: .team,
            revisionID: "rev-1",
            title: "Test",
            body: "Content",
            contentHash: "hash",
            relativePath: nil,
            isDeleted: false,
            updatedAt: nil
        )

        let payload = SharedArtifactCloudCodec.encode(record, useServerTimestamp: false)

        XCTAssertNil(payload["ownerUserID"])
        XCTAssertNil(payload["baseRevisionID"])
        XCTAssertNil(payload["relativePath"])
        XCTAssertNil(payload["updatedByUserID"])
        XCTAssertNil(payload["updatedByDeviceID"])
        XCTAssertNil(payload["resolvedConflictRevisionID"])
        XCTAssertNil(payload["updatedAt"])
    }

    func test_encode_useServerTimestamp() {
        let record = SharedArtifactCloudRecord(
            artifactID: "artifact-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: nil,
            revisionID: "rev-1",
            title: "Test",
            body: "Content",
            contentHash: "hash",
            relativePath: nil,
            isDeleted: false,
            updatedAt: Date()
        )

        let payload = SharedArtifactCloudCodec.encode(record, useServerTimestamp: true)

        // updatedAt should be FieldValue.serverTimestamp(), not the date
        XCTAssertNotNil(payload["updatedAt"])
        XCTAssertFalse(payload["updatedAt"] is Date)
    }

    func test_decode_fullRecord() throws {
        let data: [String: Any] = [
            "artifactID": "artifact-1",
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "ownerUserID": "user-1",
            "visibility": "team",
            "revisionID": "rev-1",
            "baseRevisionID": "base-rev-1",
            "title": "Test Title",
            "body": "Test Body",
            "contentHash": "hash-abc",
            "relativePath": "path/to/file.md",
            "isDeleted": false,
            "updatedByUserID": "modifier-1",
            "updatedByDeviceID": "device-1",
            "resolvedConflictRevisionID": "resolved-1",
            "updatedAt": Timestamp(date: Date(timeIntervalSince1970: 1700000000))
        ]

        let record = try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)

        XCTAssertEqual(record.artifactID, "artifact-1")
        XCTAssertEqual(record.workspaceID, "workspace-1")
        XCTAssertEqual(record.teamID, "team-1")
        XCTAssertEqual(record.ownerUserID, "user-1")
        XCTAssertEqual(record.visibility, .team)
        XCTAssertEqual(record.revisionID, "rev-1")
        XCTAssertEqual(record.baseRevisionID, "base-rev-1")
        XCTAssertEqual(record.title, "Test Title")
        XCTAssertEqual(record.body, "Test Body")
        XCTAssertEqual(record.contentHash, "hash-abc")
        XCTAssertEqual(record.relativePath, "path/to/file.md")
        XCTAssertFalse(record.isDeleted)
        XCTAssertEqual(record.updatedByUserID, "modifier-1")
        XCTAssertEqual(record.updatedByDeviceID, "device-1")
        XCTAssertEqual(record.resolvedConflictRevisionID, "resolved-1")
        XCTAssertNotNil(record.updatedAt)
    }

    func test_decode_missingRequiredField_workspaceID() {
        let data: [String: Any] = [
            "artifactID": "artifact-1",
            "teamID": "team-1",
            "revisionID": "rev-1",
            "title": "Test",
            "body": "Content",
            "contentHash": "hash"
        ]

        XCTAssertThrowsError(try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)) { error in
            if case SharedArtifactCloudCodecError.missingField(let field) = error {
                XCTAssertEqual(field, "workspaceID")
            } else {
                XCTFail("Expected missingField error")
            }
        }
    }

    func test_decode_missingRequiredField_teamID() {
        let data: [String: Any] = [
            "artifactID": "artifact-1",
            "workspaceID": "workspace-1",
            "revisionID": "rev-1",
            "title": "Test",
            "body": "Content",
            "contentHash": "hash"
        ]

        XCTAssertThrowsError(try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)) { error in
            if case SharedArtifactCloudCodecError.missingField(let field) = error {
                XCTAssertEqual(field, "teamID")
            } else {
                XCTFail("Expected missingField error")
            }
        }
    }

    func test_decode_missingRequiredField_revisionID() {
        let data: [String: Any] = [
            "artifactID": "artifact-1",
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "title": "Test",
            "body": "Content",
            "contentHash": "hash"
        ]

        XCTAssertThrowsError(try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)) { error in
            if case SharedArtifactCloudCodecError.missingField(let field) = error {
                XCTAssertEqual(field, "revisionID")
            } else {
                XCTFail("Expected missingField error")
            }
        }
    }

    func test_decode_missingRequiredField_title() {
        let data: [String: Any] = [
            "artifactID": "artifact-1",
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "revisionID": "rev-1",
            "body": "Content",
            "contentHash": "hash"
        ]

        XCTAssertThrowsError(try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)) { error in
            if case SharedArtifactCloudCodecError.missingField(let field) = error {
                XCTAssertEqual(field, "title")
            } else {
                XCTFail("Expected missingField error")
            }
        }
    }

    func test_decode_missingRequiredField_body() {
        let data: [String: Any] = [
            "artifactID": "artifact-1",
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "revisionID": "rev-1",
            "title": "Test",
            "contentHash": "hash"
        ]

        XCTAssertThrowsError(try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)) { error in
            if case SharedArtifactCloudCodecError.missingField(let field) = error {
                XCTAssertEqual(field, "body")
            } else {
                XCTFail("Expected missingField error")
            }
        }
    }

    func test_decode_missingRequiredField_contentHash() {
        let data: [String: Any] = [
            "artifactID": "artifact-1",
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "revisionID": "rev-1",
            "title": "Test",
            "body": "Content"
        ]

        XCTAssertThrowsError(try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)) { error in
            if case SharedArtifactCloudCodecError.missingField(let field) = error {
                XCTAssertEqual(field, "contentHash")
            } else {
                XCTFail("Expected missingField error")
            }
        }
    }

    func test_decode_usesIdAsArtifactID() throws {
        let data: [String: Any] = [
            "id": "legacy-id",
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "revisionID": "rev-1",
            "title": "Test",
            "body": "Content",
            "contentHash": "hash"
        ]

        let record = try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: data)
        XCTAssertEqual(record.artifactID, "legacy-id")
    }

    func test_decode_usesDocumentIDAsFallback() throws {
        let data: [String: Any] = [
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "revisionID": "rev-1",
            "title": "Test",
            "body": "Content",
            "contentHash": "hash"
        ]

        let record = try SharedArtifactCloudCodec.decode(documentID: "fallback-id", data: data)
        XCTAssertEqual(record.artifactID, "fallback-id")
    }

    func test_decode_boolConversion() throws {
        // Test that various boolean representations are correctly parsed
        let trueValues: [[String: Any]] = [
            ["isDeleted": true],
            ["isDeleted": NSNumber(value: true)],
            ["isDeleted": "true"],
            ["isDeleted": "1"],
            ["isDeleted": "yes"]
        ]

        for data in trueValues {
            var fullData = baseDecodeData()
            fullData.merge(data) { _, new in new }
            let record = try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: fullData)
            XCTAssertTrue(record.isDeleted, "Failed for \(data)")
        }

        let falseValues: [[String: Any]] = [
            ["isDeleted": false],
            ["isDeleted": NSNumber(value: false)],
            ["isDeleted": "false"],
            ["isDeleted": "0"],
            ["isDeleted": "no"]
        ]

        for data in falseValues {
            var fullData = baseDecodeData()
            fullData.merge(data) { _, new in new }
            let record = try SharedArtifactCloudCodec.decode(documentID: "doc-1", data: fullData)
            XCTAssertFalse(record.isDeleted, "Failed for \(data)")
        }
    }

    private func baseDecodeData() -> [String: Any] {
        [
            "workspaceID": "workspace-1",
            "teamID": "team-1",
            "revisionID": "rev-1",
            "title": "Test",
            "body": "Content",
            "contentHash": "hash"
        ]
    }

    // MARK: - Provenance Encoding

    func test_encodeProvenance_withOwner() {
        let provenance = SharedArtifactCloudCodec.encodeProvenance(
            workspaceID: "ws-1",
            teamID: "team-1",
            remoteArtifactID: "remote-123",
            ownerUserID: "owner-456"
        )

        XCTAssertTrue(provenance.hasPrefix("shared-sync:"))
        XCTAssertTrue(provenance.contains("ws-1"))
        XCTAssertTrue(provenance.contains("team-1"))
        XCTAssertTrue(provenance.contains("remote-123"))
        XCTAssertTrue(provenance.contains("owner-456"))
    }

    func test_encodeProvenance_withoutOwner() {
        let provenance = SharedArtifactCloudCodec.encodeProvenance(
            workspaceID: "ws-1",
            teamID: "team-1",
            remoteArtifactID: "remote-123",
            ownerUserID: nil
        )

        XCTAssertTrue(provenance.hasPrefix("shared-sync:"))
        XCTAssertTrue(provenance.contains("ws-1"))
        XCTAssertTrue(provenance.contains("team-1"))
        XCTAssertTrue(provenance.contains("remote-123"))
        // Empty owner should still be in the string
        XCTAssertTrue(provenance.hasSuffix("|"))
    }

    func test_decodeProvenance_valid() {
        let provenance = SharedArtifactCloudCodec.encodeProvenance(
            workspaceID: "ws-1",
            teamID: "team-1",
            remoteArtifactID: "remote-123",
            ownerUserID: "owner-456"
        )

        let decoded = SharedArtifactCloudCodec.decodeProvenance(provenance)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.workspaceID, "ws-1")
        XCTAssertEqual(decoded?.teamID, "team-1")
        XCTAssertEqual(decoded?.remoteArtifactID, "remote-123")
        XCTAssertEqual(decoded?.ownerUserID, "owner-456")
    }

    func test_decodeProvenance_noOwner() {
        let provenance = SharedArtifactCloudCodec.encodeProvenance(
            workspaceID: "ws-1",
            teamID: "team-1",
            remoteArtifactID: "remote-123",
            ownerUserID: nil
        )

        let decoded = SharedArtifactCloudCodec.decodeProvenance(provenance)

        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.ownerUserID)
    }

    func test_decodeProvenance_invalidPrefix() {
        let result = SharedArtifactCloudCodec.decodeProvenance("invalid-prefix|data")
        XCTAssertNil(result)
    }

    func test_decodeProvenance_insufficientPieces() {
        // Only 2 pieces
        let result = SharedArtifactCloudCodec.decodeProvenance("shared-sync:ws-1|team-1")
        XCTAssertNil(result)
    }
}

final class HermesRelayHostServiceTests: XCTestCase {
    @MainActor
    func test_disabledHermesRealtimeRelayHostClientNeverStarts() async {
        let disabled = DisabledHermesRealtimeRelayHostClient()

        let started = await disabled.start(uid: "uid", connectionID: "relay-mac")

        XCTAssertFalse(started)
        XCTAssertFalse(disabled.isReady)
        XCTAssertNil(disabled.publishableRelayURLString)
    }

    @MainActor
    func test_hermesRelayHostFanoutTreatsIrohPrimaryAsReadyWhenWSSFallbackUnavailable() async {
        let primary = StubRealtimeRelayHost(startResult: true, readyAfterStart: true)
        let fallback = StubRealtimeRelayHost(startResult: false, readyAfterStart: false)
        let fanout = HermesRelayHostFanout(primary: primary, fallback: fallback)

        let started = await fanout.start(uid: "uid", connectionID: "relay-mac")

        XCTAssertTrue(started)
        XCTAssertTrue(fanout.isReady)
        XCTAssertNil(fanout.publishableRelayURLString)
        XCTAssertEqual(primary.startCallCount, 1)
        XCTAssertEqual(fallback.startCallCount, 1)
    }

    func test_relayDataFragments_preservesLargePayloadWithoutTruncation() {
        let payload = String(repeating: "abcdef", count: 25_000)

        let fragments = HermesRelayHostService.relayDataFragments(payload)

        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertEqual(fragments.joined(), payload)
        XCTAssertTrue(fragments.allSatisfy { $0.utf8.count <= HermesRelayHostService.maxRelayChunkDataBytes })
    }

    func test_relayDataFragments_preservesUnicodeBoundaries() {
        let payload = String(repeating: "Hermes ☿ ", count: 15_000)

        let fragments = HermesRelayHostService.relayDataFragments(payload)

        XCTAssertEqual(fragments.joined(), payload)
        XCTAssertTrue(fragments.allSatisfy { $0.utf8.count <= HermesRelayHostService.maxRelayChunkDataBytes })
    }

    func test_consumeSSELine_treatsCRLFBlankLineAsEventBoundary() {
        var eventLines: [String] = []

        XCTAssertEqual(
            HermesRelayHostService.consumeSSELine("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\r", eventLines: &eventLines),
            []
        )
        let events = HermesRelayHostService.consumeSSELine("\r", eventLines: &eventLines)

        XCTAssertEqual(events, ["data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"])
        XCTAssertTrue(eventLines.isEmpty)
    }

    func test_consumeSSELine_splitsAdjacentDataFramesWhenBlankLinesAreNotYielded() {
        var eventLines: [String] = []

        XCTAssertEqual(
            HermesRelayHostService.consumeSSELine("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}", eventLines: &eventLines),
            []
        )
        let events = HermesRelayHostService.consumeSSELine("data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}", eventLines: &eventLines)

        XCTAssertEqual(events, ["data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}"])
        XCTAssertEqual(eventLines, ["data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}"])
    }

    func test_mergedModelsResponseBodies_addsDaemonGatewayModelsWithoutDuplicates() throws {
        let primary = Data(#"{"object":"list","data":[{"id":"hermes-agent","owned_by":"hermes"}]}"#.utf8)
        let secondary = Data(#"{"object":"list","data":[{"id":"hermes-agent","owned_by":"hermes"},{"id":"glm-5","owned_by":"zai","display_name":"GLM-5"},{"id":"minimax-m2.7","owned_by":"minimax"}]}"#.utf8)

        let merged = try XCTUnwrap(HermesRelayHostService.mergedModelsResponseBodies(primary, secondary))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])

        XCTAssertEqual(data.compactMap { $0["id"] as? String }, ["hermes-agent", "glm-5", "minimax-m2.7"])
        XCTAssertEqual(data[1]["display_name"] as? String, "GLM-5")
    }

    // The hermes/ollama local catalog body helpers were refactored out of
    // HermesRelayHostService — these tests are stale and live only as
    // documentation until the new entry points land. Disabled so the
    // active test suite continues to compile without referencing the
    // removed static methods.
}

@MainActor
private final class StubRealtimeRelayHost: HermesRealtimeRelayHosting {
    private(set) var isReady = false
    private(set) var startCallCount = 0
    private let startResult: Bool
    private let readyAfterStart: Bool
    let publishableRelayURLString: String?

    init(
        startResult: Bool,
        readyAfterStart: Bool,
        publishableRelayURLString: String? = nil
    ) {
        self.startResult = startResult
        self.readyAfterStart = readyAfterStart
        self.publishableRelayURLString = publishableRelayURLString
    }

    @discardableResult
    func start(uid: String, connectionID: String) async -> Bool {
        startCallCount += 1
        isReady = readyAfterStart
        return startResult
    }

    func stop() {
        isReady = false
    }
}

final class EscrowPublicKeyPublisherTests: XCTestCase {
    func testExistingPublicKeyMatcherAcceptsExactDocument() {
        let data: [String: Any] = [
            "deviceId": "device-1",
            "publicKeyData": String(repeating: "A", count: 88),
            "publicKeyFingerprint": String(repeating: "F", count: 44),
            "keyVersion": 1,
            "algorithm": "ECIES-P256-AESGCM"
        ]

        XCTAssertTrue(EscrowPublicKeyPublisher.matchesExistingPublicKey(
            data,
            deviceId: "device-1",
            publicKeyBase64: String(repeating: "A", count: 88),
            publicKeyFingerprint: String(repeating: "F", count: 44),
            keyVersion: 1
        ))
    }

    func testExistingPublicKeyMatcherAcceptsLegacyDocumentWithoutFingerprint() {
        let data: [String: Any] = [
            "deviceId": "device-1",
            "publicKeyData": String(repeating: "A", count: 88),
            "keyVersion": 1,
            "algorithm": "ECIES-P256-AESGCM"
        ]

        XCTAssertTrue(EscrowPublicKeyPublisher.matchesExistingPublicKey(
            data,
            deviceId: "device-1",
            publicKeyBase64: String(repeating: "A", count: 88),
            publicKeyFingerprint: String(repeating: "F", count: 44),
            keyVersion: 1
        ))
    }

    func testExistingPublicKeyMatcherRejectsImmutableKeyDrift() {
        let data: [String: Any] = [
            "deviceId": "device-1",
            "publicKeyData": String(repeating: "B", count: 88),
            "publicKeyFingerprint": String(repeating: "F", count: 44),
            "keyVersion": 1,
            "algorithm": "ECIES-P256-AESGCM"
        ]

        XCTAssertFalse(EscrowPublicKeyPublisher.matchesExistingPublicKey(
            data,
            deviceId: "device-1",
            publicKeyBase64: String(repeating: "A", count: 88),
            publicKeyFingerprint: String(repeating: "F", count: 44),
            keyVersion: 1
        ))
    }
}

// MARK: - V-10: shared-artifact sealing (no plaintext source content to Firestore)

final class SharedArtifactCloudCodecSealingTests: XCTestCase {

    private func makeRecord(
        artifactID: String = "artifact-1",
        revisionID: String = "rev-1",
        title: String = "secret-design.md",
        body: String = "private source content the cloud must never see",
        contentHash: String = String(repeating: "a", count: 64),
        relativePath: String? = "src/secret/design.md"
    ) -> SharedArtifactCloudRecord {
        SharedArtifactCloudRecord(
            artifactID: artifactID,
            workspaceID: "workspace-user-1",
            teamID: "team-default",
            ownerUserID: "user-1",
            visibility: .team,
            revisionID: revisionID,
            baseRevisionID: nil,
            title: title,
            body: body,
            contentHash: contentHash,
            relativePath: relativePath,
            isDeleted: false,
            updatedByUserID: "user-1",
            updatedByDeviceID: "mac-device",
            resolvedConflictRevisionID: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func headAAD(uid: String, docID: String) -> String {
        "OpenBurnBar-CloudVault-aad-v2|\(uid)|artifacts|\(docID)|sealedPayload|2|sealedPayload"
    }

    func test_encodeSealed_writesNoCleartextContent() throws {
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let record = makeRecord()

        let payload = try SharedArtifactCloudCodec.encodeSealed(
            record,
            vaultKey: key,
            vaultKeyID: vaultKeyID,
            uid: "user-1",
            aadCollection: SharedArtifactCloudCodec.headAADCollection,
            aadDocID: record.artifactID,
            useServerTimestamp: false
        )

        // The whole point: no source content leaves the device in cleartext.
        XCTAssertFalse(payload["body"] is String, "body must not be a cleartext string")
        XCTAssertFalse(payload["title"] is String, "title must not be a cleartext string")
        XCTAssertFalse(payload["contentHash"] is String, "contentHash oracle must be removed from cleartext")
        XCTAssertFalse(payload["relativePath"] is String, "relativePath must not be a cleartext string")
        XCTAssertEqual(payload["contentSealed"] as? Bool, true)
        XCTAssertEqual(payload["vaultKeyID"] as? String, vaultKeyID)

        let sealed = try XCTUnwrap(payload["sealedPayload"] as? [String: Any])
        XCTAssertEqual(sealed["algorithm"] as? String, "AES-256-GCM")
        XCTAssertEqual(sealed["aad"] as? String, headAAD(uid: "user-1", docID: record.artifactID))
        // The serialized envelope must not contain the plaintext body anywhere.
        let envelopeText = (sealed["sealedBoxBase64"] as? String) ?? ""
        XCTAssertFalse(envelopeText.contains(record.body))
    }

    func test_encodeSealed_then_decode_roundTrips() throws {
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let record = makeRecord()

        let payload = try SharedArtifactCloudCodec.encodeSealed(
            record,
            vaultKey: key,
            vaultKeyID: vaultKeyID,
            uid: "user-1",
            aadCollection: SharedArtifactCloudCodec.headAADCollection,
            aadDocID: record.artifactID,
            useServerTimestamp: false
        )

        let decoded = try SharedArtifactCloudCodec.decode(
            documentID: record.artifactID,
            data: payload,
            uid: "user-1",
            vaultKey: key
        )

        XCTAssertEqual(decoded.title, record.title)
        XCTAssertEqual(decoded.body, record.body)
        XCTAssertEqual(decoded.contentHash, record.contentHash)
        XCTAssertEqual(decoded.relativePath, record.relativePath)
        XCTAssertEqual(decoded.revisionID, record.revisionID)
    }

    func test_decode_sealedWithoutKey_throwsRequiresKey() throws {
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let record = makeRecord()

        let payload = try SharedArtifactCloudCodec.encodeSealed(
            record,
            vaultKey: key,
            vaultKeyID: vaultKeyID,
            uid: "user-1",
            aadCollection: SharedArtifactCloudCodec.headAADCollection,
            aadDocID: record.artifactID,
            useServerTimestamp: false
        )

        XCTAssertThrowsError(
            try SharedArtifactCloudCodec.decode(documentID: record.artifactID, data: payload)
        ) { error in
            guard case SharedArtifactCloudCodecError.sealedContentRequiresKey = error else {
                return XCTFail("expected sealedContentRequiresKey, got \(error)")
            }
        }
    }

    func test_decode_relocatedSealedPayload_throws() throws {
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let record = makeRecord(artifactID: "artifact-1")

        // Seal bound to artifact-1 …
        let payload = try SharedArtifactCloudCodec.encodeSealed(
            record,
            vaultKey: key,
            vaultKeyID: vaultKeyID,
            uid: "user-1",
            aadCollection: SharedArtifactCloudCodec.headAADCollection,
            aadDocID: "artifact-1",
            useServerTimestamp: false
        )

        // … then attempt to open it as if it lived at artifact-2 (relocation).
        XCTAssertThrowsError(
            try SharedArtifactCloudCodec.decode(
                documentID: "artifact-2",
                data: payload,
                uid: "user-1",
                vaultKey: key
            )
        )
    }

    func test_encodeSealed_headAndVersion_bindDistinctAAD() throws {
        let key = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: key)
        let record = makeRecord(artifactID: "artifact-1", revisionID: "rev-9")

        let headPayload = try SharedArtifactCloudCodec.encodeSealed(
            record, vaultKey: key, vaultKeyID: vaultKeyID, uid: "user-1",
            aadCollection: SharedArtifactCloudCodec.headAADCollection,
            aadDocID: record.artifactID, useServerTimestamp: false
        )
        let versionPayload = try SharedArtifactCloudCodec.encodeSealed(
            record, vaultKey: key, vaultKeyID: vaultKeyID, uid: "user-1",
            aadCollection: SharedArtifactCloudCodec.versionAADCollection,
            aadDocID: record.revisionID, useServerTimestamp: false
        )

        let headAad = (headPayload["sealedPayload"] as? [String: Any])?["aad"] as? String
        let versionAad = (versionPayload["sealedPayload"] as? [String: Any])?["aad"] as? String
        XCTAssertNotEqual(headAad, versionAad)
        XCTAssertEqual(headAad?.contains("|artifacts|"), true)
        XCTAssertEqual(versionAad?.contains("|artifact_versions|"), true)
    }

    func test_legacyPlaintextDocument_stillDecodes() throws {
        // Back-compat: a not-yet-migrated plaintext document still reads, so
        // existing cloud heads keep working until their next write re-seals them.
        let data: [String: Any] = [
            "artifactID": "artifact-legacy",
            "workspaceID": "workspace-user-1",
            "teamID": "team-default",
            "ownerUserID": "user-1",
            "visibility": "team",
            "revisionID": "rev-legacy",
            "title": "legacy.md",
            "body": "legacy plaintext body",
            "contentHash": String(repeating: "b", count: 64),
            "relativePath": "src/legacy.md",
            "isDeleted": false
        ]
        let decoded = try SharedArtifactCloudCodec.decode(documentID: "artifact-legacy", data: data)
        XCTAssertEqual(decoded.body, "legacy plaintext body")
        XCTAssertEqual(decoded.title, "legacy.md")
    }
}
