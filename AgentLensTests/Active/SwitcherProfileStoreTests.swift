import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

final class SwitcherProfileStoreTests: XCTestCase {
    private var store: SwitcherProfileStore!
    private var dbQueue: DatabaseQueue!

    override func setUp() {
        do {
            dbQueue = try DatabaseQueue()
            try self.addMigrationv32(to: dbQueue)
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

    private func addMigrationv32(to dbQueue: DatabaseQueue) throws {
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

    // MARK: - Browser Profile Tests

    func test_createBrowserProfile_storesMetadataOnly() throws {
        let metadata = SwitcherBrowserProfileMetadata(
            profileIdentifier: "Profile 1",
            displayLabel: "Work Chrome"
        )
        let record = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: metadata,
            sortKey: 1
        )

        let created = try store.create(record)

        XCTAssertEqual(created.id, record.id)
        XCTAssertEqual(created.targetKind, .browser)
        XCTAssertEqual(created.browserType, .chrome)
        XCTAssertEqual(created.browserMetadata?.profileIdentifier, "Profile 1")
        XCTAssertEqual(created.browserMetadata?.displayLabel, "Work Chrome")
        XCTAssertNil(created.cliType)
        XCTAssertNil(created.cliMetadata)
    }

    func test_fetchProfile_retrievesCreatedProfile() throws {
        let metadata = SwitcherBrowserProfileMetadata(profileIdentifier: "Default")
        let record = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: metadata,
            sortKey: 1
        )
        _ = try store.create(record)

        let fetched = try store.fetchProfile(id: record.id)

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, record.id)
        XCTAssertEqual(fetched?.browserType, .safari)
        XCTAssertEqual(fetched?.browserMetadata?.profileIdentifier, "Default")
    }

    func test_fetchAllProfiles_returnsDeterministicOrder() throws {
        // Create profiles in non-sorted order
        let metadata = SwitcherBrowserProfileMetadata(profileIdentifier: "P3")
        let p3 = try store.create(SwitcherProfileRecord(
            targetKind: .browser, browserType: .chrome, browserMetadata: metadata, sortKey: 0
        ))
        let p1 = try store.create(SwitcherProfileRecord(
            targetKind: .browser, browserType: .chrome, browserMetadata: metadata, sortKey: 0
        ))
        let p2 = try store.create(SwitcherProfileRecord(
            targetKind: .browser, browserType: .chrome, browserMetadata: metadata, sortKey: 0
        ))

        let all = try store.fetchAllProfiles()

        XCTAssertEqual(all.count, 3)
        // Should be ordered by sortKey ASC, createdAt ASC
        // p3 created first, p1 second, p2 third (sortKey=0 for all)
        XCTAssertEqual(all[0].id, p3.id)
        XCTAssertEqual(all[1].id, p1.id)
        XCTAssertEqual(all[2].id, p2.id)
    }

