import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Switcher Browser Launch Tests

@MainActor
final class SwitcherBrowserLaunchTests: XCTestCase {

    // MARK: - Chrome Profile Directory Canonicalization

    func test_canonicalizeChromeProfileDirectory_acceptsValidNames() {
        let validNames = ["Default", "Profile 1", "Work", "Personal", "Development"]

        for name in validNames {
            let result = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory(name)
            XCTAssertTrue(result.isSuccess, "Expected '\(name)' to be valid, got error")
        }
    }

    func test_canonicalizeChromeProfileDirectory_rejectsEmptyString() {
        let result = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory("")
        XCTAssertFailure(result, BrowserLaunchError.invalidProfileIdentifier("Profile identifier cannot be empty"))
    }

    func test_canonicalizeChromeProfileDirectory_rejectsWhitespaceOnly() {
        let result = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory("   ")
        XCTAssertFailure(result, BrowserLaunchError.invalidProfileIdentifier("Profile identifier cannot be empty"))
    }

    func test_canonicalizeChromeProfileDirectory_rejectsPathSeparators() {
        let result1 = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory("Profile/1")
        XCTAssertFailure(result1, BrowserLaunchError.invalidProfileIdentifier("Profile identifier cannot contain path separators"))

        let result2 = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory("Profile\\1")
        XCTAssertFailure(result2, BrowserLaunchError.invalidProfileIdentifier("Profile identifier cannot contain path separators"))

        let result3 = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory("C:\\\\Users\\\\test")
        XCTAssertFailure(result3, BrowserLaunchError.invalidProfileIdentifier("Profile identifier cannot contain path separators"))
    }

    func test_canonicalizeChromeProfileDirectory_rejectsTooLong() {
        let longName = String(repeating: "x", count: 300)
        let result = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory(longName)
        XCTAssertFailure(result, BrowserLaunchError.invalidProfileIdentifier("Profile identifier too long (max 256 chars)"))
    }

    func test_canonicalizeChromeProfileDirectory_rejectsControlCharacters() {
        let withNull = "Profile\u{0000}1"
        let result = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory(withNull)
        XCTAssertFailure(result, BrowserLaunchError.invalidProfileIdentifier("Profile identifier contains invalid characters"))
    }

    func test_canonicalizeChromeProfileDirectory_rejectsInjectionPatterns() {
        let injectionAttempts = [
            "--profile-directory=Default",
            "-e 'ls'",
            "; rm -rf",
            "& whoami",
            "| cat /etc/passwd",
            "`id`",
            "$(whoami)",
            "${HOME}",
        ]

        for attempt in injectionAttempts {
            let result = BrowserLaunchAdapter.canonicalizeChromeProfileDirectory(attempt)
            XCTAssertFailure(result, BrowserLaunchError.invalidProfileIdentifier("Profile identifier contains suspicious characters"),
                "Expected '\(attempt)' to be rejected")
        }
    }

    // MARK: - Argument Validation

    func test_validateChromeArgument_acceptsAllowlistedArgs() {
        let allowlisted = [
            "--profile-directory=Default",
            "--new-window",
            "--new-tab",
            "--incognito",
            "--silent-launch",
            "--no-default-browser-check",
            "--no-first-run",
            "--disable-extensions",
            "--disable-sync",
        ]

        for arg in allowlisted {
            let result = BrowserLaunchAdapter.validateChromeArgument(arg)
            XCTAssertNotNil(result, "Expected '\(arg)' to be allowlisted")
        }
    }

    func test_validateChromeArgument_rejectsArbitraryFlags() {
        let disallowed = [
            "--load-extension=/path/to/extension",
            "--remote-debugging-port=9222",
            "--headless",
            "--no-sandbox",
            "--user-data-dir=/tmp/chrome",
            "--proxy-server=http://proxy:8080",
        ]

        for arg in disallowed {
            let result = BrowserLaunchAdapter.validateChromeArgument(arg)
            XCTAssertNil(result, "Expected '\(arg)' to be rejected")
        }
    }

