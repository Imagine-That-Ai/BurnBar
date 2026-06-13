import CryptoKit
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class ComputerUseSecurityCallableClientTests: XCTestCase {
    func testRevocationResultParsingAndCompletionState() throws {
        let result = try ComputerUseSecurityCallableClient.parseEscrowDeviceTrustRevocationResult([
            "ok": true,
            "revokedCloudVaultWrappers": 3,
            "cloudVaultRotationRequired": true,
            "cloudVaultRotationRequirementId": "req-1",
            "cloudVaultRotationBlockedReason": "waiting_for_survivor"
        ])

        XCTAssertEqual(result.revokedCloudVaultWrappers, 3)
        XCTAssertTrue(result.cloudVaultRotationRequired)
        XCTAssertEqual(result.cloudVaultRotationRequirementId, "req-1")
        XCTAssertEqual(result.cloudVaultRotationBlockedReason, "waiting_for_survivor")
        XCTAssertFalse(result.cloudVaultRotationCompleted)
        XCTAssertNil(result.cloudVaultRotationFailureMessage)

        let completed = result.withCompletedCloudVaultRotation(
            jobId: "job-1",
            progress: CloudVaultRotationRewrapProgress(
                scannedDocuments: 12,
                rewrappedDocuments: 7,
                changedFields: 9,
                scannedStorageBlobs: 5,
                rewrappedStorageBlobs: 4
            )
        )
        XCTAssertEqual(completed.cloudVaultRotationJobId, "job-1")
        XCTAssertTrue(completed.cloudVaultRotationCompleted)
        XCTAssertEqual(completed.cloudVaultRotationRewrappedDocuments, 7)
        XCTAssertEqual(completed.cloudVaultRotationRewrappedStorageBlobs, 4)
        XCTAssertNil(completed.cloudVaultRotationFailureMessage)

        let failed = completed.withCloudVaultRotationFailure("rewrap failed")
        XCTAssertEqual(failed.cloudVaultRotationJobId, "job-1")
        XCTAssertFalse(failed.cloudVaultRotationCompleted)
        XCTAssertEqual(failed.cloudVaultRotationFailureMessage, "rewrap failed")
        XCTAssertEqual(failed.cloudVaultRotationRewrappedDocuments, 7)
        XCTAssertEqual(failed.cloudVaultRotationRewrappedStorageBlobs, 4)
    }

    func testRevocationResultRejectsFailedCallableResponse() {
        XCTAssertThrowsError(try ComputerUseSecurityCallableClient.parseEscrowDeviceTrustRevocationResult([
            "ok": false
        ])) { error in
            XCTAssertEqual(
                (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                "Escrow device trust revocation failed."
            )
        }
    }

    func testRotationRequirementNormalizesSurvivorDeviceIdsAndDefaultsGeneration() throws {
        let requirement = try ComputerUseSecurityCallableClient.RevocationCloudVaultRotationRequirement(
            data: [
                "status": "pending",
                "rotateCallable": "rotateCloudVaultKey",
                "currentVaultKeyID": "vault-current",
                "survivorDeviceIds": [" z-phone ", "", "mac-1"],
                "currentVaultGeneration": NSNumber(value: 4)
            ],
            rotatingDeviceId: "mac-1"
        )

        XCTAssertEqual(requirement.currentVaultKeyID, "vault-current")
        XCTAssertEqual(requirement.currentVaultGeneration, 4)
        XCTAssertEqual(requirement.survivorDeviceIds, ["mac-1", "z-phone"])
    }

    func testRotationRequirementFailsClosedForConsumedOrNonSurvivorRequirements() throws {
        XCTAssertThrowsError(try ComputerUseSecurityCallableClient.RevocationCloudVaultRotationRequirement(
            data: [
                "status": "complete",
                "rotateCallable": "rotateCloudVaultKey",
                "currentVaultKeyID": "vault-current",
                "survivorDeviceIds": ["mac-1"]
            ],
            rotatingDeviceId: "mac-1"
        )) { error in
            XCTAssertEqual(
                (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                "Cloud Vault rotation requirement is missing or already consumed."
            )
        }

        XCTAssertThrowsError(try ComputerUseSecurityCallableClient.RevocationCloudVaultRotationRequirement(
            data: [
                "status": "pending",
                "rotateCallable": "rotateCloudVaultKey",
                "currentVaultKeyID": "vault-current",
                "survivorDeviceIds": ["other-mac"]
            ],
            rotatingDeviceId: "mac-1"
        )) { error in
            XCTAssertEqual(
                (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                "This Mac is not a surviving trusted device for the required Cloud Vault rotation."
            )
        }
    }

    func testSurvivorWrapperEncryptsNextVaultKeyAndPayloadKeepsRequirementNonce() throws {
        let recipientPrivateKey = P256.KeyAgreement.PrivateKey()
        let nextKey = CloudVaultCrypto.generateVaultKey()
        let nextVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: nextKey)
        let survivor = CloudVaultVerifiedTrustedDevice(
            deviceId: "iphone-1",
            keyVersion: 6,
            escrowPublicKeyFingerprint: "fp_iphone",
            escrowPublicKeyData: recipientPrivateKey.publicKey.x963Representation,
            signalIdentityKeyId: "iphone-1_6",
            signalIdentityPublicKeyFingerprint: "sig_fp_iphone",
            signalIdentityPublicKeyData: Data([1, 2, 3])
        )

        let wrapper = try ComputerUseSecurityCallableClient.survivorWrapper(
            nextKey: nextKey,
            nextVaultKeyID: nextVaultKeyID,
            rotatingDeviceId: "mac-1",
            survivor: survivor
        )

        XCTAssertEqual(wrapper["wrapperId"] as? String, "\(nextVaultKeyID)_iphone-1_6")
        XCTAssertEqual(wrapper["targetDeviceId"] as? String, "iphone-1")
        XCTAssertEqual(wrapper["sourceDeviceId"] as? String, "mac-1")
        XCTAssertEqual(wrapper["publicKeyFingerprint"] as? String, "fp_iphone")
        XCTAssertEqual(wrapper["keyVersion"] as? Int, 6)
        XCTAssertEqual(wrapper["vaultKeyID"] as? String, nextVaultKeyID)
        let wrappedVaultKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(wrapper["wrappedVaultKey"] as? String)))
        XCTAssertEqual(try CloudVaultCrypto.unwrapVaultKey(wrappedVaultKey, privateKey: recipientPrivateKey), nextKey)

        let payload = ComputerUseSecurityCallableClient.rotationCallablePayload(
            rotatingDeviceId: "mac-1",
            currentVaultKeyID: "vault-old",
            nextVaultKeyID: nextVaultKeyID,
            nextVaultGeneration: 8,
            survivorWrappers: [wrapper],
            requirementId: "req-1",
            nonce: "nonce-1"
        )
        XCTAssertEqual(payload["callerDeviceId"] as? String, "mac-1")
        XCTAssertEqual(payload["currentVaultKeyID"] as? String, "vault-old")
        XCTAssertEqual(payload["newVaultKeyID"] as? String, nextVaultKeyID)
        XCTAssertEqual(payload["expectedVaultGeneration"] as? Int, 8)
        XCTAssertEqual(payload["reason"] as? String, "revocation_rewrap")
        XCTAssertEqual(payload["rotationRequirementId"] as? String, "req-1")
        XCTAssertEqual(payload["nonce"] as? String, "nonce-1")
        XCTAssertEqual((payload["survivorWrappers"] as? [[String: Any]])?.count, 1)
    }
}
