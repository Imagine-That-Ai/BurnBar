import OpenBurnBarEngine
import CryptoKit
import Foundation
import Network

// Connection lifecycle: the NWConnection read loop, request framing, and top-level dispatch (auth/rate-limit/CORS gate -> route).
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

    func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        readRequest(on: connection)
    }

    func readRequest(on connection: NWConnection) {
        var buffer = Data()
        buffer.reserveCapacity(4096)

        readLoop(on: connection, buffer: buffer, headerRange: nil, expectedBodyLength: 0)
    }

    func readLoop(
        on connection: NWConnection,
        buffer: Data,
        headerRange: Range<Data.Index>?,
        expectedBodyLength: Int
    ) {
        let chunkSize = 4096
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.error("gateway_connection_read_error", metadata: ["error": "\(error)"])
                connection.cancel()
                return
            }

            var mutableBuffer = buffer
            if let data {
                mutableBuffer.append(data)
            }

            if isComplete {
                // Client closed connection — process whatever we have
                Task { await self.processBuffer(mutableBuffer, headerRange: headerRange, connection: connection) }
                return
            }

            Task { await self.processIncomingData(mutableBuffer, connection: connection, headerRange: headerRange, expectedBodyLength: expectedBodyLength) }
        }
    }

    func processIncomingData(
        _ buffer: Data,
        connection: NWConnection,
        headerRange: Range<Data.Index>?,
        expectedBodyLength: Int
    ) async {
        let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        // Check for header terminator
        var currentHeaderRange = headerRange
        if currentHeaderRange == nil {
            if buffer.count > Self.maxHeaderBytes {
                await writeResponse(
                    on: connection,
                    status: 400,
                    headers: ["Content-Type": "application/json"],
                    body: errorBody("bad request")
                )
                connection.cancel()
                return
            }
            if let range = buffer.range(of: headerTerminator) {
                currentHeaderRange = range
            }
        }

        guard let foundHeaderRange = currentHeaderRange else {
            // Still waiting for headers
            readLoop(on: connection, buffer: buffer, headerRange: nil, expectedBodyLength: 0)
            return
        }

        // Parse headers to get content-length
        let headerData = buffer.prefix(upTo: foundHeaderRange.lowerBound)
        guard let parsed = try? parseRequestHead(headerData) else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        if parsed.contentLength > Self.maxBodyBytes {
            await writeResponse(on: connection, status: 413, headers: ["Content-Type": "application/json"], body: errorBody("request body exceeds \(Self.maxBodyBytes) bytes"))
            connection.cancel()
            return
        }

        let availableBody = buffer.count - foundHeaderRange.upperBound
        if availableBody >= parsed.contentLength {
            await processBuffer(buffer, headerRange: foundHeaderRange, connection: connection)
        } else {
            readLoop(on: connection, buffer: buffer, headerRange: foundHeaderRange, expectedBodyLength: parsed.contentLength)
        }
    }

    func processBuffer(_ buffer: Data, headerRange: Range<Data.Index>?, connection: NWConnection) async {
        let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

        guard let foundHeaderRange = headerRange ?? buffer.range(of: headerTerminator) else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        let headerData = buffer.prefix(upTo: foundHeaderRange.lowerBound)
        guard let parsed = try? parseRequestHead(headerData) else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        if parsed.contentLength > Self.maxBodyBytes {
            await writeResponse(on: connection, status: 413, headers: ["Content-Type": "application/json"], body: errorBody("request body exceeds \(Self.maxBodyBytes) bytes"))
            connection.cancel()
            return
        }

        let bodyData = buffer.suffix(from: foundHeaderRange.upperBound).prefix(parsed.contentLength)
        let body: String?
        if parsed.contentLength == 0 {
            body = nil
        } else if let decoded = String(data: bodyData, encoding: .utf8) {
            body = decoded
        } else {
            await writeResponse(on: connection, status: 400, headers: ["Content-Type": "application/json"], body: errorBody("bad request"))
            connection.cancel()
            return
        }

        let request = HTTPRequest(method: parsed.method, path: parsed.path, headers: parsed.headers, body: body)
        await handleRequest(request, connection: connection)
    }

    func handleRequest(_ request: HTTPRequest, connection: NWConnection) async {
        if request.method == "OPTIONS" {
            await writeResponse(on: connection, status: 204, headers: corsHeaders(for: request), body: "")
            connection.cancel()
            return
        }

        let staticToken = configuration.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let purpose = GatewayPurpose(header: request.headers[GatewayPurpose.headerName]) {
            // Memory Pro: a memory-purpose request may present the static token
            // or a scoped token for that purpose, and may only hit the two proxy
            // paths. Everything else is refused before routing.
            let presented = clientAuthToken(from: request)
            var authorized = false
            if let presented, let staticToken, constantTimeTokensEqual(presented, staticToken) {
                authorized = true
            } else if let presented, let memoryEgress {
                authorized = await memoryEgress.validateToken(presented, purpose: purpose)
            }
            guard authorized, BurnBarMemoryEgressEnforcer.allowedPaths.contains(request.path) else {
                await writeResponse(on: connection, status: 401, headers: ["Content-Type": "application/json"], body: errorBody("unauthorized"))
                connection.cancel()
                return
            }
        } else if let requiredToken = staticToken {
            let presented = clientAuthToken(from: request)
            guard let presented, constantTimeTokensEqual(presented, requiredToken) else {
                await writeResponse(on: connection, status: 401, headers: ["Content-Type": "application/json"], body: errorBody("unauthorized"))
                connection.cancel()
                return
            }
        }

        // Rate limiting check
        if let rateLimiter {
            let clientKey = rateLimitClientKey(for: request)
            let limitResult = await rateLimiter.checkLimit(clientKey: clientKey)
            if case .throttled(let retryAfter) = limitResult {
                logger.warning(
                    "gateway_rate_limit_exceeded",
                    metadata: [
                        "client_key": clientKey,
                        "retry_after": "\(retryAfter)"
                    ]
                )
                await writeRateLimitResponse(on: connection, retryAfter: retryAfter, request: request)
                return
            }
        }

        // remediation(loopback-c): apply the stricter tokenless-loopback ceiling
        // on top of (and after) any general limit. This limiter is non-nil only
        // while the unauthenticated-loopback escape hatch is live, so it bounds
        // an abusive same-host process from spending unlimited provider credits
        // without touching the authenticated path.
        if let unauthenticatedLoopbackRateLimiter {
            // remediation(loopback-c): collapse ALL callers into one constant bucket
            // for this limiter. `rateLimitClientKey` derives a per-credential bucket
            // from a presented bearer token, but in unauthenticated-loopback mode
            // tokens are NOT validated — so keying on them would let a local caller
            // mint fresh buckets with arbitrary tokens and evade the ceiling. A single
            // shared bucket makes the tokenless provider-credit-spend cap actually bind.
            let clientKey = "unauthenticated-loopback"
            let limitResult = await unauthenticatedLoopbackRateLimiter.checkLimit(clientKey: clientKey)
            if case .throttled(let retryAfter) = limitResult {
                logger.warning(
                    "gateway_unauthenticated_loopback_rate_limit_exceeded",
                    metadata: [
                        "client_key": clientKey,
                        "retry_after": "\(retryAfter)",
                        "reason": "tokenless-loopback escape hatch ceiling bounds provider-credit spend"
                    ]
                )
                await writeRateLimitResponse(on: connection, retryAfter: retryAfter, request: request)
                return
            }
        }

        let cors = corsHeaders(for: request)
        let outcome = await routeRequest(request, connection: connection, corsHeaders: cors)
        switch outcome {
        case .buffered(let routedResponse):
            var headers = routedResponse.headers
            for (key, value) in cors {
                headers[key] = value
            }
            await writeResponse(on: connection, response: routedResponse.withHeaders(headers))
            connection.cancel()
        case .streamed:
            // The streaming relay has already written the full response
            // (head + chunks) directly to the connection; just close it.
            connection.cancel()
        }
    }

    func routeRequest(
        _ request: HTTPRequest,
        connection: NWConnection,
        corsHeaders: [String: String]
    ) async -> GatewayRouteOutcome {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .buffered(jsonResponse(status: 200, body: encodeBody(HealthResponse(ok: true, version: BurnBarDaemonVersion.current))))

        case ("GET", "/metrics"):
            return .buffered(handleMetrics())

        case ("GET", "/v1/models"):
            return .buffered(await handleModels(headers: request.headers))

        case ("GET", "/v1/models/catalog"):
            return .buffered(await handleModels(includeUnadvertised: true, headers: request.headers))

        case ("POST", "/v1/chat/completions"):
            return await handleChatCompletions(
                body: request.body,
                headers: request.headers,
                connection: connection,
                corsHeaders: corsHeaders
            )

        case ("POST", "/v1/embeddings"):
            return await handleEmbeddings(body: request.body, headers: request.headers)
        case ("POST", "/v1/responses"):
            return await handleResponses(body: request.body, headers: request.headers)

        case ("POST", "/v1/messages"):
            return await handleAnthropicMessages(
                body: request.body,
                headers: request.headers,
                connection: connection,
                corsHeaders: corsHeaders
            )

        default:
            return .buffered(jsonResponse(status: 404, body: errorBody("not found")))
        }
    }

    func handleMetrics() -> GatewayHTTPResponse {
        let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: configuration.isEnabled)
        return jsonResponse(status: 200, body: encodeBody(snapshot))
    }
}
