import Foundation

// MARK: - Pixel Clock Configuration

public struct PixelClockConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var layout: PixelClockLayout
    public var palette: PixelClockPalette
    public var timePeriod: SmartHubTimePeriod
    public var workingSpinnerStyle: PixelClockSpinnerStyle
    public var workingSpinnerPrimaryHex: String
    public var workingSpinnerSecondaryHex: String
    public var completionClockSoundEnabled: Bool
    public var completionLocalNotificationsEnabled: Bool
    public var pageDurationSeconds: Int
    public var updateIntervalSeconds: Int
    public var scrollSpeedPercent: Int
    public var brightness: Int?
    public var providerIDs: [String]
    public var updatedAt: Date
    public var updatedByDeviceId: String?
    public var lastProbeStatus: PixelClockProbeStatus

    public init(
        enabled: Bool = false,
        host: String = "192.168.68.92",
        port: Int = 80,
        layout: PixelClockLayout = .quotaCarousel,
        palette: PixelClockPalette = .emberWhimsy,
        timePeriod: SmartHubTimePeriod = .rolling5h,
        workingSpinnerStyle: PixelClockSpinnerStyle = .orbit,
        workingSpinnerPrimaryHex: String = "#52D6FF",
        workingSpinnerSecondaryHex: String = "#FFFFFF",
        completionClockSoundEnabled: Bool = true,
        completionLocalNotificationsEnabled: Bool = true,
        pageDurationSeconds: Int = 7,
        updateIntervalSeconds: Int = 60,
        scrollSpeedPercent: Int = 100,
        brightness: Int? = nil,
        providerIDs: [String] = [],
        updatedAt: Date = Date(),
        updatedByDeviceId: String? = nil,
        lastProbeStatus: PixelClockProbeStatus = .unknown
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.layout = layout
        self.palette = palette
        self.timePeriod = timePeriod
        self.workingSpinnerStyle = workingSpinnerStyle
        self.workingSpinnerPrimaryHex = workingSpinnerPrimaryHex
        self.workingSpinnerSecondaryHex = workingSpinnerSecondaryHex
        self.completionClockSoundEnabled = completionClockSoundEnabled
        self.completionLocalNotificationsEnabled = completionLocalNotificationsEnabled
        self.pageDurationSeconds = pageDurationSeconds
        self.updateIntervalSeconds = updateIntervalSeconds
        self.scrollSpeedPercent = scrollSpeedPercent
        self.brightness = brightness
        self.providerIDs = providerIDs
        self.updatedAt = updatedAt
        self.updatedByDeviceId = updatedByDeviceId
        self.lastProbeStatus = lastProbeStatus
    }

    public static let disabled = PixelClockConfig()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case host
        case port
        case layout
        case palette
        case timePeriod
        case workingSpinnerStyle
        case workingSpinnerPrimaryHex
        case workingSpinnerSecondaryHex
        case completionClockSoundEnabled
        case completionLocalNotificationsEnabled
        case pageDurationSeconds
        case updateIntervalSeconds
        case scrollSpeedPercent
        case brightness
        case providerIDs
        case updatedAt
        case updatedByDeviceId
        case lastProbeStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            host: try c.decodeIfPresent(String.self, forKey: .host) ?? "192.168.68.92",
            port: try c.decodeIfPresent(Int.self, forKey: .port) ?? 80,
            layout: try c.decodeIfPresent(PixelClockLayout.self, forKey: .layout) ?? .quotaCarousel,
            palette: try c.decodeIfPresent(PixelClockPalette.self, forKey: .palette) ?? .emberWhimsy,
            timePeriod: try c.decodeIfPresent(SmartHubTimePeriod.self, forKey: .timePeriod) ?? .rolling5h,
            workingSpinnerStyle: try c.decodeIfPresent(PixelClockSpinnerStyle.self, forKey: .workingSpinnerStyle) ?? .orbit,
            workingSpinnerPrimaryHex: try c.decodeIfPresent(String.self, forKey: .workingSpinnerPrimaryHex) ?? "#52D6FF",
            workingSpinnerSecondaryHex: try c.decodeIfPresent(String.self, forKey: .workingSpinnerSecondaryHex) ?? "#FFFFFF",
            completionClockSoundEnabled: try c.decodeIfPresent(Bool.self, forKey: .completionClockSoundEnabled) ?? true,
            completionLocalNotificationsEnabled: try c.decodeIfPresent(Bool.self, forKey: .completionLocalNotificationsEnabled) ?? true,
            pageDurationSeconds: try c.decodeIfPresent(Int.self, forKey: .pageDurationSeconds) ?? 7,
            updateIntervalSeconds: try c.decodeIfPresent(Int.self, forKey: .updateIntervalSeconds) ?? 60,
            scrollSpeedPercent: try c.decodeIfPresent(Int.self, forKey: .scrollSpeedPercent) ?? 100,
            brightness: try c.decodeIfPresent(Int.self, forKey: .brightness),
            providerIDs: try c.decodeIfPresent([String].self, forKey: .providerIDs) ?? [],
            updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            updatedByDeviceId: try c.decodeIfPresent(String.self, forKey: .updatedByDeviceId),
            lastProbeStatus: try c.decodeIfPresent(PixelClockProbeStatus.self, forKey: .lastProbeStatus) ?? .unknown
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(layout, forKey: .layout)
        try c.encode(palette, forKey: .palette)
        try c.encode(timePeriod, forKey: .timePeriod)
        try c.encode(workingSpinnerStyle, forKey: .workingSpinnerStyle)
        try c.encode(workingSpinnerPrimaryHex, forKey: .workingSpinnerPrimaryHex)
        try c.encode(workingSpinnerSecondaryHex, forKey: .workingSpinnerSecondaryHex)
        try c.encode(completionClockSoundEnabled, forKey: .completionClockSoundEnabled)
        try c.encode(completionLocalNotificationsEnabled, forKey: .completionLocalNotificationsEnabled)
        try c.encode(pageDurationSeconds, forKey: .pageDurationSeconds)
        try c.encode(updateIntervalSeconds, forKey: .updateIntervalSeconds)
        try c.encode(scrollSpeedPercent, forKey: .scrollSpeedPercent)
        try c.encodeIfPresent(brightness, forKey: .brightness)
        try c.encode(providerIDs, forKey: .providerIDs)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(updatedByDeviceId, forKey: .updatedByDeviceId)
        try c.encode(lastProbeStatus, forKey: .lastProbeStatus)
    }

    public var clampedPort: Int {
        min(max(port, 1), 65_535)
    }

    public var clampedPageDuration: Int {
        min(max(pageDurationSeconds, 3), 30)
    }

    public var clampedUpdateInterval: Int {
        min(max(updateIntervalSeconds, 15), 3_600)
    }

    public var clampedScrollSpeed: Int {
        min(max(scrollSpeedPercent, 10), 300)
    }

    public var clampedBrightness: Int? {
        brightness.map { min(max($0, 0), 255) }
    }
}

