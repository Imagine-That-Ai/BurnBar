import OpenBurnBarEngine
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarLinuxOnboardingServiceLinuxTests: XCTestCase {
    func testLinuxRequiredVerificationFailureBlocksWithoutAdvancing() async throws {
        let service = BurnBarLinuxOnboardingService(
            stateURL: makeStateURL(),
            daemonProbe: { "daemon verified" },
            secretStoreProbe: {
                throw BurnBarLinuxOnboardingError.secretStoreUnavailable("session wallet unavailable")
            },
            providerPathsProbe: { "paths verified" }
        )

        _ = try await service.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: .daemon, action: .verify)
        )
        let blocked = try await service.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: .secretStore, action: .verify)
        )

        XCTAssertFalse(blocked.completed)
        XCTAssertEqual(blocked.currentStepID, .secretStore)
        XCTAssertEqual(blocked.steps.first(where: { $0.id == .secretStore })?.state, .blocked)
        XCTAssertEqual(
            blocked.steps.first(where: { $0.id == .secretStore })?.detail?
                .contains("session wallet unavailable"),
            true
        )
        XCTAssertEqual(
            blocked.steps.first(where: { $0.id == .secretStore })?.repairAction,
            .unlockSecretStore
        )
    }

    func testLinuxOptionalProbePersistsRepairAndRecoversAfterRestart() async throws {
        let stateURL = makeStateURL()
        let failing = BurnBarLinuxOnboardingService(
            stateURL: stateURL,
            daemonProbe: { "daemon verified" },
            secretStoreProbe: { "secret store verified" },
            providerPathsProbe: { "paths and first data verified" },
            portalInputProbe: {
                throw BurnBarLinuxOnboardingError.probeUnavailable(
                    step: .portalInput,
                    detail: "user denied portal consent"
                )
            }
        )

        _ = try await verify(.daemon, using: failing)
        _ = try await verify(.secretStore, using: failing)
        _ = try await verify(.providerPaths, using: failing)
        _ = try await acknowledge(.cloudIdentity, using: failing)
        let blocked = try await verify(.portalInput, using: failing)
        XCTAssertEqual(blocked.currentStepID, .portalInput)
        XCTAssertEqual(blocked.steps.first(where: { $0.id == .portalInput })?.state, .blocked)
        XCTAssertEqual(blocked.steps.first(where: { $0.id == .portalInput })?.repairAction, .grantPortal)

        let recovered = BurnBarLinuxOnboardingService(
            stateURL: stateURL,
            daemonProbe: { "daemon verified" },
            secretStoreProbe: { "secret store verified" },
            providerPathsProbe: { "paths and first data verified" },
            portalInputProbe: { "portal consent read back" }
        )
        let resumed = try await recovered.snapshot()
        XCTAssertEqual(resumed.steps.first(where: { $0.id == .portalInput })?.state, .blocked)
        let verified = try await verify(.portalInput, using: recovered)
        XCTAssertEqual(verified.steps.first(where: { $0.id == .portalInput })?.state, .verified)
        XCTAssertEqual(verified.steps.first(where: { $0.id == .portalInput })?.attemptCount, 2)
        XCTAssertNil(verified.steps.first(where: { $0.id == .portalInput })?.repairAction)
    }

    func testLinuxUnavailableOptionalProbeCanOnlyCompleteByExplicitSkip() async throws {
        let service = makeService(stateURL: makeStateURL())
        _ = try await verify(.daemon, using: service)
        _ = try await verify(.secretStore, using: service)
        _ = try await verify(.providerPaths, using: service)
        _ = try await acknowledge(.cloudIdentity, using: service)
        _ = try await acknowledge(.portalInput, using: service)
        let blocked = try await verify(.tray, using: service)

        XCTAssertEqual(blocked.steps.first(where: { $0.id == .tray })?.state, .blocked)
        XCTAssertEqual(blocked.steps.first(where: { $0.id == .tray })?.repairAction, .enableTray)
        let skipped = try await skip(.tray, using: service)
        XCTAssertEqual(skipped.steps.first(where: { $0.id == .tray })?.state, .skipped)
        XCTAssertNil(skipped.steps.first(where: { $0.id == .tray })?.repairAction)
    }

    func testLinuxServicePersistsPrivateStateAndResumes() async throws {
        let stateURL = makeStateURL()
        let stateDirectoryURL = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: stateDirectoryURL.path
        )
        let service = makeService(stateURL: stateURL)
        let advanced = try await service.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: .daemon, action: .verify)
        )

        XCTAssertEqual(advanced.currentStepID, .secretStore)
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: stateDirectoryURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let resumed = try await makeService(stateURL: stateURL).snapshot()
        XCTAssertEqual(resumed, advanced)
    }

    func testLinuxWritableDirectoryProbeRoundTripsAndCleansUp() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-onboarding-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let detail = try BurnBarLinuxOnboardingService.verifyWritableDirectory(directoryURL)

        XCTAssertTrue(detail.contains(directoryURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directoryURL.path), [])
    }

    func testLinuxSecretStoreProbeChecksHealthBeforeMutatingLockedBackend() throws {
        let backend = HealthGatedSecretBackend()
        let custodian = LinuxSecretCustodian(backends: [backend])

        XCTAssertThrowsError(
            try BurnBarLinuxOnboardingService.verifyProductionSecretStore(using: custodian)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Secret Service is locked"))
        }
        XCTAssertEqual(backend.healthCheckCount, 1)
        XCTAssertEqual(backend.storeCount, 0)
    }

    func testLinuxSecretStoreProbeRequiresReadbackAndCleansProbeOnMismatch() throws {
        let backend = ProbeRecordingSecretBackend(readbackMatches: false)
        let custodian = LinuxSecretCustodian(backends: [backend])

        XCTAssertThrowsError(
            try BurnBarLinuxOnboardingService.verifyProductionSecretStore(using: custodian)
        ) { error in
            guard case let BurnBarLinuxOnboardingError.secretStoreUnavailable(detail) = error else {
                return XCTFail("Expected onboarding to remain blocked, got \(error)")
            }
            XCTAssertTrue(detail.contains("round-trip"))
        }
        XCTAssertEqual(backend.events, ["health", "store", "read", "delete"])
        XCTAssertFalse(backend.hasStoredSecret)
    }

    func testLinuxSecretStoreProbeFailsClosedWhenCleanupCannotBeConfirmed() throws {
        let backend = ProbeRecordingSecretBackend(readbackMatches: true, failDelete: true)
        let custodian = LinuxSecretCustodian(backends: [backend])

        XCTAssertThrowsError(
            try BurnBarLinuxOnboardingService.verifyProductionSecretStore(using: custodian)
        ) { error in
            guard case let BurnBarLinuxOnboardingError.secretStoreUnavailable(detail) = error else {
                return XCTFail("Expected onboarding to remain blocked, got \(error)")
            }
            XCTAssertTrue(detail.contains("could not delete"))
        }
        XCTAssertEqual(backend.events, ["health", "store", "read", "delete", "delete"])
        XCTAssertTrue(backend.hasStoredSecret)
    }

    private func makeService(stateURL: URL) -> BurnBarLinuxOnboardingService {
        BurnBarLinuxOnboardingService(
            stateURL: stateURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            daemonProbe: { "daemon verified" },
            secretStoreProbe: { "secret store verified" },
            providerPathsProbe: { "paths verified" }
        )
    }

    private func makeStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-onboarding-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    private func verify(
        _ stepID: BurnBarLinuxOnboardingStepID,
        using service: BurnBarLinuxOnboardingService
    ) async throws -> BurnBarLinuxOnboardingSnapshot {
        try await service.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: stepID, action: .verify)
        )
    }

    private func acknowledge(
        _ stepID: BurnBarLinuxOnboardingStepID,
        using service: BurnBarLinuxOnboardingService
    ) async throws -> BurnBarLinuxOnboardingSnapshot {
        try await service.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: stepID, action: .acknowledge)
        )
    }

    private func skip(
        _ stepID: BurnBarLinuxOnboardingStepID,
        using service: BurnBarLinuxOnboardingService
    ) async throws -> BurnBarLinuxOnboardingSnapshot {
        try await service.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: stepID, action: .skip)
        )
    }
}