    func test_updateProfile_preservesSortKeyAndCreatedAt() throws {
        let original = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Original"),
            sortKey: 5
        ))
        let persistedOriginal = try XCTUnwrap(store.fetchProfile(id: original.id))

        let updatedRecord = SwitcherProfileRecord(
            id: original.id,
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Updated", displayLabel: "New Label"),
            sortKey: original.sortKey, // should be ignored
            createdAt: original.createdAt, // should be ignored
            updatedAt: original.updatedAt // should be ignored
        )
        let updated = try store.update(updatedRecord)

        XCTAssertEqual(updated.sortKey, 5) // sortKey preserved
        // Compare against persisted storage value to avoid in-memory precision drift.
        XCTAssertEqual(updated.createdAt.timeIntervalSince1970, persistedOriginal.createdAt.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertGreaterThan(updated.updatedAt, persistedOriginal.updatedAt) // updatedAt changed
        XCTAssertEqual(updated.browserMetadata?.profileIdentifier, "Updated")
        XCTAssertEqual(updated.browserMetadata?.displayLabel, "New Label")
    }

    func test_deleteProfile_removesFromStore() throws {
        let record = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "ToDelete"),
            sortKey: 1
        ))

        try store.deleteProfile(id: record.id)

        XCTAssertNil(try store.fetchProfile(id: record.id))
    }

    // MARK: - CLI Profile Tests

    func test_createCLIProfile_storesMetadataOnly() throws {
        let metadata = SwitcherCLIProfileMetadata(
            workingDirectory: "/Users/test/projects",
            additionalArgs: ["--verbose"],
            envKeysToPass: ["HOME", "PATH"],
            displayLabel: "Work CLI"
        )
        let record = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        )

        let created = try store.create(record)

        XCTAssertEqual(created.id, record.id)
        XCTAssertEqual(created.targetKind, .cli)
        XCTAssertEqual(created.cliType, .claude)
        XCTAssertEqual(created.cliMetadata?.workingDirectory, "/Users/test/projects")
        XCTAssertEqual(created.cliMetadata?.additionalArgs, ["--verbose"])
        XCTAssertEqual(created.cliMetadata?.envKeysToPass, ["HOME", "PATH"])
        XCTAssertEqual(created.cliMetadata?.displayLabel, "Work CLI")
        XCTAssertNil(created.browserType)
        XCTAssertNil(created.browserMetadata)
    }

    func test_fetchProfiles_filteredByTargetKind() throws {
        let browserRecord = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Chrome"),
            sortKey: 1
        ))
        _ = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 2
        ))
        _ = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 3
        ))

        let browserProfiles = try store.fetchProfiles(targetKind: .browser)
        let cliProfiles = try store.fetchProfiles(targetKind: .cli)

        XCTAssertEqual(browserProfiles.count, 1)
        XCTAssertEqual(browserProfiles.first?.id, browserRecord.id)
        XCTAssertEqual(cliProfiles.count, 2)
    }

    func test_updateCLIProfile_metadata() throws {
        let original = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "Original"),
            sortKey: 1
        ))

        let updated = try store.update(SwitcherProfileRecord(
            id: original.id,
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: "/new/path",
                displayLabel: "Updated"
            ),
            sortKey: 0,
            createdAt: Date(),
            updatedAt: Date()
        ))

        XCTAssertEqual(updated.cliMetadata?.workingDirectory, "/new/path")
        XCTAssertEqual(updated.cliMetadata?.displayLabel, "Updated")
    }

    // MARK: - Active Profile State Tests

    func test_fetchActiveProfileState_initiallyNil() throws {
        let state = try store.fetchActiveProfileState()

        XCTAssertNil(state.activeProfileID)
    }

    func test_setActiveProfile_persistsSelection() throws {
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Test"),
            sortKey: 1
        ))

        try store.setActiveProfile(profile.id)

        let state = try store.fetchActiveProfileState()
        XCTAssertEqual(state.activeProfileID, profile.id)
    }

    func test_setActiveProfile_toNil_clearsSelection() throws {
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Test"),
            sortKey: 1
        ))
        try store.setActiveProfile(profile.id)

        try store.setActiveProfile(nil)

        let state = try store.fetchActiveProfileState()
        XCTAssertNil(state.activeProfileID)
    }

    func test_deleteActiveProfile_clearsActiveState() throws {
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Test"),
            sortKey: 1
        ))
        try store.setActiveProfile(profile.id)

        try store.deleteProfile(id: profile.id)

        let state = try store.fetchActiveProfileState()
        XCTAssertNil(state.activeProfileID)
    }

    func test_validateAndRecoverActiveProfile_staleMarkerCleared() throws {
        // Create a profile and set it active
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Test"),
            sortKey: 1
        ))
        try store.setActiveProfile(profile.id)

        // Delete the profile externally (simulating external deletion)
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM switcher_profiles WHERE id = ?", arguments: [profile.id])
        }

        // Validate should detect stale and recover
        let state = try store.validateAndRecoverActiveProfile()

        XCTAssertNil(state.activeProfileID) // No fallback since profile was deleted
    }

    func test_selectFallbackActiveProfile_afterDelete() throws {
        // Create multiple profiles
        let p1 = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "P1"),
            sortKey: 2
        ))
        let p2 = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "P2"),
            sortKey: 1 // lower sortKey
        ))
        _ = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "P3"),
            sortKey: 3
        ))

        try store.setActiveProfile(p1.id)

        // Delete the active profile
        try store.deleteProfile(id: p1.id)

        let state = try store.fetchActiveProfileState()
        // Should fallback to p2 (lowest sortKey among remaining)
        XCTAssertEqual(state.activeProfileID, p2.id)
    }

    // MARK: - Deterministic Ordering Tests

    func test_profileListing_usesSortKeyAndCreatedAt() throws {
        // Create profiles with explicit sortKeys
        for i in [3, 1, 2] {
            _ = try store.create(SwitcherProfileRecord(
                targetKind: .browser,
                browserType: .chrome,
                browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "P\(i)"),
                sortKey: i
            ))
        }

        let all = try store.fetchAllProfiles()

        XCTAssertEqual(all.map { $0.sortKey }, [1, 2, 3])
    }

    // MARK: - Migration Safety Tests

    func test_emptyStore_migrationSucceeds() throws {
        // Verify the store works on a fresh database
        let freshDb = try DatabaseQueue()
        try self.addMigrationv32(to: freshDb)
        let freshStore = SwitcherProfileStore(dbQueue: freshDb)

        let state = try freshStore.fetchActiveProfileState()
        XCTAssertNil(state.activeProfileID)

        let profiles = try freshStore.fetchAllProfiles()
        XCTAssertEqual(profiles.count, 0)
    }

    func test_noCredentialsStored_inBrowserProfile() throws {
        let metadata = SwitcherBrowserProfileMetadata(
            profileIdentifier: "TestProfile",
            displayLabel: "Test"
        )
        let record = SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: metadata,
            sortKey: 1
        )
        _ = try store.create(record)

        // Verify by fetching and checking there are no credential fields
        let fetched = try store.fetchProfile(id: record.id)!

        // The metadata should NOT contain any secret/credential fields
        XCTAssertFalse(fetched.browserMetadata?.profileIdentifier.contains("token") ?? false)
        XCTAssertFalse(fetched.browserMetadata?.profileIdentifier.contains("cookie") ?? false)
        XCTAssertFalse(fetched.browserMetadata?.profileIdentifier.contains("auth") ?? false)
    }

    func test_noCredentialsStored_inCLIProfile() throws {
        let metadata = SwitcherCLIProfileMetadata(
            workingDirectory: "/test/path",
            additionalArgs: ["--flag"],
            envKeysToPass: ["PATH"], // Only keys, not values
            displayLabel: "Test CLI"
        )
        let record = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        )
        _ = try store.create(record)

        let fetched = try store.fetchProfile(id: record.id)!

        // envKeysToPass should only contain KEY names, never values
        XCTAssertFalse(fetched.cliMetadata?.envKeysToPass.contains(where: { $0.contains("=") }) ?? true)
        // Should not contain any secret-like patterns
        XCTAssertNil(fetched.cliMetadata?.additionalArgs.first(where: { $0.contains("secret") }))
    }

    // MARK: - Uniqueness Validation Tests

    func test_existsProfileWithNormalizedName_detectsDuplicate() throws {
        let metadata = SwitcherBrowserProfileMetadata(profileIdentifier: "TestProfile")
        _ = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: metadata,
            sortKey: 1
        ))

        // Check with same name (case insensitive)
        let exists = try store.existsProfileWithNormalizedName("TestProfile")
        XCTAssertTrue(exists)

        // Check with different name
        let notExists = try store.existsProfileWithNormalizedName("DifferentName")
        XCTAssertFalse(notExists)
    }

    func test_existsProfileWithNormalizedName_excludesSelf() throws {
        let metadata = SwitcherBrowserProfileMetadata(profileIdentifier: "TestProfile")
        let record = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: metadata,
            sortKey: 1
        ))

        // Should return false when excluding self
        let exists = try store.existsProfileWithNormalizedName("TestProfile", excludingID: record.id)
        XCTAssertFalse(exists)

        // Should return true when not excluding
        let existsNoExclude = try store.existsProfileWithNormalizedName("TestProfile")
        XCTAssertTrue(existsNoExclude)
    }

    // MARK: - Display Name Tests

    func test_profileDisplayName_browserProfile() throws {
        let metadata = SwitcherBrowserProfileMetadata(
            profileIdentifier: "Profile1",
            displayLabel: "Work Browser"
        )
        let record = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: metadata,
            sortKey: 1
        ))

        XCTAssertEqual(record.displayName, "Work Browser")
    }

    func test_profileDisplayName_cliProfile() throws {
        let metadata = SwitcherCLIProfileMetadata(displayLabel: nil)
        let record = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: metadata,
            sortKey: 1
        ))

        // Should fall back to cliType.displayName when no displayLabel
        XCTAssertEqual(record.displayName, "Claude Code")
    }

    // MARK: - Target Type Tests

    func test_concreteTargetType_browserChrome() throws {
        let record = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Test"),
            sortKey: 1
        ))

        XCTAssertEqual(record.concreteTargetType, "chrome")
    }

    func test_concreteTargetType_cliCodex() throws {
        let record = try store.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: 1
        ))

        XCTAssertEqual(record.concreteTargetType, "codex")
    }

    // MARK: - Sort Key Assignment Tests

    func test_create_assignsIncrementingSortKey() throws {
        let p1 = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "P1"),
            sortKey: 0 // request 0
        ))
        let p2 = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "P2"),
            sortKey: 0 // request 0
        ))
        let p3 = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "P3"),
            sortKey: 0 // request 0
        ))

        // Each should get an auto-incremented sortKey
        XCTAssertEqual(p1.sortKey, 1)
        XCTAssertEqual(p2.sortKey, 2)
        XCTAssertEqual(p3.sortKey, 3)
    }

    // MARK: - Profile Not Found Error

    func test_updateProfile_throwsWhenNotFound() throws {
        let record = SwitcherProfileRecord(
            id: "nonexistent-id",
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Test"),
            sortKey: 1
        )

        do {
            _ = try store.update(record)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is SwitcherProfileStoreError)
        }
    }

    // MARK: - Legacy Multi-Row Hydration Tests

    /// Regression test: verifies deterministic resolution when legacy code left
    /// multiple rows in switcher_active_profile due to unordered LIMIT 1 reads.
    func test_fetchActiveProfileState_resolvesDeterministically_withLegacyMultiRow() throws {
        // Create a profile first
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "LegacyTest"),
            sortKey: 1
        ))

        // Simulate legacy state: insert multiple rows directly (like old buggy code did)
        try dbQueue.write { db in
            // Oldest row
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: ["old-profile-1", Date().addingTimeInterval(-200)]
            )
            // Most recent row (should be canonical after cleanup)
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [profile.id, Date()]
            )
            // Middle row
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: ["old-profile-2", Date().addingTimeInterval(-100)]
            )
        }

        // First fetch should clean up duplicates and return the most recent
        let state = try store.fetchActiveProfileState()

        // Should return the profile.id (most recent row) not the stale ones
        XCTAssertEqual(state.activeProfileID, profile.id)

        // Verify only one row remains after cleanup
        let rowCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM switcher_active_profile") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }

    /// Verifies that repeated relaunch reads are deterministic even when
    /// legacy multi-row state was present initially.
    func test_fetchActiveProfileState_deterministicRepeatedRelaunchReads() throws {
        let profile1 = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Profile1"),
            sortKey: 1
        ))
        let profile2 = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "Profile2"),
            sortKey: 2
        ))

        // Simulate legacy state with multiple rows
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM switcher_active_profile")
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [profile1.id, Date().addingTimeInterval(-100)]
            )
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [profile2.id, Date()]
            )
        }

        // Simulate multiple relaunch reads - should be deterministic
        for _ in 0..<5 {
            let state = try store.fetchActiveProfileState()
            XCTAssertEqual(state.activeProfileID, profile2.id, "Repeated reads should be deterministic")
        }

        // Verify only one row remains
        let rowCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM switcher_active_profile") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }

    /// Verifies cleanup selects correct canonical row when active profile was
    /// the older row and a newer row with different profile exists.
    func test_fetchActiveProfileState_cleansUpStaleActiveWithNewerRowPresent() throws {
        let staleProfile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "StaleProfile"),
            sortKey: 1
        ))
        let currentProfile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .safari,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "CurrentProfile"),
            sortKey: 2
        ))

        // Legacy state: stale profile is active but there's a newer row with different profile
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM switcher_active_profile")
            // Stale (older) row - profile1 active
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [staleProfile.id, Date().addingTimeInterval(-100)]
            )
            // Newer row - profile2 active
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [currentProfile.id, Date()]
            )
        }

        // Fetch should return the newer row (currentProfile)
        let state = try store.fetchActiveProfileState()
        XCTAssertEqual(state.activeProfileID, currentProfile.id)

        // Verify only one row remains
        let rowCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM switcher_active_profile") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }

    /// Verifies that after hydration cleanup, subsequent writes work correctly.
    func test_fetchActiveProfileState_cleanupPreservesWriteIntegrity() throws {
        let profile = try store.create(SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(profileIdentifier: "TestProfile"),
            sortKey: 1
        ))

        // Create legacy multi-row state
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [nil, Date().addingTimeInterval(-100)]
            )
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [profile.id, Date()]
            )
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [nil, Date().addingTimeInterval(-50)]
            )
        }

        // Hydrate
        let state = try store.fetchActiveProfileState()
        XCTAssertEqual(state.activeProfileID, profile.id)

        // Now set to nil and back - should work correctly
        try store.setActiveProfile(nil)
        let nilState = try store.fetchActiveProfileState()
        XCTAssertNil(nilState.activeProfileID)

        try store.setActiveProfile(profile.id)
        let resetState = try store.fetchActiveProfileState()
        XCTAssertEqual(resetState.activeProfileID, profile.id)

        // Verify still exactly one row
        let rowCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM switcher_active_profile") ?? 0
        }
        XCTAssertEqual(rowCount, 1)
    }
}
