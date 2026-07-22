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

    func testEncryptedPersistenceConsentRestartAndPermissions() async throws {
        let service = makeService()
        let consent = try await service.updateConsent(
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

    func testCorruptStoreAndInvalidConsentFailClosed() async throws {
        let service = makeService()
        do {
            _ = try await service.updateConsent(
                BurnBarTextExpansionConsentUpdateRequest(inAppOnly: true, declinedGlobalCapture: false)
            )
            XCTFail("invalid consent must fail closed")
        } catch {
            XCTAssertEqual(error as? BurnBarTextExpansionService.ServiceError, .invalidConsent)
        }

        let path = directory.appendingPathComponent("text-expansion.obbsealed")
        try Data("not encrypted".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        XCTAssertThrowsError(try service.snapshot()) {
            XCTAssertEqual($0 as? BurnBarTextExpansionService.ServiceError, .corruptStore)
        }
    }

    func testSystemIMEConsentCannotRemainEnabledWhenInAppConsentIsRevoked() async throws {
        let service = makeService()
        let response = try await service.updateConsent(
            .init(inAppOnly: false, declinedGlobalCapture: true, systemIMEEnabled: true)
        )

        XCTAssertFalse(response.consent.inAppOnly)
        XCTAssertNotEqual(response.consent.systemIMEEnabled, true)
        XCTAssertEqual(try service.snapshot().consent, response.consent)
    }

    func testIsolatedKeyNamespaceDoesNotReadOrReplaceDefaultKey() throws {
        let defaultService = makeService()
        _ = try defaultService.upsert(.init(snippet: snippet()))
        let defaultRecord = try XCTUnwrap(
            backend.readSecret(id: "text-expansion-v1", secretClass: .textExpansionKey)
        )
        let isolatedURL = directory.appendingPathComponent("isolated.obbsealed")
        let isolated = BurnBarTextExpansionService(
            fileURL: isolatedURL,
            secretStore: LinuxSecretCustodian(backends: [backend]),
            logger: BurnBarDaemonLogger(category: "text-expansion-test"),
            keyNamespace: "p29-0123456789abcdef"
        )

        _ = try isolated.upsert(.init(snippet: snippet()))

        let isolatedRecord = try XCTUnwrap(
            backend.readSecret(
                id: "text-expansion-v1.p29-0123456789abcdef",
                secretClass: .textExpansionKey
            )
        )
        XCTAssertNotEqual(defaultRecord.secret, isolatedRecord.secret)
        XCTAssertEqual(
            try backend.readSecret(id: "text-expansion-v1", secretClass: .textExpansionKey)?.secret,
            defaultRecord.secret
        )
    }

    func testInvalidKeyNamespaceFailsClosedWithoutCreatingAKey() {
        let isolated = BurnBarTextExpansionService(
            fileURL: directory.appendingPathComponent("invalid-namespace.obbsealed"),
            secretStore: LinuxSecretCustodian(backends: [backend]),
            logger: BurnBarDaemonLogger(category: "text-expansion-test"),
            keyNamespace: "../not-allowed"
        )

        XCTAssertThrowsError(try isolated.upsert(.init(snippet: snippet()))) {
            XCTAssertEqual($0 as? BurnBarTextExpansionService.ServiceError, .keyStorageUnavailable)
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

    func testEngineRuntimeStatusIsDaemonOwnedAndStartRequiresPersistedConsent() async throws {
        let service = makeService()
        let status = await service.engineRuntimeStatus()
        XCTAssertEqual(status.state, "not_running")
        XCTAssertFalse(status.supportsExternalExpansion)

        do {
            _ = try await service.startExternalEngine(
                BurnBarTextExpansionEngineStartRequest(consentAcknowledged: false)
            )
            XCTFail("start must require an explicit consent acknowledgement")
        } catch let error as BurnBarTextExpansionService.ServiceError {
            XCTAssertEqual(error, .invalidConsent)
        }

        do {
            _ = try await service.startExternalEngine(
                BurnBarTextExpansionEngineStartRequest(consentAcknowledged: true)
            )
            XCTFail("start must require the daemon-persisted consent record")
        } catch let error as BurnBarTextExpansionService.ServiceError {
            XCTAssertEqual(error, .invalidConsent)
        }
    }

    func testEngineRuntimeTimeoutIsBoundedBeforeLaunch() async throws {
        let service = makeService()
        do {
            _ = try await service.stopExternalEngine(
                BurnBarTextExpansionEngineStopRequest(timeoutMillis: 30_001)
            )
            XCTFail("an unbounded lifecycle timeout must be rejected")
        } catch let error as BurnBarTextExpansionService.ServiceError {
            XCTAssertEqual(error, .invalidRuntimeRequest)
        }
    }

    func testExternalExpansionRequiresPersistedConsentBeforeEngineSession() async throws {
        let service = makeService()
        do {
            _ = try await service.expandExternalEngine(
                trigger: "reply",
                context: .init(inspectable: true, isSecureField: false),
                requestID: "request-1"
            )
            XCTFail("external expansion must require persisted consent")
        } catch let error as BurnBarTextExpansionService.ServiceError {
            XCTAssertEqual(error, .invalidConsent)
        }
    }

    func testRPCExpansionRequestKeepsSecureFieldContextTextFreeAndRequiresConsent() async throws {
        let service = makeService()
        let request = BurnBarTextExpansionEngineExpandRequest(
            trigger: "&&Reply",
            context: BurnBarTextExpansionSecureFieldContext(
                inspectable: true,
                isSecureField: false,
                applicationID: "org.example.editor",
                role: "entry",
                inputPurpose: "free-form"
            ),
            requestID: "request-1"
        )

        do {
            _ = try await service.expandExternalEngine(request)
            XCTFail("RPC expansion must require persisted consent")
        } catch let error as BurnBarTextExpansionService.ServiceError {
            XCTAssertEqual(error, .invalidConsent)
        }

        let encoded = try JSONEncoder().encode(request)
        let payload = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(payload.contains("trigger"))
        XCTAssertTrue(payload.contains("inspectable"))
        XCTAssertFalse(payload.contains("clipboard"))
        XCTAssertFalse(payload.contains("surrounding"))
        XCTAssertFalse(payload.contains("fieldText"))
        XCTAssertFalse(payload.contains("keyboard"))
    }

    func testRevokingSystemIMEConsentStopsRunningEngineBeforeReturning() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let engine = repository.appendingPathComponent("packaging/linux/openburnbar-text-expansion-engine.py")
        let manifestPath = repository.appendingPathComponent("packaging/linux/test-engine.json").path
        let manifest = BurnBarLinuxTextExpansionAdapter.EngineManifest(
            backend: .ibus,
            engineID: "org.openburnbar.TextExpansion",
            executablePath: engine.path,
            supportsWayland: true,
            supportsX11: true,
            signature: .init(
                publicKeyBase64: Data(repeating: 0, count: 32).base64EncodedString(),
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let adapter = BurnBarLinuxTextExpansionAdapter(
            environment: { name in
                ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"][name]
            },
            resolveExecutable: { name in name == "ibus" ? "/usr/bin/ibus" : nil },
            runCommand: { _, _ in .init(exitCode: 0) },
            manifestPath: manifestPath,
            externalExpansionEnabled: true,
            allowedManifestRoots: [repository.path],
            allowedExecutableRoots: [repository.path],
            trustedOwnerUIDs: [0],
            readManifest: { _ in manifestData },
            readFileMetadata: { path in
                if path == manifestPath { return .init(ownerUID: 0, mode: 0o600) }
                if path == engine.path { return .init(ownerUID: 0, mode: 0o700) }
                return nil
            },
            verifySignature: { _ in true }
        )
        let service = makeService(adapter: adapter)

        _ = try await service.updateConsent(
            .init(inAppOnly: true, declinedGlobalCapture: true, systemIMEEnabled: true)
        )
        let started = try await service.startExternalEngine(
            .init(consentAcknowledged: true, timeoutMillis: 1_000)
        )
        XCTAssertEqual(started.state, "ready")

        _ = try await service.updateConsent(
            .init(inAppOnly: true, declinedGlobalCapture: true, systemIMEEnabled: false)
        )
        let stopped = await service.engineRuntimeStatus()
        XCTAssertEqual(stopped.state, "stopped")
        XCTAssertTrue(stopped.supportsExternalExpansion)
    }

    private func makeService(
        adapter: BurnBarLinuxTextExpansionAdapter = BurnBarLinuxTextExpansionAdapter()
    ) -> BurnBarTextExpansionService {
        BurnBarTextExpansionService(
            fileURL: directory.appendingPathComponent("text-expansion.obbsealed"),
            secretStore: LinuxSecretCustodian(backends: [backend]),
            logger: BurnBarDaemonLogger(category: "text-expansion-test"),
            textExpansionAdapter: adapter
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