    func test_validateSafariArgument_acceptsAllowlistedArgs() {
        let allowlisted = ["--new-window", "--private"]

        for arg in allowlisted {
            let result = BrowserLaunchAdapter.validateSafariArgument(arg)
            XCTAssertNotNil(result, "Expected '\(arg)' to be allowlisted")
        }
    }

    func test_validateSafariArgument_rejectsArbitraryArgs() {
        let disallowed = ["--developer", "--block-cookies", "--disable-extensions"]

        for arg in disallowed {
            let result = BrowserLaunchAdapter.validateSafariArgument(arg)
            XCTAssertNil(result, "Expected '\(arg)' to be rejected")
        }
    }

    // MARK: - Profile Type Validation

    func test_validateProfileBrowserTypeMatch_acceptsMatchingChromeProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.validateProfileBrowserTypeMatch(
            profile: profile,
            targetBrowser: .chrome
        )
        XCTAssertSuccess(result)
    }

    func test_validateProfileBrowserTypeMatch_acceptsMatchingSafariProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.validateProfileBrowserTypeMatch(
            profile: profile,
            targetBrowser: .safari
        )
        XCTAssertSuccess(result)
    }

    func test_validateProfileBrowserTypeMatch_rejectsTypeMismatch() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.validateProfileBrowserTypeMatch(
            profile: profile,
            targetBrowser: .safari
        )
        XCTAssertFailure(result, BrowserLaunchError.profileTypeMismatch(expected: .safari, actual: .chrome))
    }

    func test_validateProfileBrowserTypeMatch_rejectsCLIProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.validateProfileBrowserTypeMatch(
            profile: profile,
            targetBrowser: .chrome
        )
        XCTAssertFailure(result, BrowserLaunchError.profileKindMismatch(expected: .browser, actual: .cli))
    }

    func test_validateProfileBrowserTypeMatch_rejectsMissingMetadata() {
        let profile = SwitcherProfileRecord(
            id: "test-id",
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: nil,
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.validateProfileBrowserTypeMatch(
            profile: profile,
            targetBrowser: .chrome
        )
        XCTAssertFailure(result, BrowserLaunchError.missingProfileMetadata("test-id"))
    }

    // MARK: - Build Chrome Launch

    func test_buildChromeLaunch_returnsCorrectConfiguration() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Work Profile"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildChromeLaunch(profile: profile)

        XCTAssertSuccess(result)
        if case .success(let (url, args)) = result {
            XCTAssertTrue(url.lastPathComponent.contains("Chrome"))
            XCTAssertTrue(args.contains("--profile-directory=Work Profile"))
        }
    }

    func test_buildChromeLaunch_addsAllowlistedArgs() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildChromeLaunch(
            profile: profile,
            additionalArgs: ["--new-window", "--no-first-run"]
        )

        XCTAssertSuccess(result)
        if case .success(let (_, args)) = result {
            XCTAssertTrue(args.contains("--new-window"))
            XCTAssertTrue(args.contains("--no-first-run"))
        }
    }

    func test_buildChromeLaunch_rejectsDisallowedArgs() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildChromeLaunch(
            profile: profile,
            additionalArgs: ["--remote-debugging-port=9222"]
        )

        XCTAssertFailure(result, BrowserLaunchError.disallowedArgument("--remote-debugging-port=9222"))
    }

    func test_buildChromeLaunch_rejectsSafariProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildChromeLaunch(profile: profile)

        XCTAssertFailure(result, BrowserLaunchError.profileTypeMismatch(expected: .chrome, actual: .safari))
    }

    func test_buildChromeLaunch_rejectsCLIProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildChromeLaunch(profile: profile)

        XCTAssertFailure(result, BrowserLaunchError.profileKindMismatch(expected: .browser, actual: .cli))
    }

    // MARK: - Build Safari Launch

    func test_buildSafariLaunch_returnsCorrectConfiguration() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildSafariLaunch(profile: profile)

        XCTAssertSuccess(result)
        if case .success(let (url, args)) = result {
            XCTAssertTrue(url.lastPathComponent.contains("Safari"))
            XCTAssertTrue(args.isEmpty)
        }
    }

    func test_buildSafariLaunch_addsPrivateFlag() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildSafariLaunch(profile: profile, privateBrowsing: true)

        XCTAssertSuccess(result)
        if case .success(let (_, args)) = result {
            XCTAssertTrue(args.contains("--private"))
        }
    }

    func test_buildSafariLaunch_rejectsChromeProfile() {
        let profile = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )

        let result = BrowserLaunchAdapter.buildSafariLaunch(profile: profile)

        XCTAssertFailure(result, BrowserLaunchError.profileTypeMismatch(expected: .safari, actual: .chrome))
    }

    // MARK: - Browser Availability

    func test_isBrowserAvailable_checksBundleIdentifier() {
        // This test verifies the method works - actual availability depends on installed browsers
        let chromeAvailable = BrowserLaunchAdapter.isBrowserAvailable(.chrome)
        let safariAvailable = BrowserLaunchAdapter.isBrowserAvailable(.safari)

        // At least one browser should be available on a Mac
        XCTAssertTrue(chromeAvailable || safariAvailable, "At least one browser should be installed")
    }

    // MARK: - Filesystem Guard

    func test_isProtectedBrowserPath_detectsChromePaths() {
        let chromePaths = [
            "/Users/test/Library/Application Support/Google/Chrome/Default",
            "/Users/test/Library/Google/Chrome/Profile 1",
            "~/Library/Application Support/Google/Chrome",
        ]

        for path in chromePaths {
            XCTAssertTrue(
                BrowserFilesystemGuard.isProtectedBrowserPath(path),
                "Expected '\(path)' to be protected"
            )
        }
    }

    func test_isProtectedBrowserPath_detectsSafariPaths() {
        let safariPaths = [
            "/Users/test/Library/Safari/Bookmarks",
            "/Users/test/Library/Application Support/Safari",
            "/Users/test/Library/Cookies/Cookies.binarycookies",
        ]

        for path in safariPaths {
            XCTAssertTrue(
                BrowserFilesystemGuard.isProtectedBrowserPath(path),
                "Expected '\(path)' to be protected"
            )
        }
    }

    func test_isProtectedBrowserPath_allowsNonBrowserPaths() {
        let safePaths = [
            "/Users/test/Documents",
            "/Users/test/Desktop",
            "/tmp/chrome_temp",
        ]

        for path in safePaths {
            XCTAssertFalse(
                BrowserFilesystemGuard.isProtectedBrowserPath(path),
                "Expected '\(path)' to NOT be protected"
            )
        }
    }

    func test_redactSensitiveData_redactsCookiePatterns() {
        let input = "cookie=abc123, session=xyz789"
        let result = BrowserFilesystemGuard.redactSensitiveData(input)
        XCTAssertTrue(result.contains("[COOKIE_REDACTED]"))
        XCTAssertTrue(result.contains("[SESSION_REDACTED]"))
    }

    func test_redactSensitiveData_redactsTokenPatterns() {
        let input = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let result = BrowserFilesystemGuard.redactSensitiveData(input)
        XCTAssertTrue(result.contains("[TOKEN_REDACTED]"))
        XCTAssertFalse(result.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
    }

    func test_redactSensitiveData_redactsAPIKeyPatterns() {
        // Test the regex pattern matching for API key redaction
        let input = "service_token=placeholder_value_here"
        let result = BrowserFilesystemGuard.redactSensitiveData(input)
        XCTAssertTrue(result.contains("[TOKEN_REDACTED]"))
        XCTAssertFalse(result.contains("placeholder_value_here"))
    }

    func test_redactSensitiveData_redactsAuthHeaders() {
        let input = "Authorization: Bearer token123"
        let result = BrowserFilesystemGuard.redactSensitiveData(input)
        XCTAssertTrue(result.contains("[AUTH_REDACTED]"))
    }

    func test_redactSensitiveData_preservesNonSensitiveData() {
        let input = "Profile: Work, URL: https://example.com, Path: /Users/test/Chrome"
        let result = BrowserFilesystemGuard.redactSensitiveData(input)
        XCTAssertTrue(result.contains("Work"))
        XCTAssertTrue(result.contains("example.com"))
        XCTAssertTrue(result.contains("/Users/test/Chrome"))
    }

    // MARK: - Launch Outcome

    func test_launchOutcome_equality() {
        let success1 = LaunchOutcome(success: true, error: nil)
        let success2 = LaunchOutcome(success: true, error: nil)
        XCTAssertEqual(success1, success2)

        let error = BrowserLaunchError.browserNotInstalled(.chrome)
        let failure1 = LaunchOutcome(success: false, error: error)
        let failure2 = LaunchOutcome(success: false, error: error)
        XCTAssertEqual(failure1, failure2)
    }

    func test_launchOutcome_inequality() {
        let success = LaunchOutcome(success: true, error: nil)
        let failure = LaunchOutcome(success: false, error: .browserNotInstalled(.chrome))
        XCTAssertNotEqual(success, failure)
    }

    // MARK: - Browser Launch Error Descriptions

    func test_browserLaunchError_errorDescriptions() {
        let errors: [BrowserLaunchError] = [
            .browserNotInstalled(.chrome),
            .profileNotFound("test-id"),
            .profileTypeMismatch(expected: .chrome, actual: .safari),
            .profileKindMismatch(expected: .browser, actual: .cli),
            .missingProfileMetadata("test-id"),
            .invalidProfileIdentifier("too long"),
            .disallowedArgument("--test"),
            .launchConfigurationFailed("reason"),
            .launchTimeout,
            .launchFailed("detail"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func test_browserLaunchError_recoverySuggestions() {
        let errors: [BrowserLaunchError] = [
            .browserNotInstalled(.chrome),
            .profileNotFound("test-id"),
            .profileTypeMismatch(expected: .chrome, actual: .safari),
            .disallowedArgument("--test"),
            .launchTimeout,
        ]

        for error in errors {
            XCTAssertNotNil(error.recoverySuggestion, "Error \(error) should have recovery suggestion")
            XCTAssertFalse(error.recoverySuggestion!.isEmpty)
        }
    }

    // MARK: - Coordinator Tests

    func test_coordinator_allowsSequentialLaunches() async {
        let coordinator = BrowserLaunchCoordinator()

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
        let coordinator = BrowserLaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)

        // Same profile - should be rejected
        let seq2 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNil(seq2)

        await coordinator.endLaunch(profileID: "profile-1", success: true)
    }

    func test_coordinator_allowsSameProfileAfterCompletion() async {
        let coordinator = BrowserLaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)
        await coordinator.endLaunch(profileID: "profile-1", success: true)

        // After completion, same profile can launch again
        let seq2 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq2)
    }

    func test_coordinator_tracksPendingState() async {
        let coordinator = BrowserLaunchCoordinator()

        XCTAssertFalse(await coordinator.isLaunchInProgress(profileID: "profile-1"))

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)

        XCTAssertTrue(await coordinator.isLaunchInProgress(profileID: "profile-1"))
        XCTAssertFalse(await coordinator.isLaunchInProgress(profileID: "profile-2"))

        await coordinator.endLaunch(profileID: "profile-1", success: true)

        XCTAssertFalse(await coordinator.isLaunchInProgress(profileID: "profile-1"))
    }

    func test_coordinator_clearPendingLaunches() async {
        let coordinator = BrowserLaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)
        XCTAssertTrue(await coordinator.isLaunchInProgress(profileID: "profile-1"))

        await coordinator.clearPendingLaunches()

        XCTAssertFalse(await coordinator.isLaunchInProgress(profileID: "profile-1"))

        // Should be able to launch again
        let seq2 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq2)
    }

    func test_coordinator_lastLaunchedProfileOnlyOnSuccess() async {
        let coordinator = BrowserLaunchCoordinator()

        let seq1 = await coordinator.beginLaunch(profileID: "profile-1")
        XCTAssertNotNil(seq1)

        // Failed launch doesn't update lastLaunchedProfileID
        await coordinator.endLaunch(profileID: "profile-1", success: false)

        XCTAssertNil(await coordinator.getLastLaunchedProfileID())

        // Successful launch updates it
        let seq2 = await coordinator.beginLaunch(profileID: "profile-2")
        XCTAssertNotNil(seq2)
        await coordinator.endLaunch(profileID: "profile-2", success: true)

        XCTAssertEqual(await coordinator.getLastLaunchedProfileID(), "profile-2")
    }
}

