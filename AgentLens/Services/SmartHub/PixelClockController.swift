import Foundation
import Network
import OpenBurnBarCore

@MainActor
final class PixelClockAgentStatusStore {
    static let shared = PixelClockAgentStatusStore()

    private struct Entry {
        var runningCount: Int = 0
        var lastTerminalStatus: PixelClockAgentStatus?
        var terminalAt: Date?
    }

    private var entries: [String: Entry] = [:]
    private let terminalTTL: TimeInterval = 5 * 60

    func markRunning(provider: AgentProvider) {
        let key = provider.persistedToken
        var entry = entries[key] ?? Entry()
        entry.runningCount += 1
        entry.lastTerminalStatus = nil
        entry.terminalAt = nil
        entries[key] = entry
    }

    func markCompleted(providerID: String) {
        markTerminal(providerID: providerID, status: .completed)
    }

    func markFailed(providerID: String) {
        markTerminal(providerID: providerID, status: .failed)
    }

    func markFinished(provider: AgentProvider, failed: Bool) {
        let key = provider.persistedToken
        var entry = entries[key] ?? Entry()
        entry.runningCount = max(0, entry.runningCount - 1)
        if entry.runningCount == 0 {
            entry.lastTerminalStatus = failed ? .failed : .completed
            entry.terminalAt = Date()
        }
        entries[key] = entry
    }

    func snapshot(now: Date = Date()) -> [String: PixelClockAgentStatus] {
        entries.compactMapValues { entry in
            if entry.runningCount > 0 { return .running }
            guard let status = entry.lastTerminalStatus,
                  let terminalAt = entry.terminalAt,
                  now.timeIntervalSince(terminalAt) <= terminalTTL else {
                return nil
            }
            return status
        }
    }

    private func markTerminal(providerID: String, status: PixelClockAgentStatus) {
        let key = providerID.lowercased().replacingOccurrences(of: " ", with: "")
        var entry = entries[key] ?? Entry()
        entry.runningCount = 0
        entry.lastTerminalStatus = status
        entry.terminalAt = Date()
        entries[key] = entry
    }
}

@MainActor
final class PixelClockController {
    static let awtrixLightFlasherURL = "https://blueforcer.github.io/awtrix3/#/flasher"

    private let settingsManager: SettingsManager
    private let quotaService: ProviderQuotaService?
    private let client: AWTRIXClient
    private let stockSimulator: PixelClockStockSimulatorServer

    private var heartbeat: Task<Void, Never>?
    private var lastPushedConfig: PixelClockConfig?
    private var lastPushAt: Date = .distantPast

    init(
        settingsManager: SettingsManager,
        quotaService: ProviderQuotaService?,
        client: AWTRIXClient = AWTRIXClient(),
        stockSimulator: PixelClockStockSimulatorServer = .shared
    ) {
        self.settingsManager = settingsManager
        self.quotaService = quotaService
        self.client = client
        self.stockSimulator = stockSimulator
    }

