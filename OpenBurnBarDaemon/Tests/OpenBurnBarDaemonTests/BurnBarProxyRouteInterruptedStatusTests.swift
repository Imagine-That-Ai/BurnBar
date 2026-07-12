import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

/// Pins the first-class `interrupted` proxy-route status: wire name, semantic
/// helpers, persistence round-trip through the route-log store, and the
/// cross-platform contract fixture shared with the Linux desktop port
/// (apps/linux-desktop/src/tauriBridge.test.ts reads the same JSON).
final class BurnBarProxyRouteInterruptedStatusTests: XCTestCase {

    // MARK: - Wire contract

    func testInterruptedWireNameIsStable() {
        // BurnBarRPC canon wire name — renaming requires regenerating the
        // canon via tools/ipc/generate-burnbarrpc-canon.mjs and updating the
        // Linux desktop union in apps/linux-desktop/src/tauriBridge.ts.
        XCTAssertEqual(BurnBarProxyRouteFinalStatus.interrupted.rawValue, "interrupted")
        XCTAssertEqual(BurnBarProxyRouteFinalStatus(rawValue: "interrupted"), .interrupted)
    }

    func testFinalStatusWireNamesAreExhaustivelyPinned() {
        // Adding a case forces this dictionary (and every switch over the
        // enum) to be revisited instead of silently falling through.
        let expected: [BurnBarProxyRouteFinalStatus: String] = [
            .exact: "exact",
            .sameModelFailover: "same_model_failover",
            .crossVendorFallback: "cross_vendor_fallback",
            .failed: "failed",
            .rejected: "rejected",
            .interrupted: "interrupted"
        ]
        XCTAssertEqual(Set(BurnBarProxyRouteFinalStatus.allCases), Set(expected.keys))
        for (status, wireName) in expected {
            XCTAssertEqual(status.rawValue, wireName)
        }
    }

    // MARK: - Semantics

    func testStreamRelayOutcomeMapsInterruptionToInterrupted() {
        XCTAssertEqual(BurnBarProxyRouteFinalStatus.streamRelayOutcome(interrupted: true), .interrupted)
        XCTAssertEqual(BurnBarProxyRouteFinalStatus.streamRelayOutcome(interrupted: false), .exact)
    }

    func testInterruptedSemanticsAreDistinctFromFailure() {
        for status in BurnBarProxyRouteFinalStatus.allCases {
            XCTAssertEqual(
                status.isInterruption,
                status == .interrupted,
                "\(status) isInterruption mismatch"
            )
            XCTAssertEqual(
                status.countsAgainstRouteHealth,
                status == .failed,
                "\(status) countsAgainstRouteHealth mismatch — interruptions and rejections must not strike route health"
            )
            XCTAssertEqual(
                status.mayCarryPartialUsage,
                status == .interrupted,
                "\(status) mayCarryPartialUsage mismatch"
            )
        }
        XCTAssertFalse(BurnBarProxyRouteFinalStatus.interrupted.countsAgainstRouteHealth)
        XCTAssertTrue(BurnBarProxyRouteFinalStatus.failed.countsAgainstRouteHealth)
    }

    // MARK: - Persistence round-trip (producer → persisted → rendered input)

