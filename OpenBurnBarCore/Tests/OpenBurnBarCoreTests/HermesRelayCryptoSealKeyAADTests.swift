import CryptoKit
import XCTest
@testable import OpenBurnBarCore

/// Pins the F7 (`mediaSealKeyAAD`) and F10 (`controlSealKeyAAD`) AAD
/// constructions added to `HermesRelayCrypto`. These two wraps share the
/// sealKeyV3 primitive with the chat lane, so the ONLY thing keeping a
/// media-seal wrap from being replayed onto the control lane (and vice versa,
/// or onto chat) is the AAD domain tag plus the bound identity components —
/// every byte of that binding is asserted here, including the fail-closed
/// behavior of `openKeyV3` under a cross-lane AAD.
final class HermesRelayCryptoSealKeyAADTests: XCTestCase {

    // MARK: - Exact wire-format pins

    func testMediaSealKeyAADPinsExactByteLayout() {
        let aad = HermesRelayCrypto.mediaSealKeyAAD(
            uid: "uid-1",
            connectionID: "conn-1",
            viewerId: "viewer-1",
            senderDeviceID: "iphone-1",
            senderKeyID: "key-1",
            senderCounter: 42
        )
        XCTAssertEqual(
            aad,
            Data("OpenBurnBar-HermesRelay-v1|mediaSealKey|uid-1|conn-1|viewer-1|iphone-1|key-1|42".utf8)
        )
    }

    func testControlSealKeyAADPinsExactByteLayout() {
        let aad = HermesRelayCrypto.controlSealKeyAAD(
            uid: "uid-1",
            connectionID: "conn-1",
            peerNodeId: "controller-peer",
            senderDeviceID: "iphone-1",
            senderKeyID: "key-1",
            senderCounter: 42
        )
        XCTAssertEqual(
            aad,
            Data("OpenBurnBar-HermesRelay-v1|controlSealKey|uid-1|conn-1|controller-peer|iphone-1|key-1|42".utf8)
        )
    }

    // MARK: - Domain separation

    func testMediaAndControlSealKeyAADsDifferForIdenticalComponents() {
        let media = HermesRelayCrypto.mediaSealKeyAAD(
            uid: "uid", connectionID: "conn", viewerId: "peer",
            senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
        )
        let control = HermesRelayCrypto.controlSealKeyAAD(
            uid: "uid", connectionID: "conn", peerNodeId: "peer",
            senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
        )
        XCTAssertNotEqual(media, control, "distinct domain tags must separate the two seal lanes")
    }

    func testEveryComponentChangesTheControlSealKeyAAD() {
        let base = HermesRelayCrypto.controlSealKeyAAD(
            uid: "uid", connectionID: "conn", peerNodeId: "peer",
            senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
        )
        let variants = [
            HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid2", connectionID: "conn", peerNodeId: "peer",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid", connectionID: "conn2", peerNodeId: "peer",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid", connectionID: "conn", peerNodeId: "peer2",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid", connectionID: "conn", peerNodeId: "peer",
                senderDeviceID: "device2", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid", connectionID: "conn", peerNodeId: "peer",
                senderDeviceID: "device", senderKeyID: "key2", senderCounter: 1
            ),
            HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid", connectionID: "conn", peerNodeId: "peer",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 2
            ),
        ]
        for (index, variant) in variants.enumerated() {
            XCTAssertNotEqual(base, variant, "component \(index) is not bound into the AAD")
        }
        XCTAssertEqual(Set(variants).count, variants.count, "components must bind injectively")
    }

    func testEveryComponentChangesTheMediaSealKeyAAD() {
        let base = HermesRelayCrypto.mediaSealKeyAAD(
            uid: "uid", connectionID: "conn", viewerId: "viewer",
            senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
        )
        let variants = [
            HermesRelayCrypto.mediaSealKeyAAD(
                uid: "uid2", connectionID: "conn", viewerId: "viewer",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.mediaSealKeyAAD(
                uid: "uid", connectionID: "conn2", viewerId: "viewer",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.mediaSealKeyAAD(
                uid: "uid", connectionID: "conn", viewerId: "viewer2",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.mediaSealKeyAAD(
                uid: "uid", connectionID: "conn", viewerId: "viewer",
                senderDeviceID: "device2", senderKeyID: "key", senderCounter: 1
            ),
            HermesRelayCrypto.mediaSealKeyAAD(
                uid: "uid", connectionID: "conn", viewerId: "viewer",
                senderDeviceID: "device", senderKeyID: "key2", senderCounter: 1
            ),
            HermesRelayCrypto.mediaSealKeyAAD(
                uid: "uid", connectionID: "conn", viewerId: "viewer",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 2
            ),
        ]
        for (index, variant) in variants.enumerated() {
            XCTAssertNotEqual(base, variant, "component \(index) is not bound into the AAD")
        }
    }

    // MARK: - sealKeyV3 round trip + cross-lane fail-closed

    func testSealKeyV3RoundTripsUnderControlSealKeyAAD() throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let aad = HermesRelayCrypto.controlSealKeyAAD(
            uid: "uid", connectionID: "conn", peerNodeId: "peer",
            senderDeviceID: "device", senderKeyID: "key", senderCounter: 5
        )

        let wrap = try HermesRelayCrypto.sealKeyV3(
            keyData,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            senderPrivateKey: sender,
            aad: aad
        )
        let opened = try HermesRelayCrypto.openKeyV3(
            enc: wrap.enc,
            wrappedKey: wrap.wrappedKey,
            privateKey: recipient,
            pinnedSenderPublicKeyBase64: sender.publicKeyBase64,
            aad: aad
        )
        XCTAssertEqual(opened, keyData)
    }

    func testControlSealWrapRefusesToOpenUnderTheMediaSealAAD() throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()

        let wrap = try HermesRelayCrypto.sealKeyV3(
            keyData,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            senderPrivateKey: sender,
            aad: HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid", connectionID: "conn", peerNodeId: "peer",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 5
            )
        )
        // Same components, other lane: the cross-lane replay MUST fail closed.
        XCTAssertThrowsError(
            try HermesRelayCrypto.openKeyV3(
                enc: wrap.enc,
                wrappedKey: wrap.wrappedKey,
                privateKey: recipient,
                pinnedSenderPublicKeyBase64: sender.publicKeyBase64,
                aad: HermesRelayCrypto.mediaSealKeyAAD(
                    uid: "uid", connectionID: "conn", viewerId: "peer",
                    senderDeviceID: "device", senderKeyID: "key", senderCounter: 5
                )
            )
        )
    }

    func testControlSealWrapRefusesToOpenForADifferentController() throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()

        let wrap = try HermesRelayCrypto.sealKeyV3(
            keyData,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            senderPrivateKey: sender,
            aad: HermesRelayCrypto.controlSealKeyAAD(
                uid: "uid", connectionID: "conn", peerNodeId: "controller-a",
                senderDeviceID: "device", senderKeyID: "key", senderCounter: 5
            )
        )
        XCTAssertThrowsError(
            try HermesRelayCrypto.openKeyV3(
                enc: wrap.enc,
                wrappedKey: wrap.wrappedKey,
                privateKey: recipient,
                pinnedSenderPublicKeyBase64: sender.publicKeyBase64,
                aad: HermesRelayCrypto.controlSealKeyAAD(
                    uid: "uid", connectionID: "conn", peerNodeId: "controller-b",
                    senderDeviceID: "device", senderKeyID: "key", senderCounter: 5
                )
            )
        )
    }
}