    func start() {
        stockSimulator.start()
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                await pushIfNeeded()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    @discardableResult
    func probePixelClock() async -> AWTRIXClient.ProbeResult {
        let discovery = await resolveReachablePixelClockConfig()
        return discovery.probe
    }

    func testPixelClock() async throws {
        let discovery = await resolveReachablePixelClockConfig()
        let config = discovery.config
        let result = discovery.probe
        if result.status == .stockUlanziFirmware {
            let page = PixelClockRenderedPage(
                text: "OPENBURNBAR READY",
                color: config.palette.primaryHex,
                durationSeconds: config.clampedPageDuration,
                progress: 12,
                scrollSpeed: config.clampedScrollSpeed
            )
            stockSimulator.update(pages: [page], config: config)
            updateProbeStatus(.stockUlanziFirmware)
            return
        }
        guard result.status == .awtrixReady else {
            updateProbeStatus(result.status)
            throw NSError(domain: "PixelClockController", code: 1, userInfo: [
                NSLocalizedDescriptionKey: result.message
            ])
        }
        let page = PixelClockRenderedPage(
            text: "OPENBURNBAR READY",
            color: config.palette.primaryHex,
            durationSeconds: config.clampedPageDuration,
            progress: 12,
            scrollSpeed: config.clampedScrollSpeed
        )
        // Suppress AWTRIX's stock TIME/DATE/HUM/TEMP/BAT apps so the
        // clock cycles only through our providers from now on.
        try? await client.disableAwtrixNativeApps(config: config)
        try await client.testNotify(page: page, config: config)
        updateProbeStatus(.awtrixReady)
    }

    func preparePixelClock() async throws -> PixelClockSetupResult {
        let discovery = await resolveReachablePixelClockConfig()
        var config = discovery.config
        let result = discovery.probe

        switch result.status {
        case .awtrixReady:
            try await client.applyBrightnessIfNeeded(config: config)
            updateProbeStatus(.awtrixReady)
            return PixelClockSetupResult(
                mode: .awtrixLightReady,
                probeStatus: .awtrixReady,
                message: "AWTRIX Light is ready. OpenBurnBar can push directly to \(config.host).",
                clockHost: config.host
            )
        case .stockUlanziFirmware:
            guard let macHost = LocalNetworkDiscovery.preferredLANIPv4Address() else {
                updateProbeStatus(.stockUlanziFirmware)
                return PixelClockSetupResult(
                    mode: .needsAwtrixLightFlash,
                    probeStatus: .stockUlanziFirmware,
                    message: "Stock Ulanzi firmware is reachable, but this Mac does not have a LAN IPv4 address to use for Awtrix Simulator. Flash AWTRIX Light for direct OpenBurnBar control.",
                    clockHost: config.host,
                    flasherURL: Self.awtrixLightFlasherURL
                )
            }
            try await client.configureStockSimulator(config: config, serverHost: macHost, serverPort: 7001)
            config.lastProbeStatus = .stockUlanziFirmware
            config.updatedAt = Date()
            settingsManager.pixelClockConfig = config
            stockSimulator.start(port: 7001)
            updateStockSimulatorPages(config: config)
            return PixelClockSetupResult(
                mode: .stockSimulatorConfigured,
                probeStatus: .stockUlanziFirmware,
                message: "Stock Ulanzi firmware is ready. OpenBurnBar is serving Pixel Clock frames from this Mac at \(macHost):7001.",
                clockHost: config.host,
                suggestedServerHost: macHost,
                suggestedServerPort: 7001
            )
        case .unknown, .unreachable, .unsupported, .error:
            updateProbeStatus(result.status)
            return PixelClockSetupResult(
                mode: .unreachable,
                probeStatus: result.status,
                message: result.message,
                clockHost: config.host,
                flasherURL: Self.awtrixLightFlasherURL
            )
        }
    }

    func pushPixelClockNow() async throws {
        let current = settingsManager.pixelClockConfig
        guard current.enabled else { return }

        let discovery = await resolveReachablePixelClockConfig()
        var config = discovery.config
        guard config.enabled else { return }

        let result = discovery.probe
        if result.status == .stockUlanziFirmware {
            config.lastProbeStatus = .stockUlanziFirmware
            config.updatedAt = Date()
            settingsManager.pixelClockConfig = config
            updateStockSimulatorPages(config: config)
            lastPushAt = Date()
            lastPushedConfig = config
            return
        }
        guard result.status == .awtrixReady else {
            config.lastProbeStatus = result.status
            config.updatedAt = Date()
            settingsManager.pixelClockConfig = config
            throw NSError(domain: "PixelClockController", code: 2, userInfo: [
                NSLocalizedDescriptionKey: result.message
            ])
        }

        let items = PixelClockSnapshotAdapter.quotaCycleItems(
            quotaService: quotaService,
            statuses: PixelClockAgentStatusStore.shared.snapshot()
        )
        let pages = PixelClockQuotaRenderer.renderPages(items: items, config: config)
        let payload = PixelClockQuotaRenderer.awtrixPayload(pages: pages, config: config)
        try await client.applyBrightnessIfNeeded(config: config)
        // Suppress AWTRIX's stock TIME/DATE/HUM/TEMP/BAT apps so the
        // clock only cycles through providers from the user's quota.
        try? await client.disableAwtrixNativeApps(config: config)
        try await client.pushCustomApp(pages: payload, config: config)
        lastPushAt = Date()
        lastPushedConfig = config
        updateProbeStatus(.awtrixReady)
    }

    func removePixelClockApp() async throws {
        let discovery = await resolveReachablePixelClockConfig()
        let config = discovery.config
        let result = discovery.probe
        if result.status == .stockUlanziFirmware {
            stockSimulator.clear()
            lastPushedConfig = nil
            updateProbeStatus(.stockUlanziFirmware)
            return
        }
        guard result.status == .awtrixReady else {
            updateProbeStatus(result.status)
            throw NSError(domain: "PixelClockController", code: 3, userInfo: [
                NSLocalizedDescriptionKey: result.message
            ])
        }
        try await client.removeCustomApp(config: config)
        lastPushedConfig = nil
    }

    func notifyAgentCompletion(providerID: String, providerName: String, modelName: String? = nil) async {
        let current = settingsManager.pixelClockConfig
        guard current.enabled else { return }
        guard current.completionClockSoundEnabled || current.completionLocalNotificationsEnabled else { return }
        PixelClockAgentStatusStore.shared.markCompleted(providerID: providerID)

        let item = PixelClockQuotaItem(
            providerID: providerID,
            providerName: providerName,
            percentUsed: 100,
            usageText: "done",
            windowLabel: "ok",
            agentStatus: .completed
        )
        let page = PixelClockRenderedPage(
            text: "\(providerName) DONE",
            color: current.palette.primaryHex,
            durationSeconds: 4,
            progress: 100,
            scrollSpeed: current.clampedScrollSpeed,
            draw: PixelClockQuotaRenderer.renderPages(items: [item], config: current, isWorking: false).first?.draw ?? []
        )

        let discovery = await resolveReachablePixelClockConfig()
        let config = discovery.config
        if discovery.probe.status == .stockUlanziFirmware {
            stockSimulator.update(pages: [page], config: config)
            lastPushAt = Date()
            lastPushedConfig = config
            return
        }

        guard discovery.probe.status == .awtrixReady else { return }
        try? await client.testNotify(
            page: page,
            config: config,
            sound: current.completionClockSoundEnabled ? Self.completionSoundName(providerID: providerID, providerName: providerName) : nil
        )
    }

    private func pushIfNeeded() async {
        let config = settingsManager.pixelClockConfig
        guard config.enabled else { return }
        let interval = TimeInterval(config.clampedUpdateInterval)
        let configChanged = config != lastPushedConfig
        guard configChanged || Date().timeIntervalSince(lastPushAt) >= interval else { return }
        try? await pushPixelClockNow()
    }

    private func updateStockSimulatorPages(config: PixelClockConfig) {
        let items = PixelClockSnapshotAdapter.quotaCycleItems(
            quotaService: quotaService,
            statuses: PixelClockAgentStatusStore.shared.snapshot()
        )
        let pages = PixelClockQuotaRenderer.renderPages(items: items, config: config)
        stockSimulator.update(pages: pages, config: config)
    }

    private func resolveReachablePixelClockConfig() async -> AWTRIXClient.DiscoveryResult {
        let discovery = await client.discover(config: settingsManager.pixelClockConfig)
        var config = discovery.config
        config.lastProbeStatus = discovery.probe.status
        config.updatedAt = Date()
        settingsManager.pixelClockConfig = config
        return AWTRIXClient.DiscoveryResult(config: config, probe: discovery.probe)
    }

    private func updateProbeStatus(_ status: PixelClockProbeStatus) {
        var config = settingsManager.pixelClockConfig
        config.lastProbeStatus = status
        config.updatedAt = Date()
        settingsManager.pixelClockConfig = config
    }

    private static func completionSoundName(providerID: String, providerName: String) -> String {
        let token = "\(providerID) \(providerName)".lowercased()
        if token.contains("factory") || token.contains("droid") { return "droid" }
        if token.contains("codex") || token.contains("openai") { return "codex" }
        if token.contains("claude") { return "claude" }
        if token.contains("cursor") { return "cursor" }
        if token.contains("minimax") { return "minimax" }
        if token.contains("z.ai") || token.contains("zai") { return "zai" }
        return "notify"
    }
}

// MARK: - Stock Ulanzi AWTRIX Simulator

@MainActor
final class PixelClockStockSimulatorServer {
    static let shared = PixelClockStockSimulatorServer()

