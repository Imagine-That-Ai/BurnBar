import OpenBurnBarEngine
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
}
