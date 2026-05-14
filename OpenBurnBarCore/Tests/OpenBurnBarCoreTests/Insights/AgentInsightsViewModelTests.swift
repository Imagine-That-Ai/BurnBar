import XCTest
@testable import OpenBurnBarCore

/// Fixed reference date for deterministic tests. Pulled out of the
/// `@MainActor` test class so it's safely captured in `@Sendable` closures.
private let kTestNow = Date(timeIntervalSince1970: 1_750_000_000)

@Sendable private func makeSnapshot(provider: AgentProvider, cost: Double) -> InsightDataSnapshot {
    let end = kTestNow.addingTimeInterval(-3600)
    let row = InsightUsageRow(
        sessionID: "s-\(provider.rawValue)",
        provider: provider.rawValue,
        model: "m",
        startTime: end.addingTimeInterval(-3600),
        endTime: end,
        totalTokens: 1_000,
        costUSD: cost
    )
    return InsightDataSnapshot(
        window: DateInterval(start: kTestNow.addingTimeInterval(-7 * 86_400), end: kTestNow),
        generatedAt: kTestNow,
        usages: [row]
    )
}

@Sendable private func makeBundle(for scope: AgentInsightsScope) -> AgentInsightsBundle {
    AgentInsightsBundleAssembler.assemble(
        scope: scope,
        snapshot: makeSnapshot(provider: scope.provider ?? .codex, cost: 7),
        now: kTestNow
    )
}

@MainActor
final class AgentInsightsViewModelTests: XCTestCase {

    func testLoadPopulatesBundleAndSetsLoadedState() async {
        let producer = StaticAgentInsightsBundleProducer { scope in makeBundle(for: scope) }
        let vm = AgentInsightsViewModel(scope: .agent(.codex), producer: producer)
        XCTAssertEqual(vm.loadState, .idle)
        XCTAssertNil(vm.bundle)

        await vm.load()

        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertNotNil(vm.bundle)
        XCTAssertEqual(vm.bundle?.scope.provider, .codex)
        XCTAssertEqual(vm.bundle?.header.title, "Codex")
        XCTAssertNil(vm.errorMessage)
    }

    func testSetScopeClearsBundleAndRefetches() async {
        let producer = StaticAgentInsightsBundleProducer { scope in makeBundle(for: scope) }
        let vm = AgentInsightsViewModel(scope: .agent(.codex), producer: producer)
        await vm.load()
        XCTAssertEqual(vm.bundle?.header.title, "Codex")

        await vm.setScope(.agent(.claudeCode))

        XCTAssertEqual(vm.scope.provider, .claudeCode)
        XCTAssertEqual(vm.bundle?.header.title, "Claude Code")
        XCTAssertEqual(vm.loadState, .loaded)
    }

    func testFailingProducerSurfacesErrorMessage() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "no data source" }
        }
        final class FailingProducer: AgentInsightsBundleProducer, @unchecked Sendable {
            func bundle(for scope: AgentInsightsScope) async throws -> AgentInsightsBundle {
                throw Boom()
            }
        }
        let vm = AgentInsightsViewModel(scope: .agent(.codex), producer: FailingProducer())
        await vm.load()
        XCTAssertEqual(vm.loadState, .failed)
        XCTAssertEqual(vm.errorMessage, "no data source")
        XCTAssertNil(vm.bundle)
    }

    func testRefreshLeavesPreviousBundleOnTransientFailure() async {
        actor Toggle {
            var shouldFail = false
            func setFail(_ v: Bool) { shouldFail = v }
            func get() -> Bool { shouldFail }
        }
        let toggle = Toggle()
        final class ToggleProducer: AgentInsightsBundleProducer, @unchecked Sendable {
            let toggle: Toggle
            init(toggle: Toggle) { self.toggle = toggle }
            func bundle(for scope: AgentInsightsScope) async throws -> AgentInsightsBundle {
                if await toggle.get() { throw NSError(domain: "x", code: 1) }
                return makeBundle(for: scope)
            }
        }
        let producer = ToggleProducer(toggle: toggle)
        let vm = AgentInsightsViewModel(scope: .agent(.codex), producer: producer)

        await vm.load()
        XCTAssertNotNil(vm.bundle)

        await toggle.setFail(true)
        await vm.refresh()

        // Bundle is preserved across a transient failure; load state returns to .loaded.
        XCTAssertNotNil(vm.bundle, "Previous bundle should remain visible on transient refresh failure")
        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertNotNil(vm.errorMessage)
    }
}
