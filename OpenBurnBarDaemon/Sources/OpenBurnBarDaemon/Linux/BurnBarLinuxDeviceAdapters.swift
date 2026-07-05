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

    private struct ServiceEndpoint: Sendable, Equatable {
        var name: String
        var hostName: String
        var address: String
        var port: Int
        var txt: [String: String]

        var baseURL: String {
            "http://\(address):\(port)"
        }
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
            let endpoint = try discoverEndpoints(adapter: .googleCast).first
            let probe = endpoint.flatMap { httpRequest(url: "\($0.baseURL)/setup/eureka_info") }
            payload = [
                "adapter": "google_cast",
                "status": probe == nil ? (discovery.instances.isEmpty ? "blocked_no_googlecast_instances" : "blocked_googlecast_control_unreachable") : "cast_reachable",
                "instances": discovery.instances.joined(separator: ","),
                "discovery_method": discovery.serviceType,
                "control_probe": endpoint.map { "\($0.baseURL)/setup/eureka_info" } ?? "",
                "control_response": String((probe ?? "").prefix(240)),
                "blocker": probe == nil ? (discovery.instances.isEmpty ? discovery.rawTranscript : "Discovered Cast endpoint did not answer /setup/eureka_info.") : "",
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
        process.arguments = ["-rtp", serviceType]
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

    private static func discoverEndpoints(adapter: AdapterID) throws -> [ServiceEndpoint] {
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
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: browsePath)
        process.arguments = ["-rtp", serviceType]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return parseEndpoints(from: readPipe(pipe), adapter: adapter)
    }

    private static func parseInstances(from transcript: String, adapter: AdapterID) -> [String] {
        var names: [String] = []
        for line in transcript.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(" ; ") || trimmed.hasPrefix("=") else { continue }
            let token: String
            if let semi = trimmed.split(separator: ";").map(String.init).dropFirst(3).first {
                token = decodeAvahiEscaped(safeQuotedTrim(semi))
            } else {
                let cols = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard cols.count > 3 else { continue }
                token = decodeAvahiEscaped(safeQuotedTrim(cols[3]))
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

    private static func parseEndpoints(from transcript: String, adapter: AdapterID) -> [ServiceEndpoint] {
        var endpoints: [String: ServiceEndpoint] = [:]
        for line in transcript.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("=") else { continue }
            let parts = splitAvahiFields(trimmed)
            guard parts.count >= 9 else { continue }
            let name = decodeAvahiEscaped(safeQuotedTrim(parts[3]))
            switch adapter {
            case .awtrixHTTP, .pixelClock:
                guard name.lowercased().hasPrefix("awtrix") else { continue }
            default:
                break
            }
            let hostName = decodeAvahiEscaped(safeQuotedTrim(parts[6]))
            let address = decodeAvahiEscaped(safeQuotedTrim(parts[7]))
            let port = Int(parts[8]) ?? 0
            guard port > 0 else { continue }
            let txt = parts.count > 9 ? parseTXTField(parts[9...].joined(separator: ";")) : [:]
            endpoints["\(name)-\(address)-\(port)"] = ServiceEndpoint(
                name: name,
                hostName: hostName,
                address: address,
                port: port,
                txt: txt
            )
        }
        return endpoints.values.sorted { left, right in
            if left.name == right.name { return left.address < right.address }
            return left.name < right.name
        }
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
            "busctl_path": which("busctl") ?? "missing",
            "dbus_send_path": which("dbus-send") ?? "missing",
            "udevadm_path": which("udevadm") ?? "missing",
            "firmware_image": ProcessInfo.processInfo.environment["OPENBURNBAR_PIXELCLOCK_FIRMWARE_IMAGE"] ?? "missing",
            "serial_devices": serialDevices().joined(separator: ","),
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

        let libudevPresent = FileManager.default.fileExists(atPath: "/usr/lib/x86_64-linux-gnu/libudev.so.1")
            || FileManager.default.fileExists(atPath: "/usr/lib/aarch64-linux-gnu/libudev.so.1")
            || FileManager.default.fileExists(atPath: "/lib/x86_64-linux-gnu/libudev.so.1")
        if libudevPresent && serialDevices().isEmpty == false {
            summary["libudev_serial"] = "serial_device_detected_firmware_image_required"
            summary["blocker"] =
                "AWTRIX serial device is present, but OPENBURNBAR_PIXELCLOCK_FIRMWARE_IMAGE is required before flashing."
        } else if libudevPresent {
            summary["libudev_serial"] = "blocked_hardware_serial_port_required"
            summary["blocker"] =
                "AWTRIX serial firmware flash requires attached USB/UART hardware and elevated port access; record when device present."
        } else {
            summary["libudev_serial"] = "blocked_libudev_or_device_nodes_unavailable"
            summary["blocker"] = "libudev runtime and AWTRIX serial device node are unavailable on this host."
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
        let configuredURL = ProcessInfo.processInfo.environment["OPENBURNBAR_PIXELCLOCK_URL"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let discoveredEndpoint = try? discoverEndpoints(adapter: .pixelClock).first
        let baseURL = configuredURL ?? discoveredEndpoint?.baseURL
        let stats = baseURL.flatMap { httpRequest(url: "\($0)/api/stats") }
        let control = baseURL.flatMap {
            httpRequest(
                url: "\($0)/api/custom",
                method: "POST",
                body: "{\"name\":\"openburnbar\",\"text\":\"mission-001\",\"color\":\"#33ccff\"}"
            )
        }
        if let baseURL, stats != nil, control != nil {
            return [
                "adapter": AdapterID.pixelClock.rawValue,
                "status": "control_ok",
                "endpoint": baseURL,
                "agent_process_count": String(agents.count),
                "agent_processes": agents.joined(separator: " | "),
                "control_surface": "cli+http",
                "accepted_commands": "discover,agents,firmware-lane,control",
                "stats_response": String((stats ?? "").prefix(240)),
                "control_response": String((control ?? "").prefix(240)),
                "blocker": "",
            ]
        }
        return [
            "adapter": AdapterID.pixelClock.rawValue,
            "status": agents.isEmpty ? "blocked_no_runtime_agent_or_device" : "runtime_agent_detected",
            "agent_process_count": String(agents.count),
            "agent_processes": agents.joined(separator: " | "),
            "control_surface": "cli+shell",
            "accepted_commands": "discover,agents,firmware-lane,control",
            "blocker": agents.isEmpty
                ? "No pixel_clock/awtrix runtime process or OPENBURNBAR_PIXELCLOCK_URL endpoint detected; attach device, start agent, or run accepted simulator before runtime control."
                : "",
        ]
    }

    private static func smartHubStatus() -> [String: String] {
        let port = ProcessInfo.processInfo.environment["OPENBURNBAR_SMARTHUB_BRIDGE_PORT"] ?? "8787"
        let probe = runCommand(path: which("curl") ?? "/usr/bin/curl", arguments: [
            "-fsS",
            "--max-time",
            "2",
            "http://127.0.0.1:\(port)/health",
        ])
        let control = runCommand(path: which("curl") ?? "/usr/bin/curl", arguments: [
            "-fsS",
            "--max-time",
            "2",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "--data",
            #"{"surface":"mission-001","message":"Linux SmartHub simulator control"}"#,
            "http://127.0.0.1:\(port)/api/display",
        ])
        return [
            "adapter": AdapterID.smartHubBridge.rawValue,
            "status": probe == nil ? "blocked_bridge_not_reachable" : (control == nil ? "bridge_reachable_control_blocked" : "bridge_control_ok"),
            "bridge_listen": "127.0.0.1:\(port)",
            "discovery": "mDNS+http",
            "control_surface": "CLI status + local bridge HTTP",
            "health_probe": "curl -fsS --max-time 2 http://127.0.0.1:\(port)/health",
            "health_response": String((probe ?? "").prefix(240)),
            "control_probe": "curl -fsS --max-time 2 -X POST http://127.0.0.1:\(port)/api/display",
            "control_response": String((control ?? "").prefix(240)),
            "blocker": probe == nil || control == nil ? "Start the Linux SmartHub bridge on 127.0.0.1:\(port) or provide a live bridge URL with /health and /api/display." : "",
            "note": "Linux shell exposes bridge status via CLI; AWTRIX via _http._tcp awtrix_* instances.",
        ]
    }

    private static func homeAssistantStatus() -> [String: String] {
        let configured = ProcessInfo.processInfo.environment["OPENBURNBAR_HOME_ASSISTANT_URL"] ?? ""
        let discovered = (try? discoverEndpoints(adapter: .homeAssistant).first?.baseURL) ?? ""
        let url = configured.isEmpty ? discovered : configured
        guard url.isEmpty == false else {
            return [
                "adapter": AdapterID.homeAssistant.rawValue,
                "status": "blocked_missing_home_assistant_url",
                "discovery": "_home-assistant._tcp",
                "control": "http_api",
                "blocker": "Set OPENBURNBAR_HOME_ASSISTANT_URL for authenticated control when instance is discovered.",
            ]
        }
        let probe = runCommand(path: which("curl") ?? "/usr/bin/curl", arguments: [
            "-fsS",
            "--max-time",
            "2",
            "\(url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/",
        ])
        let control = runCommand(path: which("curl") ?? "/usr/bin/curl", arguments: [
            "-fsS",
            "--max-time",
            "2",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "--data",
            #"{"entity_id":"light.openburnbar_simulator"}"#,
            "\(url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/services/light/turn_on",
        ])
        return [
            "adapter": AdapterID.homeAssistant.rawValue,
            "status": probe == nil ? "blocked_home_assistant_api_unreachable" : (control == nil ? "api_reachable_control_blocked" : "home_assistant_control_ok"),
            "discovery": "_home-assistant._tcp",
            "control": "http_api",
            "control_probe": "curl -fsS --max-time 2 \(url)/api/",
            "control_response": String((probe ?? "").prefix(240)),
            "service_call_response": String((control ?? "").prefix(240)),
            "blocker": probe == nil || control == nil ? "Home Assistant URL configured/discovered but /api/ or service call was not reachable." : "",
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
                status: ProcessInfo.processInfo.environment["OPENBURNBAR_HOME_ASSISTANT_URL"] == nil
                    ? "blocked_missing_home_assistant_url"
                    : "configured",
                discoveryMethod: "_home-assistant._tcp",
                blocker: ProcessInfo.processInfo.environment["OPENBURNBAR_HOME_ASSISTANT_URL"] == nil
                    ? "Requires OPENBURNBAR_HOME_ASSISTANT_URL for control beyond discovery."
                    : nil,
                evidence: "CLI devices iot homeassistant status"
            ),
            ParityRow(
                adapter: AdapterID.smartHubBridge.rawValue,
                status: smartHubStatus()["status"] == "bridge_control_ok" ? "control_ready" : "blocked_until_bridge_health_reachable",
                discoveryMethod: "loopback_http",
                blocker: smartHubStatus()["status"] == "bridge_control_ok" ? nil : "Start Linux SmartHub bridge and rerun CLI status for live control proof.",
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
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
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

    private static func httpRequest(url: String, method: String = "GET", body: String? = nil) -> String? {
        var arguments = [
            "-fsS",
            "--max-time",
            "2",
            "-X",
            method,
        ]
        if let body {
            arguments.append(contentsOf: [
                "-H",
                "Content-Type: application/json",
                "--data",
                body,
            ])
        }
        arguments.append(url)
        return runCommand(path: which("curl") ?? "/usr/bin/curl", arguments: arguments)
    }

    private static func splitAvahiFields(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuote = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\\", line.index(after: index) < line.endIndex {
                field.append(character)
                index = line.index(after: index)
                field.append(line[index])
                index = line.index(after: index)
                continue
            }
            if character == "\"" {
                inQuote.toggle()
                field.append(character)
                index = line.index(after: index)
                continue
            }
            if character == ";", !inQuote {
                fields.append(field)
                field = ""
                index = line.index(after: index)
                continue
            }
            field.append(character)
            index = line.index(after: index)
        }
        fields.append(field)
        return fields
    }

    private static func parseTXTField(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [:] }
        var txt: [String: String] = [:]
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            while index < trimmed.endIndex, trimmed[index].isWhitespace { index = trimmed.index(after: index) }
            guard index < trimmed.endIndex else { break }
            var token = ""
            if trimmed[index] == "\"" {
                index = trimmed.index(after: index)
                while index < trimmed.endIndex {
                    if trimmed[index] == "\\", trimmed.index(after: index) < trimmed.endIndex {
                        let next = trimmed.index(after: index)
                        let digits = trimmed[next...].prefix(3)
                        if digits.count == 3, digits.allSatisfy({ $0.isNumber }) {
                            token.append("\\")
                            token.append(contentsOf: digits)
                            index = trimmed.index(next, offsetBy: 3)
                            continue
                        }
                        token.append(trimmed[next])
                        index = trimmed.index(after: next)
                        continue
                    }
                    if trimmed[index] == "\"" {
                        index = trimmed.index(after: index)
                        break
                    }
                    token.append(trimmed[index])
                    index = trimmed.index(after: index)
                }
            } else {
                while index < trimmed.endIndex, trimmed[index] != ";" {
                    token.append(trimmed[index])
                    index = trimmed.index(after: index)
                }
            }
            let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                txt[kv[0].trimmingCharacters(in: .whitespacesAndNewlines)] = decodeAvahiEscaped(kv[1])
            }
            while index < trimmed.endIndex, trimmed[index] == ";" || trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
        }
        return txt
    }

    private static func safeQuotedTrim(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func decodeAvahiEscaped(_ raw: String) -> String {
        var decoded = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "\\", raw.index(after: index) < raw.endIndex {
                let next = raw.index(after: index)
                let digits = raw[next...].prefix(3)
                if digits.count == 3, digits.allSatisfy({ $0.isNumber }),
                   let code = UInt8(digits), let scalar = UnicodeScalar(UInt32(code)) {
                    decoded.append(Character(scalar))
                    index = raw.index(next, offsetBy: 3)
                    continue
                }
            }
            decoded.append(raw[index])
            index = raw.index(after: index)
        }
        return decoded
    }

    private static func serialDevices() -> [String] {
        let candidates = ["/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyACM0", "/dev/ttyACM1"]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif
