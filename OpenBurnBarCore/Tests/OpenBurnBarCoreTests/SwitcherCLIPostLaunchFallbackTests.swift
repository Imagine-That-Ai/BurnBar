import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarLaunchServices

private struct PackageTestCLIFallbackPlanner: CLIFallbackPlanning {
    func orderedCandidates(
        for requestedProfile: SwitcherProfileRecord,
        allProfiles: [SwitcherProfileRecord]
    ) async -> [SwitcherProfileRecord] {
        guard let cliType = requestedProfile.cliType else {
            return [requestedProfile]
        }

        let matchingProfiles = allProfiles.filter { profile in
            profile.targetKind == .cli && profile.cliType == cliType
        }

        guard let requestedIndex = matchingProfiles.firstIndex(where: { $0.id == requestedProfile.id }) else {
            return matchingProfiles
        }

        return [matchingProfiles[requestedIndex]]
            + matchingProfiles.enumerated()
                .filter { $0.offset != requestedIndex }
                .map(\.element)
    }

    func eligibility(for profile: SwitcherProfileRecord) async -> CLIFallbackEligibility {
        .eligible
    }
}

private actor PackageLaunchEventRecorder {
    private var events: [CLILaunchServiceEvent] = []

    func append(_ event: CLILaunchServiceEvent) {
        events.append(event)
    }

    func snapshot() -> [CLILaunchServiceEvent] {
        events
    }
}

final class SwitcherCLIPostLaunchFallbackTests: XCTestCase {
    override func tearDown() {
        CLILaunchAdapter.executableResolver = nil
        CLILaunchInvoker.launchHandler = nil
        CLILaunchInvoker.startupObservationTimeout = CLILaunchInvoker.defaultStartupObservationTimeout
        super.tearDown()
    }

    func test_launchCLI_recoversAfterPostLaunchQuotaSignal() async throws {
        let store = InMemorySwitcherProfileStoreAdapter()
        let recorder = PackageLaunchEventRecorder()
        let fallbackEventRecorded = expectation(description: "post-launch fallback event recorded")
        let service = SwitcherCLILAunchService(
            profileStore: store,
            fallbackPlanner: PackageTestCLIFallbackPlanner(),
            eventHandler: { event in
                Task {
                    await recorder.append(event)
                    fallbackEventRecorded.fulfill()
                }
            }
        )

        let executableURL = URL(fileURLWithPath: "/tmp/package-post-launch-codex")
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primaryWorkingDirectory = tempRoot.appendingPathComponent("package-primary", isDirectory: true)
        let fallbackWorkingDirectory = tempRoot.appendingPathComponent("package-fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryWorkingDirectory, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: fallbackWorkingDirectory, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .codex ? executableURL : nil
        }
        CLILaunchInvoker.launchHandler = { _, _, _, _, workingDirectory, observer in
            if workingDirectory == primaryWorkingDirectory.path {
                Task.detached {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    observer?("quota exhausted after launch")
                }
            }
            return .success(())
        }

        let primary = SwitcherProfileRecord(
            id: "package-primary",
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: primaryWorkingDirectory.path,
                displayLabel: "Primary"
            ),
            sortKey: 1
        )
        let fallback = SwitcherProfileRecord(
            id: "package-fallback",
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: fallbackWorkingDirectory.path,
                displayLabel: "Fallback"
            ),
            sortKey: 2
        )
        store.addProfile(primary)
        store.addProfile(fallback)
        store.setActiveProfileID(primary.id)

        let initialOutcome = await service.launchCLI(for: primary.id)
        XCTAssertTrue(initialOutcome.success)
        XCTAssertEqual(initialOutcome.launchedProfileID, primary.id)

        await fulfillment(of: [fallbackEventRecorded], timeout: 5.0)

        XCTAssertEqual(store.fetchActiveProfileID(), fallback.id)
        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            [
                .postLaunchFallbackSucceeded(
                    exhaustedProfileID: primary.id,
                    recoveredProfileID: fallback.id,
                    detail: "quota exhausted after launch",
                    attemptedProfileIDs: [primary.id, fallback.id]
                )
            ]
        )
    }

    func test_launchCLI_persistsPostLaunchOutOfLimitQuotaHold() async throws {
        let store = InMemorySwitcherProfileStoreAdapter()
        let fallbackEventRecorded = expectation(description: "post-launch fallback event recorded")
        let service = SwitcherCLILAunchService(
            profileStore: store,
            fallbackPlanner: PackageTestCLIFallbackPlanner(),
            eventHandler: { _ in
                fallbackEventRecorded.fulfill()
            }
        )

        let executableURL = URL(fileURLWithPath: "/tmp/package-post-launch-codex")
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primaryWorkingDirectory = tempRoot.appendingPathComponent("package-primary", isDirectory: true)
        let fallbackWorkingDirectory = tempRoot.appendingPathComponent("package-fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryWorkingDirectory, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: fallbackWorkingDirectory, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let outOfLimitDetail = "Codex quota is out of limit for this account."
        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .codex ? executableURL : nil
        }
        CLILaunchInvoker.launchHandler = { _, _, _, _, workingDirectory, observer in
            if workingDirectory == primaryWorkingDirectory.path {
                Task.detached {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    observer?(outOfLimitDetail)
                }
            }
            return .success(())
        }

        let primary = SwitcherProfileRecord(
            id: "package-primary",
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: primaryWorkingDirectory.path,
                displayLabel: "Primary"
            ),
            sortKey: 1
        )
        let fallback = SwitcherProfileRecord(
            id: "package-fallback",
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: fallbackWorkingDirectory.path,
                displayLabel: "Fallback"
            ),
            sortKey: 2
        )
        store.addProfile(primary)
        store.addProfile(fallback)
        store.setActiveProfileID(primary.id)

        let beforeLaunch = Date()
        let initialOutcome = await service.launchCLI(for: primary.id)
        XCTAssertTrue(initialOutcome.success)

        await fulfillment(of: [fallbackEventRecorded], timeout: 5.0)
        let afterFallback = Date()

        let persistedPrimary = try XCTUnwrap(store.fetchProfile(id: primary.id))
        let metadata = try XCTUnwrap(persistedPrimary.cliMetadata)
        let exhaustedAt = try XCTUnwrap(metadata.lastQuotaExhaustedAt)
        let exhaustedUntil = try XCTUnwrap(metadata.exhaustedUntil)

        XCTAssertGreaterThanOrEqual(exhaustedAt, beforeLaunch)
        XCTAssertLessThanOrEqual(exhaustedAt, afterFallback)
        XCTAssertGreaterThanOrEqual(exhaustedUntil, beforeLaunch.addingTimeInterval(5 * 60 * 60))
        XCTAssertLessThanOrEqual(exhaustedUntil, afterFallback.addingTimeInterval(5 * 60 * 60))
        XCTAssertEqual(metadata.lastQuotaExhaustionDetail, outOfLimitDetail)
        XCTAssertEqual(store.fetchActiveProfileID(), fallback.id)
    }
}
