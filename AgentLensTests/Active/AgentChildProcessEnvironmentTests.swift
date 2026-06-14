import Foundation
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// M-040 — the environment AgentLens hands to the child processes that execute
/// agents (per-CLI agents + the broker's restricted `shell_run` and unrestricted
/// YOLO `shell_run_unrestricted` shells) is built from an ALLOWLISTED baseline,
/// NOT the full ambient parent process environment. This stops app/daemon-held
/// secrets (OpenBurnBar gateway/socket tokens, AWS creds, arbitrary ambient
/// vars) from leaking into the trusted-agent CLI and the unrestricted shell,
/// while preserving the env an agent legitimately needs to run.
///
/// Mirrors the SwitcherCLILaunch env tests (`buildAllowlistedBaselineEnvironment`
/// / `filterAllowlistedEnvironment`).
final class AgentChildProcessEnvironmentTests: XCTestCase {

    /// An ambient env that mixes (a) what an agent legitimately needs, (b) the
    /// app/daemon-internal secrets that MUST be stripped, and (c) arbitrary
    /// unrelated secrets that MUST be stripped.
    private func mixedAmbientEnvironment() -> [String: String] {
        [
            // (a) required runtime env — must be PRESENT
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/probe",
            "USER": "probe",
            "LOGNAME": "probe",
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
            "TMPDIR": "/var/folders/tmp",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8",
            // (a) provider/API-key env the user intends the agent to use — PRESENT
            "ANTHROPIC_API_KEY": "anthropic_required_placeholder",
            "OPENAI_API_KEY": "openai_required_placeholder",
            // (b) app/daemon-INTERNAL secrets — must be ABSENT
            "OPENBURNBAR_DAEMON_TOKEN": "daemon-internal-secret",
            "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "socket-internal-secret",
            "OPENBURNBAR_GATEWAY_AUTH_TOKEN": "gateway-internal-secret",
            "OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN": "firebase-internal-secret",
            // (c) arbitrary ambient secrets — must be ABSENT
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "GITHUB_TOKEN": "ghp_secret",
            "SOME_RANDOM_AMBIENT_VAR": "junk"
        ]
    }

    // MARK: - allowlistedBaseline directly

    func test_allowlistedBaseline_stripsAppDaemonAndArbitrarySecrets() {
        let env = AgentChildProcessEnvironment.allowlistedBaseline(baseEnv: mixedAmbientEnvironment())

        // (b) app/daemon-internal secrets are stripped.
        XCTAssertNil(env["OPENBURNBAR_DAEMON_TOKEN"], "daemon-internal token must not leak to agent shells")
        XCTAssertNil(env["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"], "daemon socket auth token must not leak")
        XCTAssertNil(env["OPENBURNBAR_GATEWAY_AUTH_TOKEN"], "gateway auth token must not leak")
        XCTAssertNil(env["OPENBURNBAR_E2E_FIREBASE_CUSTOM_TOKEN"], "firebase custom token must not leak")
        // (c) arbitrary ambient secrets are stripped.
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"], "arbitrary ambient secret must not leak")
        XCTAssertNil(env["GITHUB_TOKEN"], "arbitrary ambient secret must not leak")
        XCTAssertNil(env["SOME_RANDOM_AMBIENT_VAR"], "arbitrary ambient var must not leak")
    }

    func test_allowlistedBaseline_preservesRequiredRuntimeEnv() {
        let env = AgentChildProcessEnvironment.allowlistedBaseline(baseEnv: mixedAmbientEnvironment())

        // (a) required runtime env is preserved with its values intact.
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(env["HOME"], "/Users/probe")
        XCTAssertEqual(env["USER"], "probe")
        XCTAssertEqual(env["SHELL"], "/bin/zsh")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["TMPDIR"], "/var/folders/tmp")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(env["LC_CTYPE"], "en_US.UTF-8", "LC_* locale vars must be allowlisted by prefix")
    }

    func test_allowlistedBaseline_preservesProviderApiKeysAgentNeeds() {
        let env = AgentChildProcessEnvironment.allowlistedBaseline(baseEnv: mixedAmbientEnvironment())

        // (a) provider/API-key env the agent reads from ambient to authenticate.
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "anthropic_required_placeholder")
        XCTAssertEqual(env["OPENAI_API_KEY"], "openai_required_placeholder")
    }

    func test_isAllowlisted_classification() {
        // Required runtime + provider keys are allowlisted.
        XCTAssertTrue(AgentChildProcessEnvironment.isAllowlisted("PATH"))
        XCTAssertTrue(AgentChildProcessEnvironment.isAllowlisted("HOME"))
        XCTAssertTrue(AgentChildProcessEnvironment.isAllowlisted("ANTHROPIC_API_KEY"))
        XCTAssertTrue(AgentChildProcessEnvironment.isAllowlisted("OPENAI_API_KEY"))
        XCTAssertTrue(AgentChildProcessEnvironment.isAllowlisted("LC_NUMERIC"), "LC_* allowed by prefix")

        // App/daemon-internal + arbitrary secrets are NOT allowlisted.
        XCTAssertFalse(AgentChildProcessEnvironment.isAllowlisted("OPENBURNBAR_DAEMON_TOKEN"))
        XCTAssertFalse(AgentChildProcessEnvironment.isAllowlisted("OPENBURNBAR_GATEWAY_AUTH_TOKEN"))
        XCTAssertFalse(AgentChildProcessEnvironment.isAllowlisted("AWS_SECRET_ACCESS_KEY"))
        XCTAssertFalse(AgentChildProcessEnvironment.isAllowlisted("GITHUB_TOKEN"))
    }

    // MARK: - enrichedProcessEnvironment (per-CLI + CLIProcessStreamRunner path)

    func test_enrichedProcessEnvironment_stripsSecretsAndKeepsRequiredEnv() {
        let env = CLIExecutableResolver.enrichedProcessEnvironment(
            executablePath: "/opt/homebrew/bin/claude",
            baseEnv: mixedAmbientEnvironment()
        )

        // (b)/(c) secrets stripped.
        XCTAssertNil(env["OPENBURNBAR_DAEMON_TOKEN"])
        XCTAssertNil(env["OPENBURNBAR_GATEWAY_AUTH_TOKEN"])
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(env["GITHUB_TOKEN"])

        // (a) required env present; provider API key the agent needs present.
        XCTAssertNotNil(env["PATH"])
        XCTAssertEqual(env["HOME"], "/Users/probe")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "anthropic_required_placeholder")

        // The enriched-PATH logic still runs: the executable's directory and the
        // standard bin dirs are prepended to PATH.
        let path = try? XCTUnwrap(env["PATH"])
        XCTAssertEqual((path ?? "").contains("/opt/homebrew/bin"), true)
        XCTAssertEqual((path ?? "").contains("/usr/bin"), true)
    }

    func test_enrichedProcessEnvironment_everyKeyIsAllowlisted() {
        let env = CLIExecutableResolver.enrichedProcessEnvironment(
            executablePath: nil,
            baseEnv: mixedAmbientEnvironment()
        )
        for key in env.keys {
            XCTAssertTrue(
                AgentChildProcessEnvironment.isAllowlisted(key),
                "enriched env key '\(key)' is not allowlisted — possible ambient leak"
            )
        }
    }
}
