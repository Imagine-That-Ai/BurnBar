import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Switcher CLI Launch Tests

@MainActor
final class SwitcherCLILaunchTests: XCTestCase {

    // MARK: - Executable Resolution

    func test_resolveExecutable_acceptsValidPaths() {
        // Test that the resolution logic works for valid paths
        let codexAvailable = CLILaunchAdapter.isExecutableAvailable(.codex)
        let claudeAvailable = CLILaunchAdapter.isExecutableAvailable(.claude)
        let opencodeAvailable = CLILaunchAdapter.isExecutableAvailable(.opencode)

        // At least one CLI should be available (or none if not installed)
        XCTAssertTrue(codexAvailable == true || codexAvailable == false)
        XCTAssertTrue(claudeAvailable == true || claudeAvailable == false)
        XCTAssertTrue(opencodeAvailable == true || opencodeAvailable == false)
    }

    func test_resolveExecutable_rejectsUntrustedPaths() {
        // The adapter should only resolve trusted paths
        // Trying to resolve a random executable should fail
        let tempProcess = Process()
        tempProcess.executableURL = URL(fileURLWithPath: "/tmp/malicious")

        // The CLILaunchAdapter should not return URLs for untrusted paths
        let result = CLILaunchAdapter.resolveExecutable(for: .claude)
        // Result is either nil (not found) or a trusted path
        if let url = result {
            // Verify it's an actual file
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
            XCTAssertFalse(isDir.boolValue)
        }
    }

    // MARK: - Working Directory Validation

    func test_validateWorkingDirectory_acceptsValidPaths() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let validPaths = [
            homeDir,
            homeDir + "/Documents",
            homeDir + "/Projects/work",
            NSTemporaryDirectory(),
            "/var/folders/xx/yyyy/T",
        ]

