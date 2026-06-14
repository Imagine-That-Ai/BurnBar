import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import XCTest
@testable import OpenBurnBarMobile

/// RR-5: a surviving iOS device picks up pending Cloud Vault rotation requirements
/// when the revoking device is offline or on a platform that cannot rotate. These
/// cover the pure survivor filter and payload decode that gate the rotation chain.
final class MobileCloudVaultRotationPickupTests: XCTestCase {

    private typealias Requirement = MobileCloudVaultRevocationRotation.PendingCloudVaultRotationRequirement

    // MARK: - Survivor filter

    func test_eligibleRequirements_keepsOnlyRequirementsWhereDeviceSurvives() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1", "ipad-1"]),
            Requirement(requirementId: "r2", survivorDeviceIds: ["ipad-1"]),
            Requirement(requirementId: "r3", survivorDeviceIds: ["iphone-1"])
        ]
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "iphone-1"
        )
        XCTAssertEqual(eligible, ["r1", "r3"])
    }

    func test_eligibleRequirements_excludesAlreadyActioned() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"]),
            Requirement(requirementId: "r2", survivorDeviceIds: ["iphone-1"])
        ]
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "iphone-1",
            alreadyActioned: ["r1"]
        )
        XCTAssertEqual(eligible, ["r2"])
    }

    func test_eligibleRequirements_deduplicatesRepeatedRequirementIds() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"]),
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"])
        ]
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "iphone-1"
        )
        XCTAssertEqual(eligible, ["r1"], "a single pass runs each requirement at most once")
    }

    func test_eligibleRequirements_trimsRotatingDeviceIdAndEmptyIsNoop() {
        let requirements = [Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"])]
        XCTAssertEqual(
            MobileCloudVaultRevocationRotation.eligibleRequirements(from: requirements, rotatingDeviceId: "  iphone-1  "),
            ["r1"]
        )
        XCTAssertEqual(
            MobileCloudVaultRevocationRotation.eligibleRequirements(from: requirements, rotatingDeviceId: "   "),
            []
        )
    }

    func test_eligibleRequirements_emptyWhenNotASurvivor() {
        let requirements = [Requirement(requirementId: "r1", survivorDeviceIds: ["ipad-1", "iphone-2"])]
        XCTAssertEqual(
            MobileCloudVaultRevocationRotation.eligibleRequirements(from: requirements, rotatingDeviceId: "iphone-1"),
            []
        )
    }

    // MARK: - Payload decode

    func test_parsePendingRequirements_decodesRequirementIdOrId() {
        let raw: [[String: Any]] = [
            ["requirementId": "r1", "survivorDeviceIds": ["iphone-1", " ipad-1 "]],
            ["id": "r2", "survivorDeviceIds": ["iphone-2"]],
            ["survivorDeviceIds": ["iphone-1"]],
            ["requirementId": "", "survivorDeviceIds": []]
        ]
        let parsed = MobileCloudVaultRevocationRotation.parsePendingRequirements(raw)
        XCTAssertEqual(parsed.map(\.requirementId), ["r1", "r2"])
        XCTAssertEqual(parsed.first?.survivorDeviceIds, ["iphone-1", "ipad-1"], "survivor ids are trimmed and empties dropped")
    }

    func test_parsePendingRequirements_missingSurvivorsYieldsEmptyList() {
        let parsed = MobileCloudVaultRevocationRotation.parsePendingRequirements([["requirementId": "r1"]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.survivorDeviceIds, [])
    }

    func test_listPendingCallablePayload_includesCallerDeviceId() {
        let payload = MobileCloudVaultRevocationRotation.listPendingCallablePayload(callerDeviceId: "  iphone-1  ")
        XCTAssertEqual(payload["callerDeviceId"] as? String, "iphone-1")
    }

    // MARK: - Filter composes with decode end-to-end (no Firebase)

    func test_decodeThenFilter_endToEnd() {
        let raw: [[String: Any]] = [
            ["requirementId": "r1", "survivorDeviceIds": ["iphone-1"]],
            ["requirementId": "r2", "survivorDeviceIds": ["android-1"]]
        ]
        let parsed = MobileCloudVaultRevocationRotation.parsePendingRequirements(raw)
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(from: parsed, rotatingDeviceId: "iphone-1")
        XCTAssertEqual(eligible, ["r1"], "iPhone survives r1; r2 (Android-only survivor) is skipped")
    }

    // MARK: - Injected rotation environment

    func testRevocationCloudVaultRotationRunsInjectedSuccessPath() async throws {
        let currentKey = try CloudVaultCrypto.generateVaultKey()
        let currentVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: currentKey)
        let survivorPrivateKey = P256.KeyAgreement.PrivateKey()
        let capture = RotationCapture()

        let environment = makeRotationEnvironment(
            currentKey: currentKey,
            currentVaultKeyID: currentVaultKeyID,
            survivorPrivateKey: survivorPrivateKey,
            capture: capture
        )

        let result = try await MobileCloudVaultRevocationRotation.performRevocationCloudVaultRotation(
            uid: "uid-1",
            requirementId: "req-1",
            rotatingDeviceId: "iphone-1",
            environment: environment
        )

        XCTAssertEqual(result.jobId, "job-1")
        XCTAssertEqual(result.progress.rewrappedDocuments, 7)
        XCTAssertEqual(result.progress.rewrappedStorageBlobs, 4)
        XCTAssertEqual(capture.loadedRequirementId, "req-1")
        XCTAssertEqual(capture.publishedIdentityDeviceId, "iphone-1_1")
        XCTAssertEqual(capture.verifiedSurvivorDeviceIds, ["iphone-1"])
        let payload = try XCTUnwrap(capture.rotatePayload)
        XCTAssertEqual(payload["callerDeviceId"] as? String, "iphone-1")
        XCTAssertEqual(payload["currentVaultKeyID"] as? String, currentVaultKeyID)
        XCTAssertEqual(payload["expectedVaultGeneration"] as? Int, 3)
        XCTAssertEqual(payload["rotationRequirementId"] as? String, "req-1")
        XCTAssertEqual(payload["nonce"] as? String, "nonce-rotation")
        let wrappers = try XCTUnwrap(payload["survivorWrappers"] as? [[String: Any]])
        let wrappedVaultKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(wrappers.first?["wrappedVaultKey"] as? String)))
        let nextKey = try CloudVaultCrypto.unwrapVaultKey(wrappedVaultKey, privateKey: survivorPrivateKey)
        XCTAssertEqual(capture.savedNextKey, nextKey)
        XCTAssertEqual(capture.rewrapJobId, "job-1")
        XCTAssertEqual(capture.rewrapOldKey, currentKey)
        XCTAssertEqual(capture.rewrapNewKey, nextKey)
        XCTAssertNil(capture.markedFailedJobId)
    }

    func testRevocationCloudVaultRotationMarksQueuedJobFailedWhenLocalRewrapFails() async throws {
        let currentKey = try CloudVaultCrypto.generateVaultKey()
        let currentVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: currentKey)
        let capture = RotationCapture()
        let environment = makeRotationEnvironment(
            currentKey: currentKey,
            currentVaultKeyID: currentVaultKeyID,
            survivorPrivateKey: P256.KeyAgreement.PrivateKey(),
            rewrapError: TestRotationError(message: "local rewrap failed"),
            capture: capture
        )

        do {
            _ = try await MobileCloudVaultRevocationRotation.performRevocationCloudVaultRotation(
                uid: "uid-1",
                requirementId: "req-1",
                rotatingDeviceId: "iphone-1",
                environment: environment
            )
            XCTFail("expected rotation to fail")
        } catch {
            let message = (error as? MobileCloudVaultRevocationRotation.RotationError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Cloud Vault rotation job job-1 was queued"))
            XCTAssertTrue(message.contains("local rewrap failed"))
        }
        XCTAssertEqual(capture.markedFailedJobId, "job-1")
        XCTAssertEqual(capture.markedFailureMessage, "local rewrap failed")
    }

    private func makeRotationEnvironment(
        currentKey: Data,
        currentVaultKeyID: String,
        survivorPrivateKey: P256.KeyAgreement.PrivateKey,
        requirementMissing: Bool = false,
        rotateResponse: [String: Any] = ["ok": true, "jobId": "job-1"],
        rewrapError: Error? = nil,
        capture: RotationCapture
    ) -> MobileCloudVaultRevocationRotation.RevocationCloudVaultRotationEnvironment {
        MobileCloudVaultRevocationRotation.RevocationCloudVaultRotationEnvironment(
            loadRequirement: { requirementId in
                capture.loadedRequirementId = requirementId
                if requirementMissing { return nil }
                return [
                    "status": "pending",
                    "rotateCallable": "rotateCloudVaultKey",
                    "currentVaultKeyID": currentVaultKeyID,
                    "currentVaultGeneration": 2,
                    "survivorDeviceIds": ["iphone-1"]
                ]
            },
            loadCurrentKey: {
                MobileCloudVaultResolvedKey(keyData: currentKey, vaultKeyID: currentVaultKeyID)
            },
            loadLocalIdentity: {
                OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "iphone-1")
            },
            publishLocalIdentity: { identity in
                capture.publishedIdentityDeviceId = identity.identityKeyId
            },
            verifiedTrustedDevice: { deviceId, _ in
                capture.verifiedSurvivorDeviceIds.append(deviceId)
                return MobileCloudVaultVerifiedTrustedDevice(
                    deviceId: deviceId,
                    keyVersion: 4,
                    escrowPublicKeyFingerprint: "fp_\(deviceId)",
                    escrowPublicKeyData: survivorPrivateKey.publicKey.x963Representation,
                    signalIdentityKeyId: "\(deviceId)_4",
                    signalIdentityPublicKeyFingerprint: "sig_fp_\(deviceId)",
                    signalIdentityPublicKeyData: Data([4, 5, 6])
                )
            },
            issueNonce: {
                "nonce-rotation"
            },
            rotateCloudVaultKey: { payload in
                capture.rotatePayload = payload
                return rotateResponse
            },
            saveNextKey: { nextKey in
                capture.savedNextKey = nextKey
            },
            runDocumentRewrap: { jobId, oldKeyData, newKeyData, nextVaultKeyID, nextVaultGeneration in
                if let rewrapError {
                    throw rewrapError
                }
                capture.rewrapJobId = jobId
                capture.rewrapOldKey = oldKeyData
                capture.rewrapNewKey = newKeyData
                capture.rewrapVaultKeyID = nextVaultKeyID
                capture.rewrapVaultGeneration = nextVaultGeneration
                return MobileCloudVaultRotationRewrapProgress(
                    scannedDocuments: 12,
                    rewrappedDocuments: 7,
                    changedFields: 9,
                    scannedStorageBlobs: 5,
                    rewrappedStorageBlobs: 4
                )
            },
            markRotationFailed: { jobId, error in
                capture.markedFailedJobId = jobId
                capture.markedFailureMessage = error.localizedDescription
            }
        )
    }
}

private struct TestRotationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class RotationCapture {
    var loadedRequirementId: String?
    var publishedIdentityDeviceId: String?
    var verifiedSurvivorDeviceIds: [String] = []
    var rotatePayload: [String: Any]?
    var savedNextKey: Data?
    var rewrapJobId: String?
    var rewrapOldKey: Data?
    var rewrapNewKey: Data?
    var rewrapVaultKeyID: String?
    var rewrapVaultGeneration: Int?
    var markedFailedJobId: String?
    var markedFailureMessage: String?
}