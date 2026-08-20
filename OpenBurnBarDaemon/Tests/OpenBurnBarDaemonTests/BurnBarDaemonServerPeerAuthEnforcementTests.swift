import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Darwin
import Foundation
import XCTest

/// RR-3 end-to-end: a daemon server wired with an ENFORCING peer authenticator
/// must refuse a non-first-party peer (this XCTest process) on the live socket —
/// no RPC is honored even with a valid bearer token — while the default
/// `.disabled` authenticator still answers. This is the load-bearing socket gate
/// that mitigates the launchd `KeepAlive` re-exec of a swapped daemon binary.
final class BurnBarDaemonServerPeerAuthEnforcementTests: XCTestCase {
    func test_enforcedServer_refusesUnsignedPeer_evenWithValidToken() async throws {
        let socketPath = makeSocketPath(name: "peer-auth-enforced")
        // A validator that mimics the production designated-requirement REJECT for
        // a non-first-party peer (the test host). Injecting it lets us exercise
        // the server's fail-closed accept path without a first-party-signed binary.
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            peerAuthenticator: BurnBarDaemonPeerAuthenticator(enforced: true) { _ in
                throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: -67050)
            }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        // Fail closed: the RPC is not honored. The client still gets a typed
        // unauthorized envelope so it does not decode an empty body as
        // "data isn't in the correct format."
        let bytes = try roundTripRawBytes(
            request: BurnBarRPCRequestEnvelope(id: "health-x", method: .health, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertFalse(bytes.isEmpty, "rejected peer must still receive a typed unauthorized envelope")
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarHealthResponse>.self,
            from: bytes
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.unauthorized)
        XCTAssertEqual(
            response.error?.message,
            "OpenBurnBar RPC peer failed first-party code-signature verification."
        )

        await server.stop()
    }

    func test_enforcedServer_scopesSignedCLIToSupportMethods_evenWithValidToken() async throws {
        let socketPath = makeSocketPath(name: "peer-auth-cli-scoped")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            peerAuthenticator: BurnBarDaemonPeerAuthenticator(enforced: true) { _ in
                .cli
            }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let allowedBytes = try roundTripRawBytes(
            request: BurnBarRPCRequestEnvelope(id: "cli-health", method: .health, authToken: "test-token"),
            socketPath: socketPath
        )
        let allowedResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarHealthResponse>.self,
            from: allowedBytes
        )
        XCTAssertNil(allowedResponse.error)
        XCTAssertNotNil(allowedResponse.result)

        let deniedBytes = try roundTripRawBytes(
            request: BurnBarRPCRequestEnvelope(
                id: "cli-credential-write",
                method: .providerCredentialSlotUpsert,
                authToken: "test-token"
            ),
            socketPath: socketPath
        )
        let deniedResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarEmptyResult>.self,
            from: deniedBytes
        )
        XCTAssertNil(deniedResponse.result)
        XCTAssertEqual(deniedResponse.error?.code, BurnBarRPCErrorCode.unauthorized)
        XCTAssertEqual(
            deniedResponse.error?.message,
            "OpenBurnBar RPC method '\(BurnBarRPCMethod.providerCredentialSlotUpsert.rawValue)' is outside this peer's capability scope."
        )

        await server.stop()
    }

    func test_disabledServer_answersHealth() async throws {
        let socketPath = makeSocketPath(name: "peer-auth-disabled")
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            peerAuthenticator: .disabled
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let bytes = try roundTripRawBytes(
            request: BurnBarRPCRequestEnvelope(id: "health-y", method: .health, authToken: "test-token"),
            socketPath: socketPath
        )
        XCTAssertFalse(bytes.isEmpty, "non-enforcing server must answer the RPC")

        await server.stop()
    }

    // MARK: - Minimal raw socket client

    private func makeSocketPath(name: String) -> String {
        "/tmp/openburnbar-daemon-peerauth-\(name)-\(UUID().uuidString).sock"
    }

    /// Connects, writes the envelope, reads until EOF or newline, and returns the
    /// raw response bytes (empty when the server closed without writing).
    private func roundTripRawBytes(
        request: BurnBarRPCRequestEnvelope,
        socketPath: String
    ) throws -> Data {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)
        defer { close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { rawBuffer[index] = byte }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = write(fileDescriptor, base.advanced(by: offset), remaining)
                if written <= 0 { break }
                remaining -= written
                offset += written
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        return response
    }
}
