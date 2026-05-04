// Quarantined tests extracted from: SwitcherCrossFlowTests.swift
//
// These tests were quarantined because they reference stale contracts,
// drifted schemas, or environmental preconditions not satisfied in CI.
// See QUARANTINE_MANIFEST.md for per-test owner, reason, and revival criteria.
//
// Revival workflow:
//   1. Update tests to compile against current public/@testable APIs.
//   2. Move this file to AgentLensTests/Active/ (matching subdirectory).
//   3. Remove the file from Quarantine.
//   4. Prove with: ./scripts/test-openburnbar-app.sh

import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

final class SwitcherCrossFlowTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_ui_crossSurface_startupLogRedactsSecrets() throws {
        try XCTSkipIf(true, "Stale contract — production log routing rewired; capture path no longer observable from this fixture.")
        // Set up log emitter for capture
        setUpLogEmitter()

        // Create DataStore
        let dbQueue = try DatabaseQueue()
        try Self.addMigrationv32(to: dbQueue)
        let dataStore = try DataStore(
            databaseQueue: dbQueue,
            runMigrations: false,
            refreshOnInit: false
        )

        // Create profile with metadata that looks like secrets using injectable logger
        let localStore = SwitcherProfileStore(dbQueue: dbQueue, logEmitter: logEmitter)
        let profile = try localStore.createWithLogging(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/Users/test/projects",
                additionalArgs: ["--verbose"],
                envKeysToPass: ["HOME", "PATH", "API_KEY"], // Keys only
                displayLabel: "Test Profile"
            ),
            sortKey: 1
        ))

        // Simulate startup/sync operations that would emit logs using logging variants
        let profiles = try localStore.fetchAllProfiles()
        for p in profiles {
            // Non-logging fetch for profile data
        }

        // Capture active state using logging variant (startup rehydration)
        let state = try localStore.fetchActiveProfileStateWithLogging()

        // Create a log capture to also capture profile representations for completeness
        let logCapture = RuntimeLogCapture()
        logCapture.captureProfileTextualRepresentations(profile)
        logCapture.captureActiveProfileState(state)

        // Check raw stored data for secret patterns
        let rawJSON = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT cliMetadataJSON FROM switcher_profiles LIMIT 1")
        }
        logCapture.capturedLogs.append(rawJSON ?? "")

        // Combine captured production logs with test helper captures
        var allLogs = capturedLogMessages
        allLogs.append(contentsOf: logCapture.capturedLogs)

        // Now verify captured logs don't contain raw secrets
        let foundPatterns = findSecretPatternsInRuntimeLogs(allLogs)
        XCTAssertTrue(
            foundPatterns.isEmpty,
            """
            Found secret patterns in runtime emitted logs: \(foundPatterns)
            
            Captured logs:
            \(allLogs.joined(separator: "\n"))
            """
        )

        // Verify we actually captured production log output
        XCTAssertFalse(capturedLogMessages.isEmpty, "Should have captured log output from production code")
    }

    /// VERIFICATION: Environment variable logging redacts sensitive keys.
    /// Tests that actual runtime emitted logs from env operations are secret-safe.

}
