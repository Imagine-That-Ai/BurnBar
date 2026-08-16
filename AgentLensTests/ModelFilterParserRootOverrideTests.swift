@testable import BurnBar
import Foundation
import XCTest

@MainActor
final class ModelFilterParserRootOverrideTests: XCTestCase {
    func test_providerSpecificRootsOverrideSharedFactoryRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-filter-roots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sharedRoot = root.appendingPathComponent("shared", isDirectory: true)
        let zaiRoot = root.appendingPathComponent("zai", isDirectory: true)
        let minimaxRoot = root.appendingPathComponent("minimax", isDirectory: true)
        try writeSession(root: zaiRoot, project: "zai-project", session: "zai-session", model: "zai-1")
        try writeSession(root: minimaxRoot, project: "minimax-project", session: "minimax-session", model: "minimax-01")

        let environment = [
            "BURNBAR_FLEET_ROOTS_DIR": sharedRoot.path,
            "BURNBAR_FLEET_ROOT_ZAI": zaiRoot.path,
            "BURNBAR_FLEET_ROOT_MINIMAX": minimaxRoot.path
        ]
        let appPaths = BurnBarAppPaths(applicationSupportRoot: root.appendingPathComponent("support"))
        let zaiParser = ModelFilterParser(
            modelPattern: "zai",
            provider: .zai,
            appPaths: appPaths,
            environment: environment
        )
        let minimaxParser = ModelFilterParser(
            modelPattern: "minimax",
            provider: .minimax,
            appPaths: appPaths,
            environment: environment
        )

        let zaiResult = try await zaiParser.parse()
        let minimaxResult = try await minimaxParser.parse()

        XCTAssertEqual(zaiResult.usages.map(\.sessionId), ["zai-session"])
        XCTAssertEqual(minimaxResult.usages.map(\.sessionId), ["minimax-session"])
        XCTAssertTrue(zaiResult.usages.allSatisfy { $0.provider == .zai })
        XCTAssertTrue(minimaxResult.usages.allSatisfy { $0.provider == .minimax })
    }

    private func writeSession(
        root: URL,
        project: String,
        session: String,
        model: String
    ) throws {
        let projectRoot = root
            .appendingPathComponent("sessions/\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-08-13T00:00:00Z",
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "hello"]],
                "usage": ["input_tokens": 100, "output_tokens": 50]
            ]
        ]
        let recordData = try JSONSerialization.data(withJSONObject: record)
        try recordData.write(to: projectRoot.appendingPathComponent("\(session).jsonl"))
        let settings: [String: Any] = [
            "model": model,
            "tokenUsage": ["input_tokens": 100, "output_tokens": 50]
        ]
        let settingsData = try JSONSerialization.data(withJSONObject: settings)
        try settingsData.write(to: projectRoot.appendingPathComponent("\(session).settings.json"))
    }
}
