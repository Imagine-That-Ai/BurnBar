#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class OpenBurnBarHTTPGatewayServerLinuxTests: XCTestCase {
    func testStreamsChatCompletionsThroughConfiguredProviderAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer()
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        try await harness.start()

        let body = #"{"model":"glm-5-turbo","stream":true,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        XCTAssertTrue(response.body.contains("data: {\"id\":\"chatcmpl-linux\""))
        XCTAssertTrue(response.body.contains("data: [DONE]"))

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/chat/completions")
        XCTAssertEqual(upstreamRequest.authorization, "Bearer primary-key")
        XCTAssertTrue(upstreamRequest.body.contains("\"model\":\"glm-5-turbo\""))

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "zai")
        XCTAssertEqual(event.modelID, "glm-5-turbo")
        XCTAssertEqual(event.inputTokens, 5)
        XCTAssertEqual(event.outputTokens, 5)
        XCTAssertEqual(event.cacheReadTokens, 2)
        XCTAssertEqual(event.cacheCreationTokens, 3)
        XCTAssertEqual(event.reasoningTokens, 1)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/chat/completions")
        XCTAssertEqual(entry.providerID, "zai")
        XCTAssertEqual(entry.finalStatus, .exact)
        XCTAssertEqual(entry.httpStatus, 200)
        XCTAssertTrue(entry.streamed)

        try await assertMidStreamUpstreamDropClosesWithoutSecondHTTPResponse()
    }

    private func assertMidStreamUpstreamDropClosesWithoutSecondHTTPResponse() async throws {
        let upstream = LinuxMockOpenAIStreamServer(dropsAfterFirstChunk: true)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        try await harness.start()

        let body = #"{"model":"glm-5-turbo","stream":true,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        XCTAssertTrue(response.body.contains("data: {\"id\":\"chatcmpl-linux\""))
        XCTAssertFalse(response.body.contains("HTTP/1.1 "), "gateway must not append a second buffered HTTP response after streaming starts")
        XCTAssertEqual(response.rawText.components(separatedBy: "HTTP/1.1 ").count - 1, 1)
    }

    func testStreamsAnthropicChatCompletionsThroughMessagesTransformerAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer(response: .anthropicMessagesStream)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureAnthropicProvider(baseURL: "http://127.0.0.1:\(upstream.port)/anthropic/v1")
        try await harness.start()

        let body = #"{"model":"claude-sonnet-4-6","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        XCTAssertTrue(response.body.contains(#""object":"chat.completion.chunk""#), response.body)
        XCTAssertTrue(response.body.contains(#""delta":{"role":"assistant"}"#), response.body)
        XCTAssertTrue(response.body.contains(#""content":"hello ""#), response.body)
        XCTAssertTrue(response.body.contains(#""tool_calls""#), response.body)
        XCTAssertTrue(response.body.contains(#""arguments":"{\"city\":\"Ch""#), response.body)
        XCTAssertTrue(response.body.contains(#""finish_reason":"tool_calls""#), response.body)
        XCTAssertTrue(response.body.contains("data: [DONE]"), response.body)
        XCTAssertFalse(response.body.contains("event: content_block_delta"), response.body)

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/anthropic/v1/messages")
        XCTAssertEqual(upstreamRequest.xApiKey, "sk-ant-api03-primary-key")
        XCTAssertTrue(upstreamRequest.body.contains(#""stream":true"#), upstreamRequest.body)
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"claude-sonnet-4-6""#), upstreamRequest.body)

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "anthropic")
        XCTAssertEqual(event.modelID, "claude-sonnet-4-6")
        XCTAssertEqual(event.inputTokens, 11)
        XCTAssertEqual(event.outputTokens, 8)
        XCTAssertEqual(event.cacheCreationTokens, 3)
        XCTAssertEqual(event.cacheReadTokens, 2)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/chat/completions")
        XCTAssertEqual(entry.endpoint, "Chat Completions")
        XCTAssertTrue(entry.streamed)
        XCTAssertEqual(entry.usage?.inputTokens, 11)
        XCTAssertEqual(entry.usage?.outputTokens, 8)
    }

    func testProxiesResponsesThroughConfiguredProviderAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer(response: .openAIResponsesJSON)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        try await harness.start()

        let body = #"{"model":"glm-5-turbo","input":"ping"}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/responses",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertTrue(response.body.contains(#""object":"response""#), response.body)
        XCTAssertTrue(response.body.contains("response from linux"), response.body)

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")
        XCTAssertEqual(upstreamRequest.authorization, "Bearer primary-key")
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"glm-5-turbo""#), upstreamRequest.body)

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "zai")
        XCTAssertEqual(event.inputTokens, 13)
        XCTAssertEqual(event.outputTokens, 7)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/responses")
        XCTAssertEqual(entry.endpoint, "Responses")
        XCTAssertFalse(entry.streamed)
    }

    func testProxiesAnthropicMessagesThroughConfiguredProviderAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer(response: .anthropicMessagesJSON)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureAnthropicProvider(baseURL: "http://127.0.0.1:\(upstream.port)/anthropic/v1")
        try await harness.start()

        let body = #"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/messages",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertTrue(response.body.contains(#""type":"message""#), response.body)
        XCTAssertTrue(response.body.contains("anthropic linux"), response.body)

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/anthropic/v1/messages")
        XCTAssertEqual(upstreamRequest.xApiKey, "sk-ant-api03-primary-key")
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"claude-sonnet-4-6""#), upstreamRequest.body)

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "anthropic")
        XCTAssertEqual(event.inputTokens, 17)
        XCTAssertEqual(event.outputTokens, 4)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/messages")
        XCTAssertEqual(entry.endpoint, "Anthropic Messages")
        XCTAssertFalse(entry.streamed)
    }

    func testRejectsMalformedChatCompletionsRequestBeforeRouting() async throws {
        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.start()

        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: #"{"stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(response.body.contains("model field required"))
        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 10)
        XCTAssertTrue(routeLog.isEmpty)
    }
}

private final class LinuxGatewayHarness: @unchecked Sendable {
    let port: Int
    let usageRecorder: BurnBarUsageRecorder
    let proxyRouteLogStore: BurnBarProxyRouteLogStore
    private let configStore: BurnBarConfigStore
    private let server: BurnBarHTTPGatewayServer
    private let tempDirectory: URL

    init() throws {
        self.port = try LinuxSocketSupport.reserveLoopbackPort()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-gateway-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        configStore = BurnBarConfigStore(
            fileURL: tempDirectory.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
        usageRecorder = BurnBarUsageRecorder(
            fileURL: tempDirectory.appendingPathComponent("usage-ledger.jsonl"),
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
        proxyRouteLogStore = BurnBarProxyRouteLogStore(
            fileURL: tempDirectory.appendingPathComponent("proxy-route-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
        server = BurnBarHTTPGatewayServer(
            configuration: BurnBarGatewayConfiguration(
                isEnabled: true,
                host: "127.0.0.1",
                port: port,
                authToken: nil,
                allowUnauthenticatedLoopback: true
            ),
            configStore: configStore,
            usageRecorder: usageRecorder,
            proxyRouteLogStore: proxyRouteLogStore,
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
    }

    func configureZAIProvider(baseURL: String) async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: baseURL,
                preferredModelIDs: ["glm-5-turbo"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-key"
        )
    }

    func configureAnthropicProvider(baseURL: String) async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: baseURL,
                preferredModelIDs: ["claude-sonnet-4-6"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "primary",
            label: "Primary",
            apiKey: "sk-ant-api03-primary-key"
        )
    }

    func start() async throws {
        try await server.start()
        try await LinuxSocketSupport.waitForListener(port: port)
    }

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

private final class LinuxMockOpenAIStreamServer: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let authorization: String?
        let xApiKey: String?
        let body: String
    }

    enum Response: Sendable {
        case openAIChatStream
        case openAIResponsesJSON
        case anthropicMessagesJSON
        case anthropicMessagesStream
    }

    private let lock = NSLock()
    private var requests: [Request] = []
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private(set) var port: Int = 0
    private let dropsAfterFirstChunk: Bool
    private let response: Response

    init(dropsAfterFirstChunk: Bool = false, response: Response = .openAIChatStream) {
        self.dropsAfterFirstChunk = dropsAfterFirstChunk
        self.response = response
    }

    var recordedRequests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func start() throws {
        let socketFD = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var one: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x0100007F).littleEndian

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.getsockname(socketFD, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))

        guard Glibc.listen(socketFD, SOMAXCONN) == 0 else {
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        listenFD = socketFD
        acceptTask = Task.detached(priority: .utility) { [weak self] in
            self?.acceptOnce(socketFD: socketFD)
        }
    }

    func stop() {
        acceptTask?.cancel()
        if listenFD >= 0 {
            Glibc.close(listenFD)
            listenFD = -1
        }
    }

    private func acceptOnce(socketFD: Int32) {
        var address = sockaddr()
        var addressLength = socklen_t(MemoryLayout<sockaddr>.stride)
        let clientFD = Glibc.accept(socketFD, &address, &addressLength)
        guard clientFD >= 0 else { return }
        defer { Glibc.close(clientFD) }

        guard let requestText = try? LinuxSocketSupport.readHTTPRequest(from: clientFD) else { return }
        let request = Self.parseRequest(requestText)
        lock.lock()
        requests.append(request)
        lock.unlock()

        switch response {
        case .openAIChatStream:
            let contentLength = dropsAfterFirstChunk ? "Content-Length: 10000\r\n" : ""
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\n"
                + contentLength
                + "Connection: close\r\n"
                + "\r\n"
            _ = try? LinuxSocketSupport.sendAll(Data(head.utf8), to: clientFD)

            let firstChunk = #"data: {"id":"chatcmpl-linux","object":"chat.completion.chunk","created":1783200000,"model":"glm-5-turbo","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"# + "\n\n"
            _ = try? LinuxSocketSupport.sendAll(Data(firstChunk.utf8), to: clientFD)
            if dropsAfterFirstChunk {
                var resetLinger = linger(l_onoff: 1, l_linger: 0)
                setsockopt(clientFD, SOL_SOCKET, SO_LINGER, &resetLinger, socklen_t(MemoryLayout<linger>.size))
                return
            }
            Glibc.usleep(50_000)
            let usageChunk = #"data: {"id":"chatcmpl-linux","object":"chat.completion.chunk","created":1783200000,"model":"glm-5-turbo","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"#
                + #""usage":{"prompt_tokens":7,"completion_tokens":5,"total_tokens":12,"cache_creation_input_tokens":3,"prompt_tokens_details":{"cached_tokens":2},"completion_tokens_details":{"reasoning_tokens":1}}}"# + "\n\n"
            _ = try? LinuxSocketSupport.sendAll(Data(usageChunk.utf8), to: clientFD)
            _ = try? LinuxSocketSupport.sendAll(Data("data: [DONE]\n\n".utf8), to: clientFD)
        case .openAIResponsesJSON:
            sendJSON(
                """
                {"id":"resp_linux","object":"response","created_at":1783200000,"status":"completed","model":"glm-5-turbo",\
                "output":[{"id":"msg_linux","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"response from linux","annotations":[]}]}],\
                "output_text":"response from linux","usage":{"input_tokens":13,"output_tokens":7,"total_tokens":20}}
                """,
                to: clientFD
            )
        case .anthropicMessagesJSON:
            sendJSON(
                """
                {"id":"msg_linux","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"anthropic linux"}],\
                "stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":17,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
                """,
                to: clientFD
            )
        case .anthropicMessagesStream:
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            _ = try? LinuxSocketSupport.sendAll(Data(head.utf8), to: clientFD)
            let chunks = [
                #"""
event: message_start
data: {"type":"message_start","message":{"id":"msg_stream","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[],"usage":{"input_tokens":11,"output_tokens":0,"cache_creation_input_tokens":3,"cache_read_input_tokens":2}}}

"""# + "\n",
                #"""
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}

"""# + "\n",
                #"""
event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_linux","name":"get_weather","input":{}}}

"""# + "\n",
                #"""
event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Ch"}}

"""# + "\n",
                #"""
event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"icago\"}"}}

"""# + "\n",
                #"""
event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":8}}

"""# + "\n",
                #"""
event: message_stop
data: {"type":"message_stop"}

"""# + "\n"
            ]
            for chunk in chunks {
                _ = try? LinuxSocketSupport.sendAll(Data(chunk.utf8), to: clientFD)
                Glibc.usleep(10_000)
            }
        }
    }

    private static func parseRequest(_ raw: String) -> Request {
        let sections = raw.components(separatedBy: "\r\n\r\n")
        let headerLines = sections.first?.components(separatedBy: "\r\n") ?? []
        let requestLine = headerLines.first?.split(separator: " ") ?? []
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""
        let authorization = headerLines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
        let xApiKey = headerLines.first { $0.lowercased().hasPrefix("x-api-key:") }
            .map { $0.dropFirst("x-api-key:".count).trimmingCharacters(in: .whitespaces) }
        return Request(
            path: path,
            authorization: authorization,
            xApiKey: xApiKey,
            body: sections.dropFirst().joined(separator: "\r\n\r\n")
        )
    }

    private func sendJSON(_ body: String, to clientFD: Int32) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        _ = try? LinuxSocketSupport.sendAll(Data(head.utf8), to: clientFD)
        _ = try? LinuxSocketSupport.sendAll(data, to: clientFD)
    }
}

private enum LinuxHTTPClient {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: String
        let rawText: String
    }

    static func post(port: Int, path: String, body: String) async throws -> Response {
        try await Task.detached(priority: .utility) {
            let socketFD = try LinuxSocketSupport.connectToLoopback(port: port)
            defer { Glibc.close(socketFD) }
            let request = """
            POST \(path) HTTP/1.1\r
            Host: 127.0.0.1:\(port)\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            try LinuxSocketSupport.sendAll(Data(request.utf8), to: socketFD)
            let raw = try LinuxSocketSupport.readUntilEOF(from: socketFD)
            return try parseResponse(raw)
        }.value
    }

    private static func parseResponse(_ raw: Data) throws -> Response {
        let text = String(decoding: raw, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let headerText = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = headerText.components(separatedBy: "\r\n")
        let statusCode = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[String(name)] = value
        }
        return Response(statusCode: statusCode, headers: headers, body: body, rawText: text)
    }
}

private enum LinuxSocketSupport {
    static func reserveLoopbackPort() throws -> Int {
        let socketFD = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Glibc.close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x0100007F).littleEndian

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.getsockname(socketFD, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    static func waitForListener(port: Int) async throws {
        var lastError: Error?
        for _ in 0..<250 {
            do {
                let socketFD = try connectToLoopback(port: port)
                Glibc.close(socketFD)
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw lastError ?? POSIXError(.ETIMEDOUT)
    }

    static func connectToLoopback(port: Int) throws -> Int32 {
        let socketFD = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x0100007F).littleEndian

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.connect(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: code) ?? .ECONNREFUSED)
        }
        return socketFD
    }

    static func readHTTPRequest(from socketFD: Int32) throws -> String {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let chunk = try recvChunk(from: socketFD)
            if chunk.isEmpty { break }
            data.append(chunk)
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
        }

        let headerText = String(decoding: data, as: UTF8.self)
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let currentBodyCount: Int
        if let headerEnd {
            currentBodyCount = data.distance(from: headerEnd.upperBound, to: data.endIndex)
        } else {
            currentBodyCount = 0
        }
        var remaining = max(contentLength - currentBodyCount, 0)
        while remaining > 0 {
            let chunk = try recvChunk(from: socketFD)
            if chunk.isEmpty { break }
            data.append(chunk)
            remaining -= chunk.count
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func readUntilEOF(from socketFD: Int32) throws -> Data {
        var data = Data()
        while true {
            let chunk = try recvChunk(from: socketFD)
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }

    static func sendAll(_ data: Data, to socketFD: Int32) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Glibc.send(socketFD, base.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
            }
            guard sent > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            offset += sent
        }
    }

    private static func recvChunk(from socketFD: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Glibc.recv(socketFD, &buffer, buffer.count, 0)
        if count < 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if count == 0 {
            return Data()
        }
        return Data(buffer.prefix(count))
    }
}

#else
import XCTest

final class OpenBurnBarHTTPGatewayServerLinuxTests: XCTestCase {
    func testLinuxGatewayCoverageRunsInDocker() throws {
        throw XCTSkip("Linux-only gateway parity coverage runs in the Docker toolchain.")
    }
}
#endif
