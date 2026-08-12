import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Error-envelope matrix tests (VAL-RPC-002, 003, 004, 011, 012, 016):
/// every failure class returns its exact documented code and shape, the id
/// is echoed when syntactically recoverable, and the daemon stays usable.
final class BurnBarFleetRPCErrorMatrixTests: BurnBarFleetRPCTestCase {
    // MARK: - VAL-RPC-002: unknown method typed error, daemon stays usable

    func testUnknownMethod_typedMethodNotFound_daemonKeepsServing() async throws {
        let configuration = makeConfiguration(name: "unknown-method")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest("{\"id\":\"2\",\"method\":\"daemon.fleet.nonexistent\"}", socketPath: socketPath)
        let envelope = try decodeErrorEnvelope(response)

        XCTAssertEqual(envelope.id, "2")
        XCTAssertEqual(envelope.protocolVersion, 1)
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32601)
        XCTAssertTrue(envelope.error?.message.contains("daemon.fleet.nonexistent") == true)

        // The socket keeps serving valid requests afterward.
        let health = try rawRequest("{\"id\":\"3\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        let healthEnvelope = try decodeErrorEnvelope(health)
        XCTAssertNil(healthEnvelope.error)
    }

    // MARK: - VAL-RPC-003: malformed JSON typed parse error, daemon alive

    func testMalformedJSON_typedParseError_daemonAlive() async throws {
        let configuration = makeConfiguration(name: "malformed-json")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest("{not json", socketPath: socketPath)
        let envelope = try decodeErrorEnvelope(response)

        XCTAssertEqual(envelope.protocolVersion, 1)
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32700)
        XCTAssertFalse(envelope.error?.message.isEmpty == true)

        // The daemon process stays alive and answers the next well-formed request.
        let health = try rawRequest("{\"id\":\"ok-1\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        let healthEnvelope = try decodeErrorEnvelope(health)
        XCTAssertNil(healthEnvelope.error)
        XCTAssertNotNil(healthEnvelope.result, "health must return a result after a parse error")
    }

    // MARK: - VAL-RPC-004: frame-size boundary at 65536/65537 raw UTF-8 bytes

    func testFrameBoundary_65536AtCapAccepted_65537OversizeTyped() async throws {
        let configuration = makeConfiguration(name: "frame-boundary")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        // At-cap: a syntactically valid padded request whose payload is exactly
        // 65536 raw UTF-8 bytes (excluding the newline delimiter).
        let atCapPayload = try makePaddedRequest(id: "cap-1", payloadBytes: 65_536)
        XCTAssertEqual(atCapPayload.count, 65_536, "test payload must be exactly 65536 bytes")
        let atCapResponse = try rawRequest(atCapPayload, socketPath: socketPath)
        let atCapEnvelope = try decodeErrorEnvelope(atCapResponse)
        XCTAssertNil(atCapEnvelope.error, "at-cap request must be accepted, got error: \(atCapEnvelope.error?.message ?? "nil")")
        XCTAssertEqual(atCapEnvelope.id, "cap-1")
        XCTAssertNotNil(atCapEnvelope.result, "at-cap health request must return a result")

        // Oversize: 65537 payload bytes → typed oversize error, daemon healthy.
        let oversizePayload = try makePaddedRequest(id: "cap-2", payloadBytes: 65_537)
        XCTAssertEqual(oversizePayload.count, 65_537, "test payload must be exactly 65537 bytes")
        let oversizeResponse = try rawRequest(oversizePayload, socketPath: socketPath)
        let oversizeEnvelope = try decodeErrorEnvelope(oversizeResponse)
        XCTAssertEqual(oversizeEnvelope.id, "cap-2", "id must be recovered from the partial frame")
        XCTAssertEqual(oversizeEnvelope.protocolVersion, 1)
        XCTAssertNil(oversizeEnvelope.result)
        XCTAssertEqual(oversizeEnvelope.error?.code, -32002)
        XCTAssertTrue(oversizeEnvelope.error?.message.contains("65536") == true)

        // Follow-up normal request succeeds.
        let health = try rawRequest("{\"id\":\"after-1\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        let healthEnvelope = try decodeErrorEnvelope(health)
        XCTAssertNil(healthEnvelope.error)
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

    // MARK: - VAL-RPC-011: missing/wrong id and wrong params type are typed

    func testMissingID_typedInvalidRequest_noIDCorrelation() async throws {
        let configuration = makeConfiguration(name: "missing-id")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest("{\"method\":\"daemon.health\"}", socketPath: socketPath)
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.id, BurnBarDaemonServer.noRequestID)
        XCTAssertEqual(envelope.protocolVersion, 1)
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32600)

        let health = try rawRequest("{\"id\":\"h-1\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(health).error)
    }

    func testWrongTypedID_typedInvalidRequest_noIDCorrelation() async throws {
        let configuration = makeConfiguration(name: "wrong-id")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest("{\"id\":123,\"method\":\"daemon.health\"}", socketPath: socketPath)
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.id, BurnBarDaemonServer.noRequestID)
        XCTAssertEqual(envelope.protocolVersion, 1)
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32600)