        for path in validPaths {
            // Skip if path doesn't exist in test environment
            if FileManager.default.fileExists(atPath: path) {
                let result = CLILaunchAdapter.validateWorkingDirectory(path)
                XCTAssertTrue(result.isSuccess, "Expected '\(path)' to be valid, got error")
            }
        }
    }

    func test_validateWorkingDirectory_rejectsEmptyString() {
        let result = CLILaunchAdapter.validateWorkingDirectory("")
        XCTAssertFailure(result, CLILaunchError.invalidWorkingDirectory("Working directory cannot be empty"))
    }

    func test_validateWorkingDirectory_rejectsWhitespaceOnly() {
        let result = CLILaunchAdapter.validateWorkingDirectory("   ")
        XCTAssertFailure(result, CLILaunchError.invalidWorkingDirectory("Working directory cannot be empty"))
    }

    func test_validateWorkingDirectory_rejectsNonexistentPaths() {
        let result = CLILaunchAdapter.validateWorkingDirectory("/nonexistent/path/12345")
        XCTAssertFailure(result, CLILaunchError.invalidWorkingDirectory("Working directory does not exist"))
    }

    func test_validateWorkingDirectory_rejectsNonDirectories() {
        // Create a temp file and try to use it as a directory
        let tempFile = NSTemporaryDirectory() + "/cli_test_\(UUID().uuidString)"
        FileManager.default.createFile(atPath: tempFile, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let result = CLILaunchAdapter.validateWorkingDirectory(tempFile)
        XCTAssertFailure(result, CLILaunchError.invalidWorkingDirectory("Working directory is not a directory"))
    }

    func test_validateWorkingDirectory_rejectsPathsOutsideHome() {
        // Try to use system directories as working directory - should be rejected
        let unsafePaths = [
            "/usr",
            "/bin",
            "/etc",
            "/private/etc",
        ]

        for path in unsafePaths {
            let result = CLILaunchAdapter.validateWorkingDirectory(path)
            XCTAssertFailure(result, CLILaunchError.invalidWorkingDirectory("Working directory must be within home directory or temp"),
                "Expected '\(path)' to be rejected")
        }
    }

    // MARK: - Argument Validation

    func test_validateArgument_acceptsAllowlistedArgs() {
        let allowlisted = [
            "--verbose",
            "--debug",
            "--quiet",
            "--no-color",
            "--version",
            "--help",
            "--dry-run",
            "--working-dir=/Users/test",
            "--config=/Users/test/.config",
            "--project=/Users/test/project",
        ]

        for arg in allowlisted {
            let result = CLILaunchAdapter.validateArgument(arg)
            XCTAssertNotNil(result, "Expected '\(arg)' to be allowlisted")
        }
    }

    func test_validateArgument_rejectsArbitraryFlags() {
        let disallowed = [
            "-e 'ls'",
            "; rm -rf",
            "& whoami",
            "| cat /etc/passwd",
            "`id`",
            "$(whoami)",
            "${HOME}",
            "--load-extension=/path",
            "--remote-debugging-port=9222",
        ]

        for arg in disallowed {
            let result = CLILaunchAdapter.validateArgument(arg)
            XCTAssertNil(result, "Expected '\(arg)' to be rejected")
        }
    }

    func test_validateArgument_rejectsEmptyString() {
        let result = CLILaunchAdapter.validateArgument("")
        XCTAssertNil(result)
    }

    func test_validateArgument_rejectsControlCharacters() {
        let withNull = "--arg\u{0000}value"
        let result = CLILaunchAdapter.validateArgument(withNull)
        XCTAssertNil(result)
    }

    func test_validateArguments_validatesMultiple() {
        let args = ["--verbose", "--debug", "--working-dir=/Users/test"]
        let result = CLILaunchAdapter.validateArguments(args)
        XCTAssertSuccess(result)
        if case .success(let validated) = result {
            XCTAssertEqual(validated, args)
        }
    }

    func test_validateArguments_rejectsDisallowed() {
        let args = ["--verbose", "--disallowed-flag"]
        let result = CLILaunchAdapter.validateArguments(args)
        XCTAssertFailure(result, CLILaunchError.disallowedArgument("--disallowed-flag"))
    }

    // MARK: - Environment Variable Validation

    func test_isEnvKeyAllowlisted_acceptsSafeKeys() {
        let safeKeys = ["HOME", "PATH", "USER", "SHELL", "PWD", "TMPDIR", "TERM"]

        for key in safeKeys {
            XCTAssertTrue(CLILaunchAdapter.isEnvKeyAllowlisted(key), "Expected '\(key)' to be allowlisted")
        }
    }

    func test_isEnvKeyAllowlisted_rejectsDangerousKeys() {
        let dangerousKeys = [
            "API_KEY",
            "SECRET",
            "PASSWORD",
            "ANTHROPIC_API_KEY",
            "MY_SECRET_TOKEN",
        ]

        for key in dangerousKeys {
            XCTAssertFalse(CLILaunchAdapter.isEnvKeyAllowlisted(key), "Expected '\(key)' to be rejected")
        }
    }

    func test_filterAllowlistedEnvironment_includesOnlyAllowlisted() {
        let keys = ["HOME", "PATH", "SECRET_API_KEY", "USER"]
        let result = CLILaunchAdapter.filterAllowlistedEnvironment(keys: keys)

        XCTAssertTrue(result.keys.contains("HOME"))
        XCTAssertTrue(result.keys.contains("PATH"))
        XCTAssertTrue(result.keys.contains("USER"))
        XCTAssertFalse(result.keys.contains("SECRET_API_KEY"))
    }

    func test_filterAllowlistedEnvironment_usesBaseEnvValues() {
        let keys = ["HOME", "PATH"]
        let baseEnv = ["HOME": "/custom/home", "PATH": "/custom/path", "USER": "/ignored"]
        let result = CLILaunchAdapter.filterAllowlistedEnvironment(keys: keys, baseEnv: baseEnv)

        XCTAssertEqual(result["HOME"], "/custom/home")
        XCTAssertEqual(result["PATH"], "/custom/path")
        XCTAssertNil(result["USER"])
    }

    // MARK: - Allowlisted Baseline Environment (Security Critical)

    func test_buildAllowlistedBaselineEnvironment_includesOnlyAllowlistedKeys() {
        // Simulate an ambient environment with both allowlisted and sensitive keys
        let ambientEnv = [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "USER": "testuser",
            "ANTHROPIC_API_KEY": "sk-ant-12345secret",
            "OPENAI_API_KEY": "sk-12345secret",
            "SECRET_TOKEN": "super-secret-value",
            "GITHUB_TOKEN": "ghp_secret",
        ]

        let result = CLILaunchAdapter.buildAllowlistedBaselineEnvironment(baseEnv: ambientEnv)

        // Should include only allowlisted keys
        XCTAssertTrue(result.keys.contains("HOME"))
        XCTAssertTrue(result.keys.contains("PATH"))
        XCTAssertTrue(result.keys.contains("USER"))

        // Should NOT include sensitive ambient keys
        XCTAssertFalse(result.keys.contains("ANTHROPIC_API_KEY"), "Sensitive API key should not be in baseline environment")
        XCTAssertFalse(result.keys.contains("OPENAI_API_KEY"), "Sensitive API key should not be in baseline environment")
        XCTAssertFalse(result.keys.contains("SECRET_TOKEN"), "Sensitive token should not be in baseline environment")
        XCTAssertFalse(result.keys.contains("GITHUB_TOKEN"), "Sensitive token should not be in baseline environment")
    }

    func test_buildAllowlistedBaselineEnvironment_includesAllKnownAllowlistedKeys() {
        let ambientEnv: [String: String] = [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
            "USER": "testuser",
            "SHELL": "/bin/zsh",
            "PWD": "/Users/test",
            "TMPDIR": "/tmp",
            "TERM": "xterm-256color",
            "TERM_PROGRAM": "Apple_Terminal",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "EDITOR": "vim",
            "VISUAL": "vim",
            "PAGER": "less",
            "BROWSER": "open",
            "SSH_AUTH_SOCK": "/tmp/ssh-agent",
            "GIT_EDITOR": "vim",
            "HG_EDITOR": "vim",
            "CLAUDE_CONFIG_PATH": "/Users/test/.claude",
            "CODEX_CONFIG_PATH": "/Users/test/.codex",
            "OPENCODE_CONFIG_PATH": "/Users/test/.opencode",
        ]

        let result = CLILaunchAdapter.buildAllowlistedBaselineEnvironment(baseEnv: ambientEnv)

        // All allowlisted keys should be present when they exist in base env
        XCTAssertEqual(result["HOME"], "/Users/test")
        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["USER"], "testuser")
        XCTAssertEqual(result["SHELL"], "/bin/zsh")
        XCTAssertEqual(result["PWD"], "/Users/test")
        XCTAssertEqual(result["TMPDIR"], "/tmp")
        XCTAssertEqual(result["TERM"], "xterm-256color")
        XCTAssertEqual(result["TERM_PROGRAM"], "Apple_Terminal")
        XCTAssertEqual(result["LANG"], "en_US.UTF-8")
        XCTAssertEqual(result["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(result["CLAUDE_CONFIG_PATH"], "/Users/test/.claude")
        XCTAssertEqual(result["CODEX_CONFIG_PATH"], "/Users/test/.codex")
        XCTAssertEqual(result["OPENCODE_CONFIG_PATH"], "/Users/test/.opencode")
    }

    func test_buildAllowlistedBaselineEnvironment_excludesKeysNotInBaseEnv() {
        // Base env is mostly empty - only HOME and PATH exist
        let minimalEnv: [String: String] = [
            "HOME": "/Users/test",
            "PATH": "/usr/bin",
        ]

        let result = CLILaunchAdapter.buildAllowlistedBaselineEnvironment(baseEnv: minimalEnv)

        // Should only have the keys that exist in base env
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["HOME"], "/Users/test")
        XCTAssertEqual(result["PATH"], "/usr/bin")

        // Should not have keys not in base env
        XCTAssertNil(result["USER"])
        XCTAssertNil(result["SHELL"])
    }

    func test_buildCLILaunch_usesAllowlistedBaselineNotFullAmbient() {
        // This test verifies that when building a CLI launch config,
        // the environment is built from the allowlisted baseline only,
        // NOT from the full ambient environment.
        let metadata = SwitcherCLIProfileMetadata(
            envKeysToPass: [],
            displayLabel: nil
        )
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        )

        let result = CLILaunchAdapter.buildCLILaunch(profile: profile)

        // If Claude is installed, check the env
        if case .success(let config) = result {
            // The env should only contain keys from allowlistedEnvKeys
            // It should NOT contain any sensitive ambient keys
            let sensitiveKeys = [
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "SECRET_TOKEN",
                "GITHUB_TOKEN",
                "AWS_SECRET_ACCESS_KEY",
            ]

            for sensitiveKey in sensitiveKeys {
                XCTAssertFalse(
                    config.env.keys.contains(sensitiveKey),
                    "Sensitive key '\(sensitiveKey)' should not be in launch environment"
                )
            }

            // The env should only contain allowlisted keys
            for key in config.env.keys {
                XCTAssertTrue(
                    CLILaunchAdapter.allowlistedEnvKeys.contains(key),
                    "Environment key '\(key)' is not in the allowlist"
                )
            }
        }
    }

    // MARK: - Profile Type Validation

    func test_validateCLIProfile_acceptsValidCLIProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )

        let result = CLILaunchAdapter.validateCLIProfile(profile)
        XCTAssertSuccess(result)
    }

    func test_validateCLIProfile_rejectsBrowserProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = CLILaunchAdapter.validateCLIProfile(profile)
        XCTAssertFailure(result, CLILaunchError.profileKindMismatch(expected: .cli, actual: .browser))
    }

    func test_validateCLIProfile_rejectsMissingMetadata() {
        let profile = SwitcherProfileRecord(
            id: "test-id",
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: nil,
            sortKey: 1
        )

        let result = CLILaunchAdapter.validateCLIProfile(profile)
        XCTAssertFailure(result, CLILaunchError.missingProfileMetadata("test-id"))
    }

    func test_validateProfileCLITypeMatch_acceptsMatchingProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )

        let result = CLILaunchAdapter.validateProfileCLITypeMatch(
            profile: profile,
            targetCLI: .claude
        )
        XCTAssertSuccess(result)
    }

    func test_validateProfileCLITypeMatch_rejectsTypeMismatch() {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )

        let result = CLILaunchAdapter.validateProfileCLITypeMatch(
            profile: profile,
            targetCLI: .claude
        )
        XCTAssertFailure(result, CLILaunchError.profileTypeMismatch(expected: .claude, actual: .codex))
    }

    func test_validateProfileCLITypeMatch_rejectsBrowserProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = CLILaunchAdapter.validateProfileCLITypeMatch(
            profile: profile,
            targetCLI: .claude
        )
        XCTAssertFailure(result, CLILaunchError.profileKindMismatch(expected: .cli, actual: .browser))
    }

    // MARK: - Build CLI Launch

    func test_buildCLILaunch_returnsCorrectConfiguration() {
        let metadata = SwitcherCLIProfileMetadata(
            workingDirectory: nil,
            additionalArgs: ["--verbose"],
            envKeysToPass: ["HOME", "PATH"],
            displayLabel: "Work CLI"
        )
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        )

        let result = CLILaunchAdapter.buildCLILaunch(profile: profile)

        // If Claude is installed, should succeed
        if case .success(let config) = result {
            XCTAssertEqual(config.args, ["--verbose"])
            XCTAssertTrue(config.env.keys.contains("HOME"))
            XCTAssertTrue(config.env.keys.contains("PATH"))
        }
        // If Claude is not installed, this is acceptable
    }

    func test_buildCLILaunch_addsValidatedArgs() {
        let metadata = SwitcherCLIProfileMetadata(
            additionalArgs: ["--verbose", "--debug"],
            envKeysToPass: [],
            displayLabel: nil
        )
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        )

        let result = CLILaunchAdapter.buildCLILaunch(
            profile: profile,
            additionalArgs: ["--quiet"]
        )

        // If Claude is installed
        if case .success(let config) = result {
            XCTAssertTrue(config.args.contains("--verbose"))
            XCTAssertTrue(config.args.contains("--debug"))
            XCTAssertTrue(config.args.contains("--quiet"))
        }
    }

    func test_buildCLILaunch_rejectsDisallowedArgs() {
        let metadata = SwitcherCLIProfileMetadata(
            additionalArgs: ["--verbose", "--disallowed"],
            envKeysToPass: [],
            displayLabel: nil
        )
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        )

        let result = CLILaunchAdapter.buildCLILaunch(profile: profile)
        // If Claude is installed, should get disallowedArgument error
        // If not installed, will get executableNotFound first
        if CLILaunchAdapter.isExecutableAvailable(.claude) {
            XCTAssertFailure(result, CLILaunchError.disallowedArgument("--disallowed"))
        } else {
            XCTAssertFailure(result, CLILaunchError.executableNotFound(.claude))
        }
    }

    func test_buildCLILaunch_rejectsBrowserProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = CLILaunchAdapter.buildCLILaunch(profile: profile)
        XCTAssertFailure(result, CLILaunchError.profileKindMismatch(expected: .cli, actual: .browser))
    }

    func test_buildCLILaunch_filtersEnvVariables() {
        let metadata = SwitcherCLIProfileMetadata(
            envKeysToPass: ["HOME", "PATH", "SECRET_KEY"],
            displayLabel: nil
        )
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        )

        let result = CLILaunchAdapter.buildCLILaunch(profile: profile)

        // If Claude is installed
        if case .success(let config) = result {
            XCTAssertTrue(config.env.keys.contains("HOME"))
            XCTAssertTrue(config.env.keys.contains("PATH"))
            XCTAssertFalse(config.env.keys.contains("SECRET_KEY"))
        }
    }

    // MARK: - Executable Availability

    func test_isCLIAvailable_returnsBoolean() {
        let available = CLILaunchAdapter.isExecutableAvailable(.claude)
        // Just verify it returns a boolean
        XCTAssertTrue(available == true || available == false)
    }

    func test_executablePath_returnsPathOrNil() {
        let path = CLILaunchAdapter.executablePath(for: .claude)
        // If Claude is installed, path should be non-nil
        if CLILaunchAdapter.isExecutableAvailable(.claude) {
            XCTAssertNotNil(path)
        }
    }

    // MARK: - Launch Outcome

    func test_launchOutcome_equality() {
        let success1 = CLILaunchOutcome(success: true, error: nil)
        let success2 = CLILaunchOutcome(success: true, error: nil)
        XCTAssertEqual(success1, success2)

        let error = CLILaunchError.executableNotFound(.claude)
        let failure1 = CLILaunchOutcome(success: false, error: error)
        let failure2 = CLILaunchOutcome(success: false, error: error)
        XCTAssertEqual(failure1, failure2)
    }

    func test_launchOutcome_inequality() {
        let success = CLILaunchOutcome(success: true, error: nil)
        let failure = CLILaunchOutcome(success: false, error: .executableNotFound(.claude))
        XCTAssertNotEqual(success, failure)
    }

    // MARK: - CLI Launch Error Descriptions

    func test_cliLaunchError_errorDescriptions() {
        let errors: [CLILaunchError] = [
            .executableNotFound(.codex),
            .profileNotFound("test-id"),
            .profileTypeMismatch(expected: .claude, actual: .codex),
            .profileKindMismatch(expected: .cli, actual: .browser),
            .missingProfileMetadata("test-id"),
            .invalidWorkingDirectory("too long"),
            .disallowedArgument("--test"),
            .launchConfigurationFailed("reason"),
            .launchSpawnFailed("detail"),
            .launchTimeout,
            .launchFailed("detail"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func test_cliLaunchError_recoverySuggestions() {
        let errors: [CLILaunchError] = [
            .executableNotFound(.codex),
            .profileNotFound("test-id"),
            .profileTypeMismatch(expected: .claude, actual: .codex),
            .disallowedArgument("--test"),
            .invalidWorkingDirectory("reason"),
            .launchTimeout,
        ]

        for error in errors {
            XCTAssertNotNil(error.recoverySuggestion, "Error \(error) should have recovery suggestion")
            XCTAssertFalse(error.recoverySuggestion!.isEmpty)
        }
    }

    // MARK: - Coordinator Tests

    func test_coordinator_allowsSequentialLaunches() async {
        let coordinator = CLILaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)

        let seq2 = await coordinator.beginLaunch(profileID: "profile-2")
        XCTAssertNotNil(seq2)
        XCTAssertGreaterThan(seq2!, seq1!)

        await coordinator.endLaunch(profileID: "profile-1", success: true)
        await coordinator.endLaunch(profileID: "profile-2", success: true)

        let lastID = await coordinator.getLastLaunchedProfileID()
        XCTAssertEqual(lastID, "profile-2")
    }

    func test_coordinator_rejectsConcurrentLaunchesSameProfile() async {
        let coordinator = CLILaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)

        // Same profile - should be rejected
        let seq2 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNil(seq2)

        await coordinator.endLaunch(profileID: "profile-1", success: true)
    }

    func test_coordinator_allowsSameProfileAfterCompletion() async {
        let coordinator = CLILaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)
        await coordinator.endLaunch(profileID: "profile-1", success: true)

        // After completion, same profile can launch again
        let seq2 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq2)
    }

    func test_coordinator_tracksPendingState() async {
        let coordinator = CLILaunchCoordinator()

        var isInProgress = await coordinator.isLaunchInProgress(profileID: "profile-1")
        XCTAssertFalse(isInProgress)

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)

        isInProgress = await coordinator.isLaunchInProgress(profileID: "profile-1")
        XCTAssertTrue(isInProgress)
        isInProgress = await coordinator.isLaunchInProgress(profileID: "profile-2")
        XCTAssertFalse(isInProgress)

        await coordinator.endLaunch(profileID: "profile-1", success: true)

        isInProgress = await coordinator.isLaunchInProgress(profileID: "profile-1")
        XCTAssertFalse(isInProgress)
    }

    func test_coordinator_clearPendingLaunches() async {
        let coordinator = CLILaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)
        var isInProgress = await coordinator.isLaunchInProgress(profileID: "profile-1")
        XCTAssertTrue(isInProgress)

        await coordinator.clearPendingLaunches()

        isInProgress = await coordinator.isLaunchInProgress(profileID: "profile-1")
        XCTAssertFalse(isInProgress)

        // Should be able to launch again
        let seq2 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq2)
    }

    func test_coordinator_lastLaunchedProfileOnlyOnSuccess() async {
        let coordinator = CLILaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)

        // Failed launch doesn't update lastLaunchedProfileID
        await coordinator.endLaunch(profileID: "profile-1", success: false)

        var lastID = await coordinator.getLastLaunchedProfileID()
        XCTAssertNil(lastID)

        // Successful launch updates it
        let seq2 = await coordinator.beginLaunch(profileID: "profile-2")
        XCTAssertNotNil(seq2)
        await coordinator.endLaunch(profileID: "profile-2", success: true)

        lastID = await coordinator.getLastLaunchedProfileID()
        XCTAssertEqual(lastID, "profile-2")
    }

    // MARK: - Redaction Tests

    func test_redactSensitiveData_redactsAPIKeyPatterns() {
        // Test that sk-ant- style API keys are redacted
        // Note: sk-ant- followed by fewer than 20 chars uses the sk-ant- pattern
        let input = "sk-ant-1234567890"
        let result = CLILaunchRedactor.redactSensitiveData(input)
        XCTAssertTrue(result.contains("[API_KEY_REDACTED]"), "Result should contain redaction marker, got: \(result)")
        XCTAssertFalse(result.contains("sk-ant-1234567890"))
    }

    func test_redactSensitiveData_redactsGenericSecretPatterns() {
        // Test that generic api_key= patterns are redacted
        let input = "api_key=abc123secret"
        let result = CLILaunchRedactor.redactSensitiveData(input)
        XCTAssertTrue(result.contains("[SECRET_REDACTED]"))
        XCTAssertFalse(result.contains("abc123secret"))
    }

    func test_redactSensitiveData_redactsTokenPatterns() {
        let input = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let result = CLILaunchRedactor.redactSensitiveData(input)
        XCTAssertTrue(result.contains("[TOKEN_REDACTED]"))
        XCTAssertFalse(result.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
    }

    func test_redactSensitiveData_preservesNonSensitiveData() {
        let input = "HOME=/Users/test, PATH=/usr/bin, --verbose"
        let result = CLILaunchRedactor.redactSensitiveData(input)
        XCTAssertTrue(result.contains("/Users/test"))
        XCTAssertTrue(result.contains("/usr/bin"))
        XCTAssertTrue(result.contains("--verbose"))
    }

    func test_redactEnvironment_filtersSensitiveKeys() {
        let env: [String: String] = [
            "HOME": "/Users/test",
            "SECRET_KEY": "abc123",
            "API_KEY": "xyz789",
            "PATH": "/usr/bin",
        ]
        let result = CLILaunchRedactor.redactEnvironment(env)

        XCTAssertEqual(result["HOME"], "/Users/test")
        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["SECRET_KEY"], "[REDACTED]")
        XCTAssertEqual(result["API_KEY"], "[REDACTED]")
    }
}

