#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class DaemonLinuxLocalAuthProofVerifierTests: XCTestCase {
    func testLinuxFilePinBackingRoundTripsIntoLocalAuthProofVerifier() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openburnbar-linux-local-auth-\(UUID().uuidString)")
        let fileURL = tempDirectory.appendingPathComponent("pins.json")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let deviceId = "linux-device-abc"
        let intentHash = String(repeating: "c", count: 64)
        let key = PlatformCrypto.ed25519PrivateKey()
        let backing = DaemonPhoneKeyFilePinBacking(fileURL: fileURL)
        let store = DaemonPhoneKeyPinStore(backing: backing)

        guard case .pinned = store.pin(deviceId: deviceId, key: .ed25519(key.publicKey)) else {
            return XCTFail("expected Linux file backing to persist pinned key")
        }

        let reloadedStore = DaemonPhoneKeyPinStore(
            backing: DaemonPhoneKeyFilePinBacking(fileURL: fileURL)
        )
        let ledger = DaemonConsumedLocalAuthProofLedger()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { deviceId in
                if case .pinned(let key) = reloadedStore.pinnedKey(deviceId: deviceId) {
                    return key
                }
                return nil
            },
            consumeProof: { proofId, expiresAt in
                ledger.consume(proofId: proofId, expiresAt: expiresAt)
            }
        )
        let now = Date()
        let proof = try ComputerUsePhoneControlSigner().signLocalAuthProof(
            deviceId: deviceId,
            signedIntentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120),
            privateKey: key
        )

        let result = try verifier.verify(
            proof: proof,
            expectedDeviceId: deviceId,
            expectedIntentHashHex: intentHash,
            now: now
        )

        XCTAssertEqual(result.deviceId, deviceId)
        XCTAssertEqual(result.proofId, proof.proofId)
    }

    func testLinuxVerifierRejectsBindingMismatchWithPersistedPin() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openburnbar-linux-local-auth-mismatch-\(UUID().uuidString)")
        let fileURL = tempDirectory.appendingPathComponent("pins.json")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let deviceId = "linux-device-abc"
        let signedHash = String(repeating: "d", count: 64)
        let requestedHash = String(repeating: "e", count: 64)
        let key = PlatformCrypto.ed25519PrivateKey()
        let store = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyFilePinBacking(fileURL: fileURL))
        _ = store.pin(deviceId: deviceId, key: .ed25519(key.publicKey))
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { deviceId in
                if case .pinned(let key) = store.pinnedKey(deviceId: deviceId) {
                    return key
                }
                return nil
            },
            consumeProof: { _, _ in true }
        )
        let now = Date()
        let proof = try ComputerUsePhoneControlSigner().signLocalAuthProof(
            deviceId: deviceId,
            signedIntentHash: signedHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120),
            privateKey: key
        )

        XCTAssertThrowsError(
            try verifier.verify(
                proof: proof,
                expectedDeviceId: deviceId,
                expectedIntentHashHex: requestedHash,
                now: now
            )
        ) { error in
            guard case .wrongIntent = error as? DaemonLocalAuthProofVerifier.VerificationFailure else {
                return XCTFail("expected wrongIntent, got \(error)")
            }
        }
    }
}
#endif
