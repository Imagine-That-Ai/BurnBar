import Darwin
import Foundation

// MARK: - Factory Droid probe: signal-file parsing
//
// Parsing types and helpers for `BurnBarFleetFactoryDroidProbe`, kept in a
// dedicated file so the probe struct stays under the lint type-body budget
// (precedent: BurnBarFleetLifecycleFixtures.swift).

extension BurnBarFleetFactoryDroidProbe {
    private static let nonTerminalStatuses: Set<String> = [
        "running", "queued", "pending", "in_progress", "active", "working"
    ]
    private static let terminalStatuses: Set<String> = [
        "completed", "failed", "cancelled"
    ]

    // MARK: - Task ledger

    struct Ledger {
        let path: String
        let invocations: [Invocation]
        let malformedReason: String?
    }

    struct Invocation {
        let cwd: String?
        let updatedAt: Date?
        let status: String?
        let malformedReason: String?

        /// A non-terminal invocation with a fresh `updatedAt` is live
        /// evidence. The status vocabulary is pinned in
        /// BURNBAR_FLEET_SIGNALS.md: non-terminal is exactly
        /// `running | queued | pending | in_progress | active | working`;
        /// terminal is exactly `completed | failed | cancelled`. Anything
        /// else (including unknown strings like `"bogus"`) is malformed and
        /// never counts as non-terminal.
        var isNonTerminal: Bool {
            guard let status else { return false }
            return BurnBarFleetFactoryDroidProbe.nonTerminalStatuses.contains(status)
        }

        func isLive(now: Date, freshnessSeconds: TimeInterval) -> Bool {
            guard malformedReason == nil, isNonTerminal, let updatedAt else { return false }
            return now.timeIntervalSince(updatedAt) <= freshnessSeconds
        }
    }

