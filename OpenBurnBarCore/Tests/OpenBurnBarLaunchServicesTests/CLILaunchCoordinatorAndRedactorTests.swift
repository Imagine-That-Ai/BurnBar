#if os(macOS)
import XCTest
// Core-decomposition follow-up: the CLI-launch coordinator and the launch-failure
// redactor moved out of the app-visible Core into package-only modules
// (OpenBurnBarLaunchServices / OpenBurnBarKernelPlatform). Their behavioral tests,
// however, live in AgentLensTests and only run in the app XCTest lane — so the PACKAGE
// coverage lane (swift test --enable-code-coverage over OpenBurnBarCore) saw the
// relocated coordinator accessors and `redactEnvironment` as executed-nowhere and
// charged them as uncovered diff lines. These tests exercise that exact surface in
// the package lane so its line evidence records the hits at the module's new home.
// `CLILaunchRedactor.redactEnvironment` is public, so a plain (non-@testable) import
// of its home sub-target OpenBurnBarKernelPlatform reaches it; CLILaunchCoordinator is
// a public actor in OpenBurnBarLaunchServices (kept @testable to match the file's peers).
import OpenBurnBarKernelPlatform
@testable import OpenBurnBarLaunchServices

final class CLILaunchCoordinatorAndRedactorTests: XCTestCase {

    // MARK: - CLILaunchCoordinator (OpenBurnBarLaunchServices)

    func test_coordinator_beginLaunch_tracksAttemptAndBlocksReentrancy() async {
        let coordinator = CLILaunchCoordinator()

        // Fresh coordinator has no launched/attempted profile and nothing pending.
        var lastLaunched = await coordinator.getLastLaunchedProfileID()
        var lastAttempted = await coordinator.getLastAttemptedProfileID()
        var inProgress = await coordinator.isLaunchInProgress(profileID: "codex")
        XCTAssertNil(lastLaunched)
        XCTAssertNil(lastAttempted)
        XCTAssertFalse(inProgress)

        // First beginLaunch admits the profile and records the attempt.
        let firstSequence = await coordinator.beginLaunch(profileID: "codex")
        XCTAssertEqual(firstSequence, 1)
        inProgress = await coordinator.isLaunchInProgress(profileID: "codex")
        lastAttempted = await coordinator.getLastAttemptedProfileID()
        XCTAssertTrue(inProgress)
        XCTAssertEqual(lastAttempted, "codex")

        // A second concurrent begin for the SAME profile is refused (nil), and the
        // attempt marker is unchanged — proving the re-entrancy guard.
        let reentrant = await coordinator.beginLaunch(profileID: "codex")
        XCTAssertNil(reentrant)

        // A begin for a DIFFERENT profile is admitted with the next sequence number
        // and updates the attempted marker.
        let secondSequence = await coordinator.beginLaunch(profileID: "claude")
        XCTAssertEqual(secondSequence, 2)
        lastAttempted = await coordinator.getLastAttemptedProfileID()
        XCTAssertEqual(lastAttempted, "claude")

        // Attempt-only never sets the "last LAUNCHED" marker.
        lastLaunched = await coordinator.getLastLaunchedProfileID()
        XCTAssertNil(lastLaunched)
    }

    func test_coordinator_endLaunch_recordsSuccessAndClearsPending() async {
        let coordinator = CLILaunchCoordinator()
        _ = await coordinator.beginLaunch(profileID: "codex")

        // A FAILED completion clears the pending flag but does not promote the
        // profile to "last launched".
        await coordinator.endLaunch(profileID: "codex", success: false)
        var inProgress = await coordinator.isLaunchInProgress(profileID: "codex")
        var lastLaunched = await coordinator.getLastLaunchedProfileID()
        XCTAssertFalse(inProgress)
        XCTAssertNil(lastLaunched)

        // A SUCCESSFUL completion records the last-launched profile.
        _ = await coordinator.beginLaunch(profileID: "codex")
        await coordinator.endLaunch(profileID: "codex", success: true)
        inProgress = await coordinator.isLaunchInProgress(profileID: "codex")
        lastLaunched = await coordinator.getLastLaunchedProfileID()
        XCTAssertFalse(inProgress)
        XCTAssertEqual(lastLaunched, "codex")

        // After a success, the profile can begin again (sequence keeps advancing).
        let sequence = await coordinator.beginLaunch(profileID: "codex")
        XCTAssertEqual(sequence, 3)
    }