private final class HealthGatedSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "test-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true
    private let lock = NSLock()
    private(set) var healthCheckCount = 0
    private(set) var storeCount = 0

    func readSecret(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretRecord? {
        nil
    }

    func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        lock.lock()
        storeCount += 1
        lock.unlock()
        return LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: 0,
            note: "test"
        )
    }

    func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {}

    func healthCheck() throws {
        lock.lock()
        healthCheckCount += 1
        lock.unlock()
        throw LinuxSecretStoreError.backendUnavailable("Secret Service is locked")
    }
}

private final class ProbeRecordingSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "test-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true

    private let readbackMatches: Bool
    private let failDelete: Bool
    private let lock = NSLock()
    private(set) var events: [String] = []
    private(set) var storedSecret: String?
    private(set) var hasStoredSecret = false

    init(readbackMatches: Bool, failDelete: Bool = false) {
        self.readbackMatches = readbackMatches
        self.failDelete = failDelete
        self.storedSecret = nil
    }

    func readSecret(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretRecord? {
        lock.lock()
        events.append("read")
        let storedSecret = self.storedSecret
        lock.unlock()
        guard let storedSecret else { return nil }
        let secret = readbackMatches ? storedSecret : "wrong-value"
        return LinuxSecretRecord(
            secret: secret,
            metadata: LinuxSecretMetadata(
                id: id,
                secretClass: secretClass,
                trustLevel: trustLevel,
                backend: backendName,
                createdAtMillis: 0,
                note: "test"
            )
        )
    }

    func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        lock.lock()
        events.append("store")
        storedSecret = secret
        hasStoredSecret = true
        lock.unlock()
        return LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: 0,
            note: "test"
        )
    }

    func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {
        lock.lock()
        events.append("delete")
        if failDelete == false {
            storedSecret = nil
            hasStoredSecret = false
        }
        lock.unlock()
        if failDelete {
            throw LinuxSecretStoreError.backendUnavailable("native delete failed")
        }
    }

    func healthCheck() throws {
        lock.lock()
        events.append("health")
        lock.unlock()
    }
}
