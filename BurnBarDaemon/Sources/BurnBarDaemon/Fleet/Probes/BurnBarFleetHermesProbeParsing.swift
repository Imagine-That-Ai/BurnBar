import BurnBarCore
import Foundation

private enum BurnBarFleetHermesDateParsing {
    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

// MARK: - Hermes probe: signal-file parsing
//
// Parsing types and helpers for `BurnBarFleetHermesProbe`, kept in a
// dedicated file so the probe struct stays under the lint type-body budget
// (precedent: BurnBarFleetFactoryDroidProbeParsing.swift).

extension BurnBarFleetHermesProbe {
    struct RawSignals {
        let gatewayPid: GatewayPidSignal?
        let heartbeat: HeartbeatSignal?
        let gatewayState: GatewayStateSignal?
        let processes: ProcessesSignal?
    }

    static func readSignals(rootURL: URL, timeoutSeconds: TimeInterval) -> RawSignals {
        let probeDeadline = BurnBarFleetProbeJSON.monotonicDeadline(after: timeoutSeconds)
        return RawSignals(
            gatewayPid: readGatewayPid(
                at: rootURL.appendingPathComponent("gateway.pid").path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: probeDeadline
            ),
            heartbeat: readHeartbeat(
                at: rootURL.appendingPathComponent("state/gateway.heartbeat").path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: probeDeadline
            ),
            gatewayState: readGatewayState(
                at: rootURL.appendingPathComponent("gateway_state.json").path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: probeDeadline
            ),
            processes: readProcesses(
                at: rootURL.appendingPathComponent("processes.json").path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: probeDeadline
            )
        )
    }

    /// Bundles the parsed signal files plus the derived evidence trail and
    /// health state for one probe run.
    struct Signals {
        let gatewayPid: GatewayPidSignal?
        let heartbeat: HeartbeatSignal?
        let gatewayState: GatewayStateSignal?
        let processes: ProcessesSignal?
        let sources: [BurnBarFleetSignalSource]
        let healthState: BurnBarFleetProbeHealthState
    }

    struct GatewayPidSignal {
        let path: String
        let pid: Int?
        let startTime: Date?
        let malformedReason: String?
    }

    struct HeartbeatSignal {
        let path: String
        let pid: Int?
        let updatedAt: Date?
        let startTime: Date?
        let malformedReason: String?

        func isFresh(now: Date, freshnessSeconds: TimeInterval) -> Bool {
            guard let updatedAt else { return false }
            return now.timeIntervalSince(updatedAt) < freshnessSeconds
        }
    }

    struct GatewayStateSignal {
        let path: String
        let activeAgents: Int?
        let malformedReason: String?
    }

    struct ProcessesSignal {
        let path: String
        let entries: [ProcessEntry]
        let malformedReason: String?
    }

    struct ProcessEntry {
        let cwd: String?
    }

    // MARK: - Readers

