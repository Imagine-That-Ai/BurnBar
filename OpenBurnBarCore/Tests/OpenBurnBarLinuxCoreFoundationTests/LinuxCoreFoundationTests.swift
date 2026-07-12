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
    func testCloudVaultSignalFallbackExportsCoreContractsOnLinux() throws {
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
        let plaintext = Data("signal at-rest fallback round trip".utf8)
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            plaintext,
            recipients: [identity.atRestRecipient()],
            binding: binding,
            senderIdentityKeyId: identity.identityKeyId,
            senderIdentityPrivateKey: identity.privateKeyData
        )

        XCTAssertEqual(envelope.keyDelivery.wraps.count, 1)
        XCTAssertEqual(envelope.binding, binding)
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: identity.identityKeyId,
                recipientIdentityPrivateKey: identity.privateKeyData,
                expectedBinding: binding,
                trustedSenderPublicKeys: [identity.identityKeyId: identity.publicKeyData]
            ),
            plaintext
        )
    }

    func testSignalFallbackWrapCannotBeOpenedWithPublicRecipientMaterial() throws {
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
        let plaintext = Data("fallback content key".utf8)
        let sealed = try OpenBurnBarSignalAtRest.atRestSeal(
            plaintext,
            recipientIdentityPublicKey: identity.publicKeyData,
            binding: binding
        )

        let oldPublicOnlyKey = SymmetricKey(data: Data(SHA256.hash(data: identity.publicKeyData)))
        XCTAssertThrowsError(
            try AES.GCM.open(
                AES.GCM.SealedBox(combined: sealed),
                using: oldPublicOnlyKey,
                authenticating: Data(try signalEnvelopeBindingToAAD(binding).utf8)
            )
        )
        XCTAssertEqual(
            try OpenBurnBarSignalAtRest.atRestOpen(
                sealed,
                recipientIdentityPrivateKey: identity.privateKeyData,
                binding: binding
            ),
            plaintext
        )
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
        let source = try XCTUnwrap(AgentProviderLogDiscovery.resolveLogSource(
            for: .codex,
            environment: ["HOME": home.path]
        ))
        XCTAssertEqual(source.provider, AgentProvider.codex)
        XCTAssertTrue(source.resolvedPath.hasSuffix(".codex/sessions"))
        XCTAssertEqual(source.filePattern, "*.jsonl")
        #endif
    }
}
