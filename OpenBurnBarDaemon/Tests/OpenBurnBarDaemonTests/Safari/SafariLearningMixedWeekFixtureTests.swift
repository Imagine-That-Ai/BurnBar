import Foundation
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class SafariLearningMixedWeekFixtureTests: XCTestCase {
    func testSevenDayMixedUseProducesSmallAccurateReversibleProfile()
        async throws {
        XCTAssertTrue(
            MemorySecretPIIGate.isAvailable,
            "The shared fail-closed secret and PII corpus must be available."
        )
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.days.map(\.day), Array(1...7))

        let workspace = try MixedWeekLearningWorkspace()
        defer { workspace.remove() }
        let memory = MixedWeekMemoryHarness()
        let coordinator = workspace.coordinator(
            tier: "burnbar_pro",
            memory: memory
        )
        _ = try await coordinator.optIn(
            BurnBarSafariLearningOptInRequest()
        )

        var staged: [String: BurnBarSafariLearningProposal] = [:]
        var previousDay = 0
        var rejectedSecret = ""
        for day in fixture.days {
            workspace.clock.advance(
                TimeInterval(day.day - previousDay) * 24 * 60 * 60
            )
            previousDay = day.day

            for event in day.events {
                let observation = event.observation(
                    observedAt: workspace.clock.now()
                )
                switch event.expected {
                case .staged:
                    let response = try await coordinator.propose(
                        BurnBarSafariLearningProposalRequest(
                            observation: observation
                        )
                    )
                    staged[event.id] = response.proposal
                    XCTAssertEqual(
                        response.proposal.kind,
                        try XCTUnwrap(event.expectedKind)
                    )
                    XCTAssertEqual(
                        response.proposal.reviewStatus,
                        .proposed
                    )

                case .threshold:
                    do {
                        _ = try await coordinator.propose(
                            BurnBarSafariLearningProposalRequest(
                                observation: observation
                            )
                        )
                        XCTFail(
                            "\(event.id) staged before the third repeat."
                        )
                    } catch SafariLearningCoordinatorError
                        .triggerThresholdNotMet(
                            let current,
                            let required
                        ) {
                        XCTAssertLessThan(current, required)
                        XCTAssertEqual(required, 3)
                    }

                case .noiseRejected:
                    do {
                        _ = try await coordinator.propose(
                            BurnBarSafariLearningProposalRequest(
                                observation: observation
                            )
                        )
                        XCTFail("Transient noise must not enter the profile.")
                    } catch SafariLearningCoordinatorError
                        .invalidObservation {
                        // Expected.
                    }

                case .secretRejected:
                    rejectedSecret = event.content
                    do {
                        _ = try await coordinator.propose(
                            BurnBarSafariLearningProposalRequest(
                                observation: observation
                            )
                        )
                        XCTFail("Credentials must fail before staging.")
                    } catch SafariLearningCoordinatorError
                        .sensitiveContentRejected(let findings) {
                        XCTAssertFalse(findings.isEmpty)
                    }
                }
            }
        }

        XCTAssertEqual(
            Set(staged.keys),
            Set([
                "correction-table-density",
                "correction-exact-dates",
                "correction-receipt-destination",
                "recovered-checkout-failure",
                "repeat-price-workflow-3"
            ])
        )

        var approved: [String: BurnBarSafariLearningProposal] = [:]
        for eventID in [
            "correction-table-density",
            "correction-exact-dates",
            "correction-receipt-destination",
            "recovered-checkout-failure"
        ] {
            let proposal = try XCTUnwrap(staged[eventID])
            let response = try await coordinator.approve(
                BurnBarSafariLearningMutationRequest(
                    proposalId: proposal.proposalId,
                    expectedVersion: proposal.version
                )
            )
            approved[eventID] = response.proposal
            XCTAssertEqual(response.proposal.reviewStatus, .approved)
        }

        let tablePreference = try XCTUnwrap(
            approved["correction-table-density"]
        )
        let edited = try await coordinator.update(
            BurnBarSafariLearningUpdateRequest(
                proposalId: tablePreference.proposalId,
                expectedVersion: tablePreference.version,
                title: "Compact comparison preference",
                content: """
                The user prefers compact comparison tables with totals first \
                and supporting detail kept concise.
                """
            )
        )
        XCTAssertEqual(edited.proposal.version, tablePreference.version + 1)

        let rolledBack = try await coordinator.rollback(
            BurnBarSafariLearningRollbackRequest(
                proposalId: edited.proposal.proposalId,
                targetVersion: tablePreference.version
            )
        )
        XCTAssertEqual(rolledBack.proposal.version, edited.proposal.version + 1)
        XCTAssertEqual(rolledBack.proposal.content, tablePreference.content)
        XCTAssertEqual(rolledBack.proposal.reviewStatus, .approved)

        let forgotten = try XCTUnwrap(
            approved["correction-exact-dates"]
        )
        let forgetState = try await coordinator.forget(
            BurnBarSafariLearningForgetRequest(
                proposalId: forgotten.proposalId,
                expectedVersion: forgotten.version
            )
        )
        XCTAssertEqual(forgetState.deletedEntryCount, 1)

        let timeline = try await coordinator.timeline()
        XCTAssertTrue(timeline.enabled)
        XCTAssertEqual(timeline.proposals.count, 4)

        let activeMemories = timeline.proposals.filter {
            $0.kind == .memory && $0.reviewStatus == .approved
        }
        let activeSiteRules = timeline.proposals.filter {
            $0.kind == .siteRule && $0.reviewStatus == .approved
        }
        let proposedSkills = timeline.proposals.filter {
            $0.kind == .skill && $0.reviewStatus == .proposed
        }
        XCTAssertEqual(activeMemories.count, 2)
        XCTAssertEqual(activeSiteRules.count, 1)
        XCTAssertEqual(proposedSkills.count, 1)
        XCTAssertTrue(
            timeline.proposals.contains {
                $0.proposalId == rolledBack.proposal.proposalId
                    && $0.version == rolledBack.proposal.version
            }
        )

        let serializedTimeline = try String(
            data: JSONEncoder().encode(timeline),
            encoding: .utf8
        )
        let persistedState = try String(
            contentsOf: workspace.stateURL,
            encoding: .utf8
        )
        for rawSensitiveValue in [
            "alberto@example.com",
            rejectedSecret
        ] {
            XCTAssertNotEqual(serializedTimeline?.contains(rawSensitiveValue), true)
            XCTAssertFalse(persistedState.contains(rawSensitiveValue))
        }

        let receiptMemory = try XCTUnwrap(
            activeMemories.first {
                $0.sourceObservationId
                    == "correction-receipt-destination"
            }
        )
        XCTAssertFalse(receiptMemory.content.contains("alberto@example.com"))
        XCTAssertFalse(receiptMemory.content.isEmpty)

        let writes = await memory.writes()
        XCTAssertGreaterThanOrEqual(
            writes.count,
            6,
            "Approvals plus edit and rollback must rematerialize memories."
        )
        XCTAssertTrue(
            writes.allSatisfy {
                $0.scope == "personal"
                    && $0.sourcePath == "safari_extension"
                    && $0.reviewStatus == .approved
            }
        )
        let forgottenIDs = await memory.forgottenIDs()
        XCTAssertGreaterThanOrEqual(
            forgottenIDs.count,
            3,
            "Edit, rollback, and explicit forget must clean old materializations."
        )
    }

    func testSevenDayFixtureOnFreeTierCreatesNoStateOrSkillDirectory()
        async throws {
        let fixture = try loadFixture()
        let workspace = try MixedWeekLearningWorkspace()
        defer { workspace.remove() }
        let memory = MixedWeekMemoryHarness()
        let coordinator = workspace.coordinator(
            tier: "free",
            memory: memory
        )

        do {
            _ = try await coordinator.optIn(
                BurnBarSafariLearningOptInRequest()
            )
            XCTFail("Free tier must not opt into durable learning.")
        } catch SafariLearningCoordinatorError.ineligibleTier(let tier) {
            XCTAssertEqual(tier, "free")
        }

        for day in fixture.days {
            for event in day.events {
                do {
                    _ = try await coordinator.propose(
                        BurnBarSafariLearningProposalRequest(
                            observation: event.observation(
                                observedAt: workspace.clock.now()
                            )
                        )
                    )
                    XCTFail("Free-tier event \(event.id) must not write.")
                } catch SafariLearningCoordinatorError
                    .ineligibleTier(let tier) {
                    XCTAssertEqual(tier, "free")
                }
            }
            workspace.clock.advance(24 * 60 * 60)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.stateURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.skillsURL.path
            )
        )
        let writes = await memory.writes()
        let forgottenIDs = await memory.forgottenIDs()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(forgottenIDs.isEmpty)
    }

    private func loadFixture() throws -> MixedWeekFixture {
        let bundle: Bundle
        #if SWIFT_PACKAGE
        bundle = .module
        #else
        bundle = Bundle(for: Self.self)
        #endif
        let url = bundle.url(
            forResource: "safari-learning-mixed-week",
            withExtension: "json"
        ) ?? bundle.url(
            forResource: "safari-learning-mixed-week",
            withExtension: "json",
            subdirectory: "Fixtures/Safari"
        )
        let fixtureURL = try XCTUnwrap(
            url,
            "The seven-day Safari learning fixture must be bundled."
        )
        return try JSONDecoder().decode(
            MixedWeekFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }
}