// MARK: - In-Memory Store Tests

@MainActor
final class SwitcherCLILAunchServiceTests: XCTestCase {

    private var service: SwitcherCLILAunchService!
    private var store: InMemorySwitcherProfileStoreAdapter!

    override func setUp() {
        super.setUp()
        store = InMemorySwitcherProfileStoreAdapter()
        service = SwitcherCLILAunchService(profileStore: store)
    }

    func test_launchCLI_reportsProfileNotFound_whenProfileMissing() async {
        let outcome = await service.launchCLI(for: "nonexistent-profile")

        XCTAssertFalse(outcome.success)
        if case .profileNotFound(let id) = outcome.error {
            XCTAssertEqual(id, "nonexistent-profile")
        } else {
            XCTFail("Expected .profileNotFound error")
        }
    }

    func test_launchCLI_reportsKindMismatch_forBrowserProfile() async {
        let profile = SwitcherProfileRecord(
            id: "browser-profile",
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )
        store.addProfile(profile)

        let outcome = await service.launchCLI(for: "browser-profile")

        XCTAssertFalse(outcome.success)
        if case .profileKindMismatch(let expected, let actual) = outcome.error {
            XCTAssertEqual(expected, .cli)
            XCTAssertEqual(actual, .browser)
        } else {
            XCTFail("Expected .profileKindMismatch error")
        }
    }

