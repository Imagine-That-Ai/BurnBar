import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
import OpenBurnBarSignalCore
import OpenBurnBarSignalSessionTransport

final class LinuxCoreFoundationTests: XCTestCase {
    func testCloudVaultSignalFallbackExportsCoreContractsAndFailsClosedForSignalAtRestOnLinux() throws {
        let vaultKey = try CloudVaultCrypto.generateVaultKey()
        XCTAssertEqual(vaultKey.count, 32)

        let context = try CloudVaultAADContext(
            uid: "uid-linux",
            collection: "sessions",
            docID: "doc-1",
            field: "body"
        )
        let sealedText = try CloudVaultCrypto.sealText(
            "foundation signal payload",
            keyData: vaultKey,
            keyVersion: 7,
            aadContext: context
        )
        XCTAssertEqual(
            try CloudVaultCrypto.openText(sealedText, keyData: vaultKey, aadContext: context),
            "foundation signal payload"
        )

        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "linux-device")
        let binding = CloudVaultSignalBinding(
            uid: "uid-linux",
            collection: "sessions",
            docId: "doc-1",
            field: "body"
        )
        XCTAssertThrowsError(try OpenBurnBarSignalAtRest.sealPayload(
            Data("signal at-rest fallback is disabled".utf8),
            recipients: [identity.atRestRecipient()],
            binding: binding,
            senderIdentityKeyId: identity.identityKeyId,
            senderIdentityPrivateKey: identity.privateKeyData
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }
    }

    func testSignalFallbackWrapFailsClosedWithoutLibSignal() throws {
        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "linux-device-public-wrap")
        let binding = SignalEnvelopeAAD.Binding(
            uid: "uid-linux",
            scope: .cloudvault,
            collection: "sessions",
            docId: "doc-public-wrap",
            field: "body",
            mode: .atRest,
            formatVersion: 1
        )
        XCTAssertThrowsError(try OpenBurnBarSignalAtRest.atRestSeal(
            Data("fallback content key".utf8),
            recipientIdentityPublicKey: identity.publicKeyData,
            binding: binding
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }
    }

    func testMediaAndComputerUseAeadSeamsRoundTripOnLinux() throws {
        let media = MediaFrameAEAD()
        let mediaKey = media.deriveSessionKey(
            sharedSecret: Data(repeating: 0x41, count: 32),
            salt: Data("media-session".utf8)
        )
        let frame = Data("screen frame bytes".utf8)
        let sealedFrame = try media.seal(
            plaintext: frame,
            key: mediaKey,
            streamClass: "screen",
            kind: 1,
            gopID: 3,
            frameIndex: 8
        )
        XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(sealedFrame))
        XCTAssertEqual(
            try media.open(
                envelope: sealedFrame,
                key: mediaKey,
                streamClass: "screen",
                kind: 1,
                gopID: 3,
                frameIndex: 8
            ),
            frame
        )
        XCTAssertThrowsError(try media.open(
            envelope: sealedFrame,
            key: mediaKey,
            streamClass: "screen",
            kind: 1,
            gopID: 3,
            frameIndex: 9
        ))

        let control = ControlFrameSeal()
        let controlKey = control.deriveSessionKey(
            hpkeSessionKey: Data(repeating: 0x52, count: 32),
            salt: Data("control-session".utf8)
        )
        let command = Data(#"{"type":"control.click","x":12,"y":34}"#.utf8)
        let sealedCommand = try control.seal(
            plaintext: command,
            key: controlKey,
            peerNodeId: "phone-peer",
            frameType: "control.click"
        )
        XCTAssertTrue(ControlFrameSeal.isSealedEnvelope(sealedCommand))
        XCTAssertEqual(
            try control.open(
                envelope: sealedCommand,
                key: controlKey,
                peerNodeId: "phone-peer",
                frameType: "control.click"
            ),
            command
        )
        XCTAssertThrowsError(try control.open(
            envelope: sealedCommand,
            key: controlKey,
            peerNodeId: "other-peer",
            frameType: "control.click"
        ))
    }

    func testIrohPairingSignatureAndDiscoveryPathMappingOnLinux() throws {
        let signingKey = PlatformCrypto.ed25519PrivateKey()
        let publishedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let record = try IrohPairingSignature.sign(
            uid: "uid-linux",
            connectionId: "conn-linux",
            nodeId: "node-linux",
            relayURL: "https://relay.openburnbar.invalid",
            directAddresses: ["/ip4/127.0.0.1/udp/7777/quic-v1"],
            publishedAtMillis: publishedAt,
            with: signingKey
        )

        try IrohPairingSignature.verify(
            record,
            publicKey: signingKey.publicKey.rawRepresentation,
            now: Date(timeIntervalSince1970: TimeInterval(publishedAt) / 1_000)
        )

        #if os(Linux)
        let home = URL(fileURLWithPath: "/tmp/openburnbar-linux-home", isDirectory: true)
        let source = AgentProviderLogDiscovery.resolveLogSource(
            for: .codex,
            environment: ["HOME": home.path]
        )
        XCTAssertEqual(source.provider, AgentProvider.codex)
        XCTAssertTrue(source.resolvedPath.hasSuffix(".codex/sessions"))
        XCTAssertEqual(source.filePattern, "*.jsonl")
        #endif
    }
}