    private(set) var isRunning = false
    private(set) var boundPort: UInt16?
    private(set) var connectedClientCount = 0

    private var listener: NWListener?
    private var sessions: [UUID: PixelClockStockSimulatorSession] = [:]
    private var latestFrameCommandSets: [[Data]] = [PixelClockStockSimulatorFrameEncoder.blankFrameCommands()]
    private var latestPageDurations: [TimeInterval] = [5]
    private var currentPageIndex = 0
    private var pageCycler: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.openburnbar.pixelclock.stock-simulator")

    func start(port: UInt16 = 7001) {
        if isRunning, boundPort == port { return }
        stop()

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.boundPort = port
                    case .failed, .cancelled:
                        self.isRunning = false
                        self.boundPort = nil
                        self.listener = nil
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            isRunning = false
            boundPort = nil
            listener = nil
        }
    }

    func stop() {
        pageCycler?.cancel()
        pageCycler = nil
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
        connectedClientCount = 0
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = nil
    }

    func update(pages: [PixelClockRenderedPage], config: PixelClockConfig) {
        latestFrameCommandSets = PixelClockStockSimulatorFrameEncoder.commandSets(for: pages, config: config)
        latestPageDurations = pages.isEmpty ? [5] : pages.map { TimeInterval(max($0.durationSeconds, 1)) }
        currentPageIndex = 0
        publishLatestFrame()
        restartPageCyclerIfNeeded()
    }

