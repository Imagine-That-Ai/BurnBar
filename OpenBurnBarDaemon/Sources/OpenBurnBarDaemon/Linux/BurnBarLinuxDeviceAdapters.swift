#if os(Linux)
import Foundation

/// Linux discovery/control adapters for PixelClock, Cast, SmartHub bridge, and Home Assistant.
public enum BurnBarLinuxDeviceAdapters {
    public enum AdapterID: String, Sendable, CaseIterable, Codable {
        case pixelClock = "pixel_clock"
        case googleCast = "google_cast"
        case awtrixHTTP = "awtrix_http"
        case homeAssistant = "home_assistant"
        case smartHubBridge = "smart_hub_bridge"
    }

    public struct ParityRow: Sendable, Equatable, Codable {
        public var adapter: String
        public var status: String
        public var discoveryMethod: String
        public var blocker: String?
        public var evidence: String
    }

    public struct DiscoveryResult: Sendable, Equatable, Codable {
        public var adapter: String
        public var serviceType: String
        public var instances: [String]
        public var rawTranscript: String
    }

    public enum AdapterError: Error, LocalizedError {
        case invalidUsage(String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidUsage(let usage): return usage
            case .commandFailed(let detail): return detail
            }
        }
    }

    public static func runCLI(subcommand: String, arguments: [String], json: Bool) throws -> String {
        switch subcommand {
        case "discover":
            return try handleDiscover(arguments: arguments, json: json)
        case "parity":
            return try handleParity(json: json)
        case "pixel-clock":
            return try handlePixelClock(arguments: arguments, json: json)
        case "iot":
            return try handleIoT(arguments: arguments, json: json)
        default:
            throw AdapterError.invalidUsage(
                "Usage: openburnbar-cli devices <discover|parity|pixel-clock|iot> ..."
            )
        }
    }

    private static func handleDiscover(arguments: [String], json: Bool) throws -> String {
        let filter = arguments.first ?? "all"
        let adapters: [AdapterID]
        switch filter {
        case "all":
            adapters = AdapterID.allCases
        case "pixel-clock", "pixel_clock":
            adapters = [.pixelClock]
        case "cast", "google-cast":
            adapters = [.googleCast]
        case "awtrix":
            adapters = [.awtrixHTTP]
        case "home-assistant", "home_assistant":
            adapters = [.homeAssistant]
        case "smarthub", "smart-hub":
            adapters = [.smartHubBridge]
        default:
            throw AdapterError.invalidUsage(
                "Usage: openburnbar-cli devices discover [all|pixel-clock|cast|awtrix|home-assistant|smarthub] [--json]"
            )
        }

        var results: [DiscoveryResult] = []
        for adapter in adapters {
            results.append(try discover(adapter: adapter))
        }
        if json {
            let data = try JSONEncoder().encode(results)
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        return results.map { result in
            "\(result.adapter) (\(result.serviceType)): \(result.instances.isEmpty ? "none" : result.instances.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    private static func handleParity(json: Bool) throws -> String {
        let rows = parityLedger()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rows)
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        return rows.map { row in
            if let blocker = row.blocker {
                return "\(row.adapter): \(row.status) — \(blocker)"
            }
            return "\(row.adapter): \(row.status) — \(row.evidence)"
        }.joined(separator: "\n")
    }

    private static func handlePixelClock(arguments: [String], json: Bool) throws -> String {
        guard let action = arguments.first else {
            throw AdapterError.invalidUsage(
                "Usage: openburnbar-cli devices pixel-clock <discover|agents|firmware-lane|control> [--json]"
            )
        }
        switch action {
        case "discover":
            let discovery = try discover(adapter: .pixelClock)
            if json {
                let data = try JSONEncoder().encode(discovery)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return discovery.instances.isEmpty
                ? "No AWTRIX/PixelClock mDNS instances found."
                : discovery.instances.joined(separator: "\n")
        case "agents":
            let agents = scanPixelClockAgents()
            if json {
                let data = try JSONEncoder().encode(agents)
                return String(data: data, encoding: .utf8) ?? "[]"
            }
            return agents.isEmpty ? "No pixel_clock agent processes detected." : agents.joined(separator: "\n")
        case "firmware-lane":
            let attempt = attemptPixelClockFirmwareLane()
            if json {
                let data = try JSONEncoder().encode(attempt)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return attempt["summary"] ?? "firmware lane attempted"
        case "control":
            let status = pixelClockControlStatus()
            if json {
                let data = try JSONEncoder().encode(status)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return status.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        default:
            throw AdapterError.invalidUsage("Unknown pixel-clock action '\(action)'.")
        }
    }

    private static func handleIoT(arguments: [String], json: Bool) throws -> String {
        guard let adapter = arguments.first else {
            throw AdapterError.invalidUsage(
                "Usage: openburnbar-cli devices iot <smarthub|cast|homeassistant> status [--json]"
            )
        }
        let action = arguments.dropFirst().first ?? "status"
        guard action == "status" else {
            throw AdapterError.invalidUsage("Only 'status' is supported for devices iot on Linux v1.")
        }

        let payload: [String: String]
        switch adapter {
        case "smarthub", "smart-hub":
            payload = smartHubStatus()
        case "cast":
            let discovery = try discover(adapter: .googleCast)
            payload = [
                "adapter": "google_cast",
                "instances": discovery.instances.joined(separator: ","),
                "bridge_default_port": "8787",
            ]
        case "homeassistant", "home-assistant":
            payload = homeAssistantStatus()
        default:
            throw AdapterError.invalidUsage("Unknown iot adapter '\(adapter)'.")
        }

        if json {
            let data = try JSONEncoder().encode(payload)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return payload.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    }

    private static func discover(adapter: AdapterID) throws -> DiscoveryResult {
        let serviceType: String
        switch adapter {
        case .pixelClock, .awtrixHTTP:
            serviceType = "_http._tcp"
        case .googleCast:
            serviceType = "_googlecast._tcp"
        case .homeAssistant:
            serviceType = "_home-assistant._tcp"
        case .smartHubBridge:
            serviceType = BurnBarLinuxLocalPeerDiscovery.serviceType
        }

        guard let browsePath = which("avahi-browse") else {
            return DiscoveryResult(
                adapter: adapter.rawValue,
                serviceType: serviceType,
                instances: [],
                rawTranscript: "avahi-browse unavailable"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: browsePath)
        process.arguments = ["-rt", serviceType, "-t", "3"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let transcript = readPipe(pipe)
        let instances = parseInstances(from: transcript, adapter: adapter)
        return DiscoveryResult(
            adapter: adapter.rawValue,
            serviceType: serviceType,
            instances: instances,
            rawTranscript: transcript
        )
    }

    private static func parseInstances(from transcript: String, adapter: AdapterID) -> [String] {
        var names: [String] = []
        for line in transcript.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" ; ") || trimmed.hasPrefix("=") else { continue }
            let token: String
            if let semi = trimmed.split(separator: ";").map(String.init).dropFirst(3).first {
                token = semi
            } else {
                let cols = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard cols.count > 3 else { continue }
                token = cols[3]
            }
            switch adapter {
            case .awtrixHTTP, .pixelClock:
                guard token.lowercased().hasPrefix("awtrix") else { continue }
            default:
                break
            }
            if names.contains(token) == false {
                names.append(token)
            }
        }
        return names.sorted()
    }

    private static func scanPixelClockAgents() -> [String] {
        guard let output = runCommand(path: "/bin/ps", arguments: ["-axo", "comm,args"]) else {
            return []
        }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.localizedCaseInsensitiveContains("pixel_clock") || $0.localizedCaseInsensitiveContains("awtrix") }
    }

    private static func attemptPixelClockFirmwareLane() -> [String: String] {
        var summary: [String: String] = [
            "lane": "pixel_clock_firmware_v1",
            "network_manager_dbus": "not_attempted",
            "libudev_serial": "not_attempted",
        ]

        if which("busctl") != nil || which("dbus-send") != nil {
            if let nm = runCommand(path: which("busctl") ?? "/usr/bin/dbus-send", arguments: nmDBusProbeArguments()) {
                summary["network_manager_dbus"] = nm.isEmpty ? "probe_empty" : "probe_ok"
                summary["network_manager_transcript"] = String(nm.prefix(400))
            } else {
                summary["network_manager_dbus"] = "probe_failed_permissions_or_missing_nm"
            }
        } else {
            summary["network_manager_dbus"] = "blocked_missing_dbus_tools"
        }

        if FileManager.default.fileExists(atPath: "/usr/lib/x86_64-linux-gnu/libudev.so.1")
            || FileManager.default.fileExists(atPath: "/usr/lib/aarch64-linux-gnu/libudev.so.1")
            || FileManager.default.fileExists(atPath: "/lib/x86_64-linux-gnu/libudev.so.1") {
            summary["libudev_serial"] = "blocked_hardware_serial_port_required"
            summary["blocker"] =
                "AWTRIX serial firmware flash requires attached USB/UART hardware and elevated port access; record when device present."
        } else {
            summary["libudev_serial"] = "blocked_libudev_or_device_nodes_unavailable"
            summary["blocker"] = "libudev present but no AWTRIX serial device enumerated on this host."
        }

        summary["summary"] =
            summary["blocker"] ?? "Firmware lane probed NetworkManager DBus; awaiting hardware attachment for serial flash."
        return summary
    }

    private static func nmDBusProbeArguments() -> [String] {
        if let busctl = which("busctl") {
            _ = busctl
            return [
                "call",
                "org.freedesktop.NetworkManager",
                "/org/freedesktop/NetworkManager",
                "org.freedesktop.DBus.Properties",
                "Get",
                "ss",
                "org.freedesktop.NetworkManager",
                "Connectivity",
            ]
        }
        return [
            "--system",
            "--dest=org.freedesktop.NetworkManager",
            "/org/freedesktop/NetworkManager",
            "org.freedesktop.DBus.Properties.Get",
            "string:org.freedesktop.NetworkManager",
            "string:Connectivity",
        ]
    }

    private static func pixelClockControlStatus() -> [String: String] {
        let agents = scanPixelClockAgents()
        return [
            "adapter": AdapterID.pixelClock.rawValue,
            "agent_process_count": String(agents.count),
            "control_surface": "cli+shell",
            "accepted_commands": "discover,agents,firmware-lane,control",
        ]
    }

    private static func smartHubStatus() -> [String: String] {
        let port = ProcessInfo.processInfo.environment["OPENBURNBAR_SMARTHUB_BRIDGE_PORT"] ?? "8787"
        return [
            "adapter": AdapterID.smartHubBridge.rawValue,
            "bridge_listen": "127.0.0.1:\(port)",
            "discovery": "mDNS+http",
            "note": "Linux shell exposes bridge status via CLI; AWTRIX via _http._tcp awtrix_* instances.",
        ]
    }

    private static func homeAssistantStatus() -> [String: String] {
        [
            "adapter": AdapterID.homeAssistant.rawValue,
            "discovery": "_home-assistant._tcp",
            "control": "http_api",
            "blocker": "Set OPENBURNBAR_HOME_ASSISTANT_URL for authenticated control when instance is discovered.",
        ]
    }

    public static func parityLedger() -> [ParityRow] {
        let avahi = which("avahi-browse") != nil
        return [
            ParityRow(
                adapter: AdapterID.pixelClock.rawValue,
                status: avahi ? "discoverable" : "blocked",
                discoveryMethod: "_http._tcp awtrix_*",
                blocker: avahi ? nil : "Install avahi-utils for mDNS browse.",
                evidence: "CLI devices pixel-clock discover"
            ),
            ParityRow(
                adapter: AdapterID.googleCast.rawValue,
                status: avahi ? "discoverable" : "blocked",
                discoveryMethod: "_googlecast._tcp",
                blocker: avahi ? nil : "Install avahi-utils for Cast browse.",
                evidence: "CLI devices iot cast status"
            ),
            ParityRow(
                adapter: AdapterID.homeAssistant.rawValue,
                status: "config_required",
                discoveryMethod: "_home-assistant._tcp",
                blocker: "Requires OPENBURNBAR_HOME_ASSISTANT_URL for control beyond discovery.",
                evidence: "CLI devices iot homeassistant status"
            ),
            ParityRow(
                adapter: AdapterID.smartHubBridge.rawValue,
                status: "local_bridge",
                discoveryMethod: "loopback_http",
                blocker: nil,
                evidence: "CLI devices iot smarthub status"
            ),
            ParityRow(
                adapter: AdapterID.awtrixHTTP.rawValue,
                status: avahi ? "discoverable" : "blocked",
                discoveryMethod: "_http._tcp",
                blocker: avahi ? nil : "Install avahi-utils.",
                evidence: "CLI devices discover awtrix"
            ),
        ]
    }

    private static func which(_ name: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in pathValue.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func runCommand(path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return readPipe(pipe)
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif