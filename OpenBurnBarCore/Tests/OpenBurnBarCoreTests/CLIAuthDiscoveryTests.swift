import XCTest
@testable import OpenBurnBarCore

final class CLIAuthDiscoveryTests: XCTestCase {
    func test_formattedAccountDescription_prefersNameAndEmail() {
        XCTAssertEqual(
            CLIAuthDiscovery.formattedAccountDescription(
                name: "Alberto Nunez-Garcia",
                email: "alberto8793@gmail.com"
            ),
            "Alberto Nunez-Garcia • alberto8793@gmail.com"
        )
    }

    func test_parseJWTClaims_decodesBase64URLPayload() throws {
        let payload = #"{"name":"Alberto Nunez-Garcia","email":"alberto8793@gmail.com"}"#
        let payloadData = try XCTUnwrap(payload.data(using: .utf8))
        let encoded = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(encoded).signature"

        let claims = try XCTUnwrap(CLIAuthDiscovery.parseJWTClaims(from: token))
        XCTAssertEqual(claims["name"] as? String, "Alberto Nunez-Garcia")
        XCTAssertEqual(claims["email"] as? String, "alberto8793@gmail.com")
    }

    func test_extractClaudeAccountDescription_prefersEmail() {
        let json = """
        {
          "loggedIn": true,
          "email": "alberto8793@icloud.com",
          "orgName": "Example Org"
        }
        """

        let value = CLIAuthDiscovery.extractClaudeAccountDescription(
            fromStatusJSONData: Data(json.utf8)
        )

        XCTAssertEqual(value, "alberto8793@icloud.com")
    }

    func test_claudeStatusEnvironment_usesConfigDirForScopedProfiles() {
        let scopedPath = "/tmp/openburnbar-scoped-claude"
        let environment = CLIAuthDiscovery.claudeStatusEnvironment(configDirectory: scopedPath)

        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], scopedPath)
        XCTAssertEqual(environment["CLAUDE_CONFIG_PATH"], scopedPath)
    }
}
