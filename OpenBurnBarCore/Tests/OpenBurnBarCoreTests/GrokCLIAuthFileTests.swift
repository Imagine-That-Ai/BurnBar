import XCTest
@testable import OpenBurnBarKernel

final class GrokCLIAuthFileTests: XCTestCase {
    func testInspect_rejectsEmptyObjectAndMissingKey() {
        XCTAssertNil(GrokCLIAuthFile.inspect(Data(#"{}"#.utf8)))
        XCTAssertNil(GrokCLIAuthFile.inspect(Data(#"{"https://auth.x.ai::test-client":{}}"#.utf8)))
        XCTAssertNil(GrokCLIAuthFile.inspect(Data(#"{"https://auth.x.ai::test-client":{"key":"   "}}"#.utf8)))
        XCTAssertNil(GrokCLIAuthFile.inspect(Data("not-json".utf8)))
    }

    func testInspect_oauthScopeUsesEmailWithoutExposingToken() throws {
        let json = """
        {
          "https://auth.x.ai::test-client": {
            "key": "opaque-access-token",
            "refresh_token": "opaque-refresh",
            "auth_mode": "oidc",
            "email": "emilio@example.com",
            "first_name": "Emilio",
            "last_name": "Tester",
            "expires_at": "2026-12-01T00:00:00Z"
          }
        }
        """
        let summary = try XCTUnwrap(GrokCLIAuthFile.inspect(Data(json.utf8)))
        XCTAssertEqual(summary.kind, .oauthSession)
        XCTAssertEqual(summary.accountDescription, "Emilio Tester • emilio@example.com")
        XCTAssertNotNil(summary.expiresAt)
        let dumped = String(describing: summary)
        XCTAssertFalse(dumped.contains("opaque-access-token"))
        XCTAssertFalse(dumped.contains("opaque-refresh"))
    }

    func testInspect_prefersCurrentIssuerOverLegacySignIn() throws {
        let json = """
        {
          "https://accounts.x.ai/sign-in": {
            "key": "legacy-token",
            "auth_mode": "web_login",
            "email": "legacy@example.com"
          },
          "https://auth.x.ai::test-client": {
            "key": "current-token",
            "auth_mode": "oidc",
            "email": "current@example.com"
          }
        }
        """
        let summary = try XCTUnwrap(GrokCLIAuthFile.inspect(Data(json.utf8)))
        XCTAssertEqual(summary.kind, .oauthSession)
        XCTAssertEqual(summary.accountDescription, "current@example.com")
    }

    func testInspect_apiKeyScopeIsNotAnOAuthSession() throws {
        let json = """
        {
          "xai::api_key": {
            "key": "xai-test-inference",
            "auth_mode": "api_key"
          }
        }
        """
        let summary = try XCTUnwrap(GrokCLIAuthFile.inspect(Data(json.utf8)))
        XCTAssertEqual(summary.kind, .apiKey)
        XCTAssertEqual(summary.accountDescription, "Grok CLI API key")
    }

    func testInspect_prefersOAuthWhenBothApiKeyAndSessionExist() throws {
        let json = """
        {
          "xai::api_key": {
            "key": "xai-test-inference",
            "auth_mode": "api_key"
          },
          "https://auth.x.ai::test-client": {
            "key": "session-token",
            "auth_mode": "oidc",
            "email": "session@example.com"
          }
        }
        """
        let summary = try XCTUnwrap(GrokCLIAuthFile.inspect(Data(json.utf8)))
        XCTAssertEqual(summary.kind, .oauthSession)
        XCTAssertEqual(summary.accountDescription, "session@example.com")
    }

    func testInspect_fileAtURLReadsAuthJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-grok-auth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("auth.json")
        try #"{ "xai::api_key": { "key": "xai-file", "auth_mode": "api_key" } }"#
            .write(to: url, atomically: true, encoding: .utf8)

        let summary = try XCTUnwrap(GrokCLIAuthFile.inspect(fileAt: url))
        XCTAssertEqual(summary.kind, .apiKey)
        XCTAssertNil(GrokCLIAuthFile.inspect(fileAt: root.appendingPathComponent("missing.json")))
    }
}
