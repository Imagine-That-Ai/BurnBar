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

    func testProbeReturnsAWTRIXReadyWhenStatsEndpointReturnsAWTRIXJSON() async {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/stats")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"version":"0.96","app":"Time","ram":123456,"bat":88}"#.data(using: .utf8)!
            )
        }

        let result = await AWTRIXClient(session: session).probe(config: .enabledTestClock)

        XCTAssertEqual(result.status, .awtrixReady)
        XCTAssertEqual(result.message, "AWTRIX HTTP API is ready at 192.168.68.92.")
    }

    func testProbeExplainsMacOSLocalNetworkBlock() async {
        AWTRIXStubURLProtocol.handler = { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited)"]
            )
        }

        let result = await AWTRIXClient(session: session).probe(config: .enabledTestClock)

        XCTAssertEqual(result.status, .unreachable)
        XCTAssertEqual(result.message, AWTRIXClient.localNetworkBlockedMessage)
    }

    func testPushCustomAppThrowsFriendlyMacOSLocalNetworkBlock() async throws {
        AWTRIXStubURLProtocol.handler = { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNotConnectedToInternet,
                userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited)"]
            )
        }

        do {
            try await AWTRIXClient(session: session).pushCustomApp(
                pages: [["text": "test"]],
                config: .enabledTestClock
            )
            XCTFail("Expected local network blocked error")
        } catch AWTRIXClient.ClientError.localNetworkBlocked {
            XCTAssertEqual(
                AWTRIXClient.ClientError.localNetworkBlocked.localizedDescription,
                AWTRIXClient.localNetworkBlockedMessage
            )
        } catch {
            XCTFail("Expected local network blocked error, got \(error)")
        }
    }

    func testProbeDoesNotTreatGenericStatsJSONAsAWTRIX() async {
        AWTRIXStubURLProtocol.handler = { request in
            if request.url?.path == "/api/stats" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"status":"ok","version":"1.0"}"#.data(using: .utf8)!
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let result = await AWTRIXClient(session: session).probe(config: .enabledTestClock)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.message, "Stats endpoint answered, but it did not look like AWTRIX.")
    }

    func testCurrentAppNameReturnsStatsApp() async {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/stats")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"app":"openburnbar3","version":"0.98"}"#.data(using: .utf8)!
            )
        }

        let appName = await AWTRIXClient(session: session).currentAppName(config: .enabledTestClock)

        XCTAssertEqual(appName, "openburnbar3")
    }

    func testDiscoverScansCandidatesAndReturnsReachableAWTRIXHost() async {
        AWTRIXStubURLProtocol.handler = { request in
            if request.url?.host == "192.168.68.92", request.url?.path == "/api/stats" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"version":"0.96","app":"Time","ram":123456,"bat":88}"#.data(using: .utf8)!
                )
            }
            throw URLError(.cannotConnectToHost)
        }

        let config = PixelClockConfig(enabled: true, host: "192.168.68.40", port: 80)
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
        var seenRequests: [(url: String, body: Data)] = []
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            seenRequests.append((
                request.url?.absoluteString ?? "",
                request.httpBody ?? request.bodyStreamData() ?? Data()
            ))
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

        XCTAssertEqual(seenRequests.count, 1)
        XCTAssertEqual(seenRequests.last?.url, "http://192.168.68.92/api/custom?name=openburnbar0")

        let body = try XCTUnwrap(seenRequests.last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "Claude 5H 80% 80/100")
        XCTAssertEqual(json["progress"] as? Int, 80)
        XCTAssertEqual(json["save"] as? Bool, false)
    }

    func testPushCustomAppUsesSingleSafeAWTRIXSlotWhenGivenMultipleFrames() async throws {
        var seenURLs: [String] = []
        AWTRIXStubURLProtocol.handler = { request in
            seenURLs.append(request.url?.absoluteString ?? "")
            let body = request.httpBody ?? request.bodyStreamData() ?? Data()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["save"] as? Bool, false)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).pushCustomApp(
            pages: [
                ["text": "Codex 5h", "color": "#FFFFFF", "duration": 7, "save": false],
                ["text": "Codex 7d", "color": "#FFFFFF", "duration": 7, "save": false],
                ["text": "Claude 5h", "color": "#FFFFFF", "duration": 7, "save": false]
            ],
            config: .enabledTestClock
        )

        XCTAssertEqual(seenURLs, [
            "http://192.168.68.92/api/custom?name=openburnbar0"
        ])
    }

    func testPushSentinelAppsKeepsHardwareButtonTargetsAlive() async throws {
        var seenRequests: [(url: String, body: Data)] = []
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            seenRequests.append((
                request.url?.absoluteString ?? "",
                request.httpBody ?? request.bodyStreamData() ?? Data()
            ))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).pushSentinelApps(config: .enabledTestClock)

        XCTAssertEqual(seenRequests.map(\.url), [
            "http://192.168.68.92/api/custom?name=openburnbar_btn_right",
            "http://192.168.68.92/api/custom?name=openburnbar_btn_select",
            "http://192.168.68.92/api/custom?name=openburnbar_btn_left"
        ])
        for request in seenRequests {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            XCTAssertEqual(json["duration"] as? Int, 1)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(json["lifetime"] as? Int), 900)
            XCTAssertEqual(json["save"] as? Bool, false)
            XCTAssertEqual(json["noScroll"] as? Bool, true)
            XCTAssertNotNil(json["draw"])
        }
    }

    func testTestNotifyIncludesCompletionSoundWhenProvided() async throws {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/notify")

            let body = request.httpBody ?? request.bodyStreamData() ?? Data()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["sound"] as? String, "zai")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).testNotify(
            page: PixelClockRenderedPage(text: "GLM-5 DONE", color: "#FFFFFF", durationSeconds: 4, scrollSpeed: 100),
            config: .enabledTestClock,
            sound: "zai"
        )
    }

    func testTestNotifyOmitsCompletionSoundWhenNotProvided() async throws {
        AWTRIXStubURLProtocol.handler = { request in
            let body = request.httpBody ?? request.bodyStreamData() ?? Data()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(json["sound"])
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).testNotify(
            page: PixelClockRenderedPage(text: "DONE", color: "#FFFFFF", durationSeconds: 4, scrollSpeed: 100),
            config: .enabledTestClock
        )
    }

    func testCompletionSoundResolverPrefersModelFamilyOverProvider() {
        XCTAssertEqual(
            PixelClockCompletionSoundResolver.soundName(
                providerID: AgentProvider.factory.persistedToken,
                providerName: "Factory / Droid",
                modelName: "glm-5"
            ),
            "zai"
        )
        XCTAssertEqual(
            PixelClockCompletionSoundResolver.soundName(
                providerID: AgentProvider.factory.persistedToken,
                providerName: "Factory / Droid",
                modelName: "MiniMax-M2.7-Highspeed"
            ),
            "minimax"
        )
        XCTAssertEqual(
            PixelClockCompletionSoundResolver.soundName(
                providerID: AgentProvider.codex.persistedToken,
                providerName: "Codex",
                modelName: nil
            ),
            "codex"
        )
    }

    func testAgentCompletionParserExtractsDaemonModelAndRoutesProvider() {
        let completion = AgentCompletionNotificationParser.parse(
            title: "Apollo completed its mission packet.",
            body: "Run run-123 completed on glm-5."
        )

        XCTAssertEqual(completion?.providerID, AgentProvider.zai.persistedToken)
        XCTAssertEqual(completion?.providerName, "Z.ai")
        XCTAssertEqual(completion?.modelName, "glm-5")
    }

    func testAgentCompletionParserRoutesMiniMaxModelCompletion() {
        let completion = AgentCompletionNotificationParser.parse(
            title: "Review finished",
            body: "Run run-456 finished on MiniMax-M2.7-Highspeed."
        )

        XCTAssertEqual(completion?.providerID, AgentProvider.minimax.persistedToken)
        XCTAssertEqual(completion?.providerName, "MiniMax")
        XCTAssertEqual(completion?.modelName, "MiniMax-M2.7-Highspeed")
    }

    func testApplyBrightnessClampsAndPostsSettingsPayload() async throws {
        AWTRIXStubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.68.92/api/settings")

            let body = request.httpBody ?? request.bodyStreamData() ?? Data()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["BRI"] as? Int, PixelClockConfig.safeMaximumBrightness)
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

    func testDisableAwtrixNativeAppsPostsAllStockAppFlagsOffAndKeepsButtonNavigationManual() async throws {
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
            XCTAssertEqual(json?["ATRANS"], false)
            XCTAssertEqual(json?["BLOCKN"], false)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await AWTRIXClient(session: session).disableAwtrixNativeApps(config: .enabledTestClock)
    }

    func testFirmwareFlasherRejectsSamsungAndroidUsbModemPort() {
        let usbRegistry = """
        +-o SAMSUNG_Android@00100000  <class IOUSBHostDevice>
          {
            "USB Product Name" = "SAMSUNG_Android"
            "kUSBSerialNumberString" = "R3CXB0CNS0J"
            "USB Vendor Name" = "SAMSUNG"
            "UsbExclusiveOwner" = "pid 19693, adb"
          }
        """

        XCTAssertFalse(
            PixelClockFirmwareFlasher.shouldTrySerialDevice(
                "/dev/cu.usbmodemR3CXB0CNS0J2",
                usbRegistry: usbRegistry
            )
        )
    }

    func testFirmwareFlasherAllowsEspressifUsbModemPort() {
        let usbRegistry = """
        +-o USB JTAG_serial debug unit@00100000  <class IOUSBHostDevice>
          {
            "USB Product Name" = "USB JTAG/serial debug unit"
            "kUSBSerialNumberString" = "3C84AB123456"
            "USB Vendor Name" = "Espressif"
            "idVendor" = 12346
          }
        """

        XCTAssertTrue(
            PixelClockFirmwareFlasher.shouldTrySerialDevice(
                "/dev/cu.usbmodem3C84AB1234561",
                usbRegistry: usbRegistry
            )
        )
    }

    func testFirmwareFlasherDiagnosticsSeparatesClockAndIgnoredSerialPorts() {
        let usbRegistry = """
        +-o SAMSUNG_Android@00100000  <class IOUSBHostDevice>
          {
            "USB Product Name" = "SAMSUNG_Android"
            "kUSBSerialNumberString" = "R3CXB0CNS0J"
            "USB Vendor Name" = "SAMSUNG"
          }
        +-o USB JTAG_serial debug unit@00200000  <class IOUSBHostDevice>
          {
            "USB Product Name" = "USB JTAG/serial debug unit"
            "kUSBSerialNumberString" = "3C84AB123456"
            "USB Vendor Name" = "Espressif"
          }
        """

        let diagnostics = PixelClockFirmwareFlasher.serialDiagnostics(
            serialDevices: [
                "/dev/cu.Bluetooth-Incoming-Port",
                "/dev/cu.usbmodemR3CXB0CNS0J2",
                "/dev/cu.usbmodem3C84AB1234561"
            ],
            usbRegistry: usbRegistry
        )

        XCTAssertEqual(diagnostics.clockCandidateDevices, ["/dev/cu.usbmodem3C84AB1234561"])
        XCTAssertEqual(diagnostics.ignoredSerialDevices, ["/dev/cu.usbmodemR3CXB0CNS0J2"])
    }

    func testFirmwareFlasherDiagnosticsExplainsNonClockUsbSerialOnly() {
        let diagnostics = PixelClockFirmwareFlasher.serialDiagnostics(
            serialDevices: ["/dev/cu.usbmodemR3CXB0CNS0J2"],
            usbRegistry: """
            +-o SAMSUNG_Android@00100000  <class IOUSBHostDevice>
              {
                "USB Product Name" = "SAMSUNG_Android"
                "kUSBSerialNumberString" = "R3CXB0CNS0J"
                "USB Vendor Name" = "SAMSUNG"
              }
            """
        )

        XCTAssertFalse(diagnostics.hasClockCandidate)
        XCTAssertTrue(diagnostics.setupGuidance.contains("only non-clock serial devices"), diagnostics.setupGuidance)
        XCTAssertTrue(diagnostics.setupGuidance.contains("cu.usbmodemR3CXB0CNS0J2"), diagnostics.setupGuidance)
    }

    func testFirmwareFlasherDiagnosticsExplainsBatteryCanHideMissingUsbData() {
        let diagnostics = PixelClockFirmwareFlasher.serialDiagnostics(
            serialDevices: [
                "/dev/cu.Bluetooth-Incoming-Port",
                "/dev/cu.debug-console"
            ],
            usbRegistry: ""
        )

        XCTAssertFalse(diagnostics.hasClockCandidate)
        XCTAssertTrue(diagnostics.setupGuidance.contains("battery"), diagnostics.setupGuidance)
        XCTAssertTrue(diagnostics.setupGuidance.contains("power, not data"), diagnostics.setupGuidance)
        XCTAssertTrue(diagnostics.setupGuidance.contains("data-capable USB cable"), diagnostics.setupGuidance)
    }

    func testNetworkProvisionerFindsAwtrixSetupNetworks() {
        let names = [
            "Home Wi-Fi",
            "ULANZI-SETUP",
            "awtrix_f0e1d2",
            "awtrix-fallback",
            "Coffee Shop"
        ]

        XCTAssertEqual(
            PixelClockNetworkProvisioner.setupSSIDs(fromNetworkNames: names),
            ["awtrix_f0e1d2", "awtrix-fallback", "ULANZI-SETUP"]
        )
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
        XCTAssertEqual(commands[0], Data([0x0D, UInt8(PixelClockConfig.safeMaximumBrightness)]))
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

    func testQuotaCycleItemsIncludeEveryProviderAndCorePeriodsWhenQuotaIsUnavailable() {
        let items = PixelClockSnapshotAdapter.quotaCycleItems(
            quotaService: nil,
            statuses: [:]
        )

        let expectedProviderIDs = AgentProvider.quotaSignalProviders.flatMap { provider in
            [provider.persistedToken, provider.persistedToken]
        }
        let expectedWindows = AgentProvider.quotaSignalProviders.flatMap { _ in
            ["5h", "7d"]
        }

        XCTAssertEqual(items.map(\.providerID), expectedProviderIDs)
        XCTAssertEqual(items.map(\.windowLabel), expectedWindows)
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
