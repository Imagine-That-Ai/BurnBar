import Foundation

public enum BurnBarLocalPeerCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case cli
    case http
    case pixelClock = "pixelclock"
    case smartHub = "smarthub"
    case cast
    case homeAssistant = "homeassistant"
}

public struct BurnBarLocalPeerMetadata: Codable, Hashable, Sendable {
    public static let serviceType = "_openburnbar._tcp"
    public static let defaultDomain = "local"

    public let instanceName: String
    public let peerID: String
    public let port: Int
    public let protocolVersion: Int
    public let platform: String
    public let capabilities: [BurnBarLocalPeerCapability]
    public let gatewayEnabled: Bool

    public init(
        instanceName: String,
        peerID: String,
        port: Int,
        protocolVersion: Int = 1,
        platform: String = "linux",
        capabilities: [BurnBarLocalPeerCapability] = BurnBarLocalPeerCapability.allCases,
        gatewayEnabled: Bool = true
    ) {
        self.instanceName = instanceName
        self.peerID = peerID
        self.port = port
        self.protocolVersion = protocolVersion
        self.platform = platform
        self.capabilities = capabilities
        self.gatewayEnabled = gatewayEnabled
    }

    public var txtRecords: [String: String] {
        [
            "caps": capabilities.map(\.rawValue).sorted().joined(separator: ","),
            "gateway": gatewayEnabled ? "loopback" : "disabled",
            "peer": peerID,
            "platform": platform,
            "proto": String(protocolVersion),
            "socket": "unix"
        ]
    }

    public var sortedTXTArguments: [String] {
        txtRecords
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    public func privacyValidationIssues() -> [String] {
        let sensitiveFragments = ["token", "secret", "key=", "auth", "/users/", "/home/", "/var/", "/tmp/", "library/application support"]
        return sortedTXTArguments.compactMap { argument in
            let lowered = argument.lowercased()
            guard sensitiveFragments.contains(where: { lowered.contains($0) }) || argument.contains("~") else {
                return nil
            }
            return "TXT record leaks private or secret-bearing value: \(argument)"
        }
    }
}

public struct BurnBarAvahiPublishPlan: Codable, Hashable, Sendable {
    public let metadata: BurnBarLocalPeerMetadata
    public let serviceType: String
    public let domain: String
    public let argv: [String]
    public let registerTranscript: String

    public init(metadata: BurnBarLocalPeerMetadata, domain: String = BurnBarLocalPeerMetadata.defaultDomain) {
        self.metadata = metadata
        self.serviceType = BurnBarLocalPeerMetadata.serviceType
        self.domain = domain
        self.argv = [
            "avahi-publish-service",
            "--no-reverse",
            metadata.instanceName,
            BurnBarLocalPeerMetadata.serviceType,
            String(metadata.port)
        ] + metadata.sortedTXTArguments
        self.registerTranscript = """
        Established under name '\(metadata.instanceName)'
        Service data: \(metadata.sortedTXTArguments.joined(separator: " "))
        """
    }
}

public struct BurnBarAvahiBrowsePlan: Codable, Hashable, Sendable {
    public let serviceType: String
    public let argv: [String]

    public init(serviceType: String) {
        self.serviceType = serviceType
        self.argv = ["avahi-browse", "--resolve", "--parsable", "--terminate", serviceType]
    }
}

public enum BurnBarAvahiCommandFactory {
    public static func publishPlan(for metadata: BurnBarLocalPeerMetadata) -> BurnBarAvahiPublishPlan {
        BurnBarAvahiPublishPlan(metadata: metadata)
    }

    public static func browsePlan(serviceType: String = BurnBarLocalPeerMetadata.serviceType) -> BurnBarAvahiBrowsePlan {
        BurnBarAvahiBrowsePlan(serviceType: serviceType)
    }

    public static var pixelClockBrowsePlan: BurnBarAvahiBrowsePlan {
        BurnBarAvahiBrowsePlan(serviceType: "_http._tcp")
    }

    public static var castBrowsePlan: BurnBarAvahiBrowsePlan {
        BurnBarAvahiBrowsePlan(serviceType: "_googlecast._tcp")
    }

