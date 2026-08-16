import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// VAL-RPC-016 regression tests (M1 repair, rpc-error-details-repair):
/// every error envelope carries the contract-required `details` field with
/// non-empty, machine-actionable, per-class contents — verified over the
/// socket (transport level), not just via Codable unit tests.
final class BurnBarFleetRPCErrorDetailsTests: BurnBarFleetRPCTestCase {
    // MARK: - details presence on every failure class

    func testDetails_presentOnEveryFailureClass() async throws {
        let configuration = makeConfiguration(name: "details-presence")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let requests: [DetailsRequest] = [
            DetailsRequest(
                name: "unknown-method",
                request: "{\"id\":\"d-1\",\"method\":\"daemon.fleet.nonexistent\"}",
                code: -32601
            ),
            DetailsRequest(name: "malformed-json", request: "{not json", code: -32700),
            DetailsRequest(name: "missing-id", request: "{\"method\":\"daemon.health\"}", code: -32600),
            DetailsRequest(name: "wrong-id", request: "{\"id\":123,\"method\":\"daemon.health\"}", code: -32600),
            DetailsRequest(
                name: "wrong-params",
                request: "{\"id\":\"d-3\",\"method\":\"daemon.fleet.orchestrator.set\",\"params\":\"x\"}",
                code: -32602
            ),
            DetailsRequest(
                name: "version-mismatch",
                request: "{\"id\":\"d-4\",\"method\":\"daemon.health\",\"protocolVersion\":2}",
                code: -32001
            )
        ]
        for entry in requests {
            let response = try rawRequest(entry.request, socketPath: socketPath)
            let envelope = try decodeErrorEnvelope(response)
            XCTAssertEqual(envelope.error?.code, entry.code, "code mismatch for \(entry.name)")
            XCTAssertFalse(
                envelope.error?.details.isEmpty == true,
                "details required for \(entry.name)"
            )
        }

        // Oversized frame: details carries the byte counts (cap + received,
        // excluding the trailing newline delimiter).
        let oversizePayload = try makePaddedRequest(id: "d-2", payloadBytes: 65_537)
        let oversize = try rawRequest(oversizePayload, socketPath: socketPath)
        let oversizeEnvelope = try decodeErrorEnvelope(oversize)
        XCTAssertEqual(oversizeEnvelope.error?.code, -32002)
        XCTAssertFalse(
            oversizeEnvelope.error?.details.isEmpty == true,
            "details required for oversized-frame"
        )

        // The daemon remains usable after every failure class.
        let health = try rawRequest("{\"id\":\"d-ok\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(health).error)
    }

    // MARK: - per-class details contents

    func testDetails_unknownMethodNamesMethod() async throws {
        let configuration = makeConfiguration(name: "details-method")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest(
            "{\"id\":\"c-1\",\"method\":\"daemon.fleet.nonexistent\"}",
            socketPath: socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.error?.code, -32601)
        XCTAssertTrue(
            envelope.error?.details.contains("daemon.fleet.nonexistent") == true,
            "unknown-method details must name the method, got: \(envelope.error?.details ?? "nil")"
        )
    }

    func testDetails_malformedJSONStatesExpectedShape() async throws {
        let configuration = makeConfiguration(name: "details-parse")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest("{not json", socketPath: socketPath)
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.error?.code, -32700)
        XCTAssertTrue(
            envelope.error?.details.contains("json_object") == true,
            "parse-error details must state the expected shape, got: \(envelope.error?.details ?? "nil")"
        )
    }

