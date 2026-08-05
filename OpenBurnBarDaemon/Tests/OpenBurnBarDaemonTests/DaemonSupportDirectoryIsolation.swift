import Foundation
@testable import OpenBurnBarDaemon

/// Redirects daemon on-disk state into a throwaway directory for the duration of
/// a test.
///
/// `BurnBarDaemonPaths.supportDirectoryURL` defaults to
/// `~/Library/Application Support/OpenBurnBar` — the REAL user profile. Any test
/// that constructs a `BurnBarDaemonServer` with a default configuration
/// therefore reads and writes the developer's own mission-control journal,
/// projection, and connector state.
///
/// That is not a hypothetical. It produced two distinct, long-standing failures:
///
///   • **Pollution outward.** Test runs appended to the shared
///     `controller-events.jsonl` until it reached 164 MB / 27k events, ~21k of
///     them `project_upserted` from repeated runs.
///   • **Pollution inward.** Replaying that journal took ~80 seconds per test and
///     buried the freshly-created fixture among thousands of accumulated
///     entries, so assertions like "there is exactly one followup" failed.
///
/// Both vanish once each test owns its own directory. `supportDirectoryURL`
/// re-reads the environment on every access, so setting the override in `setUp`
/// is sufficient — no production code changes, and nothing to remember at the
/// call site.
enum DaemonSupportDirectoryIsolation {
    static let environmentKey = "OPENBURNBAR_DAEMON_SUPPORT_DIR"

    /// Creates a unique directory and points the daemon at it. Returns the value
    /// previously set, so `restore` can put it back.
    @discardableResult
    static func activate(label: String) throws -> (directory: URL, previous: String?) {
        let previous = ProcessInfo.processInfo.environment[environmentKey]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-daemon-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv(environmentKey, directory.path, 1)
        return (directory, previous)
    }

    /// Removes the directory and restores any previous override.
    static func deactivate(directory: URL?, previous: String?) {
        if let previous {
            setenv(environmentKey, previous, 1)
        } else {
            unsetenv(environmentKey)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
