#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarKernel
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonLinuxAuthSocketTests: XCTestCase {
    private static let fixtureFirebaseAPIKey = "AI" + "za" + "1234567890abcdefghij"

    private let authToken = "socket-bearer-token"
    private let refreshToken = "refresh-token-must-never-cross-rpc"
    private let clientSecret = "oauth-client-secret-must-never-cross-rpc"
    private let firebaseAPIKey = BurnBarDaemonLinuxAuthSocketTests.fixtureFirebaseAPIKey

    func testAuthMethodsRoundTripAndResponsesNeverExposeCredentials() async throws {
        let backend = LinuxAuthSocketSecretBackend(refreshToken: refreshToken)
        let authority = makeAuthority(backend: backend)
        let socketPath = makeSocketPath("round-trip")
        let server = makeServer(
            socketPath: socketPath,
            authority: authority,
            capabilityProfile: .full
        )
        try await server.start()
        defer { Task { await server.stop() } }

        var responsePayloads: [Data] = []

        let initialStatusData = try roundTrip(
            try encodeEnvelope(id: "auth-status-initial", method: .linuxAuthStatus),
            socketPath: socketPath
        )
        responsePayloads.append(initialStatusData)
        let initialStatus = try decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxAuthStatusResponse>.self,
            from: initialStatusData
        )
        XCTAssertEqual(initialStatus.id, "auth-status-initial")
        XCTAssertNil(initialStatus.error)
        XCTAssertEqual(initialStatus.result?.state, .signedOut)
        XCTAssertFalse(initialStatus.result?.signedIn ?? true)
        XCTAssertNil(initialStatus.result?.identityLabel)

        let beginData = try roundTrip(
            try encodeEnvelope(id: "auth-begin", method: .linuxAuthBegin),
            socketPath: socketPath
        )
        responsePayloads.append(beginData)
        let begin = try decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxAuthBeginResponse>.self,
            from: beginData
        )
        XCTAssertEqual(begin.id, "auth-begin")
        XCTAssertNil(begin.error)
        let beginResult = try XCTUnwrap(begin.result)
        XCTAssertFalse(beginResult.operationID.isEmpty)
        XCTAssertEqual(URL(string: beginResult.authorizationURL)?.scheme, "https")

        let authorizingStatusData = try roundTrip(
            try encodeEnvelope(id: "auth-status-authorizing", method: .linuxAuthStatus),
            socketPath: socketPath
        )
        responsePayloads.append(authorizingStatusData)
        let authorizingStatus = try decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxAuthStatusResponse>.self,
            from: authorizingStatusData
        )
        XCTAssertEqual(authorizingStatus.result?.state, .authorizing)
        XCTAssertEqual(authorizingStatus.result?.authorizationOperationID, beginResult.operationID)

        let cancelRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "auth-cancel",
            method: BurnBarRPCMethod.linuxAuthCancel,
            authToken: authToken,
            params: BurnBarLinuxAuthCancelRequest(operationID: beginResult.operationID)
        )
        let cancelData = try roundTrip(try JSONEncoder().encode(cancelRequest), socketPath: socketPath)
        responsePayloads.append(cancelData)
        let cancel = try decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxAuthMutationResponse>.self,
            from: cancelData
        )
        XCTAssertEqual(cancel.id, "auth-cancel")
        XCTAssertNil(cancel.error)
        XCTAssertEqual(cancel.result?.ok, true)
        XCTAssertEqual(cancel.result?.status.state, .signedOut)

        let malformedData = try roundTrip(
            Data(#"{"id":"auth-cancel-malformed","method":"daemon.auth.cancel","authToken":"socket-bearer-token","params":{"operationID":7}}"#.utf8),
            socketPath: socketPath
        )
        responsePayloads.append(malformedData)
        let malformed = try decode(
            BurnBarRPCResponseEnvelope<BurnBarEmptyResult>.self,
            from: malformedData
        )
        XCTAssertNil(malformed.result)
        XCTAssertEqual(malformed.error?.code, BurnBarRPCErrorCode.invalidParams)

        let rotateData = try roundTrip(
            try encodeEnvelope(id: "auth-rotate-rejected", method: .linuxAuthRotateIdentity),
            socketPath: socketPath
        )
        responsePayloads.append(rotateData)
        let rotate = try decode(
            BurnBarRPCResponseEnvelope<BurnBarEmptyResult>.self,
            from: rotateData
        )
        XCTAssertNil(rotate.result)
        XCTAssertEqual(rotate.error?.code, BurnBarRPCErrorCode.invalidRequest)

        let signOutData = try roundTrip(
            try encodeEnvelope(id: "auth-sign-out", method: .linuxAuthSignOut),
            socketPath: socketPath
        )
        responsePayloads.append(signOutData)
        let signOut = try decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxAuthMutationResponse>.self,
            from: signOutData
        )
        XCTAssertEqual(signOut.id, "auth-sign-out")
        XCTAssertNil(signOut.error)
        XCTAssertEqual(signOut.result?.ok, true)
        XCTAssertEqual(signOut.result?.status.state, .signedOut)
        XCTAssertNil(backend.secret(id: "firebase-refresh-token"))

        for payload in responsePayloads {
            assertDoesNotLeakCredentials(payload)
        }

        await server.stop()
    }

    func testReadOnlyCapabilityAllowsStatusAndDeniesAuthMutationsBeforeDispatch() async throws {
        let backend = LinuxAuthSocketSecretBackend(refreshToken: refreshToken)
        let authority = makeAuthority(backend: backend)
        let socketPath = makeSocketPath("capability")
        let server = makeServer(
            socketPath: socketPath,
            authority: authority,
            capabilityProfile: .readOnly
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let statusData = try roundTrip(
            try encodeEnvelope(id: "read-only-status", method: .linuxAuthStatus),
            socketPath: socketPath
        )
        let status = try decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxAuthStatusResponse>.self,
            from: statusData
        )
        XCTAssertNil(status.error)
        XCTAssertNotNil(status.result)
        assertDoesNotLeakCredentials(statusData)

        let mutationRequests: [(BurnBarRPCMethod, Data)] = [
            (.linuxAuthBegin, try encodeEnvelope(id: "denied-begin", method: .linuxAuthBegin)),
            (
                .linuxAuthCancel,
                try JSONEncoder().encode(BurnBarRPCRequestEnvelopeWithParams(
                    id: "denied-cancel",
                    method: BurnBarRPCMethod.linuxAuthCancel,
                    authToken: authToken,
                    params: BurnBarLinuxAuthCancelRequest(operationID: "not-an-active-operation")
                ))
            ),
            (
                .linuxAuthRotateIdentity,
                try encodeEnvelope(id: "denied-rotate", method: .linuxAuthRotateIdentity)
            ),
            (.linuxAuthSignOut, try encodeEnvelope(id: "denied-sign-out", method: .linuxAuthSignOut))
        ]

        for (method, requestData) in mutationRequests {
            let responseData = try roundTrip(requestData, socketPath: socketPath)
            let response = try decode(
                BurnBarRPCResponseEnvelope<BurnBarEmptyResult>.self,
                from: responseData
            )
            XCTAssertNil(response.result, method.rawValue)
            XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.unauthorized, method.rawValue)
            XCTAssertEqual(
                response.error?.message,
                "OpenBurnBar RPC method '\(method.rawValue)' is outside this peer's capability scope.",
                method.rawValue
            )
            assertDoesNotLeakCredentials(responseData)
        }

        XCTAssertEqual(
            backend.secret(id: "firebase-refresh-token")?.contains(refreshToken),
            true,
            "A capability-denied sign-out must not mutate the secure store"
        )

        await server.stop()
    }

    private func makeAuthority(
        backend: LinuxAuthSocketSecretBackend
    ) -> LinuxDaemonCloudCredentialAuthority {
        LinuxDaemonCloudCredentialAuthority(
            configuration: LinuxCloudAuthConfiguration(
                googleOAuthClientID: "123456789012.apps.googleusercontent.com",
                googleOAuthClientSecret: clientSecret,
                firebaseAPIKey: firebaseAPIKey,
                linuxAppCheckAppID: "1:123456789:linux:abcdef123456",
                authorizationTimeout: 30
            ),
            custodian: LinuxSecretCustodian(backends: [backend]),
            httpTransport: { _, _ in throw URLError(.notConnectedToInternet) },
            hostname: "auth-socket-test"
        )
    }

    private func makeServer(
        socketPath: String,
        authority: LinuxDaemonCloudCredentialAuthority,
        capabilityProfile: BurnBarPeerCapabilityProfile
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: authToken,
                startsMissionControlBackgroundLoops: false
            ),
            capabilityProfile: capabilityProfile,
            linuxCloudCredentialAuthority: authority
        )
    }

    private func makeSocketPath(_ name: String) -> String {
        "/tmp/obb-auth-\(name)-\(UUID().uuidString).sock"
    }

    private func encodeEnvelope(id: String, method: BurnBarRPCMethod) throws -> Data {
        try JSONEncoder().encode(BurnBarRPCRequestEnvelope(
            id: id,
            method: method,
            authToken: authToken
        ))
    }

    private func decode<Result: Codable & Sendable>(
        _ type: BurnBarRPCResponseEnvelope<Result>.Type,
        from data: Data
    ) throws -> BurnBarRPCResponseEnvelope<Result> {
        try JSONDecoder().decode(type, from: data)
    }

    private func assertDoesNotLeakCredentials(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let response = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(response.contains(authToken), file: file, line: line)
        XCTAssertFalse(response.contains(refreshToken), file: file, line: line)
        XCTAssertFalse(response.contains(clientSecret), file: file, line: line)
        XCTAssertFalse(response.contains(firebaseAPIKey), file: file, line: line)
        XCTAssertFalse(response.lowercased().contains("id_token"), file: file, line: line)
        XCTAssertFalse(response.lowercased().contains("appchecktoken"), file: file, line: line)
    }

    private func roundTrip(_ requestData: Data, socketPath: String) throws -> Data {
        let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Glibc.close(descriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BurnBarDaemonError.socketPathTooLong(socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                destination[index] = UInt8(bitPattern: byte)
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let payload = requestData + Data([0x0A])
        try payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Glibc.write(descriptor, base.advanced(by: written), bytes.count - written)
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        _ = Glibc.shutdown(descriptor, Int32(SHUT_WR))

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            response.append(contentsOf: buffer.prefix(count))
            if response.last == 0x0A { break }
        }
        return response
    }
}

