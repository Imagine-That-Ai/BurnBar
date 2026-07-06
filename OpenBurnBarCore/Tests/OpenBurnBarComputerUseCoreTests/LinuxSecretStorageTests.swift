#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore
import XCTest

final class LinuxSecretStorageTests: XCTestCase {
    private func tempDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-secrets-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func newKeyBase64() -> String {
        PlatformCrypto.ed25519PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    func testControllerPinFileFallbackRoundTripsAndPersistsAcrossInstances() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var warnings: [String] = []
        let service = "com.openburnbar.test.controller-pin"
        let secretService = UnavailableLinuxSecretServiceClient(reason: "no session bus")
        let first = LinuxSecretControllerKeyPinBacking(
            service: service,
            fallbackDirectory: directory,
            secretService: secretService,
            logger: { warnings.append($0) }
        )
        let record = ControllerPinRecord(
            keyBase64: newKeyBase64(),
            confirmed: true,
            pinnedAtEpoch: 1_800_000_001
        )

        XCTAssertEqual(first.save(record, account: "uid|phone"), errSecSuccessCompat)
        XCTAssertEqual(first.load(account: "uid|phone"), .found(record))

        let second = LinuxSecretControllerKeyPinBacking(
            service: service,
            fallbackDirectory: directory,
            secretService: secretService,
            logger: { warnings.append($0) }
        )
        XCTAssertEqual(second.load(account: "uid|phone"), .found(record))
        XCTAssertFalse(warnings.isEmpty, "Secret Service degradation must be logged")
    }

    func testFileFallbackUsesOwnerOnlyPermissions() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = LinuxSecretControllerKeyPinBacking(
            service: "com.openburnbar.test.permissions",
            fallbackDirectory: directory,
            secretService: UnavailableLinuxSecretServiceClient(reason: "forced fallback")
        )
        let record = ControllerPinRecord(keyBase64: newKeyBase64(), confirmed: false, pinnedAtEpoch: 1)

        XCTAssertEqual(backing.save(record, account: "uid|phone"), errSecSuccessCompat)

        XCTAssertEqual(try permissions(directory), 0o700)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        XCTAssertGreaterThanOrEqual(files.count, 2, "fallback writes a master key and one sealed record")
        for file in files {
            XCTAssertEqual(try permissions(file), 0o600, "\(file.lastPathComponent) must be owner-read/write only")
        }
    }

    func testAbsentSecretIsNotAnError() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = LinuxSecretControllerKeyPinBacking(
            service: "com.openburnbar.test.absent",
            fallbackDirectory: directory,
            secretService: UnavailableLinuxSecretServiceClient(reason: "forced fallback")
        )

        XCTAssertEqual(backing.load(account: "missing"), .absent)
    }

    func testCorruptFallbackRecordFailsClosed() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = LinuxSecretControllerKeyPinBacking(
            service: "com.openburnbar.test.corrupt",
            fallbackDirectory: directory,
            secretService: UnavailableLinuxSecretServiceClient(reason: "forced fallback")
        )
        let record = ControllerPinRecord(keyBase64: newKeyBase64(), confirmed: false, pinnedAtEpoch: 1)

        XCTAssertEqual(backing.save(record, account: "uid|phone"), errSecSuccessCompat)
        let sealedRecord = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "obbsecret" }
        )
        try Data("not-json".utf8).write(to: sealedRecord)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sealedRecord.path)

        guard case .unreadable = backing.load(account: "uid|phone") else {
            XCTFail("corrupt fallback record must fail closed")
            return
        }
    }

    func testIrohHostPinStoreUsesSamePersistentLinuxBacking() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = LinuxSecretControllerKeyPinBacking(
            service: LinuxPersistentSecretStore.irohHostPinService,
            fallbackDirectory: directory,
            secretService: UnavailableLinuxSecretServiceClient(reason: "forced fallback")
        )
        let first = IrohHostKeyPinStore(backing: backing, localPublicKeyBase64: newKeyBase64())
        let hostKey = newKeyBase64()

        guard case .pinnedFirstUse = first.verifyOrPin(advertisedKeyBase64: hostKey, uid: "uid", roleId: "host") else {
            XCTFail("expected first-use host pin")
            return
        }

        let secondBacking = LinuxSecretControllerKeyPinBacking(
            service: LinuxPersistentSecretStore.irohHostPinService,
            fallbackDirectory: directory,
            secretService: UnavailableLinuxSecretServiceClient(reason: "forced fallback")
        )
        let second = IrohHostKeyPinStore(backing: secondBacking, localPublicKeyBase64: newKeyBase64())
        guard case .matchesPendingConfirmation = second.verifyOrPin(advertisedKeyBase64: hostKey, uid: "uid", roleId: "host") else {
            XCTFail("host pin must survive backing recreation")
            return
        }
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var info = stat()
        let status = url.path.withCString { Glibc.stat($0, &info) }
        XCTAssertEqual(status, 0)
        return info.st_mode & 0o777
    }
}
#endif
