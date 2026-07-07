#if os(Linux)
import Foundation

/// Avahi/DNS-SD advertisement and browse for Linux OpenBurnBar local peers.
///
/// TXT records intentionally exclude socket paths, auth tokens, and home-directory
/// prefixes so mobile pairing can discover capability without leaking secrets.
public enum BurnBarLinuxLocalPeerDiscovery {
    public static let serviceType = "_openburnbar-peer._tcp"
    public static let domain = "local."

    public struct AdvertiseConfiguration: Sendable, Equatable {
        public var hostName: String
        public var port: UInt16
        public var daemonVersion: String
        public var protocolVersion: String
        public var instanceSuffix: String?

        public init(
            hostName: String,
            port: UInt16 = 0,
            daemonVersion: String,
            protocolVersion: String,
            instanceSuffix: String? = nil
        ) {
            self.hostName = hostName
            self.port = port
            self.daemonVersion = daemonVersion
            self.protocolVersion = protocolVersion
            self.instanceSuffix = instanceSuffix
        }
    }

    public struct DiscoveredPeer: Sendable, Equatable, Codable {
        public var instanceName: String
        public var hostName: String
        public var port: Int
        public var txt: [String: String]
    }

    public struct AdvertiseHandle: Sendable {
        fileprivate let process: Process
        public let instanceName: String

        public func stop() {
            guard process.isRunning else { return }
            process.terminate()
            process.waitUntilExit()
        }
    }

