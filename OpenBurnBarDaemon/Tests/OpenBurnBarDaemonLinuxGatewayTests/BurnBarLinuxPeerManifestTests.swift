#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarLinuxPeerManifestTests: XCTestCase {
    private let manifestName = "appimage-peer-manifest.json"
    private let signatureName = "appimage-peer-manifest.ed25519.sig"

    func testSignedManifestAdmitsExactImmutableAppImageExecutable() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        XCTAssertEqual(try fixture.validate(), .app)
    }

    func testTamperedManifestAndExecutableAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.makeMutable()
        try Data("tampered".utf8).appendToFile(at: fixture.manifestURL)
        try fixture.makeImmutable()
        XCTAssertThrowsError(try fixture.validate())

        let executableFixture = try makeFixture()
        defer { executableFixture.remove() }
        try executableFixture.makeMutable()
        try Data("tampered".utf8).appendToFile(at: executableFixture.executableURL)
        try executableFixture.makeImmutable()
        XCTAssertThrowsError(try executableFixture.validate())
    }

    func testUnknownKeyAndInvalidSignatureAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.validate(trustedKeys: []))

        let otherKey = PlatformCrypto.ed25519PrivateKey()
        let wrongTrust = BurnBarLinuxPeerManifestTrustKey(
            keyID: fixture.keyID,
            publicKeyRaw: otherKey.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try fixture.validate(trustedKeys: [wrongTrust]))
    }

    func testSymlinkedAndOversizedManifestFilesAreRejected() throws {
        let symlinkFixture = try makeFixture()
        defer { symlinkFixture.remove() }
        try symlinkFixture.makeMutable()
        let target = symlinkFixture.resourceURL.appendingPathComponent("manifest-target")
        try FileManager.default.moveItem(at: symlinkFixture.manifestURL, to: target)
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.manifestURL,
            withDestinationURL: target
        )
        try symlinkFixture.makeImmutable()
        XCTAssertThrowsError(try symlinkFixture.validate())

        let oversizedFixture = try makeFixture()
        defer { oversizedFixture.remove() }
        try oversizedFixture.makeMutable()
        try Data(repeating: 0x20, count: 4097).write(to: oversizedFixture.manifestURL)
        try oversizedFixture.makeImmutable()
        XCTAssertThrowsError(try oversizedFixture.validate())
    }

    func testPathAndBasenameDriftAreRejectedEvenWhenSigned() throws {
        let pathFixture = try makeFixture(manifestOverrides: [
            "executableRelativePath": "../../usr/bin/openburnbar-linux-desktop"
        ])
        defer { pathFixture.remove() }
        XCTAssertThrowsError(try pathFixture.validate())

        let basenameFixture = try makeFixture(manifestOverrides: [
            "executableBasename": "OpenBurnBar"
        ])
        defer { basenameFixture.remove() }
        XCTAssertThrowsError(try basenameFixture.validate())
    }

    func testValidSignatureOverNonCanonicalManifestBytesIsRejected() throws {
        let fixture = try makeFixture(canonicalManifest: false)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testWritableAppImageRootIsRejected() throws {
        let fixture = try makeFixture(rootMode: 0o755)
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.validate())
    }

    func testReleasePolicyIgnoresRawEnvironmentPins() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openburnbar-debug-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("openburnbar-linux-desktop")
        let bytes = Data("debug-only".utf8)
        try bytes.write(to: executable)
        let sha = PlatformCrypto.sha256Hex(bytes)
        let credential = BurnBarLinuxPeerCredential(
            pid: getpid(),
            uid: geteuid(),
            gid: getegid(),
            executablePath: executable.path,
            executableSHA256: sha
        )
        let environment = ["OPENBURNBAR_DAEMON_LINUX_PEER_SHA256_PINS": "\(executable.path)=\(sha)"]

        XCTAssertThrowsError(try BurnBarDaemonPeerAuthenticator.validateLinuxPeerCredential(
            credential,
            environment: environment,
            currentUID: geteuid(),
            trustedFilesystemOwnerUID: geteuid(),
            trustedManifestKeys: [],
            allowDebugHashPins: false
        ))
        XCTAssertEqual(try BurnBarDaemonPeerAuthenticator.validateLinuxPeerCredential(
            credential,
            environment: environment,
            currentUID: geteuid(),
            trustedFilesystemOwnerUID: geteuid(),
            trustedManifestKeys: [],
            allowDebugHashPins: true
        ), .app)
    }

    private func makeFixture(
        rootMode: mode_t = 0o555,
        manifestOverrides: [String: Any] = [:],
        canonicalManifest: Bool = true
    ) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openburnbar-appimage-peer-\(UUID().uuidString)")
        let executable = root.appendingPathComponent("usr/bin/openburnbar-linux-desktop")
        let resource = root.appendingPathComponent("usr/share/openburnbar")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        let executableBytes = Data("official appimage executable".utf8)
        try executableBytes.write(to: executable)
        chmod(executable.path, 0o555)

        let signingKey = PlatformCrypto.ed25519PrivateKey()
        let keyID = PlatformCrypto.sha256Hex(signingKey.publicKey.rawRepresentation)
        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "kind": "openburnbar.appimage.peer.v1",
            "keyId": keyID,
            "identity": BurnBarDaemonPeerIdentity.app.rawValue,
            "executableRelativePath": "usr/bin/openburnbar-linux-desktop",
            "executableBasename": "openburnbar-linux-desktop",
            "executableSHA256": PlatformCrypto.sha256Hex(executableBytes)
        ]
        for (key, value) in manifestOverrides { manifest[key] = value }
        let schemaVersion = try XCTUnwrap(manifest["schemaVersion"] as? Int)
        let kind = try XCTUnwrap(manifest["kind"] as? String)
        let manifestKeyID = try XCTUnwrap(manifest["keyId"] as? String)
        let identity = try XCTUnwrap(manifest["identity"] as? String)
        let executableRelativePath = try XCTUnwrap(manifest["executableRelativePath"] as? String)
        let executableBasename = try XCTUnwrap(manifest["executableBasename"] as? String)
        let executableSHA256 = try XCTUnwrap(manifest["executableSHA256"] as? String)
        let canonicalData = Data(([
            "{",
            "  \"schemaVersion\": \(schemaVersion),",
            "  \"kind\": \"\(kind)\",",
            "  \"keyId\": \"\(manifestKeyID)\",",
            "  \"identity\": \"\(identity)\",",
            "  \"executableRelativePath\": \"\(executableRelativePath)\",",
            "  \"executableBasename\": \"\(executableBasename)\",",
            "  \"executableSHA256\": \"\(executableSHA256)\"",
            "}"
        ].joined(separator: "\n") + "\n").utf8)
        let manifestData = canonicalManifest
            ? canonicalData
            : try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let signature = try PlatformCrypto.ed25519Signature(message: manifestData, privateKey: signingKey)
        let manifestURL = resource.appendingPathComponent(manifestName)
        let signatureURL = resource.appendingPathComponent(signatureName)
        try manifestData.write(to: manifestURL)
        try signature.write(to: signatureURL)
        chmod(manifestURL.path, 0o444)
        chmod(signatureURL.path, 0o444)
        chmod(root.path, rootMode)

        return Fixture(
            rootURL: root,
            executableURL: executable,
            resourceURL: resource,
            manifestURL: manifestURL,
            signatureURL: signatureURL,
            executableSHA256: PlatformCrypto.sha256Hex(executableBytes),
            keyID: keyID,
            publicKeyRaw: signingKey.publicKey.rawRepresentation
        )
    }
}