public enum PixelClockSpinnerStyle: String, Codable, Sendable, CaseIterable, Equatable {
    case orbit
    case chase
    case pulse
    case scan
}

public enum PixelClockLayout: String, Codable, Sendable, CaseIterable {
    case providerDashboard
    case quotaCarousel
    case burnStatus
    case alertsOnly
}

public enum PixelClockPalette: String, Codable, Sendable, CaseIterable {
    case emberWhimsy
    case mercury
    case traffic
    case monochrome

    public var primaryHex: String {
        switch self {
        case .emberWhimsy: return "#E07868"
        case .mercury: return "#C8BFB5"
        case .traffic: return "#38D898"
        case .monochrome: return "#FFFFFF"
        }
    }

    public var secondaryHex: String {
        switch self {
        case .emberWhimsy: return "#A294F0"
        case .mercury: return "#9A9088"
        case .traffic: return "#F0C040"
        case .monochrome: return "#B0B0B0"
        }
    }

    public func hexColor(for percentUsed: Int) -> String {
        switch self {
        case .traffic:
            switch percentUsed {
            case 0..<60: return "#38D898"
            case 60..<85: return "#F0C040"
            default: return "#E07868"
            }
        case .monochrome:
            return "#FFFFFF"
        default:
            switch percentUsed {
            case 0..<60: return secondaryHex
            default: return primaryHex
            }
        }
    }
}

public enum PixelClockProbeStatus: String, Codable, Sendable, Equatable {
    case unknown
    case awtrixReady
    case stockUlanziFirmware
    case unreachable
    case unsupported
    case error
}

public enum PixelClockActionStatus: String, Codable, Sendable, Equatable {
    case pending
    case completed
    case failed
}

public enum PixelClockSetupMode: String, Codable, Sendable, Equatable {
    case awtrixLightReady
    case stockSimulatorConfigured
    case needsAwtrixLightFlash
    case unreachable
}

public struct PixelClockSetupResult: Codable, Sendable, Equatable {
    public var mode: PixelClockSetupMode
    public var probeStatus: PixelClockProbeStatus
    public var message: String
    public var clockHost: String
    public var suggestedServerHost: String?
    public var suggestedServerPort: Int?
    public var flasherURL: String?

    public init(
        mode: PixelClockSetupMode,
        probeStatus: PixelClockProbeStatus,
        message: String,
        clockHost: String,
        suggestedServerHost: String? = nil,
        suggestedServerPort: Int? = nil,
        flasherURL: String? = nil
    ) {
        self.mode = mode
        self.probeStatus = probeStatus
        self.message = message
        self.clockHost = clockHost
        self.suggestedServerHost = suggestedServerHost
        self.suggestedServerPort = suggestedServerPort
        self.flasherURL = flasherURL
    }
}

// MARK: - Render Contracts

public struct PixelClockDrawInstruction: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case drawPixel = "dp"
        case fillRect = "df"
        case drawText = "dt"
    }

    public var command: Command
    public var values: [PixelClockDrawValue]

    public init(command: Command, values: [PixelClockDrawValue]) {
        self.command = command
        self.values = values
    }

    public static func pixel(x: Int, y: Int, color: String) -> PixelClockDrawInstruction {
        PixelClockDrawInstruction(command: .drawPixel, values: [.int(x), .int(y), .string(color)])
    }

    public static func fillRect(x: Int, y: Int, width: Int, height: Int, color: String) -> PixelClockDrawInstruction {
        PixelClockDrawInstruction(command: .fillRect, values: [.int(x), .int(y), .int(width), .int(height), .string(color)])
    }

    public static func text(x: Int, y: Int, text: String, color: String) -> PixelClockDrawInstruction {
        PixelClockDrawInstruction(command: .drawText, values: [.int(x), .int(y), .string(text), .string(color)])
    }

    public var awtrixObject: [String: Any] {
        [command.rawValue: values.map(\.jsonValue)]
    }
}

public enum PixelClockDrawValue: Codable, Sendable, Equatable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    public var jsonValue: Any {
        switch self {
        case .int(let value): return value
        case .string(let value): return value
        }
    }
}

public struct PixelClockQuotaItem: Codable, Sendable, Equatable {
    public var providerID: String
    public var providerName: String
    public var percentUsed: Int
    public var usageText: String
    public var windowLabel: String
    public var agentStatus: PixelClockAgentStatus

    public init(
        providerID: String,
        providerName: String,
        percentUsed: Int,
        usageText: String,
        windowLabel: String,
        agentStatus: PixelClockAgentStatus = .ready
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.percentUsed = min(max(percentUsed, 0), 100)
        self.usageText = usageText
        self.windowLabel = windowLabel
        self.agentStatus = agentStatus
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case providerName
        case percentUsed
        case usageText
        case windowLabel
        case agentStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try c.decode(String.self, forKey: .providerID),
            providerName: try c.decode(String.self, forKey: .providerName),
            percentUsed: try c.decode(Int.self, forKey: .percentUsed),
            usageText: try c.decode(String.self, forKey: .usageText),
            windowLabel: try c.decode(String.self, forKey: .windowLabel),
            agentStatus: try c.decodeIfPresent(PixelClockAgentStatus.self, forKey: .agentStatus) ?? .ready
        )
    }
}

public enum PixelClockAgentStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case ready
    case running
    case completed
    case failed

    public var displayText: String {
        switch self {
        case .ready: return "READY"
        case .running: return "RUN"
        case .completed: return "DONE"
        case .failed: return "ERR"
        }
    }
}

public struct PixelClockRenderedPage: Codable, Sendable, Equatable {
    public var text: String
    public var color: String
    public var durationSeconds: Int
    public var progress: Int?
    public var scrollSpeed: Int
    public var draw: [PixelClockDrawInstruction]

    public init(
        text: String,
        color: String,
        durationSeconds: Int,
        progress: Int? = nil,
        scrollSpeed: Int,
        draw: [PixelClockDrawInstruction] = []
    ) {
        self.text = text
        self.color = color
        self.durationSeconds = durationSeconds
        self.progress = progress.map { min(max($0, 0), 100) }
        self.scrollSpeed = min(max(scrollSpeed, 10), 300)
        self.draw = draw
    }
}