    public enum DiscoveryError: Error, LocalizedError {
        case disabledByPolicy
        case avahiUnavailable(String)
        case browseFailed(String)
        case advertiseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .disabledByPolicy:
                return "Local peer discovery is disabled (OPENBURNBAR_DISABLE_LOCAL_DISCOVERY)."
            case .avahiUnavailable(let detail):
                return "Avahi tools are unavailable: \(detail)"
            case .browseFailed(let detail):
                return "Avahi browse failed: \(detail)"
            case .advertiseFailed(let detail):
                return "Avahi advertise failed: \(detail)"
            }
        }
    }

    public static func isDiscoveryDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let raw = environment["OPENBURNBAR_DISABLE_LOCAL_DISCOVERY"]
            ?? environment["BURNBAR_DISABLE_LOCAL_DISCOVERY"]
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }

    public static func sanitizedTXT(
        daemonVersion: String,
        protocolVersion: String,
        transport: String = "unix-domain"
    ) -> [String: String] {
        [
            "transport": transport,
            "daemon_version": daemonVersion,
            "protocol_version": protocolVersion,
            "platform": "linux",
            "pairing": "mdns"
        ]
    }

    public static func resolveInstanceName(
        hostName: String,
        suffix: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let base = hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        if let suffix, !suffix.isEmpty {
            return "OpenBurnBar-\(base)-\(suffix)"
        }
        if let override = environment["OPENBURNBAR_LOCAL_PEER_INSTANCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return override
        }
        return "OpenBurnBar-\(base)"
    }

    public static func startAdvertising(
        configuration: AdvertiseConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AdvertiseHandle? {
        if isDiscoveryDisabled(environment: environment) {
            return nil
        }
        guard let publishPath = whichExecutable("avahi-publish-service", environment: environment) else {
            throw DiscoveryError.avahiUnavailable("avahi-publish-service not found on PATH")
        }

        let instance = resolveInstanceName(
            hostName: configuration.hostName,
            suffix: configuration.instanceSuffix,
            environment: environment
        )
        let txtPairs = sanitizedTXT(
            daemonVersion: configuration.daemonVersion,
            protocolVersion: configuration.protocolVersion
        )
        let txtArguments = txtPairs
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: publishPath)
        process.arguments = [
            instance,
            serviceType,
            String(configuration.port)
        ] + txtArguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw DiscoveryError.advertiseFailed(error.localizedDescription)
        }

        // avahi-publish-service exits immediately when the name collides; detect fast failure.
        Thread.sleep(forTimeInterval: 0.15)
        if process.isRunning == false, process.terminationStatus != 0 {
            let detail = readPipe(process.standardError as? Pipe)
            if detail.localizedCaseInsensitiveContains("collision")
                || detail.localizedCaseInsensitiveContains("exists") {
                let retry = AdvertiseConfiguration(
                    hostName: configuration.hostName,
                    port: configuration.port,
                    daemonVersion: configuration.daemonVersion,
                    protocolVersion: configuration.protocolVersion,
                    instanceSuffix: configuration.instanceSuffix ?? "2"
                )
                return try startAdvertising(configuration: retry, environment: environment)
            }
            throw DiscoveryError.advertiseFailed(detail.isEmpty ? "avahi-publish-service exited" : detail)
        }

        return AdvertiseHandle(process: process, instanceName: instance)
    }

    public static func browsePeers(
        timeoutSeconds: TimeInterval = 3,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [DiscoveredPeer] {
        _ = timeoutSeconds
        if isDiscoveryDisabled(environment: environment) {
            return []
        }
        guard let browsePath = whichExecutable("avahi-browse", environment: environment) else {
            throw DiscoveryError.avahiUnavailable("avahi-browse not found on PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: browsePath)
        process.arguments = [
            "-rtp",
            "\(serviceType)"
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw DiscoveryError.browseFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let output = readPipe(outputPipe)
        return parseBrowseOutput(output)
    }

    public static func formatPeers(_ peers: [DiscoveredPeer], json: Bool) throws -> String {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(peers)
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        if peers.isEmpty {
            return "No OpenBurnBar peers discovered on \(serviceType)."
        }
        return peers.map { peer in
            let txt = peer.txt.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            return "\(peer.instanceName) @ \(peer.hostName):\(peer.port) {\(txt)}"
        }.joined(separator: "\n")
    }

    private static func whichExecutable(_ name: String, environment: [String: String]) -> String? {
        let pathValue = environment["PATH"] ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        for directory in pathValue.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func readPipe(_ pipe: Pipe?) -> String {
        guard let pipe else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseBrowseOutput(_ output: String) -> [DiscoveredPeer] {
        var peers: [String: DiscoveredPeer] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("=") else { continue }
            let parts = splitAvahiFields(trimmed)
            guard parts.count >= 4 else { continue }
            let instance = decodeAvahiEscaped(parts[3])
            let host = parts.count > 6 ? decodeAvahiEscaped(parts[6]) : "localhost"
            let port = parts.count > 8 ? Int(parts[8]) ?? 0 : 0
            let txt = parts.count > 9 ? parseTXTField(parts[9...].joined(separator: ";")) : [:]
            peers[instance] = DiscoveredPeer(instanceName: instance, hostName: host, port: port, txt: txt)
        }
        return peers.values.sorted { $0.instanceName < $1.instanceName }
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

    private static func decodeAvahiEscaped(_ raw: String) -> String {
        var decoded = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "\\", raw.index(after: index) < raw.endIndex {
                let next = raw.index(after: index)
                let digits = raw[next...].prefix(3)
                if digits.count == 3, digits.allSatisfy({ $0.isNumber }) {
                    if let code = UInt8(digits), let scalar = UnicodeScalar(UInt32(code)) {
                        decoded.append(Character(scalar))
                        index = raw.index(next, offsetBy: 3)
                        continue
                    }
                }
            }
            decoded.append(raw[index])
            index = raw.index(after: index)
        }
        return decoded
    }

    private static func parseTXTField(_ raw: String) -> [String: String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if trimmed.contains("\"") {
            return parseQuotedTXTRecords(trimmed)
        }
        var txt: [String: String] = [:]
        for pair in trimmed.split(separator: ";") {
            let segment = String(pair).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            let kv = segment.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                txt[kv[0].trimmingCharacters(in: .whitespacesAndNewlines)] = decodeAvahiEscaped(kv[1])
            }
        }
        return txt
    }

    private static func parseQuotedTXTRecords(_ raw: String) -> [String: String] {
        var txt: [String: String] = [:]
        var index = raw.startIndex
        while index < raw.endIndex {
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            guard index < raw.endIndex, raw[index] == "\"" else { break }
            index = raw.index(after: index)
            var token = ""
            while index < raw.endIndex {
                if raw[index] == "\\", raw.index(after: index) < raw.endIndex {
                    let next = raw.index(after: index)
                    let digits = raw[next...].prefix(3)
                    if digits.count == 3, digits.allSatisfy({ $0.isNumber }) {
                        token.append("\\")
                        token.append(contentsOf: digits)
                        index = raw.index(next, offsetBy: 3)
                        continue
                    }
                    token.append(raw[next])
                    index = raw.index(after: next)
                    continue
                }
                if raw[index] == "\"" {
                    index = raw.index(after: index)
                    break
                }
                token.append(raw[index])
                index = raw.index(after: index)
            }
            let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                txt[kv[0].trimmingCharacters(in: .whitespacesAndNewlines)] = decodeAvahiEscaped(kv[1])
            }
        }
        return txt
    }
}

extension BurnBarLinuxLocalPeerDiscovery {
    static func testing_parseBrowseOutput(_ output: String) -> [DiscoveredPeer] {
        parseBrowseOutput(output)
    }
}
#endif