    func clear() {
        pageCycler?.cancel()
        pageCycler = nil
        latestFrameCommandSets = [PixelClockStockSimulatorFrameEncoder.blankFrameCommands()]
        latestPageDurations = [5]
        currentPageIndex = 0
        publishLatestFrame()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = PixelClockStockSimulatorSession(
            id: id,
            connection: connection,
            queue: queue,
            onClose: { [weak self] closedID in
                Task { @MainActor in
                    self?.removeSession(id: closedID)
                }
            },
            onSubscribe: { [weak self] subscribedID in
                Task { @MainActor in
                    self?.publishLatestFrame(to: subscribedID)
                }
            }
        )
        sessions[id] = session
        connectedClientCount = sessions.count
        session.start()
    }

    private func removeSession(id: UUID) {
        sessions[id] = nil
        connectedClientCount = sessions.count
    }

    private func publishLatestFrame(to id: UUID? = nil) {
        let targets: [PixelClockStockSimulatorSession]
        if let id, let session = sessions[id] {
            targets = [session]
        } else {
            targets = Array(sessions.values)
        }
        for session in targets where session.isSubscribed {
            let commands = latestFrameCommandSets.indices.contains(currentPageIndex)
                ? latestFrameCommandSets[currentPageIndex]
                : PixelClockStockSimulatorFrameEncoder.blankFrameCommands()
            for command in commands {
                session.publish(topic: PixelClockStockMQTT.matrixTopic, payload: command)
            }
        }
    }

    private func restartPageCyclerIfNeeded() {
        pageCycler?.cancel()
        guard latestFrameCommandSets.count > 1 else {
            pageCycler = nil
            return
        }
        pageCycler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.latestPageDurations.indices.contains(self.currentPageIndex)
                    ? self.latestPageDurations[self.currentPageIndex]
                    : 5
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.currentPageIndex = (self.currentPageIndex + 1) % max(self.latestFrameCommandSets.count, 1)
                self.publishLatestFrame()
            }
        }
    }
}

@MainActor
private final class PixelClockStockSimulatorSession {
    let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClose: @Sendable (UUID) -> Void
    private let onSubscribe: @Sendable (UUID) -> Void
    private var buffer = Data()
    private(set) var isSubscribed = false
    private var isClosed = false

