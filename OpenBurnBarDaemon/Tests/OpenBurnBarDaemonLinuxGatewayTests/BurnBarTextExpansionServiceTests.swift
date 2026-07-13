#if os(Linux)
import Foundation
import OpenBurnBarKernel
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarTextExpansionServiceTests: XCTestCase {
    private var directory: URL!
    private var backend: TextExpansionTestSecretBackend!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-text-expansion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend = TextExpansionTestSecretBackend()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testEncryptedPersistenceConsentRestartAndPermissions() throws {
        let service = makeService()
        let consent = try service.updateConsent(
            BurnBarTextExpansionConsentUpdateRequest(inAppOnly: true, declinedGlobalCapture: true)
        ).consent
        XCTAssertTrue(consent.inAppOnly)
        let stored = try service.upsert(BurnBarTextExpansionUpsertRequest(snippet: snippet()))
        XCTAssertEqual(stored.trigger, "reply")

        let path = directory.appendingPathComponent("text-expansion.obbsealed")
        let bytes = try Data(contentsOf: path)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Thanks"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o077, 0)

        let restarted = makeService()
        let snapshot = try restarted.snapshot()
        XCTAssertEqual(snapshot.consent, consent)
        XCTAssertEqual(snapshot.snippets.first?.body, "Thanks")
    }

    func testCorruptStoreAndInvalidConsentFailClosed() throws {
        let service = makeService()
        XCTAssertThrowsError(
            try service.updateConsent(
                BurnBarTextExpansionConsentUpdateRequest(inAppOnly: true, declinedGlobalCapture: false)
            )
        ) { XCTAssertEqual($0 as? BurnBarTextExpansionService.ServiceError, .invalidConsent) }

        let path = directory.appendingPathComponent("text-expansion.obbsealed")
        try Data("not encrypted".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        XCTAssertThrowsError(try service.snapshot()) {
            XCTAssertEqual($0 as? BurnBarTextExpansionService.ServiceError, .corruptStore)
        }
    }

    func testMissingNativeSecretBackendDoesNotUsePlaintextFallback() throws {
        let service = BurnBarTextExpansionService(
            fileURL: directory.appendingPathComponent("text-expansion.obbsealed"),
            secretStore: LinuxSecretCustodian(backends: []),
            logger: BurnBarDaemonLogger(category: "text-expansion-test")
        )
        XCTAssertThrowsError(try service.upsert(BurnBarTextExpansionUpsertRequest(snippet: snippet()))) {
            XCTAssertEqual($0 as? BurnBarTextExpansionService.ServiceError, .keyStorageUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("text-expansion.obbsealed").path))
    }

    private func makeService() -> BurnBarTextExpansionService {
        BurnBarTextExpansionService(
            fileURL: directory.appendingPathComponent("text-expansion.obbsealed"),
            secretStore: LinuxSecretCustodian(backends: [backend]),
            logger: BurnBarDaemonLogger(category: "text-expansion-test")
        )
    }

    private func snippet() -> BurnBarTextExpansionWireSnippet {
        BurnBarTextExpansionWireSnippet(
            id: "snippet-1",
            title: "Reply",
            trigger: "&&Reply",
            body: "Thanks",
            mode: "static",
            isEnabled: true,
            scope: BurnBarTextExpansionScope(surfaces: ["in_app_thread"]),
            revision: 1,
            createdAt: "2026-07-13T00:00:00Z",
            updatedAt: "2026-07-13T00:00:00Z"
        )
    }
}

private final class TextExpansionTestSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "test-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true
    private let lock = NSLock()
    private var records: [String: LinuxSecretRecord] = [:]

    func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        lock.withLock { records[id] }
    }

    func storeSecret(_ secret: String, id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretMetadata {
        let metadata = LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: 1_900_000_000_000,
            note: "test"
        )
        lock.withLock { records[id] = LinuxSecretRecord(secret: secret, metadata: metadata) }
        return metadata
    }

    func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {
        _ = lock.withLock { records.removeValue(forKey: id) }
    }

    func healthCheck() throws {}
}
#endif