    public static var homeAssistantBrowsePlan: BurnBarAvahiBrowsePlan {
        BurnBarAvahiBrowsePlan(serviceType: "_home-assistant._tcp")
    }
}

public enum BurnBarAvahiEventKind: String, Codable, Hashable, Sendable {
    case appeared
    case resolved
    case removed
}

public struct BurnBarDiscoveredService: Codable, Hashable, Sendable {
    public let eventKind: BurnBarAvahiEventKind
    public let interfaceName: String
    public let protocolName: String
    public let instanceName: String
    public let serviceType: String
    public let domain: String
    public let hostName: String?
    public let address: String?
    public let port: Int?
    public let txtRecords: [String: String]

    public init(
        eventKind: BurnBarAvahiEventKind,
        interfaceName: String,
        protocolName: String,
        instanceName: String,
        serviceType: String,
        domain: String,
        hostName: String?,
        address: String?,
        port: Int?,
        txtRecords: [String: String]
    ) {
        self.eventKind = eventKind
        self.interfaceName = interfaceName
        self.protocolName = protocolName
        self.instanceName = instanceName
        self.serviceType = serviceType
        self.domain = domain
        self.hostName = hostName
        self.address = address
        self.port = port
        self.txtRecords = txtRecords
    }

    public var endpoint: String? {
        guard let address, let port else { return nil }
        return "\(address):\(port)"
    }
}

public enum BurnBarAvahiBrowseParser {
    public static func parse(_ transcript: String) -> [BurnBarDiscoveredService] {
        transcript
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> BurnBarDiscoveredService? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.first, ["+", "=", "-"].contains(marker) else {
            return nil
        }

        let eventKind: BurnBarAvahiEventKind
        switch marker {
        case "+": eventKind = .appeared
        case "-": eventKind = .removed
        default: eventKind = .resolved
        }

        let fields = splitAvahiFields(trimmed).map(cleanAvahiField)
        guard fields.count >= 6 else {
            return nil
        }

        if eventKind == .resolved {
            guard fields.count >= 9 else { return nil }
            return BurnBarDiscoveredService(
                eventKind: eventKind,
                interfaceName: fields[1],
                protocolName: fields[2],
                instanceName: fields[3],
                serviceType: fields[4],
                domain: fields[5],
                hostName: emptyToNil(fields[6]),
                address: emptyToNil(fields[7]),
                port: Int(fields[8]),
                txtRecords: parseTXT(Array(fields[9...]))
            )
        }

        return BurnBarDiscoveredService(
            eventKind: eventKind,
            interfaceName: fields[1],
            protocolName: fields[2],
            instanceName: fields[3],
            serviceType: fields[4],
            domain: fields[5],
            hostName: nil,
            address: nil,
            port: nil,
            txtRecords: [:]
        )
    }

    private static func splitAvahiFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isEscaped = false
        var inQuotes = false

