import Foundation
import XCTest
@testable import OpenBurnBarMobile

final class MobileCloudVaultTrustedDeviceSetTests: XCTestCase {
    func testLegacyMalformedTrustedDeviceDoesNotBlockValidRecipients() async throws {
        let devices = ["current-ipad", "legacy-mismatched-record", "approved-mac"]

        let verified = try await MobileCloudVaultTrustedDeviceChainVerifier
            .retainingCryptographicallyValidDevices(devices) { deviceID in
                if deviceID == "legacy-mismatched-record" {
                    throw MobileCloudVaultTrustChainVerificationError.invalidTrustedDevice(deviceId: deviceID)
                }
                return Self.verifiedDevice(deviceID)
            }

        XCTAssertEqual(verified.map(\.deviceId), ["current-ipad", "approved-mac"])
    }

    func testNonVerificationFailureStillFailsClosed() async {
        let expected = URLError(.timedOut)

        do {
            _ = try await MobileCloudVaultTrustedDeviceChainVerifier
                .retainingCryptographicallyValidDevices(["current-ipad", "network-failure"]) { deviceID in
                    if deviceID == "network-failure" { throw expected }
                    return Self.verifiedDevice(deviceID)
                }
            XCTFail("A transport failure must not be mistaken for a malformed legacy record.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, expected.code)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStoredDeviceIDMustMatchFirestoreDocumentID() throws {
        XCTAssertThrowsError(
            try MobileCloudVaultTrustedDeviceChainVerifier.boundDeviceID(
                documentID: "legacy-document-id",
                data: ["deviceId": "different-device-id"]
            )
        ) { error in
            guard case MobileCloudVaultTrustChainVerificationError.invalidTrustedDevice(let deviceID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(deviceID, "legacy-document-id")
        }
    }

    func testStoredDeviceIDAcceptsExactDocumentBinding() throws {
        XCTAssertEqual(
            try MobileCloudVaultTrustedDeviceChainVerifier.boundDeviceID(
                documentID: "current-ipad",
                data: ["deviceId": "current-ipad"]
            ),
            "current-ipad"
        )
    }

    func testExistingWrapperFromAnotherTrustedSourceIsReused() throws {
        let target = Self.verifiedDevice("current-ipad")
        let existing: [String: Any] = [
            "uid": "user-1",
            "vaultKeyID": "v1_0123456789abcdef0123456789abcdef",
            "targetDeviceId": target.deviceId,
            "sourceDeviceId": "approved-mac",
            "publicKeyFingerprint": target.escrowPublicKeyFingerprint,
            "keyVersion": target.keyVersion,
            "wrappedVaultKey": Data("already-wrapped".utf8).base64EncodedString(),
            "algorithm": "ECIES-P256-AESGCM",
            "status": "active",
            "schemaVersion": 2
        ]

        XCTAssertFalse(
            try MobileCloudVaultKeyWrapperPublisher.requiresCreate(
                existing: existing,
                wrapperID: "v1_0123456789abcdef0123456789abcdef_current-ipad_1",
                uid: "user-1",
                vaultKeyID: "v1_0123456789abcdef0123456789abcdef",
                target: target
            )
        )
    }

    func testConflictingExistingWrapperFailsClosed() throws {
        let target = Self.verifiedDevice("current-ipad")
        let conflicting: [String: Any] = [
            "uid": "user-1",
            "vaultKeyID": "v1_0123456789abcdef0123456789abcdef",
            "targetDeviceId": target.deviceId,
            "sourceDeviceId": "approved-mac",
            "publicKeyFingerprint": "different-key",
            "keyVersion": target.keyVersion,
            "wrappedVaultKey": Data("already-wrapped".utf8).base64EncodedString(),
            "algorithm": "ECIES-P256-AESGCM",
            "status": "active",
            "schemaVersion": 2
        ]

        XCTAssertThrowsError(
            try MobileCloudVaultKeyWrapperPublisher.requiresCreate(
                existing: conflicting,
                wrapperID: "v1_0123456789abcdef0123456789abcdef_current-ipad_1",
                uid: "user-1",
                vaultKeyID: "v1_0123456789abcdef0123456789abcdef",
                target: target
            )
        ) { error in
            guard case MobileCloudVaultKeyWrapperPublishError.immutableWrapperConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testVerificationCacheCoalescesSameTrustSnapshotAndInvalidatesChangedSnapshot() async throws {
        let cache = MobileCloudVaultTrustedDeviceVerificationCache(ttl: 60)
        let probe = VerificationLoaderProbe()
        let original = Self.cacheKey(snapshot: "snapshot-a")

        let first = Task { @MainActor in
            try await cache.value(for: original) {
                try await probe.load()
            }
        }
        await Task.yield()
        let concurrent = Task { @MainActor in
            try await cache.value(for: original) {
                try await probe.load()
            }
        }

        let firstValue = try await first.value
        let concurrentValue = try await concurrent.value
        let cachedValue = try await cache.value(for: original) {
            try await probe.load()
        }

        XCTAssertEqual(firstValue.map(\.deviceId), ["approved-mac"])
        XCTAssertEqual(concurrentValue.map(\.deviceId), ["approved-mac"])
        XCTAssertEqual(cachedValue.map(\.deviceId), ["approved-mac"])
        XCTAssertEqual(probe.loadCount, 1)

        _ = try await cache.value(for: Self.cacheKey(snapshot: "snapshot-b")) {
            try await probe.load()
        }
        XCTAssertEqual(probe.loadCount, 2)
    }

    private static func cacheKey(snapshot: String) -> MobileCloudVaultTrustedDeviceVerificationCache.Key {
        .init(
            uid: "user-1",
            localIdentityKeyID: "signal-current-ipad",
            localIdentityFingerprint: "fingerprint-current-ipad",
            trustSnapshotDigest: snapshot
        )
    }

    private static func verifiedDevice(_ deviceID: String) -> MobileCloudVaultVerifiedTrustedDevice {
        MobileCloudVaultVerifiedTrustedDevice(
            deviceId: deviceID,
            keyVersion: 1,
            escrowPublicKeyFingerprint: "escrow-\(deviceID)",
            escrowPublicKeyData: Data(deviceID.utf8),
            signalIdentityKeyId: "signal-\(deviceID)",
            signalIdentityPublicKeyFingerprint: "signal-fingerprint-\(deviceID)",
            signalIdentityPublicKeyData: Data("signal-\(deviceID)".utf8)
        )
    }
}

@MainActor
private final class VerificationLoaderProbe {
    private(set) var loadCount = 0

    func load() async throws -> [MobileCloudVaultVerifiedTrustedDevice] {
        loadCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        return [
            MobileCloudVaultVerifiedTrustedDevice(
                deviceId: "approved-mac",
                keyVersion: 1,
                escrowPublicKeyFingerprint: "escrow-approved-mac",
                escrowPublicKeyData: Data("approved-mac".utf8),
                signalIdentityKeyId: "signal-approved-mac",
                signalIdentityPublicKeyFingerprint: "signal-fingerprint-approved-mac",
                signalIdentityPublicKeyData: Data("signal-approved-mac".utf8)
            )
        ]
    }
}
