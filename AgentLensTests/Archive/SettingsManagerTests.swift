// Quarantined tests extracted from: SettingsManagerTests.swift
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

import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class SettingsManagerTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_detectAvailableProviders_returnsFalseForAllOnCleanSystem() throws {
        // Skipped: `detectAvailableProviders` walks the host file system for
        // every provider's log directory (e.g. `~/.codex/sessions`). Any
        // developer running this on a machine that has even one provider
        // installed will fail. Re-enable inside a hermetic FS sandbox.
        try XCTSkipIf(true, "Environmental — requires a hermetic FS sandbox.")
    }


}