    static func readGatewayPid(
        at path: String,
        timeoutSeconds: TimeInterval,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> GatewayPidSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(
                at: path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
            guard let dictionary = raw as? [String: Any] else {
                return GatewayPidSignal(
                    path: path,
                    pid: nil,
                    startTime: nil,
                    malformedReason: "gateway.pid is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return GatewayPidSignal(
                path: path,
                pid: nil,
                startTime: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        guard let pid = BurnBarFleetProbeJSON.pidValue(object["pid"]) else {
            let reason = BurnBarFleetProbeJSON.pidRejectionReason(object["pid"])
                ?? "gateway.pid is missing a numeric pid."
            return GatewayPidSignal(
                path: path,
                pid: nil,
                startTime: nil,
                malformedReason: reason
            )
        }

        let startTimeOutcome = BurnBarFleetProbeJSON.dateFromStartTimeTriState(object["start_time"])
        guard case .invalid(let reason) = startTimeOutcome else {
            let startTime: Date?
            if case .valid(let date) = startTimeOutcome {
                startTime = date
            } else {
                startTime = nil
            }
            return GatewayPidSignal(path: path, pid: pid, startTime: startTime, malformedReason: nil)
        }
        return GatewayPidSignal(
            path: path,
            pid: nil,
            startTime: nil,
            malformedReason: "gateway.pid start_time is malformed: \(reason)"
        )
    }

    static func readHeartbeat(
        at path: String,
        timeoutSeconds: TimeInterval,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> HeartbeatSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(
                at: path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
            guard let dictionary = raw as? [String: Any] else {
                return HeartbeatSignal(
                    path: path,
                    pid: nil,
                    updatedAt: nil,
                    startTime: nil,
                    malformedReason: "gateway.heartbeat is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return HeartbeatSignal(
                path: path,
                pid: nil,
                updatedAt: nil,
                startTime: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        let pid: Int?
        if let rawPid = object["pid"], !(rawPid is NSNull) {
            guard let parsedPid = BurnBarFleetProbeJSON.pidValue(rawPid) else {
                let reason = BurnBarFleetProbeJSON.pidRejectionReason(rawPid)
                    ?? "gateway.heartbeat pid is malformed."
                return HeartbeatSignal(
                    path: path,
                    pid: nil,
                    updatedAt: nil,
                    startTime: nil,
                    malformedReason: reason
                )
            }
            pid = parsedPid
        } else {
            // The heartbeat pid is optional. When absent, the gateway.pid
            // record supplies association while the heartbeat start_time
            // remains authoritative for pid-reuse guarding when present.
            pid = nil
        }

        let updatedAt = Self.parseHeartbeatUpdatedAt(object["updated_at"])
        guard updatedAt != nil else {
            return HeartbeatSignal(
                path: path,
                pid: pid,
                updatedAt: nil,
                startTime: nil,
                malformedReason: "gateway.heartbeat is missing a parseable updated_at."
            )
        }

        let startTimeOutcome = BurnBarFleetProbeJSON.dateFromStartTimeTriState(object["start_time"])
        guard case .invalid(let reason) = startTimeOutcome else {
            let startTime: Date?
            if case .valid(let date) = startTimeOutcome {
                startTime = date
            } else {
                startTime = nil
            }
            return HeartbeatSignal(
                path: path,
                pid: pid,
                updatedAt: updatedAt,
                startTime: startTime,
                malformedReason: nil
            )
        }
        return HeartbeatSignal(
            path: path,
            pid: nil,
            updatedAt: nil,
            startTime: nil,
            malformedReason: "gateway.heartbeat start_time is malformed: \(reason)"
        )
    }

    static func readGatewayState(
        at path: String,
        timeoutSeconds: TimeInterval,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> GatewayStateSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [String: Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(
                at: path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
            guard let dictionary = raw as? [String: Any] else {
                return GatewayStateSignal(
                    path: path,
                    activeAgents: nil,
                    malformedReason: "gateway_state.json is not a JSON object."
                )
            }
            object = dictionary
        } catch {
            return GatewayStateSignal(
                path: path,
                activeAgents: nil,
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        guard let activeAgents = BurnBarFleetProbeJSON.integerValue(object["active_agents"]) else {
            return GatewayStateSignal(
                path: path,
                activeAgents: nil,
                malformedReason: "gateway_state.json is missing a numeric active_agents."
            )
        }
        return GatewayStateSignal(path: path, activeAgents: activeAgents, malformedReason: nil)
    }

    static func readProcesses(
        at path: String,
        timeoutSeconds: TimeInterval,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) -> ProcessesSignal? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let object: [Any]
        do {
            let raw = try BurnBarFleetProbeJSON.readJSONBounded(
                at: path,
                timeoutSeconds: timeoutSeconds,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
            )
            guard let array = raw as? [Any] else {
                return ProcessesSignal(
                    path: path,
                    entries: [],
                    malformedReason: "processes.json is not a JSON array."
                )
            }
            object = array
        } catch {
            return ProcessesSignal(
                path: path,
                entries: [],
                malformedReason: BurnBarFleetProbeJSON.readFailureReason(error)
            )
        }

        var entries: [ProcessEntry] = []
        var malformedReasons: [String] = []
        for (index, item) in object.enumerated() {
            if let dictionary = item as? [String: Any] {
                entries.append(ProcessEntry(cwd: BurnBarFleetProbeJSON.stringValue(dictionary["cwd"])))
            } else {
                malformedReasons.append("processes.json entry \(index) is not an object.")
            }
        }
        return ProcessesSignal(
            path: path,
            entries: entries,
            malformedReason: malformedReasons.isEmpty ? nil : malformedReasons.joined(separator: " ")
        )
    }

    /// `updated_at` is an ISO-8601 string (the real heartbeat writes
    /// fractional seconds, e.g. `2026-08-12T16:00:41.601457+00:00`) or an
    /// integral epoch-milliseconds number. Fractional-second strings are
    /// tried first, then the plain form, then the strict epoch-ms helper.
    private static func parseHeartbeatUpdatedAt(_ value: Any?) -> Date? {
        if let raw = value as? String {
            return try? BurnBarFleetHermesDateParsing.iso8601.parse(raw)
        }
        return BurnBarFleetProbeJSON.dateFromEpochMilliseconds(value)
    }

    // MARK: - Detail strings

    static func pidDetail(_ signal: GatewayPidSignal) -> String? {
        guard let pid = signal.pid else { return nil }
        return "pid \(pid)"
    }

    static func heartbeatDetail(_ signal: HeartbeatSignal, now: Date) -> String? {
        guard let pid = signal.pid else { return nil }
        if let updatedAt = signal.updatedAt {
            let age = Int(now.timeIntervalSince(updatedAt))
            return "pid \(pid), \(age)s ago"
        }
        return "pid \(pid)"
    }

    static func stateDetail(_ signal: GatewayStateSignal) -> String? {
        guard let activeAgents = signal.activeAgents else { return nil }
        return "active_agents \(activeAgents)"
    }
}