        for character in line {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == ";", !inQuotes {
                fields.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        fields.append(current)
        return fields
    }

    private static func parseTXT(_ rawFields: [String]) -> [String: String] {
        rawFields.reduce(into: [String: String]()) { records, rawField in
            let field = cleanAvahiField(rawField)
            guard !field.isEmpty else { return }
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { return }
            records[key] = parts.count == 2 ? parts[1] : ""
        }
    }

    private static func cleanAvahiField(_ field: String) -> String {
        var cleaned = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\""), cleaned.hasSuffix("\""), cleaned.count >= 2 {
            cleaned.removeFirst()
            cleaned.removeLast()
        }
        return cleaned.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

public struct BurnBarAvahiRegistrationResult: Codable, Hashable, Sendable {
    public let requestedInstanceName: String
    public let registeredInstanceName: String?
    public let conflictDetected: Bool
    public let fallbackInstanceName: String?
    public let transcript: String

    public static func evaluate(metadata: BurnBarLocalPeerMetadata, transcript: String) -> BurnBarAvahiRegistrationResult {
        let lowered = transcript.lowercased()
        let conflict = lowered.contains("collision") || lowered.contains("name conflict") || lowered.contains("already exists")
        let registeredName = conflict ? nil : metadata.instanceName
        return BurnBarAvahiRegistrationResult(
            requestedInstanceName: metadata.instanceName,
            registeredInstanceName: registeredName,
            conflictDetected: conflict,
            fallbackInstanceName: conflict ? "\(metadata.instanceName)-\(metadata.peerID.prefix(6))" : nil,
            transcript: transcript
        )
    }
}

public struct BurnBarAvahiLifecycleEvidence: Codable, Hashable, Sendable {
    public let serviceName: String
    public let registerTranscript: String
    public let browseTranscript: String
    public let teardownTranscript: String
    public let teardownObserved: Bool

    public init(serviceName: String, registerTranscript: String, browseTranscript: String, teardownTranscript: String) {
        self.serviceName = serviceName
        self.registerTranscript = registerTranscript
        self.browseTranscript = browseTranscript
        self.teardownTranscript = teardownTranscript
        self.teardownObserved = teardownTranscript.contains("-;") || teardownTranscript.lowercased().contains("withdraw")
    }
}

public struct BurnBarAvahiDisabledState: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let publishCommand: [String]
    public let reason: String

    public static func disabled(reason: String) -> BurnBarAvahiDisabledState {
        BurnBarAvahiDisabledState(enabled: false, publishCommand: [], reason: reason)
    }
}

public enum BurnBarLinuxParityStatus: String, Codable, Hashable, Sendable {
    case ready
    case attempted
    case blocked
}

public struct BurnBarLinuxParityLedgerRow: Codable, Hashable, Sendable {
    public let contractID: String
    public let surface: String
    public let status: BurnBarLinuxParityStatus
    public let evidence: String
    public let blocker: String?

    public init(
        contractID: String,
        surface: String,
        status: BurnBarLinuxParityStatus,
        evidence: String,
        blocker: String? = nil
    ) {
        self.contractID = contractID
        self.surface = surface
        self.status = status
        self.evidence = evidence
        self.blocker = blocker
    }
}

public struct BurnBarLinuxDeviceControlPlan: Codable, Hashable, Sendable {
    public let adapter: String
    public let deviceName: String
    public let method: String
    public let url: String
    public let bodyDescription: String?

    public init(adapter: String, deviceName: String, method: String, url: String, bodyDescription: String? = nil) {
        self.adapter = adapter
        self.deviceName = deviceName
        self.method = method
        self.url = url
        self.bodyDescription = bodyDescription
    }
}

public struct BurnBarLinuxDeviceAdapterReport: Codable, Hashable, Sendable {
    public let adapter: String
    public let discoveredServices: [BurnBarDiscoveredService]
    public let controlPlans: [BurnBarLinuxDeviceControlPlan]
    public let parityRows: [BurnBarLinuxParityLedgerRow]

    public init(
        adapter: String,
        discoveredServices: [BurnBarDiscoveredService],
        controlPlans: [BurnBarLinuxDeviceControlPlan],
        parityRows: [BurnBarLinuxParityLedgerRow]
    ) {
        self.adapter = adapter
        self.discoveredServices = discoveredServices
        self.controlPlans = controlPlans
        self.parityRows = parityRows
    }
}

public struct BurnBarPixelClockFirmwarePrerequisites: Codable, Hashable, Sendable {
    public let networkManagerDBusAvailable: Bool
    public let libUdevAvailable: Bool
    public let serialDevices: [String]
    public let firmwareImagePath: String?

