import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarLinuxOnboardingServiceTests: XCTestCase {
    func testRequiredStepsCannotBeSkippedAndCompletionIsDerivedByDaemon() async throws {
        let stateURL = makeStateURL()
        let service = makeService(stateURL: stateURL)

        let initial = try await service.snapshot()
        XCTAssertFalse(initial.completed)
        XCTAssertEqual(initial.currentStepID, .daemon)
        XCTAssertEqual(initial.steps.map(\.id), BurnBarLinuxOnboardingStepID.allCases)

        do {
            _ = try await service.perform(
                BurnBarLinuxOnboardingActionRequest(stepID: .daemon, action: .skip)
            )
            XCTFail("Required daemon verification must not be skippable.")
        } catch let error as BurnBarLinuxOnboardingError {
            XCTAssertEqual(error, .invalidAction(step: .daemon, action: .skip))
        }

        var snapshot = try await verify(.daemon, using: service)
        XCTAssertEqual(snapshot.currentStepID, .secretStore)
        snapshot = try await verify(.secretStore, using: service)
        snapshot = try await verify(.providerPaths, using: service)
        snapshot = try await acknowledge(.cloudIdentity, using: service)
        snapshot = try await skip(.portalInput, using: service)
        snapshot = try await acknowledge(.tray, using: service)
        snapshot = try await skip(.updates, using: service)
        XCTAssertFalse(snapshot.completed)

        snapshot = try await service.perform(
            BurnBarLinuxOnboardingActionRequest(
                stepID: .privacy,
                action: .savePrivacyChoices,
                telemetryEnabled: false,
                cloudSyncEnabled: true
            )
        )

        XCTAssertTrue(snapshot.completed)
        XCTAssertEqual(
            snapshot.privacyChoices,
            BurnBarLinuxOnboardingPrivacyChoices(
                telemetryEnabled: false,
                cloudSyncEnabled: true
            )
        )
        XCTAssertTrue(BurnBarLinuxOnboardingService.isComplete(snapshot.steps))
    }

    func testBlockedProbePersistsAndRetryCanRecoverInFreshService() async throws {
        let stateURL = makeStateURL()
        let failing = BurnBarLinuxOnboardingService(
            stateURL: stateURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            daemonProbe: { "daemon verified" },
            secretStoreProbe: {
                throw BurnBarLinuxOnboardingError.secretStoreUnavailable("wallet locked")
            },
            providerPathsProbe: { "paths verified" }
        )

        _ = try await verify(.daemon, using: failing)
        let blocked = try await failing.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: .secretStore, action: .verify)
        )
        let blockedStep = try XCTUnwrap(blocked.steps.first(where: { $0.id == .secretStore }))
        XCTAssertEqual(blockedStep.state, .blocked)
        XCTAssertEqual(blockedStep.attemptCount, 1)
        XCTAssertEqual(blockedStep.detail?.contains("wallet locked"), true)
        XCTAssertEqual(blockedStep.repairAction, .unlockSecretStore)
        XCTAssertEqual(blocked.currentStepID, .secretStore)

        let recovered = makeService(stateURL: stateURL)
        let resumed = try await recovered.snapshot()
        XCTAssertEqual(resumed.steps.first(where: { $0.id == .secretStore })?.state, .blocked)
        let verified = try await verify(.secretStore, using: recovered)
        XCTAssertEqual(verified.steps.first(where: { $0.id == .secretStore })?.state, .verified)
        XCTAssertEqual(verified.steps.first(where: { $0.id == .secretStore })?.attemptCount, 2)
        XCTAssertEqual(verified.currentStepID, .providerPaths)
    }

    func testOptionalProbeFailurePersistsRepairAndFreshServiceCanRecover() async throws {
        let stateURL = makeStateURL()
        let failing = BurnBarLinuxOnboardingService(
            stateURL: stateURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
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
            now: { Date(timeIntervalSince1970: 1_700_000_001) },
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

    func testUnavailableOptionalProbeIsBlockedUntilExplicitlySkipped() async throws {
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

    func testFutureStepsCannotBeMutatedOrNavigatedBeforePrerequisites() async throws {
        let service = makeService(stateURL: makeStateURL())

        do {
            _ = try await service.perform(
                BurnBarLinuxOnboardingActionRequest(stepID: .cloudIdentity, action: .skip)
            )
            XCTFail("A future optional step must not bypass required prerequisites.")
        } catch let error as BurnBarLinuxOnboardingError {
            XCTAssertEqual(error, .stepOutOfOrder(expected: .daemon, requested: .cloudIdentity))
        }

        do {
            _ = try await service.perform(
                BurnBarLinuxOnboardingActionRequest(stepID: .secretStore, action: .navigate)
            )
            XCTFail("Navigation must not move beyond the first unresolved prerequisite.")
        } catch let error as BurnBarLinuxOnboardingError {
            XCTAssertEqual(error, .stepOutOfOrder(expected: .daemon, requested: .secretStore))
        }

        _ = try await verify(.daemon, using: service)
        let navigated = try await service.perform(
            BurnBarLinuxOnboardingActionRequest(stepID: .daemon, action: .navigate)
        )
        XCTAssertEqual(navigated.currentStepID, .daemon)
    }

    func testResetReplacesPersistedStateAndRestrictsFilePermissions() async throws {
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
        _ = try await verify(.daemon, using: service)
        let reset = try await service.reset()

        XCTAssertEqual(reset.currentStepID, .daemon)
        XCTAssertFalse(reset.completed)
        XCTAssertTrue(reset.steps.allSatisfy { $0.state == .pending })
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: stateDirectoryURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTamperedCompletionFlagFailsClosed() async throws {
        let stateURL = makeStateURL()
        let service = makeService(stateURL: stateURL)
        _ = try await verify(.daemon, using: service)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        object["completed"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL, options: [.atomic])

        do {
            _ = try await service.snapshot()
            XCTFail("A forged completion flag must fail closed.")
        } catch let error as BurnBarLinuxOnboardingError {
            XCTAssertEqual(error, .invalidPersistedState("completion invariant mismatch"))
        }
    }

    func testStateSymlinkAndSupportDirectorySymlinkFailClosed() async throws {
        let fileManager = FileManager.default

        let realDirectory = makeStateURL().deletingLastPathComponent()
        let directoryLink = realDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("openburnbar-onboarding-directory-link-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directoryLink)
            try? fileManager.removeItem(at: realDirectory)
        }
        try fileManager.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: directoryLink, withDestinationURL: realDirectory)

        let directoryLinkedService = makeService(
            stateURL: directoryLink.appendingPathComponent("linux-onboarding-state.json")
        )
        do {
            _ = try await directoryLinkedService.snapshot()
            XCTFail("A support-directory symlink must fail closed.")
        } catch let error as BurnBarLinuxOnboardingError {
            XCTAssertEqual(
                error,
                .invalidPersistedState("onboarding state directory must not be a symbolic link")
            )
        }

        let stateURL = makeStateURL()
        let stateDirectory = stateURL.deletingLastPathComponent()
        let targetURL = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-onboarding-state-target-\(UUID().uuidString).json")
        defer {
            try? fileManager.removeItem(at: stateDirectory)
            try? fileManager.removeItem(at: targetURL)
        }
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try Data("not-authoritative-state".utf8).write(to: targetURL, options: [.atomic])
        try fileManager.createSymbolicLink(at: stateURL, withDestinationURL: targetURL)

        let stateLinkedService = makeService(stateURL: stateURL)
        do {
            _ = try await stateLinkedService.snapshot()
            XCTFail("A state-file symlink must fail closed.")
        } catch let error as BurnBarLinuxOnboardingError {
            XCTAssertEqual(
                error,
                .invalidPersistedState("onboarding state file must not be a symbolic link")
            )
        }
    }

    func testProviderDataProbeRequiresCatalogAndReportsFirstDataReadback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-provider-data-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let detail = try BurnBarLinuxOnboardingService.verifyProviderData(
            at: directory,
            providerCount: 12
        )
        XCTAssertTrue(detail.contains("provider catalog loaded with 12 provider definitions"))

        XCTAssertThrowsError(
            try BurnBarLinuxOnboardingService.verifyProviderData(
                at: directory,
                providerCount: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? BurnBarLinuxOnboardingError,
                .providerPathsUnavailable("The bundled provider catalog is empty; first-run data cannot be loaded.")
            )
        }
    }

    func testDefaultProviderProbeBlocksEmptyCatalogAndAcceptsFirstData() async throws {
        let emptyStateURL = makeStateURL()
        let emptyCatalogService = BurnBarLinuxOnboardingService(
            stateURL: emptyStateURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            daemonProbe: { "daemon verified" },
            secretStoreProbe: { "secret store verified" },
            providerCatalogCount: 0
        )

        _ = try await verify(.daemon, using: emptyCatalogService)
        _ = try await verify(.secretStore, using: emptyCatalogService)
        let blocked = try await verify(.providerPaths, using: emptyCatalogService)
        XCTAssertEqual(
            blocked.steps.first(where: { $0.id == .providerPaths })?.state,
            .blocked
        )
        XCTAssertEqual(
            blocked.steps.first(where: { $0.id == .providerPaths })?.detail?.contains(
                "bundled provider catalog is empty"
            ),
            true
        )
        XCTAssertFalse(blocked.completed)

        let populatedStateURL = makeStateURL()
        let populatedCatalogService = BurnBarLinuxOnboardingService(
            stateURL: populatedStateURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            daemonProbe: { "daemon verified" },
            secretStoreProbe: { "secret store verified" },
            providerCatalogCount: 1
        )

        _ = try await verify(.daemon, using: populatedCatalogService)
        _ = try await verify(.secretStore, using: populatedCatalogService)
        let verified = try await verify(.providerPaths, using: populatedCatalogService)
        let providerStep = try XCTUnwrap(
            verified.steps.first(where: { $0.id == .providerPaths })
        )
        XCTAssertEqual(providerStep.state, .verified)
        XCTAssertEqual(providerStep.detail?.contains("provider definitions"), true)
        XCTAssertEqual(verified.currentStepID, .cloudIdentity)
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
            .appendingPathComponent("openburnbar-onboarding-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("linux-onboarding-state.json", isDirectory: false)
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