private final class LinuxAuthSocketSecretBackend: LinuxSecretStoreBackend, @unchecked Sendable {
    let backendName = "auth-socket-test-secret-service"
    let trustLevel = LinuxSecretTrustLevel.secretService
    let supportsMutations = true

    private let lock = NSLock()
    private var secrets: [String: String]

    init(refreshToken: String) {
        secrets = [
            "firebase-refresh-token": #"{"schemaVersion":1,"refreshToken":"\#(refreshToken)","uid":"socket-user","identityLabel":"socket@example.com"}"#
        ]
    }

    func readSecret(id: String, secretClass: LinuxHighValueSecretClass) throws -> LinuxSecretRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = secrets[id] else { return nil }
        return LinuxSecretRecord(secret: secret, metadata: metadata(id: id, secretClass: secretClass))
    }

    func storeSecret(
        _ secret: String,
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) throws -> LinuxSecretMetadata {
        lock.lock()
        secrets[id] = secret
        lock.unlock()
        return metadata(id: id, secretClass: secretClass)
    }

    func deleteSecret(id: String, secretClass: LinuxHighValueSecretClass) throws {
        lock.lock()
        secrets[id] = nil
        lock.unlock()
    }

    func healthCheck() throws {}

    func secret(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[id]
    }

    private func metadata(
        id: String,
        secretClass: LinuxHighValueSecretClass
    ) -> LinuxSecretMetadata {
        LinuxSecretMetadata(
            id: id,
            secretClass: secretClass,
            trustLevel: trustLevel,
            backend: backendName,
            createdAtMillis: 1_900_000_000_000,
            note: "Test-only in-memory secure store."
        )
    }
}
#endif