        let health = try rawRequest("{\"id\":\"h-2\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(health).error)
    }

    func testWrongParamsType_typedInvalidParams_idEchoed() async throws {
        let configuration = makeConfiguration(name: "wrong-params")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        // daemon.fleet.orchestrator.set with params as a string instead of an
        // object: typed invalid-params, id echoed, daemon stays healthy.
        let response = try rawRequest(
            "{\"id\":\"wp-1\",\"method\":\"daemon.fleet.orchestrator.set\",\"params\":\"not-an-object\"}",
            socketPath: socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.id, "wp-1")
        XCTAssertEqual(envelope.protocolVersion, 1)
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32602)

        let health = try rawRequest("{\"id\":\"h-3\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(health).error)
    }

    // MARK: - VAL-RPC-012: protocolVersion mismatch is typed

    func testProtocolVersionMismatch_typedError_neverSilentV1() async throws {
        let configuration = makeConfiguration(name: "version-mismatch")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let response = try rawRequest(
            "{\"id\":\"v2-1\",\"method\":\"daemon.health\",\"protocolVersion\":2}",
            socketPath: socketPath
        )
        let envelope = try decodeErrorEnvelope(response)
        XCTAssertEqual(envelope.id, "v2-1")
        XCTAssertEqual(envelope.protocolVersion, 1)
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32001)
        XCTAssertTrue(envelope.error?.message.contains("2") == true)

        // A v1 request still works.
        let health = try rawRequest("{\"id\":\"v1-1\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(health).error)
    }

    // MARK: - VAL-RPC-016: error envelope code matrix (exact shape)

    func testErrorEnvelopeMatrix_exactCodesAndShape() async throws {
        let configuration = makeConfiguration(name: "matrix")
        let socketPath = configuration.socketPath
        let fleetService = makeFleetService()
        _ = try await fleetService.buildOnce()
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: fleetService)
        try await server.start()
        defer { Task { await server.stop() } }

        let cases: [MatrixCase] = [
            MatrixCase(name: "unknown-method", request: "{\"id\":\"m-1\",\"method\":\"daemon.fleet.nonexistent\"}", expectedID: "m-1", expectedCode: -32601),
            MatrixCase(name: "malformed-json", request: "{not json", expectedID: BurnBarDaemonServer.noRequestID, expectedCode: -32700),
            MatrixCase(name: "oversized-frame", request: try makePaddedRequest(id: "f-1", payloadBytes: 65_537), expectedID: "f-1", expectedCode: -32002),
            MatrixCase(name: "missing-id", request: "{\"method\":\"daemon.health\"}", expectedID: BurnBarDaemonServer.noRequestID, expectedCode: -32600),
            MatrixCase(name: "wrong-id", request: "{\"id\":123,\"method\":\"daemon.health\"}", expectedID: BurnBarDaemonServer.noRequestID, expectedCode: -32600),
            MatrixCase(name: "wrong-params", request: "{\"id\":\"p-1\",\"method\":\"daemon.fleet.orchestrator.set\",\"params\":\"x\"}", expectedID: "p-1", expectedCode: -32602),
            MatrixCase(name: "version-mismatch", request: "{\"id\":\"v-1\",\"method\":\"daemon.health\",\"protocolVersion\":2}", expectedID: "v-1", expectedCode: -32001)
        ]

        for testCase in cases {
            let response = try rawRequest(testCase.request, socketPath: socketPath)
            let envelope = try decodeErrorEnvelope(response)
            XCTAssertEqual(envelope.id, testCase.expectedID, "id mismatch for \(testCase.name)")
            XCTAssertEqual(envelope.protocolVersion, 1, "protocolVersion mismatch for \(testCase.name)")
            XCTAssertNil(envelope.result, "no result on error for \(testCase.name)")
            XCTAssertEqual(envelope.error?.code, testCase.expectedCode, "code mismatch for \(testCase.name)")
            XCTAssertFalse(envelope.error?.message.isEmpty == true, "message required for \(testCase.name)")
        }

        // The daemon remains usable after every failure class.
        let health = try rawRequest("{\"id\":\"final-1\",\"method\":\"daemon.health\"}", socketPath: socketPath)
        XCTAssertNil(try decodeErrorEnvelope(health).error)
    }

    /// One row of the error-envelope code matrix.
    private struct MatrixCase {
        let name: String
        let request: String
        let expectedID: String
        let expectedCode: Int
    }
}
