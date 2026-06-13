import CryptoKit
import XCTest
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarSignalCore
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

    func testHighRiskCallablesFailClosedWhenNoUserIsAuthenticated() async {
        let record = IrohPairingRecord(
            uid: "uid-1",
            connectionId: "conn-1",
            nodeId: "node-1",
            relayURL: "https://relay.example",
            directAddresses: ["/ip4/127.0.0.1/tcp/1234"],
            publishedAtMillis: 1_700_000_000_000,
            signature: "sig"
        )
        let actions: [(String, () async throws -> Void)] = [
            ("bind", { try await ComputerUseSecurityCallableClient.bindAppCheckAttestation() }),
            ("nonce", { _ = try await ComputerUseSecurityCallableClient.issueHighRiskActionNonce() }),
            ("register", {
                try await ComputerUseSecurityCallableClient.registerEscrowDevice(
                    deviceId: "mac-1",
                    deviceName: "Mac",
                    platform: "macOS",
                    appVersion: "1.0",
                    publicKeyFingerprint: "fp",
                    keyVersion: 1
                )
            }),
            ("approve", {
                try await ComputerUseSecurityCallableClient.approveEscrowDeviceTrust(
                    deviceId: "iphone-1",
                    approverDeviceId: "mac-1"
                )
            }),
            ("revoke", {
                _ = try await ComputerUseSecurityCallableClient.revokeEscrowDeviceTrust(
                    deviceId: "iphone-1",
                    rotatingDeviceId: "mac-1"
                )
            }),
            ("publish-pairing-key", {
                try await ComputerUseSecurityCallableClient.publishIrohPairingPublicKey(
                    deviceId: "mac-1",
                    publicKeyBase64: "pub"
                )
            }),
            ("publish-pairing-record", {
                try await ComputerUseSecurityCallableClient.publishIrohPairingRecord(
                    deviceId: "mac-1",
                    record: record
                )
            }),
            ("revoke-pairing-record", {
                try await ComputerUseSecurityCallableClient.revokeIrohPairingRecord(
                    deviceId: "mac-1",
                    connectionId: "conn-1"
                )
            })
        ]

        for (name, action) in actions {
            await XCTAssertThrowsErrorAsync({
                try await action()
            }, { error in
                XCTAssertEqual(
                    (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                    "Sign in before performing this Computer Use security action.",
                    name
                )
            })
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

        let defaultGeneration = try ComputerUseSecurityCallableClient.RevocationCloudVaultRotationRequirement(
            data: [
                "status": "pending",
                "rotateCallable": "rotateCloudVaultKey",
                "currentVaultKeyID": "vault-default",
                "survivorDeviceIds": ["mac-1"]
            ],
            rotatingDeviceId: "mac-1"
        )
        XCTAssertEqual(defaultGeneration.currentVaultGeneration, 1)
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
        let nextKey = try CloudVaultCrypto.generateVaultKey()
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

    func testCloudVaultAccessErrorsAndEscrowPublicKeyMatching() {
        XCTAssertEqual(
            CloudVaultAccessError.vaultKeyUnavailable.errorDescription,
            "Cloud vault key is unavailable on this device."
        )
        XCTAssertEqual(
            CloudVaultAccessError.vaultKeyMismatch(expected: "expected", actual: "actual").errorDescription,
            "Cloud vault key mismatch. Expected expected, got actual."
        )
        XCTAssertEqual(
            CloudVaultAccessError.invalidWrappedKey.errorDescription,
            "Cloud vault wrapper could not be decrypted."
        )
        XCTAssertEqual(
            EscrowPublicKeyPublishError.immutablePublicKeyConflict(deviceId: "mac-1", keyVersion: 2)
                .errorDescription,
            "Escrow public key conflict for mac-1_2."
        )
        XCTAssertEqual(
            SignalIdentityPublicKeyPublishError.immutablePublicKeyConflict(deviceId: "mac-1", keyVersion: 3)
                .errorDescription,
            "Signal identity public key conflict for mac-1_3."
        )

        XCTAssertTrue(EscrowPublicKeyPublisher.matchesExistingPublicKey(
            [
                "deviceId": "mac-1",
                "publicKeyData": "pub",
                "publicKeyFingerprint": "fp",
                "keyVersion": 2,
                "algorithm": "ECIES-P256-AESGCM"
            ],
            deviceId: "mac-1",
            publicKeyBase64: "pub",
            publicKeyFingerprint: "fp",
            keyVersion: 2
        ))
        XCTAssertTrue(EscrowPublicKeyPublisher.matchesExistingPublicKey(
            [
                "deviceId": "mac-1",
                "publicKeyData": "pub",
                "keyVersion": 2,
                "algorithm": "ECIES-P256-AESGCM"
            ],
            deviceId: "mac-1",
            publicKeyBase64: "pub",
            publicKeyFingerprint: "fp",
            keyVersion: 2
        ))
        XCTAssertFalse(EscrowPublicKeyPublisher.matchesExistingPublicKey(
            [
                "deviceId": "mac-1",
                "publicKeyData": "other",
                "publicKeyFingerprint": "fp",
                "keyVersion": 2,
                "algorithm": "ECIES-P256-AESGCM"
            ],
            deviceId: "mac-1",
            publicKeyBase64: "pub",
            publicKeyFingerprint: "fp",
            keyVersion: 2
        ))
        XCTAssertFalse(EscrowPublicKeyPublisher.matchesExistingPublicKey(
            [
                "deviceId": "mac-1",
                "publicKeyData": "pub",
                "publicKeyFingerprint": "other",
                "keyVersion": 2,
                "algorithm": "ECIES-P256-AESGCM"
            ],
            deviceId: "mac-1",
            publicKeyBase64: "pub",
            publicKeyFingerprint: "fp",
            keyVersion: 2
        ))
    }

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

        let result = try await ComputerUseSecurityCallableClient.performRevocationCloudVaultRotation(
            uid: "uid-1",
            requirementId: "req-1",
            rotatingDeviceId: "mac-1",
            environment: environment
        )

        XCTAssertEqual(result.jobId, "job-1")
        XCTAssertEqual(result.progress.rewrappedDocuments, 7)
        XCTAssertEqual(result.progress.rewrappedStorageBlobs, 4)
        XCTAssertEqual(capture.loadedRequirementId, "req-1")
        XCTAssertEqual(capture.publishedIdentityDeviceId, "mac-1_1")
        XCTAssertEqual(capture.verifiedSurvivorDeviceIds, ["mac-1"])
        let payload = try XCTUnwrap(capture.rotatePayload)
        XCTAssertEqual(payload["callerDeviceId"] as? String, "mac-1")
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

    func testRevocationCloudVaultRotationRejectsMissingRequirementCurrentKeyAndMismatchedKey() async throws {
        let currentKey = try CloudVaultCrypto.generateVaultKey()
        let currentVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: currentKey)

        await XCTAssertThrowsErrorAsync({
            try await ComputerUseSecurityCallableClient.performRevocationCloudVaultRotation(
                uid: "uid-1",
                requirementId: "req-missing",
                rotatingDeviceId: "mac-1",
                environment: makeRotationEnvironment(
                    currentKey: currentKey,
                    currentVaultKeyID: currentVaultKeyID,
                    survivorPrivateKey: P256.KeyAgreement.PrivateKey(),
                    requirementMissing: true,
                    capture: RotationCapture()
                )
            )
        }, { error in
            XCTAssertEqual(
                (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                "Cloud Vault rotation requirement is missing or already consumed."
            )
        })

        await XCTAssertThrowsErrorAsync({
            try await ComputerUseSecurityCallableClient.performRevocationCloudVaultRotation(
                uid: "uid-1",
                requirementId: "req-1",
                rotatingDeviceId: "mac-1",
                environment: makeRotationEnvironment(
                    currentKey: currentKey,
                    currentVaultKeyID: currentVaultKeyID,
                    survivorPrivateKey: P256.KeyAgreement.PrivateKey(),
                    currentKeyMissing: true,
                    capture: RotationCapture()
                )
            )
        }, { error in
            XCTAssertEqual(
                (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                "This Mac does not have the current Cloud Vault key needed to rotate after revocation."
            )
        })

        await XCTAssertThrowsErrorAsync({
            try await ComputerUseSecurityCallableClient.performRevocationCloudVaultRotation(
                uid: "uid-1",
                requirementId: "req-1",
                rotatingDeviceId: "mac-1",
                environment: makeRotationEnvironment(
                    currentKey: currentKey,
                    currentVaultKeyID: currentVaultKeyID,
                    survivorPrivateKey: P256.KeyAgreement.PrivateKey(),
                    currentKeyIDOverride: "vault-other",
                    capture: RotationCapture()
                )
            )
        }, { error in
            XCTAssertEqual(
                (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                "Cloud Vault rotation requirement expected \(currentVaultKeyID), but this Mac has vault-other."
            )
        })
    }

    func testRevocationCloudVaultRotationRejectsMalformedRotateResponse() async throws {
        let currentKey = try CloudVaultCrypto.generateVaultKey()
        let currentVaultKeyID = try CloudVaultCrypto.vaultKeyID(for: currentKey)
        let environment = makeRotationEnvironment(
            currentKey: currentKey,
            currentVaultKeyID: currentVaultKeyID,
            survivorPrivateKey: P256.KeyAgreement.PrivateKey(),
            rotateResponse: ["ok": false],
            capture: RotationCapture()
        )

        await XCTAssertThrowsErrorAsync({
            try await ComputerUseSecurityCallableClient.performRevocationCloudVaultRotation(
                uid: "uid-1",
                requirementId: "req-1",
                rotatingDeviceId: "mac-1",
                environment: environment
            )
        }, { error in
            XCTAssertEqual(
                (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription,
                "Cloud Vault key rotation was not queued."
            )
        })
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

        await XCTAssertThrowsErrorAsync({
            try await ComputerUseSecurityCallableClient.performRevocationCloudVaultRotation(
                uid: "uid-1",
                requirementId: "req-1",
                rotatingDeviceId: "mac-1",
                environment: environment
            )
        }, { error in
            let message = (error as? ComputerUseSecurityCallableClient.ClientError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Cloud Vault rotation job job-1 was queued"))
            XCTAssertTrue(message.contains("local rewrap failed"))
        })
        XCTAssertEqual(capture.markedFailedJobId, "job-1")
        XCTAssertEqual(capture.markedFailureMessage, "local rewrap failed")
    }

    private func makeRotationEnvironment(
        currentKey: Data,
        currentVaultKeyID: String,
        survivorPrivateKey: P256.KeyAgreement.PrivateKey,
        requirementMissing: Bool = false,
        currentKeyMissing: Bool = false,
        currentKeyIDOverride: String? = nil,
        rotateResponse: [String: Any] = ["ok": true, "jobId": "job-1"],
        rewrapError: Error? = nil,
        capture: RotationCapture
    ) -> ComputerUseSecurityCallableClient.RevocationCloudVaultRotationEnvironment {
        ComputerUseSecurityCallableClient.RevocationCloudVaultRotationEnvironment(
            loadRequirement: { requirementId in
                capture.loadedRequirementId = requirementId
                if requirementMissing { return nil }
                return [
                    "status": "pending",
                    "rotateCallable": "rotateCloudVaultKey",
                    "currentVaultKeyID": currentVaultKeyID,
                    "currentVaultGeneration": 2,
                    "survivorDeviceIds": ["mac-1"]
                ]
            },
            loadCurrentKey: {
                if currentKeyMissing { return nil }
                return CloudVaultResolvedKey(keyData: currentKey, vaultKeyID: currentKeyIDOverride ?? currentVaultKeyID)
            },
            loadLocalIdentity: {
                OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "mac-1")
            },
            publishLocalIdentity: { identity in
                capture.publishedIdentityDeviceId = identity.identityKeyId
            },
            verifiedTrustedDevice: { deviceId, _ in
                capture.verifiedSurvivorDeviceIds.append(deviceId)
                return CloudVaultVerifiedTrustedDevice(
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
                return CloudVaultRotationRewrapProgress(
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

private struct TestRotationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