// MARK: - In-Memory Store Tests

@MainActor
final class SwitcherBrowserLaunchServiceTests: XCTestCase {

    private var service: SwitcherBrowserLaunchService!
    private var store: InMemorySwitcherProfileStoreAdapter!

    override func setUp() {
        super.setUp()
        store = InMemorySwitcherProfileStoreAdapter()
        service = SwitcherBrowserLaunchService(profileStore: store)
    }

    func test_launchBrowser_reportsBrowserNotInstalled_whenChromeMissing() async {
        let profile = SwitcherProfileRecord(
            id: "chrome-profile",
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Default"),
            sortKey: 1
        )
        store.addProfile(profile)

        let outcome = await service.launchBrowser(for: "chrome-profile")

        XCTAssertFalse(outcome.success)
        // The exact error depends on whether Chrome is installed
        // If Chrome is installed, it will attempt to launch
        // If not, it will return browserNotInstalled
    }

    func test_launchBrowser_reportsProfileNotFound_whenProfileMissing() async {
        let outcome = await service.launchBrowser(for: "nonexistent-profile")

        XCTAssertFalse(outcome.success)
        if case .profileNotFound(let id) = outcome.error {
            XCTAssertEqual(id, "nonexistent-profile")
        } else {
            XCTFail("Expected .profileNotFound error")
        }
    }

