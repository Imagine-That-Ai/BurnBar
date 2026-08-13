import AppKit
import Foundation
import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

@MainActor
final class SafariLearningTimelineViewModelTests: XCTestCase {
    func testLoadBuildsSortedSearchableFilteredProjection() async {
        let older = makeProposal(
            id: "memory-older",
            kind: .memory,
            title: "Prefer concise summaries",
            content: "Lead with the conclusion before implementation detail.",
            sourceURL: "https://example.com/brief",
            status: .approved,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newest = makeProposal(
            id: "skill-newest",
            kind: .skill,
            title: "Compare catalog entries",
            content: "Extract each catalog price into a compact comparison.",
            sourceURL: "https://shop.example/catalog",
            status: .proposed,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let middle = makeProposal(
            id: "rule-middle",
            kind: .siteRule,
            title: "Confirm before leaving checkout",
            content: "Ask before navigating away from an unfinished checkout.",
            sourceURL: "https://shop.example/checkout",
            status: .rejected,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let client = SafariLearningClientProbe(
            timeline: BurnBarSafariLearningTimelineResponse(
                enabled: true,
                tier: "burnbar_pro_max",
                proposals: [older, newest, middle]
            )
        )
        let model = SafariLearningTimelineViewModel(client: client)

        await model.load()

        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.tierDisplayName, "Pro Max")
        XCTAssertTrue(model.isEligibleTier)
        XCTAssertEqual(
            model.proposals.map(\.proposalId),
            ["skill-newest", "rule-middle", "memory-older"]
        )
        XCTAssertEqual(model.proposedCount, 1)
        XCTAssertEqual(model.activeCount, 1)
        XCTAssertEqual(model.archivedCount, 1)

        model.filter = .active
        XCTAssertEqual(model.visibleProposals.map(\.proposalId), ["memory-older"])

        model.filter = .all
        model.searchText = "CATÁLOG"
        XCTAssertEqual(
            model.visibleProposals.map(\.proposalId),
            ["skill-newest"],
            "Search should be case- and diacritic-insensitive across content and URL"
        )

        model.searchText = "checkout"
        XCTAssertEqual(model.visibleProposals.map(\.proposalId), ["rule-middle"])

        model.filter = .archived
        XCTAssertEqual(model.visibleProposals.map(\.proposalId), ["rule-middle"])
    }

    func testOverlappingLoadsIgnoreTheLateStaleResponse() async {
        let client = SafariLearningClientProbe(
            timeline: BurnBarSafariLearningTimelineResponse(
                enabled: false,
                tier: "Free",
                proposals: []
            ),
            suspendTimelineRequests: true
        )
        let model = SafariLearningTimelineViewModel(client: client)
        let stale = makeProposal(
            id: "stale",
            title: "Stale response",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let current = makeProposal(
            id: "current",
            title: "Current response",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let firstLoad = Task { await model.load() }
        await client.waitForTimelineCallCount(1)
        let secondLoad = Task { await model.refresh() }
        await client.waitForTimelineCallCount(2)

        await client.resolveTimelineCall(
            2,
            with: BurnBarSafariLearningTimelineResponse(
                enabled: true,
                tier: "Ultra",
                proposals: [current]
            )
        )
        await secondLoad.value
        await client.resolveTimelineCall(
            1,
            with: BurnBarSafariLearningTimelineResponse(
                enabled: false,
                tier: "Free",
                proposals: [stale]
            )
        )
        await firstLoad.value

        XCTAssertEqual(model.proposals.map(\.proposalId), ["current"])
        XCTAssertEqual(model.tierDisplayName, "Ultra")
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefreshing)
    }

    func testMutationsReplaceVersionsUseExactTargetsAndForgetLocally() async {
        let initial = makeProposal(
            id: "mutable",
            version: 2,
            title: "Original title",
            content: "Original durable content.",
            status: .proposed
        )
        let approved = replacing(
            initial,
            version: 3,
            title: "Original title",
            content: "Original durable content.",
            status: .approved
        )
        let rolledBack = replacing(
            approved,
            version: 4,
            title: "Restored title",
            content: "Restored durable content.",
            status: .approved
        )
        let edited = replacing(
            rolledBack,
            version: 5,
            title: "Refined title",
            content: "Refined durable content for future sessions.",
            status: .approved
        )
        let client = SafariLearningClientProbe(
            timeline: BurnBarSafariLearningTimelineResponse(
                enabled: true,
                tier: "Pro",
                proposals: [initial]
            )
        )
        await client.enqueueProposalResponses([
            BurnBarSafariLearningProposalResponse(proposal: approved),
            BurnBarSafariLearningProposalResponse(proposal: rolledBack),
            BurnBarSafariLearningProposalResponse(proposal: edited)
        ])
        await client.enqueueStateResponses([
            BurnBarSafariLearningStateResponse(
                enabled: true,
                tier: "Pro",
                deletedEntryCount: 1
            )
        ])
        let model = SafariLearningTimelineViewModel(client: client)
        await model.load()

        await model.approve(initial)
        XCTAssertEqual(model.proposals.first?.version, 3)
        XCTAssertEqual(model.proposals.first?.reviewStatus, .approved)

        await model.rollbackToPreviousVersion(approved)
        XCTAssertEqual(model.proposals.first?.version, 4)
        XCTAssertEqual(model.proposals.first?.title, "Restored title")

        model.beginEditing(rolledBack)
        model.editDraft?.title = "Refined title"
        model.editDraft?.content =
            "Refined durable content for future sessions."
        await model.saveEdit()
        XCTAssertNil(model.editDraft)
        XCTAssertEqual(model.proposals.first?.version, 5)
        XCTAssertEqual(model.proposals.first?.title, "Refined title")

        await model.forget(edited)
        XCTAssertTrue(model.proposals.isEmpty)
        XCTAssertTrue(model.visibleProposals.isEmpty)

        let snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.approveRequests,
            [
                BurnBarSafariLearningMutationRequest(
                    proposalId: "mutable",
                    expectedVersion: 2
                )
            ]
        )
        XCTAssertEqual(
            snapshot.rollbackRequests,
            [
                BurnBarSafariLearningRollbackRequest(
                    proposalId: "mutable",
                    targetVersion: 2
                )
            ]
        )
        XCTAssertEqual(
            snapshot.updateRequests,
            [
                BurnBarSafariLearningUpdateRequest(
                    proposalId: "mutable",
                    expectedVersion: 4,
                    title: "Refined title",
                    content: "Refined durable content for future sessions."
                )
            ]
        )
        XCTAssertEqual(
            snapshot.forgetRequests,
            [
                BurnBarSafariLearningForgetRequest(
                    proposalId: "mutable",
                    expectedVersion: 5
                )
            ]
        )
    }

    func testVersionConflictRefreshesTimelineAndPreservesDraftForReview() async {
        let initial = makeProposal(
            id: "conflict",
            version: 1,
            title: "Initial title",
            content: "Initial durable content.",
            status: .approved
        )
        let current = replacing(
            initial,
            version: 2,
            title: "Daemon title",
            content: "Daemon-authoritative durable content.",
            status: .approved
        )
        let client = SafariLearningClientProbe(
            timeline: BurnBarSafariLearningTimelineResponse(
                enabled: true,
                tier: "Pro",
                proposals: [initial]
            )
        )
        let model = SafariLearningTimelineViewModel(client: client)
        await model.load()
        model.beginEditing(initial)
        model.editDraft?.title = "My unsaved title"
        model.editDraft?.content = "My unsaved durable content."
        await client.setTimelineResponse(
            BurnBarSafariLearningTimelineResponse(
                enabled: true,
                tier: "Pro",
                proposals: [current]
            )
        )
        await client.failNextUpdate(
            message: "proposal changed: expected version 1, actual 2"
        )

        await model.saveEdit()

        XCTAssertEqual(model.proposals.first?.version, 2)
        XCTAssertEqual(model.proposals.first?.title, "Daemon title")
        XCTAssertEqual(model.editDraft?.title, "My unsaved title")
        XCTAssertEqual(
            model.editDraft?.content,
            "My unsaved durable content."
        )
        XCTAssertEqual(model.editDraft?.hasConflict, true)
        XCTAssertNotEqual(model.editDraft?.canSave, true)
        XCTAssertEqual(model.banner?.kind, .warning)

        model.reloadCurrentVersionForEditor()
        XCTAssertEqual(model.editDraft?.expectedVersion, 2)
        XCTAssertEqual(model.editDraft?.title, "Daemon title")
        XCTAssertEqual(
            model.editDraft?.content,
            "Daemon-authoritative durable content."
        )
        XCTAssertNotEqual(model.editDraft?.hasConflict, true)
    }

    func testProfileControlsFailClosedOnFreeAndSupportPauseThenDelete() async {
        let item = makeProposal(id: "profile-item")
        let freeClient = SafariLearningClientProbe(
            timeline: BurnBarSafariLearningTimelineResponse(
                enabled: false,
                tier: "Free",
                proposals: [item]
            )
        )
        let freeModel = SafariLearningTimelineViewModel(client: freeClient)
        await freeModel.load()

        await freeModel.optIn()
        freeModel.beginEditing(item)

        XCTAssertNil(freeModel.editDraft)
        XCTAssertEqual(freeModel.banner?.kind, .warning)
        let freeSnapshot = await freeClient.snapshot()
        XCTAssertEqual(freeSnapshot.optInCallCount, 0)
        XCTAssertTrue(freeSnapshot.updateRequests.isEmpty)

        let proClient = SafariLearningClientProbe(
            timeline: BurnBarSafariLearningTimelineResponse(
                enabled: false,
                tier: "Pro",
                proposals: [item]
            )
        )
        await proClient.enqueueStateResponses([
            BurnBarSafariLearningStateResponse(enabled: true, tier: "Pro"),
            BurnBarSafariLearningStateResponse(enabled: false, tier: "Pro"),
            BurnBarSafariLearningStateResponse(
                enabled: false,
                tier: "Pro",
                deletedEntryCount: 1
            )
        ])
        let proModel = SafariLearningTimelineViewModel(client: proClient)
        await proModel.load()

        await proModel.optIn()
        XCTAssertTrue(proModel.enabled)
        await proModel.pauseLearning()
        XCTAssertFalse(proModel.enabled)

        proModel.beginEditing(item)
        XCTAssertNil(proModel.editDraft)
        XCTAssertEqual(proModel.banner?.title, "Learning is paused")

        await proModel.deleteLearnedProfile()
        XCTAssertFalse(proModel.enabled)
        XCTAssertTrue(proModel.proposals.isEmpty)
        XCTAssertEqual(proModel.banner?.title, "Learned profile deleted")

        let proSnapshot = await proClient.snapshot()
        XCTAssertEqual(proSnapshot.optInCallCount, 1)
        XCTAssertEqual(proSnapshot.optOutDeleteFlags, [false, true])
    }

    func testEditDraftEnforcesDaemonUTF8BoundsAndNoOpRule() {
        let proposal = makeProposal(
            id: "validation",
            title: "Valid title",
            content: "Valid durable content."
        )
        let draft = SafariLearningEditDraft(proposal: proposal)

        XCTAssertEqual(
            draft.validationMessage,
            "Change the title or content before saving."
        )
        XCTAssertFalse(draft.canSave)

        draft.title = String(repeating: "é", count: 129)
        XCTAssertEqual(draft.titleByteCount, 258)
        XCTAssertEqual(
            draft.validationMessage,
            "The title must be at most 256 UTF-8 bytes."
        )

        draft.title = "Changed title"
        draft.content = "short"
        XCTAssertEqual(
            draft.validationMessage,
            "The learned content must be at least 8 UTF-8 bytes."
        )

        draft.content = String(repeating: "é", count: 8_193)
        XCTAssertEqual(draft.contentByteCount, 16_386)
        XCTAssertEqual(
            draft.validationMessage,
            "The learned content must be at most 16384 UTF-8 bytes."
        )
    }

    func testLearningDeepLinkAndWindowReuseUseTheDedicatedSurface() async throws {
        let router = AppCommandRouter()
        var openCount = 0
        router.openSafariLearning = { openCount += 1 }

        XCTAssertTrue(router.handle(URL(string: "openburnbar://learning")!))
        XCTAssertEqual(openCount, 1)
        XCTAssertTrue(router.handle(URL(string: "openburnbar:///learning")!))
        XCTAssertEqual(openCount, 2)
        XCTAssertFalse(
            router.handle(URL(string: "openburnbar://not-learning")!)
        )
        XCTAssertEqual(openCount, 2)

        let client = SafariLearningClientProbe(
            timeline: BurnBarSafariLearningTimelineResponse(
                enabled: true,
                tier: "Pro",
                proposals: []
            )
        )
        let manager = WindowManager()
        let first = manager.openSafariLearning(client: client)
        let firstModel = try XCTUnwrap(
            manager._currentSafariLearningModel()
        )
        let second = manager.openSafariLearning(client: client)

        XCTAssertIdentical(first, second)
        XCTAssertIdentical(firstModel, manager._currentSafariLearningModel())
        XCTAssertEqual(first.title, "What BurnBar Learned About You")
        XCTAssertEqual(first.contentMinSize.width, 720)
        XCTAssertEqual(first.contentMinSize.height, 520)
        first.close()

        await Task.yield()
    }

    private func makeProposal(
        id: String,
        version: Int = 1,
        kind: BurnBarSafariLearningProposalKind = .memory,
        title: String = "Prefer accessible summaries",
        content: String = "Use clear headings and concise supporting detail.",
        sourceURL: String = "https://example.com/page",
        status: BurnBarSafariLearningReviewStatus = .proposed,
        updatedAt: Date = Date(timeIntervalSince1970: 200)
    ) -> BurnBarSafariLearningProposal {
        BurnBarSafariLearningProposal(
            proposalId: id,
            version: version,
            kind: kind,
            title: title,
            content: content,
            reason: "The user explicitly corrected this behavior.",
            expectedOutcome: "Future sessions match the user's preference.",
            sourceURL: sourceURL,
            sourceObservationId: "observation-\(id)",
            reviewStatus: status,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: updatedAt
        )
    }

    private func replacing(
        _ proposal: BurnBarSafariLearningProposal,
        version: Int,
        title: String,
        content: String,
        status: BurnBarSafariLearningReviewStatus
    ) -> BurnBarSafariLearningProposal {
        BurnBarSafariLearningProposal(
            proposalId: proposal.proposalId,
            version: version,
            kind: proposal.kind,
            title: title,
            content: content,
            reason: proposal.reason,
            expectedOutcome: proposal.expectedOutcome,
            sourceURL: proposal.sourceURL,
            sourceObservationId: proposal.sourceObservationId,
            reviewStatus: status,
            createdAt: proposal.createdAt,
            updatedAt: proposal.updatedAt.addingTimeInterval(
                TimeInterval(version)
            )
        )
    }
}

private actor SafariLearningClientProbe: SafariLearningTimelineClient {
    struct Snapshot: Sendable {
        let optInCallCount: Int
        let updateRequests: [BurnBarSafariLearningUpdateRequest]
        let approveRequests: [BurnBarSafariLearningMutationRequest]
        let rejectRequests: [BurnBarSafariLearningMutationRequest]
        let forgetRequests: [BurnBarSafariLearningForgetRequest]
        let rollbackRequests: [BurnBarSafariLearningRollbackRequest]
        let optOutDeleteFlags: [Bool]
    }

    private struct ProbeFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private var timelineResponse: BurnBarSafariLearningTimelineResponse
    private var suspendTimelineRequests: Bool
    private var timelineCallCount = 0
    private var timelineContinuations: [
        Int: CheckedContinuation<
            BurnBarSafariLearningTimelineResponse,
            Error
        >
    ] = [:]
    private var proposalResponses: [BurnBarSafariLearningProposalResponse] = []
    private var stateResponses: [BurnBarSafariLearningStateResponse] = []
    private var nextUpdateFailureMessage: String?
    private var optInCallCount = 0
    private var updateRequests: [BurnBarSafariLearningUpdateRequest] = []
    private var approveRequests: [BurnBarSafariLearningMutationRequest] = []
    private var rejectRequests: [BurnBarSafariLearningMutationRequest] = []
    private var forgetRequests: [BurnBarSafariLearningForgetRequest] = []
    private var rollbackRequests: [BurnBarSafariLearningRollbackRequest] = []
    private var optOutDeleteFlags: [Bool] = []

    init(
        timeline: BurnBarSafariLearningTimelineResponse,
        suspendTimelineRequests: Bool = false
    ) {
        timelineResponse = timeline
        self.suspendTimelineRequests = suspendTimelineRequests
    }

    func timeline() async throws -> BurnBarSafariLearningTimelineResponse {
        timelineCallCount += 1
        let callNumber = timelineCallCount
        if suspendTimelineRequests {
            return try await withCheckedThrowingContinuation { continuation in
                timelineContinuations[callNumber] = continuation
            }
        }
        return timelineResponse
    }

    func optIn() async throws -> BurnBarSafariLearningStateResponse {
        optInCallCount += 1
        return try nextStateResponse()
    }

    func update(
        _ request: BurnBarSafariLearningUpdateRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        updateRequests.append(request)
        if let message = nextUpdateFailureMessage {
            nextUpdateFailureMessage = nil
            throw ProbeFailure(message: message)
        }
        return try nextProposalResponse()
    }

    func approve(
        _ request: BurnBarSafariLearningMutationRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        approveRequests.append(request)
        return try nextProposalResponse()
    }

    func reject(
        _ request: BurnBarSafariLearningMutationRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        rejectRequests.append(request)
        return try nextProposalResponse()
    }

    func forget(
        _ request: BurnBarSafariLearningForgetRequest
    ) async throws -> BurnBarSafariLearningStateResponse {
        forgetRequests.append(request)
        return try nextStateResponse()
    }

    func rollback(
        _ request: BurnBarSafariLearningRollbackRequest
    ) async throws -> BurnBarSafariLearningProposalResponse {
        rollbackRequests.append(request)
        return try nextProposalResponse()
    }

    func optOut(
        deleteLearnedProfile: Bool
    ) async throws -> BurnBarSafariLearningStateResponse {
        optOutDeleteFlags.append(deleteLearnedProfile)
        return try nextStateResponse()
    }

    func setTimelineResponse(
        _ response: BurnBarSafariLearningTimelineResponse
    ) {
        timelineResponse = response
    }

    func enqueueProposalResponses(
        _ responses: [BurnBarSafariLearningProposalResponse]
    ) {
        proposalResponses.append(contentsOf: responses)
    }

    func enqueueStateResponses(
        _ responses: [BurnBarSafariLearningStateResponse]
    ) {
        stateResponses.append(contentsOf: responses)
    }

    func failNextUpdate(message: String) {
        nextUpdateFailureMessage = message
    }

    func waitForTimelineCallCount(_ expectedCount: Int) async {
        while timelineCallCount < expectedCount {
            await Task.yield()
        }
    }

    func resolveTimelineCall(
        _ callNumber: Int,
        with response: BurnBarSafariLearningTimelineResponse
    ) {
        guard let continuation = timelineContinuations.removeValue(
            forKey: callNumber
        ) else {
            preconditionFailure(
                "No suspended timeline request \(callNumber)"
            )
        }
        continuation.resume(returning: response)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            optInCallCount: optInCallCount,
            updateRequests: updateRequests,
            approveRequests: approveRequests,
            rejectRequests: rejectRequests,
            forgetRequests: forgetRequests,
            rollbackRequests: rollbackRequests,
            optOutDeleteFlags: optOutDeleteFlags
        )
    }

    private func nextProposalResponse()
        throws -> BurnBarSafariLearningProposalResponse {
        guard !proposalResponses.isEmpty else {
            throw ProbeFailure(message: "No proposal response was queued.")
        }
        return proposalResponses.removeFirst()
    }

    private func nextStateResponse()
        throws -> BurnBarSafariLearningStateResponse {
        guard !stateResponses.isEmpty else {
            throw ProbeFailure(message: "No state response was queued.")
        }
        return stateResponses.removeFirst()
    }
}