    func testRouteLogStorePersistsInterruptedEntryLossly() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-route-interrupted-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = BurnBarProxyRouteLogStore(
            fileURL: tempDirectory.appendingPathComponent("proxy-route-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "proxy-route-interrupted-tests")
        )
        let entry = BurnBarProxyRouteLogEntry(
            occurredAt: Date(),
            requestPath: "/v1/chat/completions",
            endpoint: "Chat Completions",
            clientModelSlug: "openburnbar/primary",
            finalStatus: .interrupted,
            streamed: true,
            streamInterrupted: true,
            httpStatus: 200,
            usage: BurnBarProxyRouteUsage(inputTokens: 412, outputTokens: 96, cost: 0.0123)
        )
        await store.append(entry)

        // Fresh store instance forces a decode from disk, not the cache.
        let reloaded = BurnBarProxyRouteLogStore(
            fileURL: tempDirectory.appendingPathComponent("proxy-route-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "proxy-route-interrupted-tests")
        )
        let persisted = try await reloaded.recent(limit: 1)
        let decoded = try XCTUnwrap(persisted.first)
        XCTAssertEqual(decoded.finalStatus, .interrupted)
        XCTAssertTrue(decoded.streamInterrupted)
        XCTAssertEqual(decoded.usage?.inputTokens, 412)
        XCTAssertEqual(decoded.usage?.outputTokens, 96)
    }

    // MARK: - Producer → persisted → aggregated (end-to-end through the gateway)

    /// Full-pipeline proof on macOS: a verbatim SSE relay whose upstream drops
    /// mid-stream (after the response head is committed) must end the client
    /// stream with a terminal SSE error event, log first-class `interrupted`
    /// (never `failed`), and still record the partial usage exactly once.
    /// Uses a real loopback upstream because the verbatim relay path streams
    /// through `BurnBarProxyStreaming.streamingSession`, which URLProtocol
    /// stubs cannot intercept.
    func testGatewayStreamInterruptionRecordsFirstClassInterruptedStatusAndPartialUsage() async throws {
        let upstream = try InterruptedStreamMockUpstream()
        defer { upstream.stop() }

        let harness = try GatewayHarness()
        try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "http://127.0.0.1:\(upstream.port)/v1",
                preferredModelIDs: ["glm-5-turbo"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-key"
        )
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(harness.port)/v1/chat/completions"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            #"{"model":"glm-5-turbo","stream":true,"messages":[{"role":"user","content":"hello"}]}"#.utf8
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        // The head was already committed, so the client sees a 200 stream that
        // ends with a terminal SSE error event instead of [DONE].
        XCTAssertEqual(httpResponse.statusCode, 200)
        let bodyText = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(bodyText.contains(#""content":"partial ""#), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("event: error"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("upstream stream interrupted"), "body was: \(bodyText)")
        XCTAssertFalse(bodyText.contains("data: [DONE]"), "body was: \(bodyText)")

        // Producer → persisted: the route log records first-class `interrupted`
        // (not `failed`), flags the stream, and keeps the partial usage.
        let entries = try await harness.proxyRouteLogStore.recent(limit: 5)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.finalStatus, .interrupted)
        XCTAssertTrue(entry.streamed)
        XCTAssertTrue(entry.streamInterrupted)
        XCTAssertEqual(entry.attempts.count, 1)
        XCTAssertEqual(entry.attempts.first?.status, .interrupted)
        let usage = try XCTUnwrap(entry.usage, "interrupted streams must keep their partial usage")
        XCTAssertEqual(usage.inputTokens, 412)
        XCTAssertEqual(usage.outputTokens, 96)

        // Usage/cost aggregation: partial spend from the interrupted stream
        // still lands in the ledger exactly once.
        let recorded = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.inputTokens, 412)
        XCTAssertEqual(recorded.first?.outputTokens, 96)

        // Semantics: interrupted is distinct from failed/rejected — retryable,
        // partial-usage-carrying, and never a route-health strike.
        XCTAssertTrue(entry.finalStatus.isInterruption)
        XCTAssertFalse(entry.finalStatus.countsAgainstRouteHealth)
        XCTAssertTrue(entry.finalStatus.mayCarryPartialUsage)
    }

    // MARK: - Cross-platform contract fixture

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OpenBurnBarDaemonTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OpenBurnBarDaemon
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("docs/linux-port/fixtures/proxy-route-log-interrupted.fixture.json")
    }

    func testCrossPlatformInterruptedFixtureDecodesWithDaemonWireCoding() throws {
        let data = try Data(contentsOf: fixtureURL)
        // Same coding the daemon uses for the RPC payload and the on-disk
        // store: default Foundation JSONDecoder.
        let response = try JSONDecoder().decode(BurnBarProxyRouteLogRecentResponse.self, from: data)
        let entry = try XCTUnwrap(response.entries.first)
        XCTAssertEqual(entry.finalStatus, .interrupted)
        XCTAssertTrue(entry.streamed)
        XCTAssertTrue(entry.streamInterrupted)
        XCTAssertEqual(entry.attempts.first?.status, .interrupted)
        XCTAssertEqual(entry.usage?.inputTokens, 412)
        XCTAssertEqual(entry.usage?.outputTokens, 96)
        XCTAssertEqual(entry.failureMessage, "upstream stream interrupted")

        // Re-encode → re-decode: the wire name survives a Swift round trip.
        let reencoded = try JSONEncoder().encode(response)
        let roundTripped = try JSONDecoder().decode(BurnBarProxyRouteLogRecentResponse.self, from: reencoded)
        XCTAssertEqual(roundTripped.entries.first?.finalStatus, .interrupted)
        XCTAssertTrue(
            String(decoding: reencoded, as: UTF8.self).contains("\"interrupted\""),
            "wire name must serialize as the canon string"
        )
    }
}

