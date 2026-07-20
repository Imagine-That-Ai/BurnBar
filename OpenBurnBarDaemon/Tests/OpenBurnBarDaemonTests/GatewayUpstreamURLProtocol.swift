import Foundation

struct GatewayUpstreamRequest: Hashable {
    let authorization: String?
    let path: String
    let query: String?
    let body: String
    let xApiKey: String?
    let anthropicVersion: String?
    let anthropicBeta: String?
    let anthropicBillingHeader: String?
    let userAgent: String?
    let xApp: String?
    let directBrowserAccess: String?
    let timeoutInterval: TimeInterval
}

final class GatewayUpstreamURLProtocol: URLProtocol {
    private struct Response {
        let status: Int
        let body: Data
        let delayNanoseconds: UInt64
        let path: String?
        let headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuedResponses: [Response] = []
    nonisolated(unsafe) private static var requests: [GatewayUpstreamRequest] = []

    static func enqueue(
        status: Int,
        body: String,
        delayNanoseconds: UInt64 = 0,
        path: String? = nil,
        headers: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses.append(
            Response(
                status: status,
                body: Data(body.utf8),
                delayNanoseconds: delayNanoseconds,
                path: path,
                headers: headers
            )
        )
    }

    static func recordedRequests() -> [GatewayUpstreamRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = []
        requests = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return ["gateway-upstream.test", "ollama.com", "127.0.0.1", "localhost"].contains(host)
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let requestPath = request.url?.path ?? ""
        let response: Response
        var shouldRecordRequest = true
        if let index = Self.queuedResponses.firstIndex(where: { $0.path == requestPath }) {
            response = Self.queuedResponses.remove(at: index)
        } else if requestPath == "/anthropic/v1/models" {
            response = Response(
                status: 200,
                body: Data(Self.defaultAnthropicModelCatalogBody.utf8),
                delayNanoseconds: 0,
                path: requestPath,
                headers: [:]
            )
            shouldRecordRequest = false
        } else if requestPath == "/api/tags" {
            // Tests that do not enqueue a local Ollama fixture get a stable,
            // empty local catalog. Exact-path fixtures above still exercise and
            // record real local discovery behavior when a test opts into it.
            response = Response(
                status: 200,
                body: Data(#"{"models":[]}"#.utf8),
                delayNanoseconds: 0,
                path: requestPath,
                headers: [:]
            )
            shouldRecordRequest = false
        } else if let index = Self.queuedResponses.firstIndex(where: { $0.path == nil }) {
            response = Self.queuedResponses.remove(at: index)
        } else {
            response = Response(
                status: 500,
                body: Data(#"{"error":"missing fixture"}"#.utf8),
                delayNanoseconds: 0,
                path: nil,
                headers: [:]
            )
        }
        if shouldRecordRequest {
            Self.requests.append(
                GatewayUpstreamRequest(
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    path: request.url?.path ?? "",
                    query: request.url?.query,
                    body: Self.bodyString(from: request),
                    xApiKey: request.value(forHTTPHeaderField: "x-api-key"),
                    anthropicVersion: request.value(forHTTPHeaderField: "anthropic-version"),
                    anthropicBeta: request.value(forHTTPHeaderField: "anthropic-beta"),
                    anthropicBillingHeader: request.value(forHTTPHeaderField: "x-anthropic-billing-header"),
                    userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                    xApp: request.value(forHTTPHeaderField: "x-app"),
                    directBrowserAccess: request.value(forHTTPHeaderField: "anthropic-dangerous-direct-browser-access"),
                    timeoutInterval: request.timeoutInterval
                )
            )
        }
        Self.lock.unlock()

        if response.delayNanoseconds > 0 {
            let delay = TimeInterval(response.delayNanoseconds) / 1_000_000_000
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [self] in
                self.send(response)
            }
            return
        }
        send(response)
    }

    private func send(_ response: Response) {
        var headerFields = response.headers
        if headerFields["Content-Type"] == nil && headerFields["content-type"] == nil {
            headerFields["Content-Type"] = "application/json"
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyString(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static let defaultAnthropicModelCatalogBody = """
    {
      "data": [
        {"id": "claude-sonnet-4-6", "display_name": "Claude Sonnet 4.6", "type": "model"},
        {"id": "claude-opus-4-8", "display_name": "Claude Opus 4.8", "type": "model"},
        {"id": "claude-opus-4-7", "display_name": "Claude Opus 4.7", "type": "model"},
        {"id": "claude-haiku-4-5", "display_name": "Claude Haiku 4.5", "type": "model"},
        {"id": "anth-shared-pro", "display_name": "Shared Claude Pro", "type": "model"},
        {"id": "anth-shared-base", "display_name": "Shared Claude Base", "type": "model"}
      ],
      "has_more": false
    }
    """
}