private struct Fixture {
    let rootURL: URL
    let executableURL: URL
    let resourceURL: URL
    let manifestURL: URL
    let signatureURL: URL
    let executableSHA256: String
    let keyID: String
    let publicKeyRaw: Data

    func makeMutable() throws {
        guard chmod(rootURL.path, 0o700) == 0,
              chmod(manifestURL.path, 0o600) == 0,
              chmod(signatureURL.path, 0o600) == 0,
              chmod(executableURL.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func makeImmutable() throws {
        guard chmod(executableURL.path, 0o555) == 0,
              chmod(manifestURL.path, 0o444) == 0,
              chmod(signatureURL.path, 0o444) == 0,
              chmod(rootURL.path, 0o555) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func validate(
        trustedKeys: [BurnBarLinuxPeerManifestTrustKey]? = nil
    ) throws -> BurnBarDaemonPeerIdentity {
        let credential = BurnBarLinuxPeerCredential(
            pid: getpid(),
            uid: geteuid(),
            gid: getegid(),
            executablePath: executableURL.path,
            executableSHA256: executableSHA256
        )
        return try BurnBarDaemonPeerAuthenticator.validateLinuxPeerCredential(
            credential,
            environment: [:],
            currentUID: geteuid(),
            trustedFilesystemOwnerUID: geteuid(),
            trustedManifestKeys: trustedKeys ?? [BurnBarLinuxPeerManifestTrustKey(
                keyID: keyID,
                publicKeyRaw: publicKeyRaw
            )],
            allowDebugHashPins: false
        )
    }

    func remove() {
        chmod(rootURL.path, 0o700)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private extension Data {
    func appendToFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
#endif