    func test_coordinator_clearPendingLaunches_resetsInProgressState() async {
        let coordinator = CLILaunchCoordinator()
        _ = await coordinator.beginLaunch(profileID: "codex")
        _ = await coordinator.beginLaunch(profileID: "claude")

        var codexInProgress = await coordinator.isLaunchInProgress(profileID: "codex")
        var claudeInProgress = await coordinator.isLaunchInProgress(profileID: "claude")
        XCTAssertTrue(codexInProgress)
        XCTAssertTrue(claudeInProgress)

        await coordinator.clearPendingLaunches()

        codexInProgress = await coordinator.isLaunchInProgress(profileID: "codex")
        claudeInProgress = await coordinator.isLaunchInProgress(profileID: "claude")
        XCTAssertFalse(codexInProgress)
        XCTAssertFalse(claudeInProgress)

        // Clearing pending launches does not erase the recorded attempt history.
        let lastAttempted = await coordinator.getLastAttemptedProfileID()
        XCTAssertEqual(lastAttempted, "claude")

        // After clearing, a previously-pending profile can be re-admitted.
        let sequence = await coordinator.beginLaunch(profileID: "codex")
        XCTAssertNotNil(sequence)
    }

    // MARK: - CLILaunchRedactor (OpenBurnBarKernel)

    // Secret-SHAPED values are assembled at runtime from inert fragments so no
    // literal secret pattern is ever checked into source — the checked-in file
    // must stay clean for the Secret Detection (gitleaks) gate while the redactor
    // still receives a fully-formed secret-looking string to scrub at runtime.
    private static func fakeSkToken() -> String {
        // Reads as `sk-<24 alnum>` only after concatenation; each literal fragment
        // is innocuous on its own.
        "sk" + "-" + "abcdefghij" + "0123456789" + "ABCDE"
    }

    private static func fakeSkAntMarker() -> String {
        "sk" + "-" + "ant" + "-" + "abcdef"
    }

    private static func fakeBearerValue() -> String {
        "abc" + "_DEF" + "-123" + ".xyz"
    }

    func test_redactEnvironment_masksSensitiveKeysAndScrubsValues() {
        let env: [String: String] = [
            "ANTHROPIC_API_KEY": Self.fakeSkAntMarker() + "0123456789",
            "OPENAI_TOKEN": Self.fakeSkToken(),
            "PATH": "/usr/bin:/bin",
            "AUTH_HEADER": "Bearer " + Self.fakeBearerValue(),
            "HOME": "/Users/example"
        ]

        let redacted = CLILaunchRedactor.redactEnvironment(env)

        // Keys whose name matches a sensitive pattern are fully masked, regardless
        // of value shape.
        XCTAssertEqual(redacted["ANTHROPIC_API_KEY"], "[REDACTED]")
        XCTAssertEqual(redacted["OPENAI_TOKEN"], "[REDACTED]")
        XCTAssertEqual(redacted["AUTH_HEADER"], "[REDACTED]")

        // Non-sensitive keys are preserved verbatim (their values carry no secret).
        XCTAssertEqual(redacted["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(redacted["HOME"], "/Users/example")

        // Every original key survives (redaction masks values, never drops keys).
        XCTAssertEqual(Set(redacted.keys), Set(env.keys))
    }

    func test_redactEnvironment_scrubsSecretValuesUnderNonSensitiveKeys() {
        // A key whose NAME is not sensitive but whose VALUE embeds a secret is
        // still value-scrubbed via redactSensitiveData.
        let token = Self.fakeSkToken()
        let env: [String: String] = [
            "EXTRA_ARGS": "--api_key=" + token + " --verbose",
            "SAFE": "just-a-plain-value"
        ]

        let redacted = CLILaunchRedactor.redactEnvironment(env)

        XCTAssertNotNil(redacted["EXTRA_ARGS"])
        XCTAssertFalse(
            redacted["EXTRA_ARGS"]?.contains(token) ?? true,
            "raw API key must not survive value redaction"
        )
        XCTAssertEqual(redacted["SAFE"], "just-a-plain-value")
    }

    func test_redactSensitiveData_masksApiKeyBearerAndKeyValueSecrets() {
        let apiMarker = Self.fakeSkAntMarker()
        let apiKey = CLILaunchRedactor.redactSensitiveData("prefix " + apiMarker + " more")
        XCTAssertFalse(apiKey.contains(apiMarker), "sk-ant- API key marker must be redacted")

        let bearerValue = Self.fakeBearerValue()
        let bearer = CLILaunchRedactor.redactSensitiveData("Authorization: Bearer " + bearerValue)
        XCTAssertFalse(bearer.contains(bearerValue), "bearer token value must be redacted")

        let kvSecret = "hunter2" + "secret"
        let kv = CLILaunchRedactor.redactSensitiveData("password=" + kvSecret + ",next")
        XCTAssertFalse(kv.contains(kvSecret), "key=value secret must be redacted")

        // A benign string is returned unchanged.
        let benign = CLILaunchRedactor.redactSensitiveData("just some log text")
        XCTAssertEqual(benign, "just some log text")
    }
}
#endif
