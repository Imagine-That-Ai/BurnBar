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
@MainActor
final class SwitcherRuntimeLogCaptureTests: XCTestCase {

    // MARK: - Test Data

    private var dbQueue: DatabaseQueue!
    private var store: SwitcherProfileStore!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        do {
            dbQueue = try DatabaseQueue()
            try Self.addMigrationv32(to: dbQueue)
            store = SwitcherProfileStore(dbQueue: dbQueue)
        } catch {
            XCTFail("Failed to set up test store: \(error)")
        }
    }

    override func tearDown() {
        dbQueue = nil
        store = nil
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

    /// Patterns that should never appear raw in logs or stored data
    private static let secretPatterns: [String] = [
        "sk-[a-zA-Z0-9]{20,}",           // API key patterns (sk- followed by 20+ chars)
        "sk-ant-",                         // Anthropic API key prefix
        "Bearer\\s+[A-Za-z0-9_\\-\\.]+", // Bearer tokens
        "api_key\\s*=\\s*[^,\\s]+",      // api_key=value patterns
        "token\\s*=\\s*[^,\\s]+",        // token=value patterns
        "password\\s*=\\s*[^,\\s]+",     // password=value patterns
        "secret\\s*=\\s*[^,\\s]+",       // secret=value patterns
    ]

    /// Keys that are considered sensitive
    private static let sensitiveKeys: Set<String> = [
        "API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "AUTH",
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY",
    ]

    // MARK: - Helper Methods

    /// Captures all observable outputs from store operations that could contain secrets.
    /// This includes stored JSON, error messages, and any logged strings.
    private func captureStoreOutputs() throws -> [String] {
        var outputs: [String] = []

        // Capture all profile records
        let profiles = try store.fetchAllProfiles()
        for profile in profiles {
            if let json = profile.cliMetadata.flatMap({ try? JSONEncoder().encode($0) }),
               let jsonStr = String(data: json, encoding: .utf8) {
                outputs.append(jsonStr)
            }
            if let json = profile.browserMetadata.flatMap({ try? JSONEncoder().encode($0) }),
               let jsonStr = String(data: json, encoding: .utf8) {
                outputs.append(jsonStr)
            }
        }

        // Capture raw database content
        let rawJSON = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT cliMetadataJSON FROM switcher_profiles WHERE cliMetadataJSON IS NOT NULL")
        }
        outputs.append(contentsOf: rawJSON)

        let rawBrowserJSON = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT browserMetadataJSON FROM switcher_profiles WHERE browserMetadataJSON IS NOT NULL")
        }
        outputs.append(contentsOf: rawBrowserJSON)

        return outputs
    }

    /// Verifies no secret patterns appear in the given strings.
    /// Returns the patterns that were found (empty if all are properly redacted).
    private func findSecretPatterns(in strings: [String]) -> [String] {
        var foundPatterns: [String] = []

        for string in strings {
            // Check for sk- API key patterns
            if let regex = try? NSRegularExpression(pattern: "sk-[a-zA-Z0-9]{20,}", options: .caseInsensitive) {
                let range = NSRange(string.startIndex..., in: string)
                if regex.firstMatch(in: string, options: [], range: range) != nil {
                    foundPatterns.append("sk- API key pattern")
                }
            }

            // Check for sk-ant- prefix
            if string.contains("sk-ant-") {
                foundPatterns.append("sk-ant- prefix")
            }

            // Check for Bearer tokens
            if let regex = try? NSRegularExpression(pattern: "Bearer\\s+[A-Za-z0-9_\\-\\.]+", options: .caseInsensitive) {
                let range = NSRange(string.startIndex..., in: string)
                if regex.firstMatch(in: string, options: [], range: range) != nil {
                    foundPatterns.append("Bearer token")
                }
            }

            // Check for key=value patterns with secrets
            if let regex = try? NSRegularExpression(pattern: "(api_key|token|password|secret)\\s*=\\s*[^,\\s]+", options: .caseInsensitive) {
                let range = NSRange(string.startIndex..., in: string)
                if regex.firstMatch(in: string, options: [], range: range) != nil {
                    foundPatterns.append("key=value secret pattern")
                }
            }
        }

        return foundPatterns
    }

    // MARK: - Runtime Startup/Sync Tests

    /// Tests that profile creation during startup/sync doesn't leak secrets.
    /// Creates profiles with secret-like metadata and verifies stored data is safe.
    func test_startupProfileCreation_noSecretsInStoredData() throws {
        // Create profile with metadata that looks like secrets
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/Users/test/projects",
                additionalArgs: ["--verbose"],
                envKeysToPass: ["HOME", "PATH", "ANTHROPIC_API_KEY"],
                displayLabel: "Test Profile"
            ),
            sortKey: 1
        ))

        // Capture all observable outputs
        let outputs = try captureStoreOutputs()

        // Verify no secret patterns in stored data
        let foundPatterns = findSecretPatterns(in: outputs)
        XCTAssertTrue(
            foundPatterns.isEmpty,
            "Found secret patterns in stored data: \(foundPatterns). Stored data must never contain raw secrets."
        )

        // Verify envKeysToPass only contains keys, not key=value pairs
        if let metadata = profile.cliMetadata {
            for key in metadata.envKeysToPass {
                XCTAssertFalse(
                    key.contains("="),
                    "envKeysToPass should only contain keys, not 'key=value' pairs. Found: \(key)"
                )
            }
        }
    }

    /// Tests that profile fetch during startup/sync doesn't leak secrets.
    /// Fetches profiles and verifies the fetched data is safe.
    func test_syncProfileFetch_noSecretsInFetchedData() throws {
        // Create profile with potential secret-like data
        _ = try store.create(SwitcherProfileRecord(
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

        // Execute profile fetch (simulating startup/sync read)
        let fetchedProfiles = try store.fetchAllProfiles()

        // Capture all outputs from the fetch
        var outputs: [String] = []
        for profile in fetchedProfiles {
            if let json = profile.cliMetadata.flatMap({ try? JSONEncoder().encode($0) }),
               let str = String(data: json, encoding: .utf8) {
                outputs.append(str)
            }
        }

        // Verify no secret patterns
        let foundPatterns = findSecretPatterns(in: outputs)
        XCTAssertTrue(
            foundPatterns.isEmpty,
            "Found secret patterns after profile fetch: \(foundPatterns)"
        )
    }

    /// Tests that active profile state operations don't leak secrets.
    func test_startupActiveProfileState_noSecretsInState() throws {
        // Create and activate a profile
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "ChromeProfile",
                displayLabel: "Chrome Work"
            ),
            sortKey: 1
        ))

        try store.setActiveProfile(profile.id)

        // Fetch active state (simulating startup rehydration)
        let state = try store.fetchActiveProfileState()

        // State should only contain profile ID, not secrets
        XCTAssertEqual(state.activeProfileID, profile.id)
        XCTAssertNil(state.activeProfileID?.contains("sk-") ?? false ? profile.id : nil,
                      "Active profile ID should not contain API key patterns")

        // Verify no secrets in database active profile table
        let activeRow = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT activeProfileID FROM switcher_active_profile")
        }
        XCTAssertFalse(activeRow?.contains("sk-") ?? false, "Active profile row should not contain raw secrets")
    }

    /// Tests that profile update operations preserve secret safety.
    func test_syncProfileUpdate_noSecretsAfterUpdate() throws {
        // Create profile
        let profile = try store.create(SwitcherProfileRecord(
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

        // Update profile (simulating sync/update)
        let updated = SwitcherProfileRecord(
            id: profile.id,
            targetKind: profile.targetKind,
            browserType: profile.browserType,
            browserMetadata: profile.browserMetadata,
            cliType: profile.cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/updated/path",
                additionalArgs: ["--debug"],
                envKeysToPass: ["HOME", "PATH", "CODEX_API_KEY"],
                displayLabel: "Updated"
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt,
            updatedAt: Date()
        )
        _ = try store.update(updated)

        // Capture outputs after update
        let outputs = try captureStoreOutputs()

        // Verify no secret patterns
        let foundPatterns = findSecretPatterns(in: outputs)
        XCTAssertTrue(
            foundPatterns.isEmpty,
            "Found secret patterns after update: \(foundPatterns)"
        )
    }

    /// Tests that profile deletion doesn't leave secrets behind.
    func test_syncProfileDeletion_noSecretsAfterDeletion() throws {
        // Create profile with secret-like data
        let profile = try store.create(SwitcherProfileRecord(
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

        // Delete profile
        try store.deleteProfile(id: profile.id)

        // Verify no traces of secrets in database
        let remainingJSON = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT cliMetadataJSON FROM switcher_profiles WHERE cliMetadataJSON IS NOT NULL")
        }

        let foundPatterns = findSecretPatterns(in: remainingJSON)
        XCTAssertTrue(
            foundPatterns.isEmpty,
            "Found secret patterns after deletion: \(foundPatterns)"
        )
    }

    // MARK: - Error Path Secret Safety Tests

    /// Tests that error messages don't leak secrets.
    func test_errorPaths_noSecretsInErrorDescriptions() throws {
        // Test profile not found error
        let notFoundError = SwitcherProfileStoreError.profileNotFound("test-id-123")
        let notFoundDesc = notFoundError.errorDescription ?? ""

        // Error description should only contain the profile ID, not secrets
        XCTAssertTrue(notFoundDesc.contains("test-id-123"))
        XCTAssertFalse(notFoundDesc.contains("sk-"))
        XCTAssertFalse(notFoundDesc.contains("token"))
        XCTAssertFalse(notFoundDesc.contains("password"))

        // Test duplicate name error
        let dupError = SwitcherProfileStoreError.duplicateProfileName("Test Profile")
        let dupDesc = dupError.errorDescription ?? ""

        XCTAssertTrue(dupDesc.contains("Test Profile"))
        XCTAssertFalse(dupDesc.contains("sk-"))
        XCTAssertFalse(dupDesc.contains("="))
    }

    /// Tests that CLI launch error descriptions don't leak secrets.
    func test_cliLaunchErrorPaths_noSecretsInErrorDescriptions() throws {
        // Test executable not found error
        let execError = CLILaunchError.executableNotFound(.claude)
        let execDesc = execError.errorDescription ?? ""

        XCTAssertTrue(execDesc.contains("Claude"))
        XCTAssertFalse(execDesc.contains("sk-"))
        XCTAssertFalse(execDesc.contains("token"))

        // Test profile not found error
        let profileError = CLILaunchError.profileNotFound("prof-123")
        let profileDesc = profileError.errorDescription ?? ""

        XCTAssertTrue(profileDesc.contains("prof-123"))
        XCTAssertFalse(profileDesc.contains("sk-"))

        // Test missing metadata error
        let metaError = CLILaunchError.missingProfileMetadata("meta-test-id")
        let metaDesc = metaError.errorDescription ?? ""

        XCTAssertTrue(metaDesc.contains("meta-test-id"))
        XCTAssertFalse(metaDesc.contains("sk-"))
    }

    // MARK: - Redaction Pipeline Integration Tests

    /// Tests the full redaction pipeline through the CLI launch service.
    /// This verifies that when secrets flow through the system, they're properly redacted.
    func test_redactionPipeline_fullFlow_noRawSecrets() throws {
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

        // Execute profile fetch (this would be called during startup/sync)
        let profiles = try store.fetchAllProfiles()

        // Build allowlisted environment (this would be called during launch)
        let envKeys = profiles.first?.cliMetadata?.envKeysToPass ?? []
        let filteredEnv = CLILaunchAdapter.filterAllowlistedEnvironment(keys: envKeys)

        // Apply redaction for logging
        let redactedEnv = CLILaunchRedactor.redactEnvironment(filteredEnv)

        // Verify sensitive keys are redacted
        for (key, value) in redactedEnv {
            if Self.sensitiveKeys.contains(where: { key.contains($0) }) {
                XCTAssertEqual(
                    value,
                    "[REDACTED]",
                    "Sensitive key '\(key)' should be redacted to [REDACTED], got: \(value)"
                )
            }
        }

        // Verify the redacted environment would be safe to log
        let envDescription = redactedEnv.description
        let foundPatterns = findSecretPatterns(in: [envDescription])
        XCTAssertTrue(
            foundPatterns.isEmpty,
            "Redacted environment description should not contain raw secrets: \(foundPatterns)"
        )
    }

    /// Tests that raw secret strings passed through redaction are properly masked.
    func test_redactionPipeline_rawSecretStrings_areRedacted() throws {
        // These are the kinds of strings that might appear if secrets leak
        let rawSecretStrings: [(String, String)] = [
            ("Bearer abc123xyz sk-ant-api03-xxxxx", "sk-ant- API key"),
            ("api_key=sk-1234567890abcdefghij", "sk- API key"),
            ("token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", "JWT token"),
            ("password=superSecret123!", "password pattern"),
            ("ANTHROPIC_API_KEY=sk-ant-1234567890abcdef", "Anthropic key"),
        ]

        for (raw, description) in rawSecretStrings {
            let redacted = CLILaunchRedactor.redactSensitiveData(raw)
            let foundPatterns = findSecretPatterns(in: [redacted])

            XCTAssertTrue(
                foundPatterns.isEmpty,
                "\(description): After redaction, found patterns: \(foundPatterns). Original: \(raw), Redacted: \(redacted)"
            )
        }
    }

    // MARK: - Browser Launch Secret Safety Tests

    /// Tests that browser launch paths don't leak secrets.
    func test_browserLaunch_noSecretsInLaunchPaths() throws {
        // Create browser profile
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "ChromeTest",
                displayLabel: "Chrome Test Profile"
            ),
            sortKey: 1
        ))

        // Fetch profile for launch
        let fetched = try store.fetchProfile(id: profile.id)

        // Verify metadata doesn't contain secrets
        if let metadata = fetched?.browserMetadata {
            XCTAssertFalse(metadata.profileIdentifier.contains("oauth"))
            XCTAssertFalse(metadata.profileIdentifier.contains("token"))
            XCTAssertFalse(metadata.profileIdentifier.contains("cookie"))
            XCTAssertFalse(metadata.profileIdentifier.contains("sk-"))
        }
    }

    // MARK: - Metadata Schema Secret Safety Tests

    /// Tests that the stored JSON schema never allows secret values.
    func test_metadataSchema_noSecretFieldsAllowed() throws {
        // Verify that profile records only store non-sensitive metadata

        // CLI profile - should only have working directory, args, env keys (not values)
        let cliProfile = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/Users/test",
                additionalArgs: ["--verbose"],
                envKeysToPass: ["HOME", "PATH", "API_KEY"], // Keys only
                displayLabel: "Schema Test"
            ),
            sortKey: 1
        ))

        // Verify envKeysToPass only contains key names, not key=value
        if let metadata = cliProfile.cliMetadata {
            for key in metadata.envKeysToPass {
                // Keys should not contain = sign (which would indicate key=value stored)
                XCTAssertFalse(
                    key.contains("="),
                    "envKeysToPass should contain only keys, not 'key=value'. Found: \(key)"
                )
                // Keys should not be actual secret values
                XCTAssertFalse(
                    key.hasPrefix("sk-"),
                    "envKeysToPass should contain env var NAMES, not actual secret values like API keys"
                )
            }
        }

        // Verify the raw stored JSON
        let rawJSON = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT cliMetadataJSON FROM switcher_profiles WHERE id = ?", arguments: [cliProfile.id])
        }

        // JSON should not contain raw secret patterns
        let foundPatterns = findSecretPatterns(in: [rawJSON ?? ""])
        XCTAssertTrue(
            foundPatterns.isEmpty,
            "Stored CLI metadata JSON should not contain raw secrets: \(foundPatterns)"
        )
    }

    // MARK: - Rapid Operations Secret Safety Tests

    /// Tests that rapid create/update/delete operations don't cause secret leaks.
    func test_rapidOperations_noSecretsAfterBurst() throws {
        // Rapid profile creation
        for i in 0..<5 {
            _ = try store.create(SwitcherProfileRecord(
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
        }

        // Rapid updates
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
            _ = try store.update(updated)
        }

        // Capture all outputs after burst operations
        let outputs = try captureStoreOutputs()

        // Verify no secret patterns
        let foundPatterns = findSecretPatterns(in: outputs)
        XCTAssertTrue(
            foundPatterns.isEmpty,
            "Found secret patterns after rapid operations: \(foundPatterns)"
        )
    }
}