    static func readLedger(at path: String, timeoutSeconds: TimeInterval) -> Ledger? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                let reason = "task-invocations.json is not a JSON object."
                return Ledger(path: path, invocations: [], malformedReason: reason)
            }
            object = dictionary
        } catch {
            let reason = BurnBarFleetProbeJSON.readFailureReason(error)
            return Ledger(path: path, invocations: [], malformedReason: reason)
        }

        guard let rawInvocations = object["invocations"] as? [[String: Any]] else {
            let reason = "task-invocations.json is missing the invocations array."
            return Ledger(path: path, invocations: [], malformedReason: reason)
        }

        var invocations: [Invocation] = []
        var malformedCount = 0
        for raw in rawInvocations {
            let status = BurnBarFleetProbeJSON.stringValue(raw["status"])
            let updatedAt = BurnBarFleetProbeJSON.dateFromEpochMilliseconds(raw["updatedAt"])
            let cwd = BurnBarFleetProbeJSON.stringValue(raw["cwd"])
            if status == nil || updatedAt == nil {
                malformedCount += 1
                invocations.append(
                    Invocation(
                        cwd: cwd,
                        updatedAt: updatedAt,
                        status: status,
                        malformedReason: "Invocation is missing a string status or numeric updatedAt."
                    )
                )
            } else if let status, !isKnownStatus(status) {
                // Unknown status strings (e.g. "bogus") are malformed: they
                // never count as non-terminal and never yield running.
                malformedCount += 1
                invocations.append(
                    Invocation(
                        cwd: cwd,
                        updatedAt: updatedAt,
                        status: status,
                        malformedReason: "Invocation status '\(status)' is not in the documented vocabulary."
                    )
                )
            } else {
                invocations.append(
                    Invocation(cwd: cwd, updatedAt: updatedAt, status: status, malformedReason: nil)
                )
            }
        }

        let reason: String?
        if malformedCount > 0 {
            // Surface the first malformed invocation's reason verbatim so the
            // offending status/key is visible in the probeHealth reason.
            let firstReason = invocations.first { $0.malformedReason != nil }?.malformedReason ?? "malformed"
            if malformedCount == 1 {
                reason = "Invocation malformed: \(firstReason)"
            } else {
                reason = "\(malformedCount) invocation(s) malformed; first: \(firstReason)"
            }
        } else {
            reason = nil
        }
        return Ledger(path: path, invocations: invocations, malformedReason: reason)
    }

    /// The documented invocation status vocabulary (pinned in
    /// BURNBAR_FLEET_SIGNALS.md): non-terminal
    /// `running | queued | pending | in_progress | active | working` and
    /// terminal `completed | failed | cancelled`.
    static func isKnownStatus(_ status: String) -> Bool {
        nonTerminalStatuses.contains(status) || terminalStatuses.contains(status)
    }

    // MARK: - Background processes

    struct BackgroundRegistry {
        let path: String
        let entries: [BackgroundEntry]
        let malformedReason: String?
    }

    struct BackgroundEntry {
        let pid: Int?
        let cwd: String?
        let startTime: Date?
        let malformedReason: String?

        /// Liveness applies the recorded process-start identity check
        /// (PID-reuse guard) before `kill -0`, to the same standard as the
        /// claude-code probe: a pid whose current process started after the
        /// entry's recorded `startTime` is a reused pid and is treated as
        /// dead. A missing/unqueryable record skips the guard (`kill -0`
        /// decides). A PRESENT-but-invalid `startTime` is malformed (the
        /// entry never reaches liveness) — it is never silently converted to
        /// nil and treated like an absent record.
        var isLive: Bool {
            guard malformedReason == nil, let pid else { return false }
            return BurnBarFleetProcessLiveness.isLiveProcess(pid: pid, fileStartedAt: startTime)
        }
    }

    static func readBackgroundProcesses(at path: String, timeoutSeconds: TimeInterval) -> BackgroundRegistry? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: timeoutSeconds)
            guard let dictionary = raw as? [String: Any] else {
                let reason = "background-processes.json is not a JSON object."
                return BackgroundRegistry(path: path, entries: [], malformedReason: reason)
            }
            object = dictionary
        } catch {
            let reason = BurnBarFleetProbeJSON.readFailureReason(error)
            return BackgroundRegistry(path: path, entries: [], malformedReason: reason)
        }

        guard let rawEntries = object["processes"] as? [[String: Any]] else {
            let reason = "background-processes.json is missing the processes array."
            return BackgroundRegistry(path: path, entries: [], malformedReason: reason)
        }

        var entries: [BackgroundEntry] = []
        var malformedCount = 0
        for raw in rawEntries {
            let pid = BurnBarFleetProbeJSON.pidValue(raw["pid"])
            let cwd = BurnBarFleetProbeJSON.stringValue(raw["cwd"])
            let startTimeOutcome = BurnBarFleetProbeJSON.dateFromEpochMillisecondsTriState(raw["startTime"])
            if pid == nil {
                malformedCount += 1
                let reason = BurnBarFleetProbeJSON.pidRejectionReason(raw["pid"])
                    ?? "Entry is missing a numeric pid."
                entries.append(
                    BackgroundEntry(pid: nil, cwd: cwd, startTime: nil, malformedReason: reason)
                )
            } else if case .invalid(let reason) = startTimeOutcome {
                // A PRESENT-but-invalid startTime is malformed: the entry
                // degrades typed and never reaches liveness — it is never
                // treated like an absent record (which would skip the
                // pid-reuse guard and let a live pid pass).
                malformedCount += 1
                entries.append(
                    BackgroundEntry(pid: nil, cwd: cwd, startTime: nil, malformedReason: reason)
                )
            } else {
                let startTime: Date?
                if case .valid(let date) = startTimeOutcome {
                    startTime = date
                } else {
                    startTime = nil
                }
                entries.append(BackgroundEntry(pid: pid, cwd: cwd, startTime: startTime, malformedReason: nil))
            }
        }

        let reason: String?
        if malformedCount > 0 {
            // Surface the first malformed entry's reason verbatim so the
            // offending pid/startTime is visible in the probeHealth reason
            // (same pattern as the task ledger).
            let firstReason = entries.first { $0.malformedReason != nil }?.malformedReason ?? "malformed"
            if malformedCount == 1 {
                reason = "Background entry malformed: \(firstReason)"
            } else {
                reason = "\(malformedCount) background entries malformed; first: \(firstReason)"
            }
        } else {
            reason = nil
        }
        return BackgroundRegistry(path: path, entries: entries, malformedReason: reason)
    }

    // MARK: - Session / mission directories

    struct DirectoryFreshness {
        let path: String
        let name: String
        let mtime: Date?

        func isFresh(now: Date, freshnessSeconds: TimeInterval) -> Bool {
            guard let mtime else { return false }
            return now.timeIntervalSince(mtime) <= freshnessSeconds
        }
    }

    struct DirectoryReadResult {
        let directories: [DirectoryFreshness]
        let rejectionReasons: [String]
    }

    static func readDirectoryFreshness(at path: String) -> DirectoryReadResult {
        // `contentsOfDirectory` follows a symlink. Reject the declared
        // directory itself before opening it so `sessions -> ../artifacts`
        // cannot turn a known path into an escape hatch.
        var directoryStatus = stat()
        guard lstat(path, &directoryStatus) == 0 else {
            // Missing declared directories are ordinary absent signals.
            return DirectoryReadResult(directories: [], rejectionReasons: [])
        }
        let directoryType = directoryStatus.st_mode & S_IFMT
        guard directoryType == S_IFDIR else {
            if directoryType == S_IFLNK {
                return DirectoryReadResult(
                    directories: [],
                    rejectionReasons: ["Rejected symlink declared directory \(path)."]
                )
            }
            return DirectoryReadResult(directories: [], rejectionReasons: [])
        }

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return DirectoryReadResult(
                directories: [],
                rejectionReasons: ["Unable to read declared directory \(path)."]
            )
        }

        var result: [DirectoryFreshness] = []
        var rejectionReasons: [String] = []
        for name in contents {
            let itemPath = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(name).path
            var itemStatus = stat()
            guard lstat(itemPath, &itemStatus) == 0 else {
                rejectionReasons.append("Unable to inspect declared descendant \(itemPath).")
                continue
            }
            guard (itemStatus.st_mode & S_IFMT) != S_IFLNK else {
                // Do not resolve or stat the link target. A descendant can
                // point into ~/.factory/artifacts (or any other outside
                // root), so rejecting it is the hermetic boundary.
                rejectionReasons.append("Rejected symlink descendant \(itemPath).")
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: itemPath))?[.modificationDate] as? Date
            result.append(DirectoryFreshness(path: itemPath, name: name, mtime: mtime))
        }
        return DirectoryReadResult(directories: result, rejectionReasons: rejectionReasons)
    }
}