    public init(
        networkManagerDBusAvailable: Bool,
        libUdevAvailable: Bool,
        serialDevices: [String],
        firmwareImagePath: String?
    ) {
        self.networkManagerDBusAvailable = networkManagerDBusAvailable
        self.libUdevAvailable = libUdevAvailable
        self.serialDevices = serialDevices
        self.firmwareImagePath = firmwareImagePath
    }
}

public struct BurnBarPixelClockFirmwareLaneReport: Codable, Hashable, Sendable {
    public let status: BurnBarLinuxParityStatus
    public let attemptedCommands: [String]
    public let blocker: String?
    public let parityRow: BurnBarLinuxParityLedgerRow
}

public enum BurnBarPixelClockLinuxAdapter {
    public static func evaluate(services: [BurnBarDiscoveredService]) -> BurnBarLinuxDeviceAdapterReport {
        let matches = services.filter(isPixelClockService)
        let plans = matches.flatMap { service -> [BurnBarLinuxDeviceControlPlan] in
            guard let endpoint = service.endpoint else { return [] }
            return [
                BurnBarLinuxDeviceControlPlan(
                    adapter: "PixelClock",
                    deviceName: service.instanceName,
                    method: "GET",
                    url: "http://\(endpoint)/api/stats"
                ),
                BurnBarLinuxDeviceControlPlan(
                    adapter: "PixelClock",
                    deviceName: service.instanceName,
                    method: "POST",
                    url: "http://\(endpoint)/api/custom?name=openburnbar",
                    bodyDescription: "OpenBurnBar quota/status frame"
                ),
                BurnBarLinuxDeviceControlPlan(
                    adapter: "PixelClock",
                    deviceName: service.instanceName,
                    method: "POST",
                    url: "http://\(endpoint)/api/notify",
                    bodyDescription: "OpenBurnBar alert notification"
                )
            ]
        }
        let row: BurnBarLinuxParityLedgerRow
        if matches.isEmpty {
            row = BurnBarLinuxParityLedgerRow(
                contractID: "VAL-DEVICE-001",
                surface: "PixelClock mDNS discovery/control",
                status: .blocked,
                evidence: "Avahi _http._tcp browse returned no AWTRIX/PixelClock services",
                blocker: "No PixelClock/AWTRIX mDNS fixture or hardware service present"
            )
        } else {
            row = BurnBarLinuxParityLedgerRow(
                contractID: "VAL-DEVICE-001",
                surface: "PixelClock mDNS discovery/control",
                status: .ready,
                evidence: "Resolved \(matches.count) PixelClock service(s) and built stats/custom/notify HTTP control plans"
            )
        }
        return BurnBarLinuxDeviceAdapterReport(adapter: "PixelClock", discoveredServices: matches, controlPlans: plans, parityRows: [row])
    }

    public static func evaluateFirmwareLane(prerequisites: BurnBarPixelClockFirmwarePrerequisites) -> BurnBarPixelClockFirmwareLaneReport {
        var missing: [String] = []
        if !prerequisites.networkManagerDBusAvailable {
            missing.append("NetworkManager DBus service org.freedesktop.NetworkManager is unavailable")
        }
        if !prerequisites.libUdevAvailable {
            missing.append("libudev device enumeration is unavailable")
        }
        if prerequisites.serialDevices.isEmpty {
            missing.append("no /dev/ttyUSB* or /dev/ttyACM* PixelClock serial device was detected")
        }
        if prerequisites.firmwareImagePath?.isEmpty ?? true {
            missing.append("no PixelClock firmware image path was supplied")
        }

        if !missing.isEmpty {
            let blocker = missing.joined(separator: "; ")
            return BurnBarPixelClockFirmwareLaneReport(
                status: .blocked,
                attemptedCommands: [
                    "busctl introspect org.freedesktop.NetworkManager /org/freedesktop/NetworkManager",
                    "udevadm info --export-db"
                ],
                blocker: blocker,
                parityRow: BurnBarLinuxParityLedgerRow(
                    contractID: "VAL-DEVICE-001",
                    surface: "PixelClock firmware flashing",
                    status: .blocked,
                    evidence: "Firmware lane attempted prerequisite discovery through NetworkManager DBus and libudev probes",
                    blocker: blocker
                )
            )
        }

        let serialDevice = prerequisites.serialDevices[0]
        let imagePath = prerequisites.firmwareImagePath ?? ""
        return BurnBarPixelClockFirmwareLaneReport(
            status: .attempted,
            attemptedCommands: [
                "busctl introspect org.freedesktop.NetworkManager /org/freedesktop/NetworkManager",
                "udevadm info --query=property --name=\(serialDevice)",
                "python3 -m esptool --chip esp32 --port \(serialDevice) write_flash 0x0 \(imagePath)"
            ],
            blocker: nil,
            parityRow: BurnBarLinuxParityLedgerRow(
                contractID: "VAL-DEVICE-001",
                surface: "PixelClock firmware flashing",
                status: .attempted,
                evidence: "Firmware lane reached NetworkManager, libudev serial selection, and esptool flash command construction"
            )
        )
    }