/// Minimal loopback upstream: serves the OpenAI model catalog normally, and
/// answers `POST /v1/chat/completions` with two SSE chunks (the second carries
/// usage) before dropping the connection with an RST *and* an over-long
/// `Content-Length`, so the gateway's streaming URLSession reliably observes a
/// mid-stream transport error rather than a clean EOF — the canonical
/// `interrupted` producer path. BSD sockets on purpose: the gateway's verbatim
/// relay uses the real network stack, which URLProtocol stubs cannot reach.
private final class InterruptedStreamMockUpstream: @unchecked Sendable {
    private(set) var port: Int = 0
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "interrupted-mock-upstream-accept")

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var reuse: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(socketFD, rebound, &boundLength)
            }
        }
        guard nameResult == 0, listen(socketFD, SOMAXCONN) == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
        listenFD = socketFD

        acceptQueue.async { [weak self] in
            self?.acceptLoop(socketFD: socketFD)
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop(socketFD: Int32) {
        while true {
            var address = sockaddr()
            var addressLength = socklen_t(MemoryLayout<sockaddr>.stride)
            let clientFD = accept(socketFD, &address, &addressLength)
            guard clientFD >= 0 else { return }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        guard let requestHead = readRequestHead(clientFD: clientFD) else { return }

        if requestHead.contains("/chat/completions") {
            let chunks = "data: {\"id\":\"chatcmpl_interrupt\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"partial \"},\"finish_reason\":null}]}\n\n"
                + "data: {\"id\":\"chatcmpl_interrupt\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"answer\"},\"finish_reason\":null}],\"usage\":{\"prompt_tokens\":412,\"completion_tokens\":96,\"total_tokens\":508}}\n\n"
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Content-Length: \(chunks.utf8.count + 4_096)\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            sendAll(Data((head + chunks).utf8), to: clientFD)
            // Give the gateway time to drain the sent chunks off the loopback
            // socket before the RST lands — an abortive close can discard
            // undelivered receive-buffer data, and this test needs the partial
            // chunks (and their usage frame) to reach the relay first.
            usleep(500_000)
            // Abortive close (RST) so the gateway's URLSession surfaces a
            // transport error instead of a clean end-of-body.
            var resetOnClose = linger(l_onoff: 1, l_linger: 0)
            _ = withUnsafePointer(to: &resetOnClose) { pointer in
                setsockopt(clientFD, SOL_SOCKET, SO_LINGER, pointer, socklen_t(MemoryLayout<linger>.size))
            }
            return
        }

        // Model catalog (and anything else): a well-formed JSON response.
        let body = #"{"object":"list","data":[{"id":"glm-5-turbo","display_name":"glm-5-turbo"}]}"#
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        sendAll(Data((head + body).utf8), to: clientFD)
    }

    private func readRequestHead(clientFD: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var received = Data()
        while true {
            let count = recv(clientFD, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received.append(contentsOf: buffer.prefix(count))
            guard let text = String(data: received, encoding: .utf8) else { continue }
            if let headEnd = text.range(of: "\r\n\r\n") {
                // Drain the body when a Content-Length is present so the
                // client is not mid-send when we respond.
                let head = String(text[..<headEnd.lowerBound])
                let bodyBytesSoFar = received.count - text.distance(from: text.startIndex, to: headEnd.upperBound)
                if let lengthLine = head
                    .components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let expected = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)),
                   bodyBytesSoFar < expected {
                    continue
                }
                return text
            }
        }
        return received.isEmpty ? nil : String(data: received, encoding: .utf8)
    }

    private func sendAll(_ data: Data, to clientFD: Int32) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let sent = send(clientFD, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
}
