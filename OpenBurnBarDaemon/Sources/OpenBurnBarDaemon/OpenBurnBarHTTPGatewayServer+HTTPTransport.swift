import OpenBurnBarEngine
import OpenBurnBarKernel
import CryptoKit
import Foundation
import Network

// HTTP wire layer: response/stream serialization, request-head parsing, auth-token extraction, CORS, and JSON body builders.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

    func writeResponse(on connection: NWConnection, response: GatewayHTTPResponse) async {
        let statusText: String
        switch response.status {
        case 204: statusText = "No Content"
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 429: statusText = "Too Many Requests"
        case 500: statusText = "Internal Server Error"
        case 502: statusText = "Bad Gateway"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Unknown"
        }

        var head = "HTTP/1.1 \(response.status) \(statusText)\r\n"
        for (key, value) in response.headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        guard var data = head.data(using: .utf8) else {
            connection.cancel()
            return
        }
        data.append(response.body)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func writeResponse(on connection: NWConnection, status: Int, headers: [String: String], body: String) async {
        await writeResponse(
            on: connection,
            response: GatewayHTTPResponse(
                status: status,
                headers: headers,
                body: Data(body.utf8)
            )
        )
    }

    /// Relay an upstream SSE stream to the client chunk-by-chunk (A1).
    ///
    /// `openStream` performs the upstream request and resolves once response
    /// headers arrive. If it throws before any client bytes are written (e.g.
    /// an upstream 429), the error propagates so the caller can still fail
    /// over to another account. Once the head is written we are committed to
    /// this connection: a mid-stream failure is surfaced as a terminal SSE
    /// error event rather than a fail-over, because the client has already
    /// begun consuming the response.
    func relayProxyStream(
        on connection: NWConnection,
        corsHeaders: [String: String],
        usageFormat: GatewayStreamUsageFormat,
        route: BurnBarProviderRoute,
        idempotencyKey: String,
        parentRequestID: String? = nil,
        executionSource: UsageExecutionSource = .unknown,
        openStream: () async throws -> BurnBarProviderProxyStream
    ) async throws -> GatewayStreamRelayResult {
        let stream = try await openStream()

        await writeStreamingHead(
            on: connection,
            status: stream.statusCode,
            contentType: stream.contentType,
            corsHeaders: corsHeaders
        )

        let accumulator = GatewayStreamingUsageAccumulator(format: usageFormat)
        var interrupted = false
        do {
            for try await chunk in stream.chunks {
                accumulator.consume(chunk)
                await sendRaw(chunk, on: connection)
            }
        } catch {
            interrupted = true
            // Bytes already flowed to the client; we cannot fail over now.
            // Emit a terminal SSE error event so the client sees a clean end.
            logger.warning(
                "gateway_stream_interrupted",
                metadata: ["provider": route.providerID, "error": "\(error)"]
            )
            let errorEvent = "event: error\ndata: {\"error\":{\"message\":\"upstream stream interrupted\"}}\n\n"
            await sendRaw(Data(errorEvent.utf8), on: connection)
        }

        let usage = accumulator.finalize()
        await recordUsageIfAvailable(
            usage,
            route: route,
            idempotencyKey: idempotencyKey,
            parentRequestID: parentRequestID,
            executionSource: executionSource
        )
        return GatewayStreamRelayResult(
            outcome: .streamed,
            usage: usage,
            headers: stream.headers,
            interrupted: interrupted,
            httpStatus: stream.statusCode
        )
    }

    func writeStreamingHead(
        on connection: NWConnection,
        status: Int,
        contentType: String,
        corsHeaders: [String: String]
    ) async {
        var head = "HTTP/1.1 \(status) \(Self.statusText(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "X-Accel-Buffering: no\r\n"
        for (key, value) in corsHeaders {
            head += "\(key): \(value)\r\n"
        }
        // No Content-Length: the body length is unknown up front. We signal
        // end-of-response by closing the connection (Connection: close), which
        // is the standard HTTP/1.1 way to stream a body of indeterminate size.
        head += "Connection: close\r\n"
        head += "\r\n"
        await sendRaw(Data(head.utf8), on: connection)
    }

    func sendRaw(_ data: Data, on connection: NWConnection) async {
        guard !data.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    /// Append one extra SSE `data:` frame on an already-open streamed connection,
    /// after the synthesis stream's `[DONE]`. Clients that don't understand the
    /// frame ignore it because it carries no OpenAI `choices` delta.
    func emitFusionSpendFrame(_ session: FusionSessionSpend, on connection: NWConnection) async {
        guard let payload = try? JSONEncoder().encode([FusionSessionSpend.wireKey: session]),
              let text = String(data: payload, encoding: .utf8) else { return }
        await sendRaw(Data("data: \(text)\n\n".utf8), on: connection)
    }

    static func statusText(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    func parseRequestHead(_ headerData: Data) throws -> ParsedRequestHead {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPRequestReadError.invalidRequest
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPRequestReadError.invalidRequest
        }

        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2 else {
            throw HTTPRequestReadError.invalidRequest
        }

        let method = String(requestLineParts[0]).uppercased()
        let rawPath = String(requestLineParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.isEmpty == false {
            guard let separator = line.firstIndex(of: ":") else {
                throw HTTPRequestReadError.invalidRequest
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        if let transferEncoding = headers["transfer-encoding"], transferEncoding.lowercased().contains("chunked") {
            throw HTTPRequestReadError.invalidRequest
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsedLength = Int(rawContentLength), parsedLength >= 0 else {
                throw HTTPRequestReadError.invalidRequest
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }

        return ParsedRequestHead(method: method, path: path, headers: headers, contentLength: contentLength)
    }

    func bearerToken(from authorizationHeader: String?) -> String? {
        guard let authorizationHeader else { return nil }
        let parts = authorizationHeader.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else {
            return nil
        }
        let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Gateway auth token presented by routed CLI clients. Droid's Anthropic BYOK
    /// adapter sends `x-api-key`; OpenAI-style clients use `Authorization: Bearer`.
    func clientAuthToken(from request: HTTPRequest) -> String? {
        if let bearer = bearerToken(from: request.headers["authorization"]) {
            return bearer
        }
        if let apiKey = request.headers["x-api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return apiKey
        }
        return nil
    }

    func rateLimitClientKey(for request: HTTPRequest) -> String {
        if let token = clientAuthToken(from: request) {
            return "token:\(Self.stableDigest(token))"
        }
        return "anonymous"
    }

    /// remediation(loopback-c): shared 429 writer so the general limiter and the
    /// stricter tokenless-loopback ceiling emit byte-identical throttle responses
    /// (CORS headers + `Retry-After`), then close the connection.
    func writeRateLimitResponse(
        on connection: NWConnection,
        retryAfter: Double,
        request: HTTPRequest
    ) async {
        var rateLimitHeaders: [String: String] = [
            "Content-Type": "application/json",
            "Retry-After": "\(Int(ceil(retryAfter)))"
        ]
        for (key, value) in corsHeaders(for: request) {
            rateLimitHeaders[key] = value
        }
        await writeResponse(on: connection, status: 429, headers: rateLimitHeaders, body: errorBody("rate limit exceeded"))
        connection.cancel()
    }

    static func stableDigest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func corsHeaders(for request: HTTPRequest) -> [String: String] {
        guard let origin = request.headers["origin"], isAllowedCORSOrigin(origin) else {
            return [:]
        }
        return [
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, x-api-key, X-OpenBurnBar-Purpose",
            "Vary": "Origin"
        ]
    }

    func isAllowedCORSOrigin(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    func errorBody(_ message: String) -> String {
        encodeBody(GatewayErrorResponse(error: message))
    }

    func jsonResponse(status: Int, body: String) -> GatewayHTTPResponse {
        GatewayHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }

    func encodeBody<Value: Encodable>(_ value: Value) -> String {
        do {
            let payload = try JSONEncoder().encode(value)
            return String(decoding: payload, as: UTF8.self)
        } catch {
            return "{\"error\":\"internal error\"}"
        }
    }
}
