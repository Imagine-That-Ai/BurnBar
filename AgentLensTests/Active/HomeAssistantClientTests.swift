import XCTest
@preconcurrency import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class HomeAssistantClientTests: XCTestCase {

    var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HomeAssistantStubURLProtocol.self]
        session = URLSession(configuration: config)
        HomeAssistantStubURLProtocol.handler = nil
    }

    override func tearDown() async throws {
        HomeAssistantStubURLProtocol.handler = nil
        session = nil
        try await super.tearDown()
    }

    // MARK: - Probe

    func testProbe_returnsOkWhenHAReturns200() async throws {
        HomeAssistantStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://homeassistant.local:8123/api/")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-HA-Version": "2026.5.0"]
            )!
            let data = "{\"message\":\"API running.\"}".data(using: .utf8)!
            return (response, data)
        }

        let client = HomeAssistantClient(session: session)
        let result = await client.probe(baseURL: URL(string: "http://homeassistant.local:8123")!)
        XCTAssertEqual(result, .ok(version: "2026.5.0"))
    }

    func testProbe_returnsOkWhenHAReturns401WithVersion() async throws {
        // Modern HA: /api/ requires auth even for healthcheck
        HomeAssistantStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["X-HA-Version": "2026.4.1"]
            )!
            return (response, Data())
        }

        let client = HomeAssistantClient(session: session)
        let result = await client.probe(baseURL: URL(string: "http://homeassistant.local:8123")!)
        XCTAssertEqual(result, .ok(version: "2026.4.1"))
    }

    func testProbe_returnsNoHomeAssistantHere_on404() async throws {
        HomeAssistantStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = HomeAssistantClient(session: session)
        let result = await client.probe(baseURL: URL(string: "http://homeassistant.local:8123")!)
        XCTAssertEqual(result, .noHomeAssistantHere)
    }

    func testProbe_returnsUnreachable_onTransport() async throws {
        HomeAssistantStubURLProtocol.handler = { _ in
            throw URLError(.cannotFindHost)
        }

        let client = HomeAssistantClient(session: session)
        let result = await client.probe(baseURL: URL(string: "http://no-such-host.local:8123")!)
        if case .unreachable = result {
            // ok
        } else {
            XCTFail("expected unreachable, got \(result)")
        }
    }

    // MARK: - Token validation

    func testValidateToken_succeedsOn200() async throws {
        let bearer = "test-token-abc"
        HomeAssistantStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(bearer)")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, "{\"message\":\"API running.\"}".data(using: .utf8)!)
        }
        let client = HomeAssistantClient(session: session)
        try await client.validateToken(
            baseURL: URL(string: "http://homeassistant.local:8123")!,
            accessToken: bearer
        )
    }

    func testValidateToken_throwsUnauthorizedOn401() async throws {
        HomeAssistantStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let client = HomeAssistantClient(session: session)
        do {
            try await client.validateToken(
                baseURL: URL(string: "http://homeassistant.local:8123")!,
                accessToken: "bad"
            )
            XCTFail("expected throw")
        } catch let error as HomeAssistantClient.ClientError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: - List media players

    func testListMediaPlayers_filtersAndSortsCastable() async throws {
        let json = """
        [
          {
            "entity_id": "light.kitchen",
            "state": "on",
            "attributes": {"friendly_name": "Kitchen Light"}
          },
          {
            "entity_id": "media_player.bedroom_speaker",
            "state": "off",
            "attributes": {"friendly_name": "Bedroom Speaker", "supported_features": 0}
          },
          {
            "entity_id": "media_player.kitchen_display",
            "state": "idle",
            "attributes": {"friendly_name": "Kitchen Display", "supported_features": 512, "model_name": "Google Nest Hub"}
          },
          {
            "entity_id": "media_player.living_room_chromecast",
            "state": "off",
            "attributes": {"friendly_name": "Living Room Chromecast", "supported_features": 512}
          }
        ]
        """
        HomeAssistantStubURLProtocol.handler = { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/api/states"))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }
        let client = HomeAssistantClient(session: session)
        let players = try await client.listMediaPlayers(
            baseURL: URL(string: "http://homeassistant.local:8123")!,
            accessToken: "tok"
        )
        XCTAssertEqual(players.count, 3)
        XCTAssertTrue(players[0].supportsCast)
        XCTAssertTrue(players[1].supportsCast)
        // Cast-capable should be first
        XCTAssertTrue(players[0].friendlyName == "Kitchen Display" || players[0].friendlyName == "Living Room Chromecast")
        XCTAssertEqual(players.last?.entityID, "media_player.bedroom_speaker")
    }

    // MARK: - Best match heuristic

    func testBestMatch_picksExactNameMatch() {
        let players = [
            HomeAssistantClient.MediaPlayer(
                entityID: "media_player.kitchen_display",
                friendlyName: "Kitchen Display",
                model: "Google Nest Hub",
                supportsCast: true,
                supportedFeatures: 0x200,
                state: "idle"
            ),
            HomeAssistantClient.MediaPlayer(
                entityID: "media_player.bedroom_chromecast",
                friendlyName: "Bedroom",
                model: "Chromecast",
                supportsCast: true,
                supportedFeatures: 0x200,
                state: "off"
            )
        ]
        let best = HomeAssistantClient.MediaPlayer.bestMatch(in: players, for: "Kitchen Display")
        XCTAssertEqual(best?.entityID, "media_player.kitchen_display")
    }

    func testBestMatch_fallsBackToFirstCastable() {
        let players = [
            HomeAssistantClient.MediaPlayer(
                entityID: "media_player.basement",
                friendlyName: "Basement",
                model: "Chromecast",
                supportsCast: true,
                supportedFeatures: 0x200,
                state: "off"
            )
        ]
        let best = HomeAssistantClient.MediaPlayer.bestMatch(in: players, for: "Nonexistent Entity")
        XCTAssertEqual(best?.entityID, "media_player.basement")
    }

    // MARK: - Upsert automation

    func testUpsertAutomation_postsPayloadToConfigEndpoint() async throws {
        let configReceived = Locked<[String: Any]?>(nil)
        let bodyReceived = Locked<Data?>(nil)
        let methodReceived = Locked<String?>(nil)
        let urlReceived = Locked<URL?>(nil)
        HomeAssistantStubURLProtocol.handler = { request in
            urlReceived.write(request.url)
            methodReceived.write(request.httpMethod)
            let body = request.httpBody ?? request.bodyStreamData()
            bodyReceived.write(body)
            if let body, let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                configReceived.write(parsed)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, "{\"result\":\"ok\"}".data(using: .utf8)!)
        }

        let client = HomeAssistantClient(session: session)
        let payload = HomeAssistantRecoveryProvisioner.automationPayload(
            webhookID: "openburnbar_cast_recover_zzz",
            mediaPlayerEntityID: "media_player.kitchen_display",
            fallbackDashboardURL: URL(string: "http://192.168.1.10:8787/render.html")!
        )
        try await client.upsertAutomation(
            baseURL: URL(string: "http://homeassistant.local:8123")!,
            accessToken: "tok",
            automationID: "openburnbar_smart_display_recovery",
            payload: payload
        )
        XCTAssertEqual(methodReceived.read(), "POST")
        XCTAssertEqual(
            urlReceived.read()?.absoluteString,
            "http://homeassistant.local:8123/api/config/automation/config/openburnbar_smart_display_recovery"
        )
        XCTAssertEqual(configReceived.read()?["alias"] as? String, "OpenBurnBar Smart Display Recovery")
    }
}

extension URLRequest {
    /// Test helper. URLProtocol stubbing strips httpBody on stream-only requests.
    func bodyStreamData() -> Data? {
        guard let stream = self.httpBodyStream else { return nil }
        var data = Data()
        stream.open()
        defer { stream.close() }
        let chunk = 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunk)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - URLProtocol stub for HA tests

final class HomeAssistantStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlerLock = Locked<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.read() }
        set { handlerLock.write(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.contains("homeassistant") == true
            || request.url?.path.contains("/api/") == true
            || request.url?.path.contains("/api") == true
            || request.url?.absoluteString.contains("homeassistant.local") == true
            || request.url?.absoluteString.contains("/api") == true
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
