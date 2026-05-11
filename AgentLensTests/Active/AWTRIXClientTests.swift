import XCTest
@preconcurrency import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class AWTRIXClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AWTRIXStubURLProtocol.self]
        session = URLSession(configuration: config)
        AWTRIXStubURLProtocol.handler = nil
    }

    override func tearDown() async throws {
        AWTRIXStubURLProtocol.handler = nil
        session = nil
        try await super.tearDown()
    }

    func testProbeReturnsAWTRIXReadyWhenStatsEndpointReturnsJSON() async {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/stats")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"version":"0.96"}"#.data(using: .utf8)!
            )
        }

        let result = await AWTRIXClient(session: session).probe(config: .enabledTestClock)

        XCTAssertEqual(result.status, .awtrixReady)
        XCTAssertEqual(result.message, "AWTRIX HTTP API is ready at 192.168.68.92.")
    }

    func testDiscoverScansCandidatesAndReturnsReachableAWTRIXHost() async {
        AWTRIXStubURLProtocol.handler = { request in
            if request.url?.host == "192.168.68.92", request.url?.path == "/api/stats" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"version":"0.96"}"#.data(using: .utf8)!
                )
            }
            throw URLError(.cannotConnectToHost)
        }

        var config = PixelClockConfig(enabled: true, host: "192.168.68.40", port: 80)
        let result = await AWTRIXClient(session: session).discover(
            config: config,
            candidateHosts: ["192.168.68.41", "192.168.68.92"],
            candidatePorts: [80]
        )

        XCTAssertEqual(result.config.host, "192.168.68.92")
        XCTAssertEqual(result.probe.status, .awtrixReady)
    }

    func testProbeIdentifiesStockUlanziFirmwareWhenStatsFailsAndRootLooksStock() async {
        AWTRIXStubURLProtocol.handler = { request in
            if request.url?.path == "/api/stats" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            if request.url?.path == "/" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "<html><title>Ulanzi Clock</title><body>Ulanzi Pixel Clock</body></html>".data(using: .utf8)!
                )
            }
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/app_switch")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                """
                <input class='mswitch' type='checkbox' name='isAwtrixSimulator' checked>
                <input type='text' name='awtrixServer' value='192.168.68.92'>
                <input type='text' name='awtrixPort' value='7001'>
                """.data(using: .utf8)!
            )
        }

        let result = await AWTRIXClient(session: session).probe(config: .enabledTestClock)

        XCTAssertEqual(result.status, .stockUlanziFirmware)
        XCTAssertTrue(result.message.contains("Awtrix Simulator is pointing at the clock itself"), result.message)
        XCTAssertTrue(result.message.contains("Server Port to 7001"), result.message)
    }

    func testPushCustomAppPostsRenderedPagesToNamedAWTRIXApp() async throws {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/custom?name=openburnbar")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = request.httpBody ?? request.bodyStreamData() ?? Data()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
            XCTAssertEqual(json.first?["text"] as? String, "Claude 5H 80% 80/100")
            XCTAssertEqual(json.first?["progress"] as? Int, 80)
            XCTAssertEqual(json.first?["save"] as? Bool, false)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).pushCustomApp(
            pages: [
                [
                    "text": "Claude 5H 80% 80/100",
                    "color": "#E07868",
                    "duration": 6,
                    "progress": 80,
                    "save": false
                ]
            ],
            config: .enabledTestClock
        )
    }

    func testApplyBrightnessClampsAndPostsSettingsPayload() async throws {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/settings")

            let body = request.httpBody ?? request.bodyStreamData() ?? Data()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["BRI"] as? Int, 255)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        var config = PixelClockConfig(enabled: true, brightness: 999)
        config.host = "192.168.68.92"
        try await AWTRIXClient(session: session).applyBrightnessIfNeeded(config: config)
    }

    func testConfigureStockSimulatorPostsMacHostAndDisablesStockAppsByOmission() async throws {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/app_switch")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")

            let body = String(data: request.httpBody ?? request.bodyStreamData() ?? Data(), encoding: .utf8)
            // `isShowIp=off` is sent explicitly because the stock
            // firmware keeps an already-enabled checkbox unchanged
            // when the field is omitted from this partial POST.
            XCTAssertEqual(body, "page=app_switch&isAwtrixSimulator=on&awtrixServer=192.168.68.93&awtrixPort=7001&isShowIp=off")
            XCTAssertFalse(body?.contains("isTime=on") ?? true)
            XCTAssertFalse(body?.contains("isDate=on") ?? true)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).configureStockSimulator(
            config: .enabledTestClock,
            serverHost: "192.168.68.93",
            serverPort: 7001
        )
    }

    func testDisableAwtrixNativeAppsPostsAllStockAppFlagsOff() async throws {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/settings")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = request.httpBody ?? request.bodyStreamData() ?? Data()
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Bool]
            XCTAssertEqual(json?["TIM"], false)
            XCTAssertEqual(json?["DAT"], false)
            XCTAssertEqual(json?["HUM"], false)
            XCTAssertEqual(json?["TEMP"], false)
            XCTAssertEqual(json?["BAT"], false)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).disableAwtrixNativeApps(config: .enabledTestClock)
    }

    func testStockMQTTParsesSubscribePacketIdentifier() {
        var packet = Data([0x82, 0x13, 0x00, 0x02, 0x00, 0x0E])
        packet.append(Data("awtrixmatrix/#".utf8))
        packet.append(0x00)

        let parsed = PixelClockStockMQTT.nextPacket(from: &packet)

        XCTAssertEqual(parsed?.type, .subscribe)
        XCTAssertEqual(parsed?.packetIdentifier, 2)
        XCTAssertTrue(packet.isEmpty)
    }

    func testStockMQTTPublishTargetsAwtrixMatrixTopic() throws {
        let payload = Data([0x09])
        let packet = PixelClockStockMQTT.publish(topic: PixelClockStockMQTT.matrixTopic, payload: payload)

        XCTAssertEqual(packet.prefix(2), Data([0x30, 0x11]))
        XCTAssertEqual(packet.dropFirst(2).prefix(2), Data([0x00, 0x0E]))
        let topicStart = packet.index(packet.startIndex, offsetBy: 4)
        let topicEnd = packet.index(topicStart, offsetBy: PixelClockStockMQTT.matrixTopic.utf8.count)
        XCTAssertEqual(String(data: packet[topicStart..<topicEnd], encoding: .utf8), "awtrixmatrix/a")
        XCTAssertEqual(packet.last, 0x09)
    }

    func testStockFrameEncoderConvertsDrawPixelsToFullBmpCommand() throws {
        let page = PixelClockRenderedPage(
            text: "",
            color: "#FFFFFF",
            durationSeconds: 7,
            scrollSpeed: 100,
            draw: [
                .pixel(x: 0, y: 0, color: "#FF0000"),
                .fillRect(x: 1, y: 0, width: 2, height: 1, color: "#00FF00")
            ]
        )

        let commands = PixelClockStockSimulatorFrameEncoder.commands(
            for: [page],
            config: PixelClockConfig(enabled: true, brightness: 128)
        )

        XCTAssertEqual(commands.map { $0.first }, [UInt8(0x0D), UInt8(0x09), UInt8(0x01), UInt8(0x08)])
        XCTAssertEqual(commands[0], Data([0x0D, 0x80]))
        XCTAssertEqual(commands[2].count, 7 + 32 * 8 * 2)
        XCTAssertEqual(commands[2].prefix(7), Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x20, 0x08]))
        XCTAssertEqual(commands[2][7], 0xF8)
        XCTAssertEqual(commands[2][8], 0x00)
        XCTAssertEqual(commands[2][9], 0x07)
        XCTAssertEqual(commands[2][10], 0xE0)
    }

    func testStockFrameEncoderBuildsACommandSetPerProviderPage() throws {
        let pages = [
            PixelClockRenderedPage(text: "CODEX", color: "#FFFFFF", durationSeconds: 7, scrollSpeed: 100),
            PixelClockRenderedPage(text: "CLAUDE", color: "#D97757", durationSeconds: 7, scrollSpeed: 100)
        ]

        let commandSets = PixelClockStockSimulatorFrameEncoder.commandSets(
            for: pages,
            config: PixelClockConfig(enabled: true, brightness: 128)
        )

        XCTAssertEqual(commandSets.count, 2)
        XCTAssertEqual(commandSets[0].map { $0.first }, [UInt8(0x0D), UInt8(0x09), UInt8(0x00), UInt8(0x08)])
        XCTAssertEqual(commandSets[1].map { $0.first }, [UInt8(0x0D), UInt8(0x09), UInt8(0x00), UInt8(0x08)])
        XCTAssertTrue(String(data: commandSets[0][2].dropFirst(8), encoding: .utf8)?.contains("CODEX") == true)
        XCTAssertTrue(String(data: commandSets[1][2].dropFirst(8), encoding: .utf8)?.contains("CLAUDE") == true)
    }
}

@MainActor
final class PixelClockSnapshotAdapterTests: XCTestCase {
    func testQuotaItemsIncludeEveryProviderWithReadyStatusWhenQuotaIsUnavailable() {
        let items = PixelClockSnapshotAdapter.quotaItems(
            quotaService: nil,
            period: .rolling5h,
            statuses: [:]
        )

        XCTAssertEqual(items.map(\.providerID), AgentProvider.quotaSignalProviders.map(\.persistedToken))
        XCTAssertTrue(items.allSatisfy { $0.agentStatus == .ready })
        XCTAssertTrue(items.allSatisfy { $0.usageText == "ready" })
    }

    func testQuotaItemsSurfaceRunningStatusWithoutQuotaSnapshot() {
        let runningProvider = AgentProvider.codex
        let items = PixelClockSnapshotAdapter.quotaItems(
            quotaService: nil,
            period: .rolling5h,
            statuses: [runningProvider.persistedToken: .running]
        )

        let codex = items.first { $0.providerID == runningProvider.persistedToken }
        XCTAssertEqual(codex?.agentStatus, .running)
        XCTAssertEqual(codex?.usageText, "run")
    }
}

private extension PixelClockConfig {
    static let enabledTestClock = PixelClockConfig(
        enabled: true,
        host: "192.168.68.92",
        port: 80
    )
}

private final class AWTRIXStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlerLock = Locked<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.read() }
        set { handlerLock.write(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("192.168.68.") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