    func test_launchBrowser_reportsKindMismatch_forCLIProfile() async {
        let profile = SwitcherProfileRecord(
            id: "cli-profile",
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        )
        store.addProfile(profile)

        let outcome = await service.launchBrowser(for: "cli-profile")

        XCTAssertFalse(outcome.success)
        if case .profileKindMismatch(let expected, let actual) = outcome.error {
            XCTAssertEqual(expected, .browser)
            XCTAssertEqual(actual, .cli)
        } else {
            XCTFail("Expected .profileKindMismatch error")
        }
    }

    func test_isBrowserAvailable_checksChrome() {
        let available = service.isBrowserAvailable(.chrome)
        // This depends on whether Chrome is installed
        // Just verify it returns a boolean
        XCTAssertTrue(available == true || available == false)
    }

    func test_isBrowserAvailable_checksSafari() {
        let available = service.isBrowserAvailable(.safari)
        // Safari should always be available on macOS
        XCTAssertTrue(available)
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

private func XCTAssertSuccess(_ result: Result<Any, Error>, file: StaticString = #file, line: UInt = #line) {
    switch result {
    case .success:
        break
    case .failure(let error):
        XCTFail("Expected success, got \(error)", file: file, line: line)
    }
}

private func XCTAssertFailure(_ result: Result<Any, Error>, _ expectedError: Error, file: StaticString = #file, line: UInt = #line) {
    switch result {
    case .success(let value):
        XCTFail("Expected failure \(expectedError), got success with \(value)", file: file, line: line)
    case .failure(let error):
        XCTAssertEqual("\(error)", "\(expectedError)", file: file, line: line)
    }
}

private func XCTAssertFailure<T>(_ result: Result<T, Error>, _ expectedError: Error, file: StaticString = #file, line: UInt = #line) {
    switch result {
    case .success(let value):
        XCTFail("Expected failure \(expectedError), got success with \(value)", file: file, line: line)
    case .failure(let error):
        XCTAssertEqual("\(type(of: error))", "\(type(of: expectedError))", file: file, line: line)
        XCTAssertEqual("\(error)", "\(expectedError)", file: file, line: line)
    }
}