    private static func isPixelClockService(_ service: BurnBarDiscoveredService) -> Bool {
        guard service.serviceType == "_http._tcp", service.eventKind == .resolved else { return false }
        let haystack = ([service.instanceName] + service.txtRecords.map { "\($0.key)=\($0.value)" })
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("awtrix") || haystack.contains("pixelclock")
    }
}

public enum BurnBarLinuxIoTAdapterSuite {
    public static func evaluate(services: [BurnBarDiscoveredService]) -> [BurnBarLinuxDeviceAdapterReport] {
        [
            smartHubReport(services: services),
            castReport(services: services),
            homeAssistantReport(services: services)
        ]
    }

    private static func smartHubReport(services: [BurnBarDiscoveredService]) -> BurnBarLinuxDeviceAdapterReport {
        let matches = services.filter { $0.serviceType == BurnBarLocalPeerMetadata.serviceType && $0.eventKind == .resolved }
        let plans = matches.compactMap { service -> BurnBarLinuxDeviceControlPlan? in
            guard let endpoint = service.endpoint else { return nil }
            return BurnBarLinuxDeviceControlPlan(
                adapter: "SmartHub",
                deviceName: service.instanceName,
                method: "GET",
                url: "http://\(endpoint)/local-peer/status"
            )
        }
        return report(
            adapter: "SmartHub",
            contractID: "VAL-IOT-001",
            surface: "SmartHub local peer adapter",
            matches: matches,
            plans: plans,
            absentEvidence: "No OpenBurnBar local peer advertisement resolved through Avahi"
        )
    }

    private static func castReport(services: [BurnBarDiscoveredService]) -> BurnBarLinuxDeviceAdapterReport {
        let matches = services.filter { $0.serviceType == "_googlecast._tcp" && $0.eventKind == .resolved }
        let plans = matches.compactMap { service -> BurnBarLinuxDeviceControlPlan? in
            guard let endpoint = service.endpoint else { return nil }
            return BurnBarLinuxDeviceControlPlan(
                adapter: "Cast",
                deviceName: service.txtRecords["fn"] ?? service.instanceName,
                method: "GET",
                url: "http://\(endpoint)/setup/eureka_info?options=detail"
            )
        }
        return report(
            adapter: "Cast",
            contractID: "VAL-IOT-001",
            surface: "Cast mDNS adapter",
            matches: matches,
            plans: plans,
            absentEvidence: "No _googlecast._tcp service resolved through Avahi"
        )
    }

    private static func homeAssistantReport(services: [BurnBarDiscoveredService]) -> BurnBarLinuxDeviceAdapterReport {
        let matches = services.filter { $0.serviceType == "_home-assistant._tcp" && $0.eventKind == .resolved }
        let plans = matches.compactMap { service -> BurnBarLinuxDeviceControlPlan? in
            guard let endpoint = service.endpoint else { return nil }
            return BurnBarLinuxDeviceControlPlan(
                adapter: "HomeAssistant",
                deviceName: service.instanceName,
                method: "GET",
                url: "http://\(endpoint)/api/"
            )
        }
        return report(
            adapter: "HomeAssistant",
            contractID: "VAL-IOT-001",
            surface: "Home Assistant mDNS adapter",
            matches: matches,
            plans: plans,
            absentEvidence: "No _home-assistant._tcp service resolved through Avahi"
        )
    }

    private static func report(
        adapter: String,
        contractID: String,
        surface: String,
        matches: [BurnBarDiscoveredService],
        plans: [BurnBarLinuxDeviceControlPlan],
        absentEvidence: String
    ) -> BurnBarLinuxDeviceAdapterReport {
        let row: BurnBarLinuxParityLedgerRow
        if matches.isEmpty {
            row = BurnBarLinuxParityLedgerRow(
                contractID: contractID,
                surface: surface,
                status: .blocked,
                evidence: absentEvidence,
                blocker: "Adapter has no resolved Avahi service or fixture to target"
            )
        } else {
            row = BurnBarLinuxParityLedgerRow(
                contractID: contractID,
                surface: surface,
                status: .ready,
                evidence: "Resolved \(matches.count) service(s) and built \(plans.count) status/control plan(s)"
            )
        }
        return BurnBarLinuxDeviceAdapterReport(adapter: adapter, discoveredServices: matches, controlPlans: plans, parityRows: [row])
    }
}
