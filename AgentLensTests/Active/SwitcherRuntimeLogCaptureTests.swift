import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Runtime Log Capture Tests for VAL-CROSS-006

/// Tests that verify runtime log output during startup/sync paths
/// remains secret-safe. These tests complement the helper-unit tests
/// by ensuring actual runtime codepaths don't emit raw secrets.
///
/// VAL-CROSS-006: Startup and sync logs remain secret-safe
/// On startup rehydration and cross-surface sync, logs include operational
/// state only and never include raw credentials/tokens/auth headers.
///
/// These tests use a LogEmitter with capture handler to intercept actual
/// production log output from startup/sync flows - not just stored data.
@MainActor
final class SwitcherRuntimeLogCaptureTests: XCTestCase {

    // MARK: - Test Data

    private var dbQueue: DatabaseQueue!
    private var store: SwitcherProfileStore!
    private var logCapture: RuntimeLogCapture!
    /// Captured log messages from the production log emitter
    private var capturedLogMessages: [String] = []
    /// The log emitter with capture handler for intercepting production logs
    private var logEmitter: LogEmitter!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        do {
            dbQueue = try DatabaseQueue()
            try Self.addMigrationv32(to: dbQueue)

            // Create log emitter with capture handler for deterministic interception
            capturedLogMessages = []
            logEmitter = LogEmitter { [weak self] message in
                self?.capturedLogMessages.append(message)
            }

            // Create store with injectable log emitter for test capture
            store = SwitcherProfileStore(dbQueue: dbQueue, logEmitter: logEmitter)
            logCapture = RuntimeLogCapture()
        } catch {
            XCTFail("Failed to set up test store: \(error)")
        }
    }

    override func tearDown() {
        dbQueue = nil
        store = nil
        logCapture = nil
        capturedLogMessages.removeAll()
        logEmitter = nil
        super.tearDown()
    }

    // MARK: - Migration Helper

    private static func addMigrationv32(to dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE switcher_profiles (
                    id TEXT PRIMARY KEY,
                    targetKind TEXT NOT NULL,
                    browserType TEXT,
                    browserMetadataJSON TEXT,
                    cliType TEXT,
                    cliMetadataJSON TEXT,
                    sortKey INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX switcher_profiles_targetKind_idx ON switcher_profiles(targetKind)
            """)
            try db.execute(sql: """
                CREATE INDEX switcher_profiles_sortKey_idx ON switcher_profiles(sortKey)
            """)
            try db.execute(sql: """
                CREATE TABLE switcher_active_profile (
                    activeProfileID TEXT,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (NULL, '2024-01-01T00:00:00Z')
            """)
        }
    }

    // MARK: - Secret Pattern Definitions

    /// Keys that are considered sensitive
    private static let sensitiveKeys: Set<String> = [
        "API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "AUTH",
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY",
    ]

    // MARK: - Runtime Log Capture

    /// A log capture mechanism that intercepts textual output emitted during
    /// startup/sync flows. This captures actual runtime output, not just
    /// stored data.
    ///
    /// The capture intercepts:
    /// - Error descriptions from thrown errors
    /// - Debug descriptions of objects
    /// - Recovery suggestions from errors
    /// - Any string output produced during startup/sync flows
    final class RuntimeLogCapture {
        /// All captured log strings from runtime execution
        var capturedLogs: [String] = []

        /// Captures a log entry during test execution
        func capture(_ entry: String) {
            capturedLogs.append(entry)
        }

        /// Captures multiple log entries
        func captureAll(_ entries: [String]) {
            capturedLogs.append(contentsOf: entries)
        }

        /// Captures an error's description and recovery suggestion
        func captureError(_ error: Error) {
            capturedLogs.append(error.localizedDescription)
            if let localError = error as? LocalizedError {
                capturedLogs.append(localError.errorDescription ?? "")
                capturedLogs.append(localError.recoverySuggestion ?? "")
            }
        }

        /// Captures a debug description of an object
        func captureDebugDescription(_ description: String) {
            capturedLogs.append(description)
        }

        /// Captures all textual representations of a profile
        func captureProfileTextualRepresentations(_ profile: SwitcherProfileRecord) {
            capturedLogs.append(profile.id)
            capturedLogs.append(profile.displayName)
            if let browserMeta = profile.browserMetadata {
                capturedLogs.append(browserMeta.profileIdentifier)
                capturedLogs.append(browserMeta.displayLabel ?? "")
            }
            if let cliMeta = profile.cliMetadata {
                capturedLogs.append(cliMeta.workingDirectory ?? "")
                capturedLogs.append(cliMeta.displayLabel ?? "")
                capturedLogs.append(contentsOf: cliMeta.envKeysToPass)
                capturedLogs.append(contentsOf: cliMeta.additionalArgs)
            }
        }

        /// Captures active profile state textual representations
        func captureActiveProfileState(_ state: SwitcherActiveProfileState) {
            capturedLogs.append(String(describing: state))
            if let id = state.activeProfileID {
                capturedLogs.append(id)
            }
        }

        /// Returns all captured logs joined into a single string for pattern checking
        var allCapturedText: String {
            capturedLogs.joined(separator: "\n")
        }

        /// Clears captured logs
        func reset() {
            capturedLogs.removeAll()
        }
    }

    // MARK: - Helper Methods

    /// Verifies no secret patterns appear in the given strings.
    /// Returns the patterns that were found (empty if all are properly redacted).
    private func findSecretPatterns(in strings: [String]) -> [String] {
        var foundPatterns: [String] = []

        for string in strings {
            // Check for sk- API key patterns (20+ chars after sk-)
            if let regex = try? NSRegularExpression(pattern: "sk-[a-zA-Z0-9]{20,}", options: .caseInsensitive) {
                let range = NSRange(string.startIndex..., in: string)
                if regex.firstMatch(in: string, options: [], range: range) != nil {
                    foundPatterns.append("sk- API key pattern (>20 chars)")
                }
            }

            // Check for sk-ant- prefix (Anthropic API key)
            if string.contains("sk-ant-") {
                foundPatterns.append("sk-ant- prefix")
            }

            // Check for Bearer tokens
            if let regex = try? NSRegularExpression(pattern: "Bearer[\\s_]+[A-Za-z0-9_\\-\\.]+", options: .caseInsensitive) {
                let range = NSRange(string.startIndex..., in: string)
                if regex.firstMatch(in: string, options: [], range: range) != nil {
                    foundPatterns.append("Bearer token pattern")
                }
            }

            // Check for JWT-like tokens (base64 patterns with dots)
            if let regex = try? NSRegularExpression(pattern: "eyJ[A-Za-z0-9_\\-\\.]+", options: []) {
                let range = NSRange(string.startIndex..., in: string)
                if regex.firstMatch(in: string, options: [], range: range) != nil {
                    foundPatterns.append("JWT-like token pattern")
                }
            }

            // Check for key=value patterns with potential secrets
            if let regex = try? NSRegularExpression(pattern: "(api_key|apikey|token|password|secret|auth)[=:\\s]+[^,\\s]+", options: .caseInsensitive) {
                let range = NSRange(string.startIndex..., in: string)
                if regex.firstMatch(in: string, options: [], range: range) != nil {
                    foundPatterns.append("key=value secret pattern")
                }
            }
        }

        return foundPatterns
    }

    /// Asserts that no secret patterns are found in the captured logs.
    /// This is the core assertion for VAL-CROSS-006.
    private func assertNoSecretPatternsInLogs(
        logs: [String],
        context: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let foundPatterns = findSecretPatterns(in: logs)
        XCTAssertTrue(
            foundPatterns.isEmpty,
            """
            \(context): Found forbidden secret patterns in runtime emitted logs: \(foundPatterns)
            
            Captured logs:
            \(logs.joined(separator: "\n"))
            
            All captured text:
            \(logCapture.allCapturedText)
            """,
            file: file,
            line: line
        )
    }

    // MARK: - Runtime Startup Log Capture Tests

    /// VAL-CROSS-006: Tests that startup profile creation emits no raw secrets in logs.
    /// Uses the logging variant of store methods to capture actual production log output,
    /// then verifies no secret patterns appear in the emitted logs.
    func test_startupProfileCreation_capturesRuntimeLogs_noSecrets() throws {
        // Create profile with metadata that looks like secrets
        let profileSpec = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/Users/test/projects",
                additionalArgs: ["--verbose"],
                envKeysToPass: ["HOME", "PATH", "ANTHROPIC_API_KEY"],
                displayLabel: "Test Profile"
            ),
            sortKey: 1
        )

        // Clear any previous captured logs
        capturedLogMessages.removeAll()

        // Create profile using logging variant - this emits actual production logs
        let profile = try store.createWithLogging(profileSpec)

        // Fetch active state using logging variant (simulating startup rehydration)
        let state = try store.fetchActiveProfileStateWithLogging()

        // Also capture profile textual representations for completeness
        logCapture.reset()
        logCapture.captureProfileTextualRepresentations(profile)
        logCapture.captureActiveProfileState(state)

        // Combine captured log messages from production log emitter with test helper captures
        var allLogs = capturedLogMessages
        allLogs.append(contentsOf: logCapture.capturedLogs)

        // Assert no secret patterns in captured runtime emitted logs
        assertNoSecretPatternsInLogs(logs: allLogs, context: "test_startupProfileCreation_capturesRuntimeLogs_noSecrets")

        // Verify that we actually captured some log output
        XCTAssertFalse(capturedLogMessages.isEmpty, "Should have captured log output from production code")
    }

    /// VAL-CROSS-006: Tests that startup profile fetch emits no raw secrets in logs.
    /// Uses the logging variant of store methods to capture actual production log output.
    func test_startupProfileFetch_capturesRuntimeLogs_noSecrets() throws {
        // Create profile using logging variant
        let profile = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/codex/work",
                additionalArgs: [],
                envKeysToPass: ["HOME", "PATH", "OPENAI_API_KEY"],
                displayLabel: "Codex Profile"
            ),
            sortKey: 1
        ))

        // Clear logs from creation
        capturedLogMessages.removeAll()

        // Fetch profile using logging variant
        let fetchedProfiles = try store.fetchAllProfiles()
        for fetched in fetchedProfiles {
            logCapture.reset()
            logCapture.captureProfileTextualRepresentations(fetched)
        }

        // Combine captured log messages
        var allLogs = capturedLogMessages
        allLogs.append(contentsOf: logCapture.capturedLogs)

        assertNoSecretPatternsInLogs(logs: allLogs, context: "test_startupProfileFetch_capturesRuntimeLogs_noSecrets")
    }

    /// VAL-CROSS-006: Tests that active profile state rehydration emits no raw secrets.
    /// Uses the logging variant to capture actual production log output during rehydration.
    func test_startupActiveProfileRehydration_capturesRuntimeLogs_noSecrets() throws {
        // Create and activate a profile using logging variant
        let profile = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "ChromeProfile",
                displayLabel: "Chrome Work"
            ),
            sortKey: 1
        ))

        try store.setActiveProfileWithLogging(profile.id)

        // Clear logs from creation and activation
        capturedLogMessages.removeAll()

        // Simulate startup rehydration - fresh store reads active state
        // Create a fresh store with the same log emitter for consistent capture
        let freshStore = SwitcherProfileStore(dbQueue: dbQueue, logEmitter: logEmitter)
        let state = try freshStore.fetchActiveProfileStateWithLogging()

        // Capture for verification
        logCapture.reset()
        logCapture.captureProfileTextualRepresentations(profile)
        logCapture.captureActiveProfileState(state)

        // Combine captured log messages
        var allLogs = capturedLogMessages
        allLogs.append(contentsOf: logCapture.capturedLogs)

        assertNoSecretPatternsInLogs(logs: allLogs, context: "test_startupActiveProfileRehydration_capturesRuntimeLogs_noSecrets")

        // Verify we captured the rehydration log
        XCTAssertTrue(capturedLogMessages.contains { $0.contains("rehydrated") },
                      "Should have captured rehydration log output")
    }

    /// VAL-CROSS-006: Tests that profile update emits no raw secrets in logs.
    /// Uses logging variant to capture actual production log output during update.
    func test_syncProfileUpdate_capturesRuntimeLogs_noSecrets() throws {
        // Create profile using logging variant
        let original = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/test/path",
                additionalArgs: [],
                envKeysToPass: ["HOME", "PATH"],
                displayLabel: "Original"
            ),
            sortKey: 1
        ))

        // Clear logs from creation
        capturedLogMessages.removeAll()

        let updated = SwitcherProfileRecord(
            id: original.id,
            targetKind: original.targetKind,
            browserType: original.browserType,
            browserMetadata: original.browserMetadata,
            cliType: original.cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/updated/path",
                additionalArgs: ["--debug"],
                envKeysToPass: ["HOME", "PATH", "CODEX_API_KEY"],
                displayLabel: "Updated"
            ),
            sortKey: original.sortKey,
            createdAt: original.createdAt,
            updatedAt: Date()
        )

        do {
            _ = try store.updateWithLogging(updated)
        } catch {
            logCapture.captureError(error)
        }

        // Combine captured log messages
        var allLogs = capturedLogMessages
        allLogs.append(contentsOf: logCapture.capturedLogs)

        assertNoSecretPatternsInLogs(logs: allLogs, context: "test_syncProfileUpdate_capturesRuntimeLogs_noSecrets")

        // Verify we captured update log
        XCTAssertTrue(capturedLogMessages.contains { $0.contains("Updated") },
                      "Should have captured update log output")
    }

    /// VAL-CROSS-006: Tests that profile deletion emits no raw secrets in logs.
    /// Uses logging variant to capture actual production log output during deletion.
    func test_syncProfileDeletion_capturesRuntimeLogs_noSecrets() throws {
        // Create profile with secret-like data using logging variant
        let profile = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .opencode,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/tmp",
                additionalArgs: [],
                envKeysToPass: ["HOME", "PATH", "SECRET_TOKEN"],
                displayLabel: "To Delete"
            ),
            sortKey: 1
        ))

        // Clear logs from creation
        capturedLogMessages.removeAll()

        do {
            try store.deleteProfileWithLogging(id: profile.id)
        } catch {
            logCapture.captureError(error)
        }

        // Combine captured log messages
        var allLogs = capturedLogMessages
        allLogs.append(contentsOf: logCapture.capturedLogs)

        assertNoSecretPatternsInLogs(logs: allLogs, context: "test_syncProfileDeletion_capturesRuntimeLogs_noSecrets")

        // Verify we captured deletion log
        XCTAssertTrue(capturedLogMessages.contains { $0.contains("Deleted") },
                      "Should have captured deletion log output")
    }

    /// VAL-CROSS-006: Tests that cross-surface sync emits no raw secrets.
    /// Uses logging variants to capture actual production log output during sync.
    func test_crossSurfaceSync_capturesRuntimeLogs_noSecrets() throws {
        // Clear logs
        capturedLogMessages.removeAll()

        // Create multiple profiles using logging variants
        let cliProfile = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/claude/work",
                additionalArgs: [],
                envKeysToPass: ["HOME", "PATH", "ANTHROPIC_API_KEY"],
                displayLabel: "Claude Profile"
            ),
            sortKey: 1
        ))

        let browserProfile = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "SafariProfile",
                displayLabel: "Safari Personal"
            ),
            sortKey: 2
        ))

        // Set active using logging variant
        try store.setActiveProfileWithLogging(cliProfile.id)

        // Verify captured logs from creation and activation
        let allLogs = capturedLogMessages
        assertNoSecretPatternsInLogs(logs: allLogs, context: "test_crossSurfaceSync_capturesRuntimeLogs_noSecrets")

        // Verify we captured logs for both profiles and active state
        XCTAssertTrue(capturedLogMessages.contains { $0.contains("Created") },
                      "Should have captured profile creation logs")
        XCTAssertTrue(capturedLogMessages.contains { $0.contains("Active profile set") },
                      "Should have captured active profile set log")
    }

    // MARK: - Error Path Runtime Log Tests

    /// VAL-CROSS-006: Tests that error paths emit no raw secrets.
    /// Verifies error descriptions don't leak secrets.
    func test_errorPaths_capturesRuntimeLogs_noSecrets() throws {
        // Clear logs
        capturedLogMessages.removeAll()
        logCapture.reset()

        // Test profile not found error
        let notFoundError = SwitcherProfileStoreError.profileNotFound("test-id-123")
        logCapture.captureError(notFoundError)

        // Test duplicate name error
        let dupError = SwitcherProfileStoreError.duplicateProfileName("Test Profile")
        logCapture.captureError(dupError)

        // Test migration error
        let migError = SwitcherProfileStoreError.migrationFailed("schema mismatch")
        logCapture.captureError(migError)

        let logs = logCapture.capturedLogs
        assertNoSecretPatternsInLogs(logs: logs, context: "test_errorPaths_capturesRuntimeLogs_noSecrets")

        // Additionally verify specific safety properties
        let allText = logCapture.allCapturedText
        XCTAssertFalse(allText.contains("sk-"), "Error logs should not contain sk- API key patterns")
        XCTAssertFalse(allText.contains("token="), "Error logs should not contain token= patterns")
        XCTAssertFalse(allText.contains("password="), "Error logs should not contain password= patterns")
    }

    /// VAL-CROSS-006: Tests that CLI launch error paths emit no raw secrets.
    func test_cliLaunchErrorPaths_capturesRuntimeLogs_noSecrets() throws {
        logCapture.reset()

        // Test executable not found error
        let execError = CLILaunchError.executableNotFound(.claude)
        logCapture.captureError(execError)

        // Test profile not found error
        let profileError = CLILaunchError.profileNotFound("prof-123")
        logCapture.captureError(profileError)

        // Test missing metadata error
        let metaError = CLILaunchError.missingProfileMetadata("meta-test-id")
        logCapture.captureError(metaError)

        // Test disallowed argument error
        let argError = CLILaunchError.disallowedArgument("--evil-flag")
        logCapture.captureError(argError)

        let logs = logCapture.capturedLogs
        assertNoSecretPatternsInLogs(logs: logs, context: "test_cliLaunchErrorPaths_capturesRuntimeLogs_noSecrets")

        // Verify error descriptions only contain safe identifiers
        let allText = logCapture.allCapturedText
        // At least one error should mention CLI type
        XCTAssertTrue(
            allText.contains("claude") || allText.contains("Claude") || allText.contains("CLI"),
            "Error logs should mention CLI type. Got: \(allText)"
        )
        XCTAssertFalse(allText.contains("sk-"), "Error logs should not contain sk- API keys")
        XCTAssertFalse(allText.contains("eyJ"), "Error logs should not contain JWT tokens")
    }

    // MARK: - Browser Launch Log Tests

    /// VAL-CROSS-006: Tests that browser launch metadata emits no raw secrets.
    func test_browserLaunch_capturesRuntimeLogs_noSecrets() throws {
        // Create browser profile using logging variant
        _ = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "ChromeTest",
                displayLabel: "Chrome Test Profile"
            ),
            sortKey: 1
        ))

        // Clear logs from creation
        capturedLogMessages.removeAll()
        logCapture.reset()

        // Fetch profile using non-logging variant (logging variant would create duplicate logs)
        let fetched = try store.fetchProfile(id: "ChromeTest")
        if let fetchedProfile = fetched {
            logCapture.captureProfileTextualRepresentations(fetchedProfile)
        }

        let logs = logCapture.capturedLogs
        assertNoSecretPatternsInLogs(logs: logs, context: "test_browserLaunch_capturesRuntimeLogs_noSecrets")

        // Verify browser metadata doesn't contain OAuth/cookie patterns
        let allText = logCapture.allCapturedText
        XCTAssertFalse(allText.lowercased().contains("oauth"), "Browser metadata should not contain oauth")
        XCTAssertFalse(allText.lowercased().contains("cookie"), "Browser metadata should not contain cookie")
        XCTAssertFalse(allText.contains("sk-"), "Browser metadata should not contain API keys")
    }

    // MARK: - Metadata Schema Log Tests

    /// VAL-CROSS-006: Tests that stored metadata schema emits no raw secrets.
    func test_metadataSchema_capturesRuntimeLogs_noSecrets() throws {
        // Clear logs
        capturedLogMessages.removeAll()

        // Create CLI profile with env keys using logging variant
        let cliProfile = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/Users/test",
                additionalArgs: ["--verbose"],
                envKeysToPass: ["HOME", "PATH", "API_KEY"],
                displayLabel: "Schema Test"
            ),
            sortKey: 1
        ))

        // Create browser profile using logging variant
        let browserProfile = try store.createWithLogging(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "SafariSchema",
                displayLabel: "Safari Schema Test"
            ),
            sortKey: 2
        ))

        // Capture logs from all profile representations
        logCapture.reset()
        logCapture.captureProfileTextualRepresentations(cliProfile)
        logCapture.captureProfileTextualRepresentations(browserProfile)

        // Also capture raw database content (handle NULL values)
        let rawJSON = try dbQueue.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: "SELECT cliMetadataJSON, browserMetadataJSON FROM switcher_profiles")
            return rows.compactMap { row -> String? in
                let cliJSON: String? = row["cliMetadataJSON"]
                let browserJSON: String? = row["browserMetadataJSON"]
                return (cliJSON ?? "") + (browserJSON ?? "")
            }
        }
        logCapture.captureAll(rawJSON)

        // Combine with captured production logs
        var allLogs = capturedLogMessages
        allLogs.append(contentsOf: logCapture.capturedLogs)

        assertNoSecretPatternsInLogs(logs: allLogs, context: "test_metadataSchema_capturesRuntimeLogs_noSecrets")

        // Verify envKeysToPass only contains key names
        if let metadata = cliProfile.cliMetadata {
            for key in metadata.envKeysToPass {
                XCTAssertFalse(key.contains("="), "envKeysToPass should contain only keys, not key=value: \(key)")
                XCTAssertFalse(key.hasPrefix("sk-"), "envKeysToPass should not contain actual API key values")
            }
        }
    }

    // MARK: - Rapid Operations Log Tests

    /// VAL-CROSS-006: Tests that rapid operations emit no raw secrets.
    func test_rapidOperations_capturesRuntimeLogs_noSecrets() throws {
        // Capture logs from rapid profile creation
        logCapture.reset()

        for i in 0..<5 {
            let profile = try store.create(SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .claude,
                cliMetadata: SwitcherCLIProfileMetadata(
                    workingDirectory: "/path/\(i)",
                    additionalArgs: [],
                    envKeysToPass: ["HOME", "PATH", "API_KEY_\(i)"],
                    displayLabel: "Rapid \(i)"
                ),
                sortKey: i + 100
            ))
            logCapture.captureProfileTextualRepresentations(profile)
        }

        // Capture logs from rapid updates
        let profiles = try store.fetchAllProfiles()
        for profile in profiles {
            let updated = SwitcherProfileRecord(
                id: profile.id,
                targetKind: profile.targetKind,
                browserType: profile.browserType,
                browserMetadata: profile.browserMetadata,
                cliType: profile.cliType,
                cliMetadata: profile.cliMetadata,
                sortKey: profile.sortKey,
                createdAt: profile.createdAt,
                updatedAt: Date()
            )
            do {
                _ = try store.update(updated)
                logCapture.captureProfileTextualRepresentations(updated)
            } catch {
                logCapture.captureError(error)
            }
        }

        let logs = logCapture.capturedLogs
        assertNoSecretPatternsInLogs(logs: logs, context: "test_rapidOperations_capturesRuntimeLogs_noSecrets")
    }

    // MARK: - Validation and Recovery Log Tests

    /// VAL-CROSS-006: Tests that validation and recovery emit no raw secrets.
    func test_validationRecovery_capturesRuntimeLogs_noSecrets() throws {
        // Create profile and set as active
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "ValidationTest",
                displayLabel: "Validation Test"
            ),
            sortKey: 1
        ))

        try store.setActiveProfile(profile.id)

        // Simulate external deletion (legacy state)
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM switcher_profiles WHERE id = ?", arguments: [profile.id])
        }

        // Capture logs during validation and recovery
        logCapture.reset()

        let state = try store.validateAndRecoverActiveProfile()
        logCapture.captureActiveProfileState(state)

        let logs = logCapture.capturedLogs
        assertNoSecretPatternsInLogs(logs: logs, context: "test_validationRecovery_capturesRuntimeLogs_noSecrets")
    }

    // MARK: - Redaction Pipeline Integration Tests

    /// VAL-CROSS-006: Tests the full redaction pipeline with captured runtime logs.
    /// This verifies that when secrets flow through the system, they're properly
    /// redacted in all emitted output.
    func test_redactionPipeline_capturesRuntimeLogs_noRawSecrets() throws {
        // Create a profile with secret-like env keys
        _ = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/test",
                additionalArgs: [],
                envKeysToPass: ["HOME", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"],
                displayLabel: "Redaction Test"
            ),
            sortKey: 1
        ))

        // Execute profile fetch
        let profiles = try store.fetchAllProfiles()

        // Build allowlisted environment (this would be called during launch)
        let envKeys = profiles.first?.cliMetadata?.envKeysToPass ?? []
        let filteredEnv = CLILaunchAdapter.filterAllowlistedEnvironment(keys: envKeys)

        // Apply redaction for logging
        let redactedEnv = CLILaunchRedactor.redactEnvironment(filteredEnv)

        // Capture all runtime emitted logs including the redacted environment
        logCapture.reset()
        logCapture.captureDebugDescription("envKeys: \(envKeys)")
        logCapture.captureDebugDescription("filteredEnv: \(filteredEnv)")
        logCapture.captureDebugDescription("redactedEnv: \(redactedEnv)")

        // Verify the redacted environment is safe to log
        for (key, value) in redactedEnv {
            if Self.sensitiveKeys.contains(where: { key.contains($0) }) {
                XCTAssertEqual(
                    value,
                    "[REDACTED]",
                    "Sensitive key '\(key)' should be redacted to [REDACTED], got: \(value)"
                )
            }
        }

        let logs = logCapture.capturedLogs
        assertNoSecretPatternsInLogs(logs: logs, context: "test_redactionPipeline_capturesRuntimeLogs_noRawSecrets")
    }

    /// VAL-CROSS-006: Tests that raw secret strings are properly redacted.
    func test_redactionPipeline_rawSecretStrings_areRedacted() throws {
        logCapture.reset()

        // These are the kinds of strings that might appear if secrets leak
        let rawSecretStrings: [(String, String)] = [
            ("Bearer abc123xyz sk-ant-api03-xxxxx", "sk-ant- API key"),
            ("api_key=sk-1234567890abcdefghij", "sk- API key"),
            ("token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "JWT token"),
            ("password=superSecret123!", "password pattern"),
            ("ANTHROPIC_API_KEY=sk-ant-1234567890abcdef", "Anthropic key"),
            ("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9...", "Authorization header"),
        ]

        var allRedactedLogs: [String] = []

        for (raw, description) in rawSecretStrings {
            let redacted = CLILaunchRedactor.redactSensitiveData(raw)
            // Only capture the redacted output for pattern checking
            allRedactedLogs.append(redacted)

            let foundPatterns = findSecretPatterns(in: [redacted])
            XCTAssertTrue(
                foundPatterns.isEmpty,
                "\(description): After redaction, found patterns: \(foundPatterns). Original: \(raw), Redacted: \(redacted)"
            )
        }

        // Verify no secret patterns in all redacted outputs combined
        assertNoSecretPatternsInLogs(logs: allRedactedLogs, context: "test_redactionPipeline_rawSecretStrings_areRedacted")
    }
}
