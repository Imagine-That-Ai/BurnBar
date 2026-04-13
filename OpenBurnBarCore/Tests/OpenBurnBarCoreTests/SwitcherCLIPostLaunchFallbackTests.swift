import XCTest
@testable import OpenBurnBarCore

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
        CLILaunchInvoker.startupObservationTimeout = 1.5
        super.tearDown()
    }

    func test_launchCLI_recoversAfterPostLaunchQuotaSignal() async throws {
        let store = InMemorySwitcherProfileStoreAdapter()
        let recorder = PackageLaunchEventRecorder()
        let service = SwitcherCLILAunchService(
            profileStore: store,
            fallbackPlanner: PackageTestCLIFallbackPlanner(),
            eventHandler: { event in
                Task { await recorder.append(event) }
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

        try? await Task.sleep(nanoseconds: 400_000_000)

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
}
