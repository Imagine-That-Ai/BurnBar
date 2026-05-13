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
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains("burnbar_atom_open"))
        XCTAssertTrue(names.contains("burnbar_hermes_sessions"))
        XCTAssertTrue(names.contains("burnbar_runtime_status"))
    }

    func test_toolsWireArray_emitsOpenAIFunctionDescriptor() throws {
        let catalog = MobileToolCatalog.default
        let wire = catalog.toolsWireArray()
        XCTAssertEqual(wire.count, 3)
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
}

// MARK: - Stub Context

@MainActor
final class StubToolContext: MobileToolContext {
    var capturedAtomNavigator: (() -> HermesAtomNavigator?)?
    var stubSessions: [MobileToolSessionSummary] = []
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
}