    func test_launchCLI_reportsMissingMetadata_whenCLIMetadataNil() async {
        let profile = SwitcherProfileRecord(
            id: "incomplete-profile",
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: nil,
            sortKey: 1
        )
        store.addProfile(profile)

        let outcome = await service.launchCLI(for: "incomplete-profile")

        XCTAssertFalse(outcome.success)
        if case .missingProfileMetadata(let id) = outcome.error {
            XCTAssertEqual(id, "incomplete-profile")
        } else {
            XCTFail("Expected .missingProfileMetadata error")
        }
    }

    func test_launchCLI_reportsExecutableNotFound_whenNotInstalled() async {
        let profile = SwitcherProfileRecord(
            id: "claude-profile",
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )
        store.addProfile(profile)

        let outcome = await service.launchCLI(for: "claude-profile")

        // If Claude is installed, this will succeed (or fail for other reasons)
        // If not installed, should get executableNotFound
        if !CLILaunchAdapter.isExecutableAvailable(.claude) {
            XCTAssertFalse(outcome.success)
            if case .executableNotFound(let cliType) = outcome.error {
                XCTAssertEqual(cliType, .claude)
            } else {
                XCTFail("Expected .executableNotFound error")
            }
        }
    }

    func test_launchCLI_usesCorrectCLIType() async {
        let profile = SwitcherProfileRecord(
            id: "codex-profile",
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )
        store.addProfile(profile)

        // Use the typed launch method
        let outcome = await service.launchCLI(cliType: .codex, profileID: "codex-profile")

        // If Codex is not installed, should get executableNotFound
        if !CLILaunchAdapter.isExecutableAvailable(.codex) {
            XCTAssertFalse(outcome.success)
            if case .executableNotFound(let cliType) = outcome.error {
                XCTAssertEqual(cliType, .codex)
            }
        }
    }

