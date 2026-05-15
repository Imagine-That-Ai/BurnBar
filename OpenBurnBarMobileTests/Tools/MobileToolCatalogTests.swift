import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class MobileToolCatalogTests: XCTestCase {

    // MARK: - Catalog

    func test_defaultCatalog_advertisesThreeNamedTools() {
        let catalog = MobileToolCatalog.default
        let names = catalog.tools.map { type(of: $0).name }
        XCTAssertEqual(names.count, 5)
        XCTAssertTrue(names.contains("burnbar_atom_open"))
        XCTAssertTrue(names.contains("burnbar_hermes_sessions"))
        XCTAssertTrue(names.contains("burnbar_project_memory_list"))
        XCTAssertTrue(names.contains("burnbar_project_memory_wiki"))
        XCTAssertTrue(names.contains("burnbar_runtime_status"))
    }

    func test_toolsWireArray_emitsOpenAIFunctionDescriptor() throws {
        let catalog = MobileToolCatalog.default
        let wire = catalog.toolsWireArray()
        XCTAssertEqual(wire.count, 5)
        for entry in wire {
            XCTAssertEqual(entry["type"] as? String, "function")
            let function = try XCTUnwrap(entry["function"] as? [String: Any])
            XCTAssertNotNil(function["name"] as? String)
            XCTAssertNotNil(function["description"] as? String)
            let params = try XCTUnwrap(function["parameters"] as? [String: Any])
            XCTAssertEqual(params["type"] as? String, "object")
        }
    }

    func test_lookup_findsToolByNameAndNilForUnknown() {
        let catalog = MobileToolCatalog.default
        XCTAssertNotNil(catalog.tool(named: "burnbar_atom_open"))
        XCTAssertNotNil(catalog.tool(named: "burnbar_project_memory_wiki"))
        XCTAssertNil(catalog.tool(named: "definitely_not_a_tool"))
    }

    // MARK: - Executor

    func test_executor_runsKnownToolAndReturnsContent() async throws {
        let context = StubToolContext()
        let executor = MobileToolExecutor(catalog: MobileToolCatalog.default)
        let result = await executor.execute(
            PendingToolCall(
                id: "call-1",
                name: "burnbar_runtime_status",
                arguments: "{}"
            ),
            context: context
        )
        XCTAssertEqual(result.toolCallID, "call-1")
        XCTAssertFalse(result.isError)
        let payload = try XCTUnwrap(parseJSON(result.content))
        XCTAssertEqual(payload["runtime"] as? String, "test")
    }

    func test_executor_unknownToolReturnsStructuredError() async {
        let context = StubToolContext()
        let executor = MobileToolExecutor(catalog: MobileToolCatalog.default)
        let result = await executor.execute(
            PendingToolCall(id: "call-2", name: "nope", arguments: "{}"),
            context: context
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown tool"))
    }

    func test_executor_invalidArgumentsErrorBubblesAsJSONError() async {
        let context = StubToolContext()
        let executor = MobileToolExecutor(catalog: MobileToolCatalog.default)
        let result = await executor.execute(
            PendingToolCall(
                id: "call-3",
                name: "burnbar_atom_open",
                arguments: "not a json object"
            ),
            context: context
        )
        XCTAssertTrue(result.isError)
        // We render errors as `{"error": "..."}` so the model can
        // recover with a follow-up call.
        XCTAssertTrue(result.content.contains("\"error\""))
    }

    func test_truncatedForWire_capsAtCeiling() {
        let big = String(repeating: "a", count: MobileToolExecutionResult.maxContentBytes + 100)
        let trimmed = MobileToolExecutionResult.truncatedForWire(big)
        XCTAssertLessThan(trimmed.utf8.count, big.utf8.count)
        XCTAssertTrue(trimmed.contains("truncated"))
    }

    func test_projectMemoryListTool_filtersByQueryAndLimit() async throws {
        let context = StubToolContext()
        context.stubProjectMemoryProvider = StubProjectMemoryProvider(
            entries: [
                MobileProjectMemoryCatalogEntry(
                    projectID: "burnbar",
                    projectName: "BurnBar",
                    sessionCount: 20,
                    totalTokens: 120_000,
                    totalCost: 42.12,
                    lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
                    freshness: .fresh,
                    summary: "20 sessions"
                ),
                MobileProjectMemoryCatalogEntry(
                    projectID: "atlas",
                    projectName: "Atlas Evolution",
                    sessionCount: 8,
                    totalTokens: 80_000,
                    totalCost: 18.22,
                    lastSeen: Date(timeIntervalSince1970: 1_699_000_000),
                    freshness: .needsRefresh,
                    summary: "8 sessions"
                )
            ],
            snapshots: [:]
        )
        let executor = MobileToolExecutor(catalog: MobileToolCatalog.default)
        let result = await executor.execute(
            PendingToolCall(
                id: "call-project-list",
                name: "burnbar_project_memory_list",
                arguments: #"{"query":"burn","limit":1}"#
            ),
            context: context
        )
        XCTAssertFalse(result.isError)
        let payload = try XCTUnwrap(parseJSON(result.content))
        XCTAssertEqual(payload["count"] as? Int, 1)
        let projects = try XCTUnwrap(payload["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.first?["project_name"] as? String, "BurnBar")
    }

    func test_projectMemoryWikiTool_returnsSnapshot() async throws {
        let context = StubToolContext()
        let snapshot = makeSnapshot(projectID: "burnbar", projectName: "BurnBar")
        context.stubProjectMemoryProvider = StubProjectMemoryProvider(
            entries: [],
            snapshots: ["burnbar": snapshot]
        )
        let executor = MobileToolExecutor(catalog: MobileToolCatalog.default)
        let result = await executor.execute(
            PendingToolCall(
                id: "call-project-wiki",
                name: "burnbar_project_memory_wiki",
                arguments: #"{"project_id":"burnbar","focus_question":"What changed?"}"#
            ),
            context: context
        )
        XCTAssertFalse(result.isError)
        let payload = try XCTUnwrap(parseJSON(result.content))
        XCTAssertEqual(payload["found"] as? Bool, true)
        let snapshotPayload = try XCTUnwrap(payload["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshotPayload["project_name"] as? String, "BurnBar")
        let sections = try XCTUnwrap(snapshotPayload["sections"] as? [[String: Any]])
        XCTAssertFalse(sections.isEmpty)
    }

    func test_projectMemoryWikiTool_returnsNotFoundPayload() async throws {
        let context = StubToolContext()
        context.stubProjectMemoryProvider = StubProjectMemoryProvider(entries: [], snapshots: [:])
        let executor = MobileToolExecutor(catalog: MobileToolCatalog.default)
        let result = await executor.execute(
            PendingToolCall(
                id: "call-project-wiki-miss",
                name: "burnbar_project_memory_wiki",
                arguments: #"{"project_id":"missing"}"#
            ),
            context: context
        )
        XCTAssertFalse(result.isError)
        let payload = try XCTUnwrap(parseJSON(result.content))
        XCTAssertEqual(payload["found"] as? Bool, false)
    }

    // MARK: - JSON Schema helpers

    func test_objectSchema_includesPropertiesAndRequired() {
        let schema = MobileToolJSONSchema.object(
            properties: ["foo": MobileToolJSONSchema.string(description: "bar")],
            required: ["foo"],
            description: "Test object"
        )
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["description"] as? String, "Test object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = schema["required"] as? [String]
        XCTAssertEqual(required, ["foo"])
    }

    func test_integerSchema_honoursBounds() {
        let schema = MobileToolJSONSchema.integer(description: "x", minimum: 1, maximum: 50)
        XCTAssertEqual(schema["type"] as? String, "integer")
        XCTAssertEqual(schema["minimum"] as? Int, 1)
        XCTAssertEqual(schema["maximum"] as? Int, 50)
    }

    // MARK: - Helpers

    private func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    private func makeSnapshot(projectID: String, projectName: String) -> MobileProjectMemorySnapshot {
        MobileProjectMemorySnapshot(
            projectID: projectID,
            projectName: projectName,
            summary: "10 sessions · 40K tokens · $12.10",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            freshness: .fresh,
            sections: [
                MobileProjectMemorySection(
                    id: "recent",
                    title: "Recent agent work",
                    body: "1. claude-sonnet-4.7 · $2.10",
                    citations: [
                        MobileProjectMemoryCitation(
                            id: "c1",
                            sessionID: "session-1",
                            model: "claude-sonnet-4.7",
                            provider: "Anthropic",
                            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            note: "Evidence"
                        )
                    ]
                )
            ],
            visuals: [
                MobileProjectMemoryVisual(
                    id: "provider",
                    title: "Provider mix",
                    subtitle: "Spend by provider",
                    kind: .bar,
                    points: [
                        MobileProjectMemoryVisualPoint(label: "Anthropic", value: 12.1, display: "$12.10")
                    ]
                )
            ],
            sourceSessionCount: 10,
            sourceTokenTotal: 40_000,
            sourceCostTotal: 12.1
        )
    }
}

// MARK: - Stub Context

@MainActor
final class StubToolContext: MobileToolContext {
    var capturedAtomNavigator: (() -> HermesAtomNavigator?)?
    var stubSessions: [MobileToolSessionSummary] = []
    var stubProjectMemoryProvider: (any MobileProjectMemoryProviding)?
    var stubStatus: MobileToolRuntimeStatus = MobileToolRuntimeStatus(
        runtime: "test",
        isReachable: true,
        connectionName: "Test host",
        connectionMode: "local",
        selectedModelID: "fake-model",
        advertisedModel: "fake-model",
        lastError: nil
    )

    var atomNavigator: HermesAtomNavigator? {
        capturedAtomNavigator?()
    }

    var availableSessions: [MobileToolSessionSummary] { stubSessions }
    var runtimeStatusSnapshot: MobileToolRuntimeStatus { stubStatus }
    var projectMemoryProvider: any MobileProjectMemoryProviding {
        stubProjectMemoryProvider ?? MobileProjectMemoryProvider.shared
    }
}

@MainActor
final class StubProjectMemoryProvider: MobileProjectMemoryProviding {
    private let entries: [MobileProjectMemoryCatalogEntry]
    private let snapshots: [String: MobileProjectMemorySnapshot]

    init(
        entries: [MobileProjectMemoryCatalogEntry],
        snapshots: [String: MobileProjectMemorySnapshot]
    ) {
        self.entries = entries
        self.snapshots = snapshots
    }

    func listProjectMemory(limit: Int) async throws -> [MobileProjectMemoryCatalogEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    func projectMemorySnapshot(projectID: String, focusQuestion: String?) async throws -> MobileProjectMemorySnapshot? {
        snapshots[projectID.lowercased()]
    }
}
