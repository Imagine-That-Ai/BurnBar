import Foundation
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class UsageObservationSpoolTests: XCTestCase {
    func testDisabledSpoolDropsSilentlyWithCounter() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let spool = fixture.spool()

        let first = try await spool.append(fixture.observation(id: "obs-1"))
        XCTAssertFalse(first.stored)
        XCTAssertEqual(first.droppedCount, 1)

        let second = try await spool.append(fixture.observation(id: "obs-2"))
        XCTAssertFalse(second.stored)
        XCTAssertEqual(second.droppedCount, 2)

        let listed = try await spool.list(limit: 10)
        XCTAssertTrue(listed.observations.isEmpty)
        XCTAssertEqual(listed.droppedCount, 2)
    }

    func testEnabledSpoolStoresFIFOWithEntryCapAndDropCounter() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let spool = fixture.spool(
            configuration: UsageObservationSpool.Configuration(
                maximumEntryCount: 4
            )
        )
        let enabled = try await spool.setEnabled(true)
        XCTAssertTrue(enabled)

        for index in 1...6 {
            let result = try await spool.append(
                fixture.observation(id: "obs-\(index)")
            )
            XCTAssertTrue(result.stored)
        }

        let listed = try await spool.list(limit: 10)
        XCTAssertEqual(
            listed.observations.map(\.observationId),
            ["obs-3", "obs-4", "obs-5", "obs-6"]
        )
        XCTAssertEqual(listed.droppedCount, 2)

        // Re-appending an already-spooled identifier is idempotent.
        let duplicate = try await spool.append(fixture.observation(id: "obs-6"))
        XCTAssertTrue(duplicate.stored)
        let unchanged = try await spool.list(limit: 10)
        XCTAssertEqual(unchanged.observations.count, 4)
        XCTAssertEqual(unchanged.droppedCount, 2)
    }

    func testEnabledSpoolEvictsOldestWhenByteCapIsExceeded() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let spool = fixture.spool(
            configuration: UsageObservationSpool.Configuration(
                maximumStoreBytes: 64 * 1024
            )
        )
        let enabled = try await spool.setEnabled(true)
        XCTAssertTrue(enabled)

        let largePrompt = String(repeating: "p", count: 4_000)
        for index in 1...25 {
            _ = try await spool.append(
                fixture.observation(id: "obs-\(index)", prompt: largePrompt)
            )
        }

        let listed = try await spool.list(limit: 100)
        XCTAssertLessThan(listed.observations.count, 25)
        XCTAssertGreaterThan(listed.droppedCount, 0)
        XCTAssertEqual(
            listed.observations.last?.observationId,
            "obs-25",
            "Byte-cap eviction must drop the oldest entries first."
        )
        let size = try FileManager.default.attributesOfItem(
            atPath: fixture.spoolURL.path
        )[.size] as? Int
        XCTAssertLessThanOrEqual(try XCTUnwrap(size), 64 * 1024)
    }

    func testAckRemovesOnlyAckedEntries() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let spool = fixture.spool()
        _ = try await spool.setEnabled(true)
        for index in 1...4 {
            _ = try await spool.append(fixture.observation(id: "obs-\(index)"))
        }

        // Two-phase destructive read: listing removes nothing.
        let drained = try await spool.list(limit: 2)
        XCTAssertEqual(
            drained.observations.map(\.observationId),
            ["obs-1", "obs-2"]
        )
        let undisturbed = try await spool.list(limit: 10)
        XCTAssertEqual(undisturbed.observations.count, 4)

        let acked = try await spool.ack(
            ids: ["obs-1", "obs-2", "obs-unknown"]
        )
        XCTAssertEqual(acked.removedCount, 2)
        XCTAssertEqual(acked.remainingCount, 2)
        let remaining = try await spool.list(limit: 10)
        XCTAssertEqual(
            remaining.observations.map(\.observationId),
            ["obs-3", "obs-4"]
        )
    }

    func testDeleteAllClearsEntriesCounterAndGate() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let spool = fixture.spool()
        _ = try await spool.append(fixture.observation(id: "dropped"))
        _ = try await spool.setEnabled(true)
        _ = try await spool.append(fixture.observation(id: "stored"))

        try await spool.deleteAll()

        let stillEnabled = try await spool.isEnabled()
        XCTAssertFalse(stillEnabled)
        let listed = try await spool.list(limit: 10)
        XCTAssertTrue(listed.observations.isEmpty)
        XCTAssertEqual(listed.droppedCount, 0)

        let followUp = try await spool.append(fixture.observation(id: "after"))
        XCTAssertFalse(followUp.stored, "deleteAll must leave the spool disabled.")
    }

    func testStateSurvivesAcrossSpoolInstances() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let first = fixture.spool()
        _ = try await first.setEnabled(true)
        _ = try await first.append(fixture.observation(id: "obs-1"))

        let second = fixture.spool()
        let stillEnabled = try await second.isEnabled()
        XCTAssertTrue(stillEnabled)
        let listed = try await second.list(limit: 10)
        XCTAssertEqual(
            listed.observations.map(\.observationId),
            ["obs-1"]
        )
    }

    func testInvalidObservationsAreRejectedBeforeSpooling() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let spool = fixture.spool()
        _ = try await spool.setEnabled(true)

        let invalidObservations: [BurnBarSafariUsageObservation] = [
            fixture.observation(id: "bad-digest", answerSha256: "not-hex"),
            fixture.observation(
                id: "uppercase-digest",
                answerSha256: String(repeating: "AB", count: 32)
            ),
            fixture.observation(id: "tiny-prompt", prompt: "hey"),
            fixture.observation(
                id: "huge-prompt",
                prompt: String(repeating: "p", count: 4 * 1024 + 1)
            ),
            fixture.observation(
                id: "credential-url",
                sourceURL: "https://user:secret@example.com/products"
            ),
            fixture.observation(id: "non-web-url", sourceURL: "file:///etc/passwd"),
            fixture.observation(
                id: "future",
                observedAt: fixture.clockNow.addingTimeInterval(60 * 60)
            )
        ]
        for observation in invalidObservations {
            do {
                _ = try await spool.append(observation)
                XCTFail("Observation \(observation.observationId) must be rejected.")
            } catch UsageObservationSpoolError.invalidObservation {
                // Expected.
            }
        }
        let listed = try await spool.list(limit: 10)
        XCTAssertTrue(listed.observations.isEmpty)
    }

    func testCoordinatorSeamRoundTripAndProfileDeleteKillTheSpool() async throws {
        let fixture = try UsageSpoolFixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()

        let enabled = try await coordinator.usageMemorySetEnabled(
            BurnBarSafariUsageMemoryStateRequest(enabled: true)
        )
        XCTAssertTrue(enabled.enabled)

        let ingested = try await coordinator.usageObserve(
            BurnBarSafariUsageObservationIngestRequest(
                observation: fixture.observation(id: "safari-usage:obs-1")
            )
        )
        XCTAssertTrue(ingested.accepted)
        XCTAssertTrue(ingested.stored)

        let listed = try await coordinator.usageObservationsList(
            BurnBarSafariUsageObservationListRequest(limit: 10)
        )
        XCTAssertEqual(
            listed.observations.map(\.observationId),
            ["safari-usage:obs-1"]
        )

        let acked = try await coordinator.usageObservationsAck(
            BurnBarSafariUsageObservationAckRequest(
                observationIds: ["safari-usage:obs-1"]
            )
        )
        XCTAssertEqual(acked.removedCount, 1)
        XCTAssertEqual(acked.remainingCount, 0)

        // Refill, then delete the learned profile: the spool dies with it.
        _ = try await coordinator.usageObserve(
            BurnBarSafariUsageObservationIngestRequest(
                observation: fixture.observation(id: "safari-usage:obs-2")
            )
        )
        _ = try await coordinator.optOut(
            BurnBarSafariLearningOptOutRequest(deleteLearnedProfile: true)
        )

        let afterWipe = try await coordinator.usageObservationsList(
            BurnBarSafariUsageObservationListRequest(limit: 10)
        )
        XCTAssertTrue(afterWipe.observations.isEmpty)
        XCTAssertEqual(afterWipe.droppedCount, 0)
        let postWipe = try await coordinator.usageObserve(
            BurnBarSafariUsageObservationIngestRequest(
                observation: fixture.observation(id: "safari-usage:obs-3")
            )
        )
        XCTAssertFalse(
            postWipe.stored,
            "Deleting the learned profile must disable the usage spool."
        )
    }
}

