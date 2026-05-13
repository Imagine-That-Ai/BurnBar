import XCTest
@testable import OpenBurnBarCore

final class InsightGatewayTests: XCTestCase {

    func testLocalRuleBasedAdapterProducesNonEmptyCanvas() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let digest = try InsightDigestBuilder().build(from: snapshot,
                                                       filter: InsightFilter(window: .last30d))
        let adapter = LocalRuleBasedAdapter()
        let models = try await adapter.availableModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.egressTier, .localOnly)

        let request = InsightInvestigateRequest(
            prompt: "show me what's going on",
            digest: digest,
            modelTag: .init(providerKey: adapter.providerKey,
                            modelID: "local-rules-v1",
                            displayName: "Local rules",
                            egressTier: .localOnly),
            capabilityTier: .narrativeOnly
        )

        var sawFinal = false
        for try await event in adapter.investigate(request: request, tools: nil) {
            if case .finalCanvas(let canvas) = event {
                sawFinal = true
                XCTAssertGreaterThanOrEqual(canvas.widgets.count, 6)
                XCTAssertTrue(canvas.widgets.contains { $0.kind == .narrative })
                XCTAssertTrue(canvas.widgets.contains { $0.kind == .kpiTile })
                XCTAssertEqual(canvas.modelTag?.providerKey, adapter.providerKey)
                // Every widget the local adapter produces must carry the
                // model attribution so the chrome footer shows "Local rules"
                // on every card.
                for widget in canvas.widgets {
                    XCTAssertEqual(widget.modelTag?.providerKey, adapter.providerKey,
                                    "Widget \(widget.title) is missing its model tag")
                    XCTAssertEqual(widget.modelTag?.egressTier, .localOnly)
                }
                // Every widget must have a layout placement — regression
                // for the empty-layout bug.
                for widget in canvas.widgets {
                    XCTAssertNotNil(canvas.layout.placements[widget.id],
                                    "Widget \(widget.title) is missing its layout placement")
                }
            }
        }
        XCTAssertTrue(sawFinal)
    }

    func testCapabilityFallbackChain() {
        let high = InsightModelCapabilities(supportsStrictJSONSchema: true)
        XCTAssertEqual(high.bestTier(requested: .strictJSONSchema), .strictJSONSchema)
        XCTAssertEqual(high.bestTier(requested: .jsonObject), .jsonObject)

        let mid = InsightModelCapabilities(supportsStrictJSONSchema: false, supportsJSONObject: true)
        XCTAssertEqual(mid.bestTier(requested: .strictJSONSchema), .jsonObject)

        let low = InsightModelCapabilities(supportsStrictJSONSchema: false, supportsJSONObject: false)
        XCTAssertEqual(low.bestTier(requested: .strictJSONSchema), .narrativeOnly)
        XCTAssertEqual(low.bestTier(requested: .jsonObject), .narrativeOnly)
    }

    func testCatalogOrdersLocalFirst() async throws {
        let catalog = InsightModelCatalog()
        await catalog.register(LocalRuleBasedAdapter())
        // Stub a fake user-key adapter via a closure-driven helper.
        struct UserKeyStub: InsightModelGateway {
            let providerKey = "stub"
            let displayName = "Stub"
            let capabilities = InsightModelCapabilities(supportsStrictJSONSchema: true)
            func availableModels() async throws -> [InsightCatalogModel] {
                [.init(id: "stub-1", displayName: "Stub 1", providerKey: "stub",
                       egressTier: .userKey, capabilities: capabilities)]
            }
            func investigate(request: InsightInvestigateRequest,
                              tools: InsightToolBroker?) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        await catalog.register(UserKeyStub())
        let all = await catalog.allModels()
        XCTAssertEqual(all.first?.egressTier, .localOnly)
        XCTAssertTrue(all.contains { $0.egressTier == .userKey })
    }

    func testPromptEngineIncludesAllWidgetKinds() {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let digest = (try? InsightDigestBuilder().build(from: snapshot,
                                                         filter: InsightFilter(window: .last30d))) ?? InsightDigest(
            contentHash: "", generatedAt: Date(),
            window: snapshot.window, rowCount: 0,
            totals: .init(),
            providers: [], models: [], projects: [], devices: [],
            daily: [], hourly: [], useCaseHistogram: [],
            agentFocusSignals: [], modelFocusSignals: [],
            quotaSnapshots: [], operatingActions: [],
            summaryRunsLog: [], anomalies: []
        )
        let request = InsightInvestigateRequest(
            prompt: "what changed",
            digest: digest,
            modelTag: .init(providerKey: "x", modelID: "y", displayName: "Y", egressTier: .userKey),
            capabilityTier: .strictJSONSchema
        )
        let prompt = InsightPromptEngine().systemPrompt(for: request, actualTier: .strictJSONSchema)
        for kind in InsightWidgetKind.allCases where kind != .error {
            XCTAssertTrue(prompt.contains(kind.rawValue),
                          "Prompt missing widget kind: \(kind.rawValue)")
        }
    }

    func testToolBrokerListVocabularyTools() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let broker = InsightToolBroker(dataSource: InMemoryInsightDataSource(usages: snapshot.usages,
                                                                              sessions: snapshot.sessions))
        let focuses = await broker.dispatch(.init(id: "1", name: "list_focuses", arguments: .listFocuses))
        XCTAssertFalse(focuses.isError)
        if case .vocabulary(let list) = focuses.payload {
            XCTAssertEqual(list, InsightTaxonomy.default.focuses)
        } else {
            XCTFail("expected vocabulary payload")
        }
        let useCases = await broker.dispatch(.init(id: "2", name: "list_use_cases", arguments: .listUseCases))
        XCTAssertFalse(useCases.isError)
    }

    func testToolBrokerDrilldownSearchReturnsBounded() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let broker = InsightToolBroker(dataSource: InMemoryInsightDataSource(usages: snapshot.usages,
                                                                              sessions: snapshot.sessions),
                                       maxRows: 5)
        let result = await broker.dispatch(.init(
            id: "1", name: "drilldown_search",
            arguments: .drilldownSearch(query: "bug", filter: InsightFilter(window: .last30d))
        ))
        if case .sessions(let rows) = result.payload {
            XCTAssertLessThanOrEqual(rows.count, 5)
        } else {
            XCTFail("expected sessions")
        }
    }
}
