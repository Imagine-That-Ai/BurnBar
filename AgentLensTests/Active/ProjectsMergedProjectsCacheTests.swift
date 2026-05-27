import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

@MainActor
final class ProjectsMergedProjectsCacheTests: XCTestCase {

    private func usage(slug: String, cost: Double, tokens: Int, provider: AgentProvider = .factory) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: UUID().uuidString,
            projectName: slug,
            model: "model",
            inputTokens: tokens / 2,
            outputTokens: tokens - tokens / 2,
            costUSD: cost,
            startTime: Date(),
            endTime: Date().addingTimeInterval(60)
        )
    }

    private func snapshot(slug: String, displayName: String, needsAttention: Bool = false) -> BurnBarReviewProjectSnapshot {
        BurnBarReviewProjectSnapshot(
            id: slug,
            projectSlug: slug,
            displayName: displayName,
            summary: "",
            status: .healthy,
            preferredCadence: .daily,
            freshness: .fresh,
            pendingQuestionCount: 0,
            openFollowupCount: 0,
            activeMissionCount: 0,
            needsOperatorAttention: needsAttention
        )
    }

    func testCompute_emptyInputs_returnsEmpty() {
        let merged = ProjectsView.computeMergedProjects(usages: [], controllerProjects: [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testCompute_unregisteredUsageOnlyProject_isIncluded() {
        let merged = ProjectsView.computeMergedProjects(
            usages: [usage(slug: "alpha", cost: 1.0, tokens: 100)],
            controllerProjects: []
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.slug, "alpha")
        XCTAssertFalse(merged.first?.isRegistered ?? true)
        XCTAssertEqual(merged.first?.totalCost ?? -1, 1.0, accuracy: 0.0001)
    }

    func testCompute_registeredProject_matchesUsageBySlug() {
        let merged = ProjectsView.computeMergedProjects(
            usages: [usage(slug: "beta", cost: 5.0, tokens: 500)],
            controllerProjects: [snapshot(slug: "beta", displayName: "Beta Project")]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged.first?.isRegistered ?? false)
        XCTAssertEqual(merged.first?.displayName, "Beta Project")
        XCTAssertEqual(merged.first?.totalCost ?? -1, 5.0, accuracy: 0.0001)
        XCTAssertEqual(merged.first?.totalTokens ?? -1, 500)
    }

    func testCompute_registeredProject_matchesUsageByDisplayNameFallback() {
        let merged = ProjectsView.computeMergedProjects(
            usages: [usage(slug: "Beta Project", cost: 2.0, tokens: 200)],
            controllerProjects: [snapshot(slug: "beta", displayName: "Beta Project")]
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.totalCost ?? -1, 2.0, accuracy: 0.0001)
    }

    func testCompute_aggregatesMultipleUsagesPerProject() {
        let merged = ProjectsView.computeMergedProjects(
            usages: [
                usage(slug: "gamma", cost: 1.0, tokens: 100, provider: .factory),
                usage(slug: "gamma", cost: 2.0, tokens: 200, provider: .factory),
                usage(slug: "gamma", cost: 3.0, tokens: 300, provider: .claudeCode)
            ],
            controllerProjects: []
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.totalCost ?? -1, 6.0, accuracy: 0.0001)
        XCTAssertEqual(merged.first?.totalTokens ?? -1, 600)
        XCTAssertEqual(merged.first?.sessionCount, 3)
        XCTAssertEqual(merged.first?.providers.count, 2)
    }

    func testCompute_sortOrder_attentionFirstThenCostThenSlug() {
        let merged = ProjectsView.computeMergedProjects(
            usages: [
                usage(slug: "low-cost", cost: 0.1, tokens: 10),
                usage(slug: "high-cost", cost: 10.0, tokens: 100)
            ],
            controllerProjects: [
                snapshot(slug: "needs-attention", displayName: "Needs Attention", needsAttention: true),
                snapshot(slug: "low-cost", displayName: "Low Cost"),
                snapshot(slug: "high-cost", displayName: "High Cost")
            ]
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].slug, "needs-attention")
        XCTAssertEqual(merged[1].slug, "high-cost")
        XCTAssertEqual(merged[2].slug, "low-cost")
    }

    func testCompute_isPure_sameInputsProduceSameOutputs() {
        let usages = [
            usage(slug: "alpha", cost: 1.0, tokens: 100),
            usage(slug: "beta", cost: 2.0, tokens: 200)
        ]
        let snapshots = [snapshot(slug: "alpha", displayName: "Alpha")]
        let a = ProjectsView.computeMergedProjects(usages: usages, controllerProjects: snapshots)
        let b = ProjectsView.computeMergedProjects(usages: usages, controllerProjects: snapshots)
        XCTAssertEqual(a.map(\.slug), b.map(\.slug))
        XCTAssertEqual(
            a.map(\.totalCost),
            b.map(\.totalCost)
        )
    }
}