private final class UsageSpoolFixture {
    let rootURL: URL
    let stateURL: URL
    let spoolURL: URL
    let skillsURL: URL
    let clockNow = Date(timeIntervalSince1970: 1_786_300_000)

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-usage-spool-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        stateURL = rootURL
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("learning.json", isDirectory: false)
        spoolURL = stateURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "usage-observations-v1.json",
                isDirectory: false
            )
        skillsURL = rootURL.appendingPathComponent(
            "safari-skills",
            isDirectory: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func spool(
        configuration: UsageObservationSpool.Configuration = .init()
    ) -> UsageObservationSpool {
        UsageObservationSpool(
            stateURL: spoolURL,
            configuration: configuration,
            now: { [clockNow] in clockNow }
        )
    }

    func coordinator(tier: String = "burnbar_pro") -> LearningCoordinator {
        LearningCoordinator(
            stateURL: stateURL,
            skillsRootURL: skillsURL,
            now: { [clockNow] in clockNow },
            eligibilityProvider: {
                SafariLearningEligibility.canonical(tier: tier)
            }
        )
    }

    func observation(
        id: String,
        prompt: String = "What color is the call to action?",
        sourceURL: String = "https://example.com/products",
        answerSha256: String = String(repeating: "ab", count: 32),
        observedAt: Date? = nil
    ) -> BurnBarSafariUsageObservation {
        BurnBarSafariUsageObservation(
            observationId: id,
            sourceURL: sourceURL,
            sourceTitle: "Example products",
            prompt: prompt,
            answerSha256: answerSha256,
            answerPreview: "The CTA is orange.",
            observedAt: observedAt ?? clockNow
        )
    }
}
