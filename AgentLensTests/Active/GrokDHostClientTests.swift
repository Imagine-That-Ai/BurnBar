import XCTest
@preconcurrency import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class GrokDHostClientTests: XCTestCase {
    private var session: URLSession!
    private let token = "test-token-do-not-print-xyz"

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GrokDStubURLProtocol.self]
        session = URLSession(configuration: config)
        GrokDStubURLProtocol.handler = nil
        GrokDStubURLProtocol.requests = []
    }

    override func tearDown() async throws {
        GrokDStubURLProtocol.handler = nil
        GrokDStubURLProtocol.requests = []
        session = nil
        try await super.tearDown()
    }

    func testBoxTitleCopy() {
        XCTAssertEqual(GrokDFeature.boxTitle(liveCount: 7), "Local D box (7 live agents)")
        XCTAssertFalse(GrokDFeature.isEnabled(defaults: UserDefaults(suiteName: "GrokDHostClientTests.flag")!))
    }

    func testConfigNeverUsesLocalhostAndRedactsToken() throws {
        let env = try makeActiveEnv(token: token, mode: "cursor")
        let config = try GrokDHostConfig.load(fromActiveEnv: env)
        XCTAssertEqual(config.loopbackHost, "127.0.0.1")
        XCTAssertEqual(config.shimPort, 1337)
        XCTAssertEqual(config.apiURL("listAgents").absoluteString, "http://127.0.0.1:1337/api/listAgents")
        XCTAssertFalse(config.apiURL("sendPrompt").absoluteString.contains("localhost"))
        XCTAssertFalse(config.guiIsLocalProfile)
        XCTAssertFalse(config.description.contains(token))
        XCTAssertFalse(String(reflecting: config).contains(token))
    }

    func testHealthCannotListWhenShimAndHostDown() async {
        let client = makeClient(ports: [])
        let health = await client.health()
        XCTAssertEqual(health, .cannotList)
        await XCTAssertThrowsErrorAsync({ try await client.sendPrompt(agentID: Self.benchID, prompt: "x") }) { error in
            XCTAssertEqual(error as? GrokDHostError, .sendRefused(.cannotList))
        }
    }

    func testHealthCanListHostDownRefusesSendEvenIfListAgentsWould200() async {
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false))
        }
        let client = makeClient(ports: [1337, 8787])
        let health = await client.health()
        XCTAssertEqual(health, .canListHostDown)
        XCTAssertEqual(health.userMessage, "local box host is down")
        await XCTAssertThrowsErrorAsync({ try await client.sendPrompt(agentID: Self.benchID, prompt: "x") }) { error in
            XCTAssertEqual(error as? GrokDHostError, .sendRefused(.canListHostDown))
        }
        XCTAssertTrue(GrokDStubURLProtocol.requests.isEmpty, "must not POST sendPrompt when 1338 is down")
    }

    func testHealthCanListCannotCompleteWhenInferenceDown() async {
        let client = makeClient(ports: [1337, 1338])
        let health = await client.health()
        XCTAssertEqual(health, .canListCannotComplete)
        XCTAssertEqual(health.userMessage, "inference proxy is down")
        await XCTAssertThrowsErrorAsync({ try await client.sendPrompt(agentID: Self.benchID, prompt: "hi") }) { error in
            XCTAssertEqual(error as? GrokDHostError, .sendRefused(.canListCannotComplete))
        }
        XCTAssertTrue(GrokDStubURLProtocol.requests.isEmpty)
    }

    func testHealthOkRequiresListAgents200() async {
        GrokDStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.path, "/api/listAgents")
            return Self.json(request, 200, Self.agentJSON(running: false))
        }
        let client = makeClient(ports: [1337, 1338, 8787])
        let health = await client.health()
        XCTAssertEqual(health, .ok)
    }

    func testSendPromptPostsUUIDAwaitTurnFalseAndBearer() async throws {
        let expectedToken = token
        GrokDStubURLProtocol.handler = { request in
            if request.url?.path == "/api/listAgents" {
                return Self.json(request, 200, Self.agentJSON(running: false))
            }
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1337/api/sendPrompt")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedToken)")
            let body = try XCTUnwrap(Self.bodyJSON(request))
            XCTAssertEqual(body["agentId"] as? String, Self.benchID)
            XCTAssertEqual(body["awaitTurn"] as? Bool, false)
            XCTAssertEqual(body["prompt"] as? String, "hello")
            return Self.json(request, 200, #"{"accepted":true}"#)
        }
        let client = makeClient(ports: [1337, 1338, 8787])
        let handle = try await client.sendPrompt(agentID: Self.benchID, prompt: "hello")
        XCTAssertEqual(handle.agentID, Self.benchID)
        XCTAssertFalse(String(describing: handle).contains(token))
    }

    func testSendPromptRejectsNonUUIDName() async {
        let client = makeClient(ports: [1337, 1338, 8787])
        await XCTAssertThrowsErrorAsync({ try await client.sendPrompt(agentID: "Robust Bench", prompt: "x") }) { error in
            XCTAssertEqual(error as? GrokDHostError, .invalidAgentID)
        }
        XCTAssertTrue(GrokDStubURLProtocol.requests.isEmpty)
    }

    func testBusyAgentDrop() async {
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: true))
        }
        let client = makeClient(ports: [1337, 1338, 8787])
        await XCTAssertThrowsErrorAsync({ try await client.sendPrompt(agentID: Self.benchID, prompt: "x") }) { error in
            XCTAssertEqual(error as? GrokDHostError, .agentBusy(id: Self.benchID))
        }
        XCTAssertFalse(GrokDStubURLProtocol.requests.contains(where: { $0.url?.path == "/api/sendPrompt" }))
    }

    func testAutoStartDoesNotRunWhenFlagOffOrSandboxed() {
        let defaults = UserDefaults(suiteName: "GrokDHostClientTests.autostart.\(UUID().uuidString)")!
        defaults.set(false, forKey: GrokDFeature.DefaultsKey.enabled)
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.autoStart)
        var ran = false
        let started = GrokDFeature.startLocalBoxIfNeeded(defaults: defaults) { _ in ran = true }
        XCTAssertFalse(started)
        XCTAssertFalse(ran)
    }

    func testCursorModeMissingTokenUsesLoopbackBearerAndWarns() throws {
        let env = try makeActiveEnv(token: nil, mode: "cursor")
        let config = try GrokDHostConfig.load(fromActiveEnv: env)
        XCTAssertFalse(config.guiIsLocalProfile)
        XCTAssertEqual(config.bearerToken, GrokDHostConfig.localBoxShimBearer)
        XCTAssertFalse(config.description.contains(GrokDHostConfig.localBoxShimBearer))
    }

    func testBoxModelDisabledDoesNotNetwork() async {
        let defaults = UserDefaults(suiteName: "GrokDBoxModel.off.\(UUID().uuidString)")!
        defaults.set(false, forKey: GrokDFeature.DefaultsKey.enabled)
        let listed = Locked<Int>(0)
        let session = self.session!
        let token = self.token
        let model = GrokDBoxModel(defaults: defaults) {
            listed.withLock { $0 += 1 }
            return GrokDHostClient(
                config: GrokDHostConfig(
                    loopbackHost: "127.0.0.1",
                    shimPort: 1337,
                    hostPort: 1338,
                    inferencePort: 8787,
                    bearerToken: token,
                    guiMode: "local"
                ),
                session: session,
                portProbe: GrokDStubPortProbe(open: [1337, 1338, 8787])
            )
        }
        await model.refresh()
        XCTAssertEqual(listed.read(), 0)
        XCTAssertEqual(model.title, "Local D box (0 live agents)")
        XCTAssertFalse(model.canSend)
    }

    func testBoxModelHostDownRefusesSend() async {
        let defaults = UserDefaults(suiteName: "GrokDBoxModel.hostdown.\(UUID().uuidString)")!
        defaults.set(true, forKey: GrokDFeature.DefaultsKey.enabled)
        GrokDStubURLProtocol.handler = { request in
            Self.json(request, 200, Self.agentJSON(running: false))
        }
        let session = self.session!
        let token = self.token
        let model = GrokDBoxModel(defaults: defaults) {
            GrokDHostClient(
                config: GrokDHostConfig(
                    loopbackHost: "127.0.0.1",
                    shimPort: 1337,
                    hostPort: 1338,
                    inferencePort: 8787,
                    bearerToken: token,
                    guiMode: "local"
                ),
                session: session,
                portProbe: GrokDStubPortProbe(open: [1337, 8787])
            )
        }
        await model.refresh()
        XCTAssertEqual(model.health, .canListHostDown)
        XCTAssertEqual(model.agents.count, 1)
        model.selectedAgentID = Self.benchID
        model.promptText = "hello"
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.lastMessage, "local box host is down")
        await model.send()
        XCTAssertTrue(GrokDStubURLProtocol.requests.allSatisfy { $0.url?.path != "/api/sendPrompt" })
    }

    func testLiveHealthRefusesUnlessAllPortsUp() async throws {
        let probe = GrokDTCPPortProbe()
        let shim = probe.isListening(host: "127.0.0.1", port: 1337)
        try XCTSkipUnless(shim, "Local D shim :1337 is down")
        let envURL = GrokDHostConfig.defaultActiveEnvURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: envURL.path), "active-env.json missing")
        let config = try GrokDHostConfig.load(fromActiveEnv: envURL)
        let client = GrokDHostClient(config: config, portProbe: probe)
        let host = probe.isListening(host: "127.0.0.1", port: 1338)
        let inference = probe.isListening(host: "127.0.0.1", port: 8787)
        let started = Date()
        let health = await client.health()
        if !host {
            XCTAssertEqual(health, .canListHostDown)
            XCTAssertEqual(health.userMessage, "local box host is down")
        } else if !inference {
            XCTAssertEqual(health, .canListCannotComplete)
            XCTAssertEqual(health.userMessage, "inference proxy is down")
        } else {
            XCTAssertEqual(health, .ok)
            return
        }
        do {
            _ = try await client.sendPrompt(agentID: Self.benchID, prompt: "should-not-run")
            XCTFail("send must refuse when health is \(health)")
        } catch let error as GrokDHostError {
            XCTAssertEqual(error, .sendRefused(health))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testLiveLoopbackHealthSkipsWhenPortsDown() async throws {
        let probe = GrokDTCPPortProbe()
        let shim = probe.isListening(host: "127.0.0.1", port: 1337)
        let host = probe.isListening(host: "127.0.0.1", port: 1338)
        let inference = probe.isListening(host: "127.0.0.1", port: 8787)
        try XCTSkipUnless(shim && host && inference, "Local D ports 1337/1338/8787 are down")
        let envURL = GrokDHostConfig.defaultActiveEnvURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: envURL.path), "active-env.json missing")
        let config = try GrokDHostConfig.load(fromActiveEnv: envURL)
        let client = GrokDHostClient(config: config, portProbe: probe)
        let health = await client.health()
        XCTAssertEqual(health, .ok)
        let agents = try await client.listAgents()
        XCTAssertFalse(agents.isEmpty)
        XCTAssertTrue(agents.allSatisfy { GrokDHostClient.isAgentUUID($0.id) })
    }

    // MARK: - Helpers

    private nonisolated static let benchID = "7fa6a3c4-9f24-46be-9795-396308b0f612"

    private func makeClient(ports: Set<UInt16>) -> GrokDHostClient {
        let config = GrokDHostConfig(
            loopbackHost: "127.0.0.1",
            shimPort: 1337,
            hostPort: 1338,
            inferencePort: 8787,
            bearerToken: token,
            guiMode: "local"
        )
        return GrokDHostClient(
            config: config,
            session: session,
            portProbe: GrokDStubPortProbe(open: ports)
        )
    }

    private func makeActiveEnv(token: String?, mode: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grokd-env-\(UUID().uuidString).json")
        let body: String
        if let token {
            body = #"{"mode":"\#(mode)","SAND_HOST_GATEWAY_TOKEN":"\#(token)"}"#
        } else {
            body = #"{"mode":"\#(mode)"}"#
        }
        try Data(body.utf8).write(to: url)
        return url
    }

    private nonisolated static func agentJSON(running: Bool) -> String {
        """
        [{"id":"\(benchID)","name":"Robust Bench","isRunning":\(running),"isComposingMessage":false}]
        """
    }

    private nonisolated static func json(_ request: URLRequest, _ status: Int, _ body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    private nonisolated static func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.flatMap { stream in
            let buffer = NSMutableData()
            stream.open()
            let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { tmp.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(tmp, maxLength: 4096)
                if n > 0 { buffer.append(tmp, length: n) } else { break }
            }
            return buffer as Data
        })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct GrokDStubPortProbe: GrokDPortProbing {
    var open: Set<UInt16>
    func isListening(host: String, port: UInt16) -> Bool {
        host == "127.0.0.1" && open.contains(port)
    }
}

private final class GrokDStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlerLock = Locked<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static let requestLock = Locked<[URLRequest]>([])

    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.read() }
        set { handlerLock.write(newValue) }
    }

    static var requests: [URLRequest] {
        get { requestLock.read() }
        set { requestLock.write(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLock.withLock { $0.append(request) }
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

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