    init(
        id: UUID,
        connection: NWConnection,
        queue: DispatchQueue,
        onClose: @escaping @Sendable (UUID) -> Void,
        onSubscribe: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.queue = queue
        self.onClose = onClose
        self.onSubscribe = onSubscribe
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self.close() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func stop() {
        close()
    }

    func publish(topic: String, payload: Data) {
        send(PixelClockStockMQTT.publish(topic: topic, payload: payload))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.consumeBufferedPackets()
                }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func consumeBufferedPackets() {
        while let packet = PixelClockStockMQTT.nextPacket(from: &buffer) {
            handle(packet)
        }
    }

    private func handle(_ packet: PixelClockStockMQTT.Packet) {
        switch packet.type {
        case .connect:
            send(PixelClockStockMQTT.connack())
        case .subscribe:
            isSubscribed = true
            send(PixelClockStockMQTT.suback(packetIdentifier: packet.packetIdentifier ?? 1))
            onSubscribe(id)
        case .pingreq:
            send(PixelClockStockMQTT.pingresp())
        case .disconnect:
            close()
        case .publish, .unknown:
            break
        }
    }

    private func send(_ data: Data) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error != nil else { return }
            Task { @MainActor in self.close() }
        })
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose(id)
    }
}

enum PixelClockStockMQTT {
    static let matrixTopic = "awtrixmatrix/a"

    enum PacketType {
        case connect
        case publish
        case subscribe
        case pingreq
        case disconnect
        case unknown
    }

    struct Packet: Equatable {
        var type: PacketType
        var body: Data
        var packetIdentifier: UInt16?
    }

    static func nextPacket(from buffer: inout Data) -> Packet? {
        guard buffer.count >= 2 else { return nil }
        let firstByte = buffer[buffer.startIndex]
        var multiplier = 1
        var value = 0
        var cursor = buffer.index(after: buffer.startIndex)
        var encodedLengthBytes = 0

        while true {
            guard cursor < buffer.endIndex, encodedLengthBytes < 4 else { return nil }
            let byte = Int(buffer[cursor])
            value += (byte & 127) * multiplier
            encodedLengthBytes += 1
            cursor = buffer.index(after: cursor)
            if (byte & 128) == 0 { break }
            multiplier *= 128
        }

        let headerLength = 1 + encodedLengthBytes
        let totalLength = headerLength + value
        guard buffer.count >= totalLength else { return nil }

        let bodyStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
        let bodyEnd = buffer.index(bodyStart, offsetBy: value)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let typeNibble = firstByte >> 4
        let type: PacketType
        switch typeNibble {
        case 1: type = .connect
        case 3: type = .publish
        case 8: type = .subscribe
        case 12: type = .pingreq
        case 14: type = .disconnect
        default: type = .unknown
        }

        return Packet(
            type: type,
            body: body,
            packetIdentifier: packetIdentifier(for: type, body: body)
        )
    }

    static func connack() -> Data {
        Data([0x20, 0x02, 0x00, 0x00])
    }

    static func suback(packetIdentifier: UInt16) -> Data {
        Data([0x90, 0x03, UInt8(packetIdentifier >> 8), UInt8(packetIdentifier & 0xFF), 0x00])
    }

    static func pingresp() -> Data {
        Data([0xD0, 0x00])
    }

    static func publish(topic: String, payload: Data) -> Data {
        let topicBytes = Data(topic.utf8)
        var body = Data()
        body.append(UInt8((topicBytes.count >> 8) & 0xFF))
        body.append(UInt8(topicBytes.count & 0xFF))
        body.append(topicBytes)
        body.append(payload)

        var packet = Data([0x30])
        packet.append(remainingLength(body.count))
        packet.append(body)
        return packet
    }

    static func remainingLength(_ value: Int) -> Data {
        var x = max(value, 0)
        var output = Data()
        repeat {
            var encodedByte = UInt8(x % 128)
            x /= 128
            if x > 0 {
                encodedByte |= 128
            }
            output.append(encodedByte)
        } while x > 0
        return output
    }

    private static func packetIdentifier(for type: PacketType, body: Data) -> UInt16? {
        guard type == .subscribe, body.count >= 2 else { return nil }
        return UInt16(body[body.startIndex]) << 8 | UInt16(body[body.index(after: body.startIndex)])
    }
}

