import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

// Journal replay / projection-migration coverage extracted from
// OpenBurnBarMissionControlServiceTests.swift to keep that god-file under the
// SwiftLint file_length ratchet (it may only shrink).
extension BurnBarMissionControlServiceTests {
    func testLargeOrderedJournalReplayStreamsToLatestProjection() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-large-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }

        let eventsFileURL = rootURL.appendingPathComponent("controller-events.jsonl")
        let projectionFileURL = rootURL.appendingPathComponent("controller-projection.json")
        let baseline = Date(timeIntervalSince1970: 1_710_621_000)
        let eventCount = 2_000
        var events: [BurnBarControllerEvent] = []
        events.reserveCapacity(eventCount)
        for index in 0..<eventCount {
            let snapshot = project(slug: "large-replay", revision: index)
            events.append(
                try projectUpsertEvent(
                    id: "large-replay-event-\(index)",
                    sequence: index + 1,
                    recordedAt: baseline.addingTimeInterval(Double(index)),
                    project: snapshot
                )
            )
        }
        try writeControllerEvents(events, to: eventsFileURL)

        let store = BurnBarMissionControlStore(
            eventsFileURL: eventsFileURL,
            projectionFileURL: projectionFileURL,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: BurnBarInMemoryNotificationSecretStore()
        )

        let latestProject = try await store.project(slug: "large-replay")
        XCTAssertEqual(latestProject?.displayName, "Large-Replay revision \(eventCount - 1)")
        XCTAssertEqual(
            latestProject?.summary,
            "Native OpenBurnBar mission-control test project revision \(eventCount - 1)."
        )

        let persistedProjection = try JSONDecoder().decode(
            BurnBarMissionControlProjectionFile.self,
            from: Data(contentsOf: projectionFileURL)
        )
        XCTAssertEqual(persistedProjection.lastSequence, eventCount)
        XCTAssertEqual(persistedProjection.projects.count, 1)
        XCTAssertEqual(
            persistedProjection.projects["large-replay"]?.displayName,
            latestProject?.displayName
        )
    }

    func testJournalReplaySkipsMalformedLinesWithoutDroppingValidEvents() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-malformed-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }

        let eventsFileURL = rootURL.appendingPathComponent("controller-events.jsonl")
        let projectionFileURL = rootURL.appendingPathComponent("controller-projection.json")
        let baseline = Date(timeIntervalSince1970: 1_710_623_500)
        let before = try projectUpsertEvent(
            id: "malformed-replay-before",
            sequence: 1,
            recordedAt: baseline,
            project: project(slug: "malformed-replay", revision: 1)
        )
        let after = try projectUpsertEvent(
            id: "malformed-replay-after",
            sequence: 2,
            recordedAt: baseline.addingTimeInterval(1),
            project: project(slug: "malformed-replay", revision: 2)
        )
        let encoder = JSONEncoder()
        var journalData = try encoder.encode(before) + Data([0x0A])
        journalData.append(Data(#"{"sequence": "definitely-not-an-event"}"#.utf8))
        journalData.append(0x0A)
        journalData.append(try encoder.encode(after))
        journalData.append(0x0A)
        try journalData.write(to: eventsFileURL, options: .atomic)

        let store = BurnBarMissionControlStore(
            eventsFileURL: eventsFileURL,
            projectionFileURL: projectionFileURL,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: BurnBarInMemoryNotificationSecretStore()
        )

        let projectAfterReplay = try await store.project(slug: "malformed-replay")
        XCTAssertEqual(projectAfterReplay?.displayName, "Malformed-Replay revision 2")

        let persistedProjection = try JSONDecoder().decode(
            BurnBarMissionControlProjectionFile.self,
            from: Data(contentsOf: projectionFileURL)
        )
        XCTAssertEqual(persistedProjection.lastSequence, 2)
        XCTAssertEqual(persistedProjection.projects.count, 1)
    }

    func testLegacyProjectionWithoutDeletionTombstonesRebuildsAndPersistsThem() async throws {
        let harness = try makeHarnessWithStore(name: "legacy-deletion-tombstone-migration")
        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )
        _ = try await harness.service.controllerProjectDelete(
            BurnBarControllerProjectDeleteRequest(projectSlug: "apollo")
        )

        let eventsFileURL = harness.rootURL.appendingPathComponent("controller-events.jsonl")
        let projectionFileURL = harness.rootURL.appendingPathComponent("controller-projection.json")
        var legacyProjection = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: projectionFileURL)
            ) as? [String: Any]
        )
        XCTAssertNotNil(legacyProjection.removeValue(forKey: "projectDeletionTombstones"))
        try JSONSerialization.data(withJSONObject: legacyProjection, options: [.sortedKeys])
            .write(to: projectionFileURL, options: .atomic)

        let restartedStore = BurnBarMissionControlStore(
            eventsFileURL: eventsFileURL,
            projectionFileURL: projectionFileURL,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: BurnBarInMemoryNotificationSecretStore()
        )
        let deletedProject = try await restartedStore.project(slug: "apollo")
        XCTAssertNil(deletedProject)

        let migratedProjection = try JSONDecoder().decode(
            BurnBarMissionControlProjectionFile.self,
            from: Data(contentsOf: projectionFileURL)
        )
        XCTAssertEqual(migratedProjection.projectDeletionTombstones?["apollo"], "apollo")
        XCTAssertEqual(migratedProjection.projectDeletionTombstones?["project-apollo"], "apollo")
    }

    func testRecentEventCacheRetainsAtMostOneHundredEvents() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-recent-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }

        let eventsFileURL = rootURL.appendingPathComponent("controller-events.jsonl")
        let projectionFileURL = rootURL.appendingPathComponent("controller-projection.json")
        let baseline = Date(timeIntervalSince1970: 1_710_625_000)
        var events: [BurnBarControllerEvent] = []
        events.reserveCapacity(150)
        for index in 0..<150 {
            events.append(
                try projectUpsertEvent(
                    id: "recent-cache-event-\(index)",
                    sequence: index + 1,
                    recordedAt: baseline.addingTimeInterval(Double(index)),
                    project: project(slug: "recent-cache", revision: index)
                )
            )
        }
        try writeControllerEvents(events, to: eventsFileURL)

        let store = BurnBarMissionControlStore(
            eventsFileURL: eventsFileURL,
            projectionFileURL: projectionFileURL,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            notificationSecretStore: BurnBarInMemoryNotificationSecretStore()
        )
        _ = try await store.controllerSummary(
            BurnBarControllerSummaryRequest(
                projectSlug: "recent-cache",
                includeRecentEvents: true,
                includeProjectionStatus: false
            )
        )
        let loadedRetainedCount = await store.retainedRecentEventCount
        XCTAssertEqual(loadedRetainedCount, 100)

        for revision in 150..<175 {
            _ = try await store.upsertProject(project(slug: "recent-cache", revision: revision))
        }
        let appendedRetainedCount = await store.retainedRecentEventCount
        XCTAssertEqual(appendedRetainedCount, 100)
    }

    func testControllerActivityIngestionSkipsInvalidDerivedProjectIdentifiers() async throws {
        let now = Date(timeIntervalSince1970: 1_710_002_100)
        let harness = try makeHarness(
            name: "activity-ingestion-invalid-project",
            activitySnapshot: BurnBarControllerActivitySnapshot(
                generatedAt: now,
                activeProjectSlug: "apollo",
                projects: [
                    BurnBarControllerActivityProject(
                        projectSlug: "~",
                        displayName: "~",
                        summary: "Legacy punctuation-only activity row.",
                        latestActivityAt: now,
                        sessionCountLast7Days: 0,
                        totalCostLast7Days: 0,
                        totalTokensLast7Days: 0
                    ),
                    BurnBarControllerActivityProject(
                        projectSlug: "apollo",
                        displayName: "Apollo",
                        summary: "Valid activity remains available.",
                        latestActivityAt: now,
                        sessionCountLast7Days: 1,
                        totalCostLast7Days: 0,
                        totalTokensLast7Days: 0
                    )
                ]
            )
        )

        let projects = try await harness.service.controllerProjects(
            BurnBarControllerProjectsListRequest(includePaused: true, limit: 20)
        )

        XCTAssertEqual(projects.projects.map(\.projectSlug), ["apollo"])
    }

    func testControllerActivityIngestionIgnoresTimestampOnlySnapshotRefreshes() async throws {
        let now = Date(timeIntervalSince1970: 1_710_002_200)
        let activityProject = BurnBarControllerActivityProject(
            projectSlug: "apollo",
            displayName: "Apollo",
            summary: "Semantically unchanged activity.",
            latestActivityAt: now,
            sessionCountLast7Days: 3,
            totalCostLast7Days: 1.25,
            totalTokensLast7Days: 8_000
        )
        let harness = try makeHarness(
            name: "activity-ingestion-timestamp-only-refresh",
            activitySnapshot: BurnBarControllerActivitySnapshot(
                generatedAt: now,
                activeProjectSlug: "apollo",
                projects: [activityProject]
            )
        )

        _ = try await harness.service.controllerProjects(
            BurnBarControllerProjectsListRequest(includePaused: true, limit: 20)
        )
        let eventsFileURL = harness.rootURL.appendingPathComponent("controller-events.jsonl")
        let firstEventCount = try Data(contentsOf: eventsFileURL).split(separator: 0x0A).count

        let timestampOnlyRefresh = BurnBarControllerActivitySnapshot(
            generatedAt: now.addingTimeInterval(60),
            activeProjectSlug: "apollo",
            projects: [activityProject]
        )
        let activitySnapshotURL = harness.rootURL.appendingPathComponent("controller-activity-snapshot.json")
        try JSONEncoder().encode(timestampOnlyRefresh).write(to: activitySnapshotURL, options: .atomic)

        _ = try await harness.service.controllerProjects(
            BurnBarControllerProjectsListRequest(includePaused: true, limit: 20)
        )
        let secondEventCount = try Data(contentsOf: eventsFileURL).split(separator: 0x0A).count

        XCTAssertEqual(
            secondEventCount,
            firstEventCount,
            "generatedAt-only refreshes must not re-ingest an otherwise identical activity payload"
        )
    }

    func testRegistryProjectLookupBypassesDerivedEnrichment() async throws {
        let harness = try makeHarnessWithStore(name: "registry-project-lookup")
        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )
        _ = try await harness.service.questionCreate(
            BurnBarQuestionCreateRequest(
                question: BurnBarPendingQuestionSnapshot(
                    id: BurnBarQuestionID(rawValue: "question-apollo"),
                    projectSlug: "apollo",
                    title: "Apollo decision",
                    prompt: "Choose the release window.",
                    status: .pending,
                    priority: .medium,
                    askedAt: Date()
                )
            )
        )

        let registryProject = try await harness.store.registryProject(slug: "apollo")
        let publicProject = try await harness.store.project(slug: "apollo")

        XCTAssertEqual(registryProject?.pendingQuestionCount, 0)
        XCTAssertEqual(registryProject?.openFollowupCount, 0)
        XCTAssertFalse(registryProject?.needsOperatorAttention ?? true)
        XCTAssertEqual(publicProject?.pendingQuestionCount, 1)
        XCTAssertEqual(publicProject?.openFollowupCount, 1)
        XCTAssertTrue(publicProject?.needsOperatorAttention ?? false)
    }
}
