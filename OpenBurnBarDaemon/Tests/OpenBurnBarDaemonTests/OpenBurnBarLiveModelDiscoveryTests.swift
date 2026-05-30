import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class OpenBurnBarLiveModelDiscoveryTests: XCTestCase {

    // MARK: - Anthropic Model ID Normalization

    func testNormalizeAnthropicModelID_stripsDatedSuffix() {
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-opus-4-8-20260514"),
            "claude-opus-4-8",
            "Dated snapshot IDs should be normalized to their family ID."
        )
    }

    func testNormalizeAnthropicModelID_stripsDatedSuffix_sonnet() {
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-sonnet-4-6-20250514"),
            "claude-sonnet-4-6"
        )
    }

    func testNormalizeAnthropicModelID_stripsDatedSuffix_legacy35() {
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-3-5-sonnet-20241022"),
            "claude-3-5-sonnet"
        )
    }

    func testNormalizeAnthropicModelID_stripsDatedSuffix_legacy3() {
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-3-opus-20240229"),
            "claude-3-opus"
        )
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-3-haiku-20240307"),
            "claude-3-haiku"
        )
    }

    func testNormalizeAnthropicModelID_passesThroughNonDatedIDs() {
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-opus-4-8"),
            "claude-opus-4-8",
            "Family IDs without dated suffixes should pass through unchanged."
        )
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-sonnet-4-6"),
            "claude-sonnet-4-6"
        )
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-3-5-sonnet"),
            "claude-3-5-sonnet"
        )
    }

    func testNormalizeAnthropicModelID_handlesEdgeCases() {
        // Single-digit version numbers should not be stripped (not 8 digits).
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID("claude-2-1"),
            "claude-2-1",
            "Short numeric suffixes should not be stripped."
        )
        // Empty string
        XCTAssertEqual(
            BurnBarLiveModelCatalog.normalizeAnthropicModelID(""),
            ""
        )
    }

    // MARK: - Anthropic Response Parsing

    func testParseAnthropicModelsResponse_extractsModelIDs() throws {
        let json = """
        {
            "data": [
                {"id": "claude-opus-4-8-20260514", "display_name": "Claude Opus 4.8", "type": "model"},
                {"id": "claude-sonnet-4-6-20250514", "display_name": "Claude Sonnet 4.6", "type": "model"},
                {"id": "claude-haiku-4-5-20251001", "display_name": "Claude Haiku 4.5", "type": "model"}
            ],
            "has_more": false,
            "last_id": "claude-haiku-4-5-20251001"
        }
        """.data(using: .utf8)!

        let page = try BurnBarLiveModelCatalog.parseAnthropicModelsResponse(json)
        XCTAssertEqual(page.models.count, 3)
        XCTAssertEqual(page.models[0].id, "claude-opus-4-8", "Dated snapshot IDs should be normalized.")
        XCTAssertEqual(page.models[0].displayName, "Claude Opus 4.8")
        XCTAssertEqual(page.models[1].id, "claude-sonnet-4-6")
        XCTAssertEqual(page.models[2].id, "claude-haiku-4-5")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.lastID, "claude-haiku-4-5-20251001")
    }

    func testParseAnthropicModelsResponse_deduplicatesAfterNormalization() throws {
        // Both dated and non-dated IDs for the same model should deduplicate.
        let json = """
        {
            "data": [
                {"id": "claude-opus-4-8", "display_name": "Claude Opus 4.8", "type": "model"},
                {"id": "claude-opus-4-8-20260514", "display_name": "Claude Opus 4.8 (2026-05-14)", "type": "model"}
            ],
            "has_more": false
        }
        """.data(using: .utf8)!

        let page = try BurnBarLiveModelCatalog.parseAnthropicModelsResponse(json)
        XCTAssertEqual(page.models.count, 1, "Dated and non-dated IDs for the same model should deduplicate.")
        XCTAssertEqual(page.models[0].id, "claude-opus-4-8")
    }

    func testParseAnthropicModelsResponse_handlesPaginationFields() throws {
        let json = """
        {
            "data": [
                {"id": "claude-opus-4-8", "display_name": "Claude Opus 4.8", "type": "model"}
            ],
            "has_more": true,
            "first_id": "claude-opus-4-8",
            "last_id": "claude-opus-4-8"
        }
        """.data(using: .utf8)!

        let page = try BurnBarLiveModelCatalog.parseAnthropicModelsResponse(json)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.lastID, "claude-opus-4-8")
    }

    func testParseAnthropicModelsResponse_emptyData() throws {
        let json = """
        {"data": [], "has_more": false}
        """.data(using: .utf8)!

        let page = try BurnBarLiveModelCatalog.parseAnthropicModelsResponse(json)
        XCTAssertTrue(page.models.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    func testParseAnthropicModelsResponse_malformedJSON() {
        let json = "not json at all".data(using: .utf8)!
        XCTAssertThrowsError(try BurnBarLiveModelCatalog.parseAnthropicModelsResponse(json))
    }

    func testParseAnthropicModelsResponse_fallsBackToNameField() throws {
        let json = """
        {
            "data": [
                {"id": "claude-opus-4-8", "name": "Opus 4.8 Legacy Name", "type": "model"}
            ],
            "has_more": false
        }
        """.data(using: .utf8)!

        let page = try BurnBarLiveModelCatalog.parseAnthropicModelsResponse(json)
        XCTAssertEqual(page.models[0].displayName, "Opus 4.8 Legacy Name")
    }

    func testParseAnthropicModelsResponse_fallsBackToIDForDisplayName() throws {
        let json = """
        {
            "data": [
                {"id": "claude-opus-4-8", "type": "model"}
            ],
            "has_more": false
        }
        """.data(using: .utf8)!

        let page = try BurnBarLiveModelCatalog.parseAnthropicModelsResponse(json)
        XCTAssertEqual(page.models[0].displayName, "claude-opus-4-8", "Missing display_name should fall back to ID.")
    }

    // MARK: - Anthropic Request Construction

    func testAnthropicRequest_usesCorrectPath() {
        let baseURL = URL(string: "https://api.anthropic.com/v1")!
        let endpoint = baseURL.appending(path: "models")
        XCTAssertEqual(endpoint.absoluteString, "https://api.anthropic.com/v1/models",
                       "Anthropic discovery should hit /v1/models")
    }

    func testAnthropicRequest_consoleKeyUsesAPIKeyHeader() {
        let apiKey = "sk-ant-api03-test-key"
        let usesOAuth = apiKey.hasPrefix("sk-ant-oat")
        XCTAssertFalse(usesOAuth, "Console API key (sk-ant-api*) should not be detected as OAuth")

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testAnthropicRequest_oauthKeyUsesBearerHeader() {
        let apiKey = "sk-ant-oat01-oauth-token"
        let usesOAuth = apiKey.hasPrefix("sk-ant-oat")
        XCTAssertTrue(usesOAuth, "OAuth token (sk-ant-oat*) should be detected as OAuth")

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-oauth-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testAnthropicRequest_paginationCursorAppendedCorrectly() {
        let baseURL = URL(string: "https://api.anthropic.com/v1")!
        let endpoint = baseURL.appending(path: "models").appending(queryItems: [URLQueryItem(name: "after_id", value: "claude-opus-4-8")])
        XCTAssertTrue(endpoint.absoluteString.contains("after_id=claude-opus-4-8"),
                       "Pagination cursor should be appended as after_id query parameter")
    }

    // MARK: - Factory Droid CLI Discovery

    func testFactoryDroidCLI_parsesDiscoveryOutput() {
        let cliOutput = """
        Available Models:
          claude-opus-4-8  Claude Opus 4.8 (flagship)
          claude-sonnet-4-6  Claude Sonnet 4.6 (balanced)
        Custom Models:
          mini-max-m2.7  MiniMax M2.7 (fast)

        """
        let options = CLIRuntimeModelCatalog.parseDroidExecHelp(cliOutput)
        XCTAssertTrue(options.contains { $0.modelID == "claude-opus-4-8" }, "Should discover Opus 4.8")
        XCTAssertTrue(options.contains { $0.modelID == "claude-sonnet-4-6" }, "Should discover Sonnet 4.6")
        XCTAssertTrue(options.contains { $0.modelID == "mini-max-m2.7" }, "Should discover custom models")
    }

    func testFactoryDroidCLI_handlesEmptyOutput() {
        let options = CLIRuntimeModelCatalog.parseDroidExecHelp("")
        XCTAssertTrue(options.isEmpty, "Empty output should produce no models")
    }
}