private struct MixedWeekFixture: Decodable {
    let schemaVersion: Int
    let days: [Day]

    struct Day: Decodable {
        let day: Int
        let events: [Event]
    }

    struct Event: Decodable {
        enum Expected: String, Decodable {
            case staged
            case threshold
            case noiseRejected = "noise_rejected"
            case secretRejected = "secret_rejected"
        }

        let id: String
        let trigger: BurnBarSafariLearningTrigger
        let actionCount: Int
        let contentParts: [String]
        let tags: [String]
        let sourceURL: String
        let sourceTitle: String
        let expected: Expected
        let expectedKind: BurnBarSafariLearningProposalKind?

        var content: String {
            contentParts.joined()
        }

        func observation(observedAt: Date)
            -> BurnBarSafariLearningObservation {
            BurnBarSafariLearningObservation(
                observationId: id,
                safariSessionId: "mixed-week-safari-session",
                runId: "mixed-week-\(id)",
                sourceURL: sourceURL,
                sourceTitle: sourceTitle,
                trigger: trigger,
                actionCount: actionCount,
                content: content,
                tags: tags,
                observedAt: observedAt
            )
        }
    }
}

private final class MixedWeekLearningWorkspace {
    let rootURL: URL
    let stateURL: URL
    let skillsURL: URL
    let clock: MixedWeekLearningClock

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "openburnbar-learning-mixed-week-\(UUID().uuidString)",
                isDirectory: true
            )
        stateURL = rootURL
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("learning.json", isDirectory: false)
        skillsURL = rootURL
            .appendingPathComponent("safari-skills", isDirectory: true)
        clock = MixedWeekLearningClock(
            Date(timeIntervalSince1970: 1_786_300_000)
        )
    }

    func coordinator(
        tier: String,
        memory: MixedWeekMemoryHarness
    ) -> LearningCoordinator {
        LearningCoordinator(
            stateURL: stateURL,
            skillsRootURL: skillsURL,
            now: { [clock] in clock.now() },
            eligibilityProvider: {
                SafariLearningEligibility.canonical(tier: tier)
            },
            memoryWriter: { request in
                await memory.write(request)
            },
            memoryForgetter: { request in
                await memory.forget(request)
            }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class MixedWeekLearningClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(_ interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}

private actor MixedWeekMemoryHarness {
    private var writtenRequests: [BurnBarProjectMemoryRememberRequest] = []
    private var forgotten: [String] = []

    func write(
        _ request: BurnBarProjectMemoryRememberRequest
    ) -> BurnBarProjectMemoryRememberResponse {
        writtenRequests.append(request)
        let memoryID = "mixed-week-memory-\(writtenRequests.count)"
        return BurnBarProjectMemoryRememberResponse(
            traceID: "trace-\(memoryID)",
            projectID: "personal",
            memoryID: memoryID,
            auditHash: "audit-\(memoryID)"
        )
    }

    func forget(
        _ request: BurnBarProjectMemoryForgetRequest
    ) -> BurnBarProjectMemoryForgetResponse {
        forgotten.append(request.memoryID)
        return BurnBarProjectMemoryForgetResponse(
            traceID: "trace-forget-\(request.memoryID)",
            projectID: "personal",
            memoryID: request.memoryID,
            localDeleted: true,
            cloudDeletePending: false,
            auditHash: "audit-forget-\(request.memoryID)"
        )
    }

    func writes() -> [BurnBarProjectMemoryRememberRequest] {
        writtenRequests
    }

    func forgottenIDs() -> [String] {
        forgotten
    }
}