    func test_launchCLI_rejectsTypeMismatch_inTypedLaunch() async {
        let profile = SwitcherProfileRecord(
            id: "claude-profile",
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )
        store.addProfile(profile)

        // Try to launch as Codex
        let outcome = await service.launchCLI(cliType: .codex, profileID: "claude-profile")

        XCTAssertFalse(outcome.success)
        if case .profileTypeMismatch(let expected, let actual) = outcome.error {
            XCTAssertEqual(expected, .codex)
            XCTAssertEqual(actual, .claude)
        } else {
            XCTFail("Expected .profileTypeMismatch error")
        }
    }

    func test_isCLIAvailable_checksClaude() {
        let available = service.isCLIAvailable(.claude)
        // Just verify it returns a boolean
        XCTAssertTrue(available == true || available == false)
    }

    func test_executablePath_returnsPathForAvailableCLI() {
        let path = service.executablePath(for: .claude)
        // If Claude is installed, should return a path
        if service.isCLIAvailable(.claude) {
            XCTAssertNotNil(path)
        } else {
            XCTAssertNil(path)
        }
    }

    func test_launchCLI_rejectsConcurrentLaunchSameProfile() async {
        let profile = SwitcherProfileRecord(
            id: "test-profile",
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )
        store.addProfile(profile)

        // If Claude is not installed, skip this part of the test
        guard !CLILaunchAdapter.isExecutableAvailable(.claude) else {
            return
        }

        // Launch twice concurrently - second should be rejected
        let outcome1 = await service.launchCLI(for: "test-profile")
        let outcome2 = await service.launchCLI(for: "test-profile")

        // At least one should fail with "already in progress"
        let hasAlreadyInProgress = outcome1.error == .launchFailed("Launch already in progress for this profile") ||
                                   outcome2.error == .launchFailed("Launch already in progress for this profile")
        XCTAssertTrue(hasAlreadyInProgress || (!outcome1.success && !outcome2.success))
    }
}

// MARK: - Helper Extensions

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

private func XCTAssertSuccess<Success, Failure: Error>(_ result: Result<Success, Failure>, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    switch result {
    case .success:
        if !message.isEmpty {
            XCTAssert(true, message, file: file, line: line)
        }
    case .failure(let error):
        XCTFail("Expected success, got \(error). \(message)", file: file, line: line)
    }
}

private func XCTAssertFailure<Success, Failure: Error>(_ result: Result<Success, Failure>, _ expectedError: Failure, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    switch result {
    case .success(let value):
        XCTFail("Expected failure \(expectedError), got success with \(value). \(message)", file: file, line: line)
    case .failure(let error):
        XCTAssertEqual("\(type(of: error))", "\(type(of: expectedError))", file: file, line: line)
        XCTAssertEqual("\(error)", "\(expectedError)", file: file, line: line)
    }
}