enum PixelClockStockSimulatorFrameEncoder {
    private static let columns = 32
    private static let rows = 8

    static func commands(for pages: [PixelClockRenderedPage], config: PixelClockConfig) -> [Data] {
        let page = pages.first ?? PixelClockRenderedPage(
            text: "OPENBURNBAR",
            color: config.palette.primaryHex,
            durationSeconds: config.clampedPageDuration,
            scrollSpeed: config.clampedScrollSpeed
        )

        var commands: [Data] = []
        if let brightness = config.clampedBrightness {
            commands.append(Data([0x0D, UInt8(brightness)]))
        }
        commands.append(Data([0x09]))

        if page.draw.isEmpty {
            commands.append(drawTextCommand(text: page.text, color: page.color))
        } else {
            commands.append(drawBMPCommand(page: page))
        }
        commands.append(Data([0x08]))
        return commands
    }

    static func commandSets(for pages: [PixelClockRenderedPage], config: PixelClockConfig) -> [[Data]] {
        let selectedPages = pages.isEmpty
            ? [
                PixelClockRenderedPage(
                    text: "OPENBURNBAR",
                    color: config.palette.primaryHex,
                    durationSeconds: config.clampedPageDuration,
                    scrollSpeed: config.clampedScrollSpeed
                )
            ]
            : pages
        return selectedPages.map { commands(for: [$0], config: config) }
    }

    static func blankFrameCommands() -> [Data] {
        [Data([0x09]), Data([0x08])]
    }

    private static func drawTextCommand(text: String, color: String) -> Data {
        let rgb = rgbComponents(hex: color) ?? RGB(r: 255, g: 255, b: 255)
        var command = Data([0x00, 0x00, 0x00, 0x00, 0x01, rgb.r, rgb.g, rgb.b])
        command.append(Data(text.prefix(48).utf8))
        return command
    }

    private static func drawBMPCommand(page: PixelClockRenderedPage) -> Data {
        var canvas = Array(
            repeating: Array(repeating: RGB(r: 0, g: 0, b: 0), count: columns),
            count: rows
        )
        for instruction in page.draw {
            apply(instruction, to: &canvas)
        }

        var command = Data([0x01, 0x00, 0x00, 0x00, 0x00, UInt8(columns), UInt8(rows)])
        for row in 0..<rows {
            for column in 0..<columns {
                let color = canvas[row][column].rgb565
                command.append(UInt8(color >> 8))
                command.append(UInt8(color & 0xFF))
            }
        }
        return command
    }

    private static func apply(_ instruction: PixelClockDrawInstruction, to canvas: inout [[RGB]]) {
        switch instruction.command {
        case .drawPixel:
            guard instruction.values.count >= 3,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let color = instruction.values[2].stringValue.flatMap(rgbComponents(hex:)) else {
                return
            }
            setPixel(x: x, y: y, color: color, canvas: &canvas)
        case .fillRect:
            guard instruction.values.count >= 5,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let width = instruction.values[2].intValue,
                  let height = instruction.values[3].intValue,
                  let color = instruction.values[4].stringValue.flatMap(rgbComponents(hex:)) else {
                return
            }
            for row in y..<(y + max(height, 0)) {
                for column in x..<(x + max(width, 0)) {
                    setPixel(x: column, y: row, color: color, canvas: &canvas)
                }
            }
        case .drawText:
            break
        }
    }

    private static func setPixel(x: Int, y: Int, color: RGB, canvas: inout [[RGB]]) {
        guard (0..<columns).contains(x), (0..<rows).contains(y) else { return }
        canvas[y][x] = color
    }

    private static func rgbComponents(hex: String) -> RGB? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let intValue = Int(value, radix: 16) else { return nil }
        return RGB(
            r: UInt8((intValue >> 16) & 0xFF),
            g: UInt8((intValue >> 8) & 0xFF),
            b: UInt8(intValue & 0xFF)
        )
    }

    struct RGB: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        var rgb565: UInt16 {
            let red = UInt16(r >> 3) << 11
            let green = UInt16(g >> 2) << 5
            let blue = UInt16(b >> 3)
            return red | green | blue
        }
    }
}

private extension PixelClockDrawValue {
    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