    func testDetails_oversizedFrameCarriesByteCounts() async throws {
        let configuration = makeConfiguration(name: "details-frame")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let oversizePayload = try makePaddedRequest(id: "c-2", payloadBytes: 65_537)
        let response = try rawRequest(oversizePayload, socketPath: socketPath)
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.error?.code, -32002)
        XCTAssertTrue(
            envelope.error?.details.contains("max_bytes=65536") == true,
            "frame-too-large details must carry the cap, got: \(envelope.error?.details ?? "nil")"
        )
        XCTAssertTrue(
            envelope.error?.details.contains("received_bytes=65537") == true,
            "frame-too-large details must carry the received byte count, got: \(envelope.error?.details ?? "nil")"
        )
    }

    func testDetails_missingAndWrongIDStateExpectedEnvelope() async throws {
        let configuration = makeConfiguration(name: "details-id")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let missingID = try rawRequest("{\"method\":\"daemon.health\"}", socketPath: socketPath)
        let missingIDEnvelope = try decodeErrorEnvelope(missingID)
        XCTAssertEqual(missingIDEnvelope.error?.code, -32600)
        XCTAssertTrue(
            missingIDEnvelope.error?.details.contains("expected_envelope") == true,
            "missing-id details must state the expected envelope shape, got: "
                + (missingIDEnvelope.error?.details ?? "nil")
        )

        let wrongID = try rawRequest("{\"id\":123,\"method\":\"daemon.health\"}", socketPath: socketPath)
        let wrongIDEnvelope = try decodeErrorEnvelope(wrongID)
        XCTAssertEqual(wrongIDEnvelope.error?.code, -32600)
        XCTAssertTrue(
            wrongIDEnvelope.error?.details.contains("expected_envelope") == true,
            "wrong-id details must state the expected envelope shape, got: \(wrongIDEnvelope.error?.details ?? "nil")"
        )
    }

    func testDetails_wrongParamsNamesExpectedAndReceivedTypes() async throws {
        let configuration = makeConfiguration(name: "details-params")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest(
            "{\"id\":\"c-3\",\"method\":\"daemon.fleet.orchestrator.set\",\"params\":\"x\"}",
            socketPath: socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.error?.code, -32602)
        XCTAssertTrue(
            envelope.error?.details.contains("expected_params=object") == true,
            "invalid-params details must name the expected params type, got: \(envelope.error?.details ?? "nil")"
        )
        XCTAssertTrue(
            envelope.error?.details.contains("received=string") == true,
            "invalid-params details must name the received type, got: \(envelope.error?.details ?? "nil")"
        )
    }

    func testDetails_versionMismatchCarriesDeclaredAndSupported() async throws {
        let configuration = makeConfiguration(name: "details-version")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest(
            "{\"id\":\"c-4\",\"method\":\"daemon.health\",\"protocolVersion\":2}",
            socketPath: socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.error?.code, -32001)
        XCTAssertTrue(
            envelope.error?.details.contains("declared_version=2") == true,
            "version-mismatch details must carry the declared version, got: \(envelope.error?.details ?? "nil")"
        )
        XCTAssertTrue(
            envelope.error?.details.contains("supported_versions=[1]") == true,
            "version-mismatch details must carry the supported versions, got: \(envelope.error?.details ?? "nil")"
        )
    }

    func testHandlerSideDecodingError_mapsToInternalErrorNotInvalidParams() async throws {
        let configuration = makeConfiguration(name: "handler-decode")
        let socketPath = configuration.socketPath
        let configURL = tempRoots.appendingPathComponent("malformed-config.json")
        try Data("{ malformed".utf8).write(to: configURL)
        let configStore = BurnBarConfigStore(fileURL: configURL)
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(
            configuration: configuration,
            configStore: configStore,
            fleetService: fleetService
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest(
            "{\"id\":\"handler-decode\",\"method\":\"daemon.config.get\"}",
            socketPath: socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.error?.code, -32603)
        XCTAssertTrue(
            envelope.error?.details.contains("error=") == true,
            "handler-side decode details must identify a daemon error"
        )
    }

    /// Builds `{"id":"<id>","method":"daemon.health","pad":"<spaces>"}` padded
    /// with spaces inside the pad string so the payload is exactly
    /// `payloadBytes` raw UTF-8 bytes.
    private func makePaddedRequest(id: String, payloadBytes: Int) throws -> String {
        let prefix = "{\"id\":\"\(id)\",\"method\":\"daemon.health\",\"pad\":\""
        let suffix = "\"}"
        let padLength = payloadBytes - prefix.count - suffix.count
        guard padLength >= 0 else {
            throw XCTSkip("payload target too small for the fixed prefix/suffix")
        }
        return prefix + String(repeating: " ", count: padLength) + suffix
    }

    /// One row of the details-presence matrix.
    private struct DetailsRequest {
        let name: String
        let request: String
        let code: Int
    }
}
