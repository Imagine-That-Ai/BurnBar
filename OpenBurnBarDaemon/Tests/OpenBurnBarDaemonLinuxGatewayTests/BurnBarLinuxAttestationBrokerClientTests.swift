#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

@_silgen_name("memfd_create")
private func burnBarTestMemfdCreate(_ name: UnsafePointer<CChar>, _ flags: UInt32) -> Int32

final class BurnBarLinuxAttestationBrokerClientTests: XCTestCase {
    func testGoldenDescribeRequestAndResponse() async throws {
        let fixture = try goldenFixture()
        let response = try framedJSON(fixture["describeBindingResponse"] as Any)
        let recorder = BrokerRequestRecorder()
        let client = BurnBarLinuxAttestationBrokerClient(
            exchange: { request in
                await recorder.record(request)
                return BurnBarLinuxAttestationBrokerPacket(payload: response, descriptors: [])
            },
            requestID: { "describe-0001" }
        )

        let binding = try await client.describeBinding()

        XCTAssertEqual(
            binding,
            try decodedFixture(
                BurnBarLinuxAppCheckAttestationBinding.self,
                at: ["describeBindingResponse", "binding"]
            )
        )
        let recordedRequest = await recorder.onlyRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(
            try canonicalJSON(try unframe(request)),
            try canonicalJSON(fixture["describeBindingRequest"] as Any)
        )
    }

    func testGoldenUnsupportedResponseMapsFailClosed() async throws {
        let response = try framedFixture(at: ["unsupportedResponse"])
        let client = fixtureClient(response: response, requestID: "describe-0001")

        await assertClientError(.unsupported) {
            _ = try await client.describeBinding()
        }
    }

    func testResponseRejectsExtraKeysAndMismatchedRequestID() async throws {
        var extra = try fixtureObject(at: ["describeBindingResponse"])
        extra["unexpected"] = true
        let extraClient = fixtureClient(response: try framedJSON(extra), requestID: "describe-0001")
        await assertClientError(.invalidResponse) {
            _ = try await extraClient.describeBinding()
        }

        var mismatched = try fixtureObject(at: ["describeBindingResponse"])
        mismatched["requestId"] = "different-request"
        let mismatchClient = fixtureClient(response: try framedJSON(mismatched), requestID: "describe-0001")
        await assertClientError(.protocolMismatch) {
            _ = try await mismatchClient.describeBinding()
        }
    }

    func testInjectedExchangePropagatesCancellation() async throws {
        let client = BurnBarLinuxAttestationBrokerClient(
            exchange: { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw BurnBarLinuxAttestationBrokerClientError.unavailable
            },
            requestID: { "describe-0001" }
        )
        let request = Task { try await client.describeBinding() }
        await Task.yield()
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("A cancelled broker request must not complete")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testAttestRejectsPaddedAndWrongLengthChallengesBeforeExchange() async throws {
        let original = try decodedFixture(BurnBarLinuxAppCheckChallenge.self, at: ["attestRequest", "challenge"])
        let binding = try decodedFixture(BurnBarLinuxAppCheckAttestationBinding.self, at: ["attestRequest", "binding"])
        let padded = BurnBarLinuxAppCheckChallenge(
            challengeId: original.challengeId,
            challenge: original.challenge + "=",
            expiresAtMillis: original.expiresAtMillis,
            appId: original.appId,
            policyId: original.policyId,
            protocolVersion: original.protocolVersion
        )
        let wrongLength = BurnBarLinuxAppCheckChallenge(
            challengeId: original.challengeId,
            challenge: base64URL(Data(repeating: 0x61, count: 31)),
            expiresAtMillis: original.expiresAtMillis,
            appId: original.appId,
            policyId: original.policyId,
            protocolVersion: original.protocolVersion
        )
        let client = BurnBarLinuxAttestationBrokerClient(
            exchange: { _ in throw BurnBarLinuxAttestationBrokerClientError.unavailable },
            requestID: { "attest-0001" }
        )

        for challenge in [padded, wrongLength] {
            await assertClientError(.protocolMismatch) {
                _ = try await client.attest(challenge: challenge, binding: binding)
            }
        }
    }

    func testAttestAcceptsGoldenShapeAndSealedEvidenceDescriptor() async throws {
        let evidenceBytes = Data(repeating: 0x41, count: 4_096)
        let descriptor = try makeMemfd(bytes: evidenceBytes, sealed: true)
        var response = try fixtureObject(at: ["attestResponse"])
        setEvidenceBundle(
            in: &response,
            byteLength: evidenceBytes.count,
            sha256: PlatformCrypto.sha256Hex(evidenceBytes)
        )
        let responseData = try framedJSON(response)
        let recorder = BrokerRequestRecorder()
        let client = BurnBarLinuxAttestationBrokerClient(
            exchange: { request in
                await recorder.record(request)
                return BurnBarLinuxAttestationBrokerPacket(payload: responseData, descriptors: [descriptor])
            },
            requestID: { "attest-0001" }
        )
        let challenge = try decodedFixture(BurnBarLinuxAppCheckChallenge.self, at: ["attestRequest", "challenge"])
        let binding = try decodedFixture(BurnBarLinuxAppCheckAttestationBinding.self, at: ["attestRequest", "binding"])

        let result = try await client.attest(challenge: challenge, binding: binding)

        XCTAssertEqual(result.challengeId, challenge.challengeId)
        XCTAssertEqual(result.challenge, challenge.challenge)
        XCTAssertEqual(result.kind, binding.attestationKind)
        XCTAssertEqual(result.evidenceDescriptor.metadata.byteLength, evidenceBytes.count)
        let duplicate = try result.evidenceDescriptor.duplicateForStreaming()
        defer { _ = Glibc.close(duplicate) }
        XCTAssertEqual(try readAll(duplicate, count: evidenceBytes.count), evidenceBytes)
        let recordedRequest = await recorder.onlyRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(
            try canonicalJSON(try unframe(request)),
            try canonicalJSON(try fixtureValue(at: ["attestRequest"]))
        )
    }

    func testRealSeqpacketTransportReceivesGoldenFrameAndSealedMemfd() async throws {
        let evidenceBytes = Data(repeating: 0x51, count: 4_096)
        let evidenceDescriptor = try makeMemfd(bytes: evidenceBytes, sealed: true)
        var response = try fixtureObject(at: ["attestResponse"])
        setEvidenceBundle(
            in: &response,
            byteLength: evidenceBytes.count,
            sha256: PlatformCrypto.sha256Hex(evidenceBytes)
        )
        let responseData = try framedJSON(response)
        let server = try makeSeqpacketServer(name: "success")
        defer { server.cleanup() }
        let serverTask = Task.detached { () throws -> Data in
            defer { _ = Glibc.close(evidenceDescriptor) }
            let peer = try Self.acceptPeer(server.descriptor)
            defer { _ = Glibc.close(peer) }
            let request = try Self.receivePacket(peer)
            try Self.sendPacket(responseData, descriptor: evidenceDescriptor, peer: peer)
            return request
        }
        let client = BurnBarLinuxAttestationBrokerClient(
            socketPath: server.path,
            timeout: 2,
            expectedOwnerUID: getuid(),
            expectedOwnerGID: getgid(),
            requestID: { "attest-0001" }
        )
        let challenge = try decodedFixture(BurnBarLinuxAppCheckChallenge.self, at: ["attestRequest", "challenge"])
        let binding = try decodedFixture(BurnBarLinuxAppCheckAttestationBinding.self, at: ["attestRequest", "binding"])

        let result = try await client.attest(challenge: challenge, binding: binding)
        let request = try await serverTask.value

        XCTAssertEqual(
            try canonicalJSON(try unframe(request)),
            try canonicalJSON(try fixtureValue(at: ["attestRequest"]))
        )
        let duplicate = try result.evidenceDescriptor.duplicateForStreaming()
        defer { _ = Glibc.close(duplicate) }
        XCTAssertEqual(try readAll(duplicate, count: evidenceBytes.count), evidenceBytes)
    }

    func testStreamingDuplicatesHaveIndependentFileOffsets() throws {
        let evidenceBytes = Data(repeating: 0x61, count: 4_096)
        let descriptor = try makeMemfd(bytes: evidenceBytes, sealed: true)
        let owner = BurnBarLinuxAttestationEvidenceDescriptor(
            fileDescriptor: descriptor,
            metadata: BurnBarLinuxAttestationEvidenceBundleMetadata(
                descriptorIndex: 0,
                format: BurnBarLinuxAttestationEvidenceBundleMetadata.formatV1,
                byteLength: evidenceBytes.count,
                sha256: PlatformCrypto.sha256Hex(evidenceBytes)
            )
        )
        let first = try owner.duplicateForStreaming()
        let second = try owner.duplicateForStreaming()
        defer {
            _ = Glibc.close(first)
            _ = Glibc.close(second)
        }

        XCTAssertEqual(lseek(first, 64, SEEK_SET), 64)
        XCTAssertEqual(lseek(second, 0, SEEK_CUR), 0)
        XCTAssertEqual(try readAll(second, count: evidenceBytes.count), evidenceBytes)
        XCTAssertEqual(lseek(first, 0, SEEK_CUR), 64)
    }

    func testRealTransportRejectsWritableSocketParent() async throws {
        let server = try makeSeqpacketServer(name: "writable-parent", directoryMode: 0o777)
        defer { server.cleanup() }
        let client = BurnBarLinuxAttestationBrokerClient(
            socketPath: server.path,
            timeout: 1,
            expectedOwnerUID: getuid(),
            expectedOwnerGID: getgid(),
            requestID: { "describe-0001" }
        )

        await assertClientError(.invalidSocket) {
            _ = try await client.describeBinding()
        }
    }

    func testRealTransportTimesOutAfterSingleAtomicRequest() async throws {
        let server = try makeSeqpacketServer(name: "timeout")
        defer { server.cleanup() }
        let serverTask = Task.detached { () throws -> Data in
            let peer = try Self.acceptPeer(server.descriptor)
            defer { _ = Glibc.close(peer) }
            let request = try Self.receivePacket(peer)
            usleep(200_000)
            return request
        }
        let client = BurnBarLinuxAttestationBrokerClient(
            socketPath: server.path,
            timeout: 0.05,
            expectedOwnerUID: getuid(),
            expectedOwnerGID: getgid(),
            requestID: { "describe-0001" }
        )

        await assertClientError(.timedOut) {
            _ = try await client.describeBinding()
        }
        let request = try await serverTask.value
        XCTAssertEqual(
            try canonicalJSON(try unframe(request)),
            try canonicalJSON(try fixtureValue(at: ["describeBindingRequest"]))
        )
    }

    func testMalformedQuoteClosesReceivedDescriptor() async throws {
        let evidenceBytes = Data(repeating: 0x42, count: 4_096)
        let descriptor = try makeMemfd(bytes: evidenceBytes, sealed: true)
        var response = try fixtureObject(at: ["attestResponse"])
        setEvidenceBundle(
            in: &response,
            byteLength: evidenceBytes.count,
            sha256: PlatformCrypto.sha256Hex(evidenceBytes)
        )
        var attestation = try XCTUnwrap(response["attestation"] as? [String: Any])
        var evidence = try XCTUnwrap(attestation["evidence"] as? [String: Any])
        evidence["pcrSelection"] = [0, 2, 4, 7]
        attestation["evidence"] = evidence
        response["attestation"] = attestation
        let client = fixtureClient(
            response: try framedJSON(response),
            descriptors: [descriptor],
            requestID: "attest-0001"
        )

        await assertClientError(.invalidResponse) {
            try await self.performGoldenAttest(client)
        }
        assertClosed(descriptor)
    }

    func testUnsealedEvidenceDescriptorIsRejectedAndClosed() async throws {
        let evidenceBytes = Data(repeating: 0x43, count: 4_096)
        let descriptor = try makeMemfd(bytes: evidenceBytes, sealed: false)
        var response = try fixtureObject(at: ["attestResponse"])
        setEvidenceBundle(
            in: &response,
            byteLength: evidenceBytes.count,
            sha256: PlatformCrypto.sha256Hex(evidenceBytes)
        )
        let client = fixtureClient(
            response: try framedJSON(response),
            descriptors: [descriptor],
            requestID: "attest-0001"
        )

        await assertClientError(.invalidEvidenceDescriptor) {
            try await self.performGoldenAttest(client)
        }
        assertClosed(descriptor)
    }

    func testEvidenceDescriptorAcceptsExact16MiBBoundaryAndRejectsOneByteOver() async throws {
        let maximumBytes = 16 * 1_024 * 1_024
        XCTAssertEqual(BurnBarLinuxAttestationEvidenceBundleMetadata.maximumBytes, maximumBytes)

        let boundaryBytes = Data(repeating: 0x46, count: maximumBytes)
        let boundaryDescriptor = try makeMemfd(bytes: boundaryBytes, sealed: true)
        var boundaryResponse = try fixtureObject(at: ["attestResponse"])
        setEvidenceBundle(
            in: &boundaryResponse,
            byteLength: boundaryBytes.count,
            sha256: PlatformCrypto.sha256Hex(boundaryBytes)
        )
        let boundaryClient = fixtureClient(
            response: try framedJSON(boundaryResponse),
            descriptors: [boundaryDescriptor],
            requestID: "attest-0001"
        )

        let accepted = try await attestWithGoldenRequest(boundaryClient)
        XCTAssertEqual(accepted.evidenceDescriptor.metadata.byteLength, maximumBytes)
        accepted.evidenceDescriptor.closeDescriptor()
        assertClosed(boundaryDescriptor)

        let oversizedBytes = Data(repeating: 0x47, count: maximumBytes + 1)
        let oversizedDescriptor = try makeMemfd(bytes: oversizedBytes, sealed: true)
        var oversizedResponse = try fixtureObject(at: ["attestResponse"])
        setEvidenceBundle(
            in: &oversizedResponse,
            byteLength: oversizedBytes.count,
            sha256: PlatformCrypto.sha256Hex(oversizedBytes)
        )
        let oversizedClient = fixtureClient(
            response: try framedJSON(oversizedResponse),
            descriptors: [oversizedDescriptor],
            requestID: "attest-0001"
        )

        await assertClientError(.invalidEvidenceDescriptor) {
            _ = try await self.attestWithGoldenRequest(oversizedClient)
        }
        assertClosed(oversizedDescriptor)
    }

    func testMultipleDescriptorsAreRejectedAndClosed() async throws {
        let first = try makeMemfd(bytes: Data(repeating: 0x44, count: 4_096), sealed: true)
        let second = try makeMemfd(bytes: Data(repeating: 0x45, count: 4_096), sealed: true)
        let client = fixtureClient(
            response: try framedFixture(at: ["attestResponse"]),
            descriptors: [first, second],
            requestID: "attest-0001"
        )

        await assertClientError(.invalidResponse) {
            try await self.performGoldenAttest(client)
        }
        assertClosed(first)
        assertClosed(second)
    }

    private func performGoldenAttest(_ client: BurnBarLinuxAttestationBrokerClient) async throws {
        _ = try await attestWithGoldenRequest(client)
    }

    private func attestWithGoldenRequest(
        _ client: BurnBarLinuxAttestationBrokerClient
    ) async throws -> BurnBarLinuxAttestationBrokerResult {
        let challenge = try decodedFixture(BurnBarLinuxAppCheckChallenge.self, at: ["attestRequest", "challenge"])
        let binding = try decodedFixture(BurnBarLinuxAppCheckAttestationBinding.self, at: ["attestRequest", "binding"])
        return try await client.attest(challenge: challenge, binding: binding)
    }

    private func fixtureClient(
        response: Data,
        descriptors: [Int32] = [],
        requestID: String
    ) -> BurnBarLinuxAttestationBrokerClient {
        BurnBarLinuxAttestationBrokerClient(
            exchange: { _ in BurnBarLinuxAttestationBrokerPacket(payload: response, descriptors: descriptors) },
            requestID: { requestID }
        )
    }

    private func assertClientError(
        _ expected: BurnBarLinuxAttestationBrokerClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as BurnBarLinuxAttestationBrokerClientError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected \(expected), got \(error)")
        }
    }

    private func assertClosed(_ descriptor: Int32) {
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    private func setEvidenceBundle(in response: inout [String: Any], byteLength: Int, sha256: String) {
        guard var attestation = response["attestation"] as? [String: Any],
              var bundle = attestation["evidenceBundle"] as? [String: Any] else {
            XCTFail("Golden attestation response is malformed")
            return
        }
        bundle["byteLength"] = byteLength
        bundle["sha256"] = sha256
        attestation["evidenceBundle"] = bundle
        response["attestation"] = attestation
    }

    private func makeMemfd(bytes: Data, sealed: Bool) throws -> Int32 {
        let flags = UInt32(0x0001 | 0x0002) // MFD_CLOEXEC | MFD_ALLOW_SEALING
        let descriptor = "openburnbar-attestation-test".withCString {
            burnBarTestMemfdCreate($0, flags)
        }
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Glibc.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
            guard lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if sealed {
                let seals = Int32(0x0001 | 0x0002 | 0x0004 | 0x0008)
                guard fcntl(descriptor, 1_033, seals) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
            return descriptor
        } catch {
            _ = Glibc.close(descriptor)
            throw error
        }
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while result.count < count {
            let readCount = buffer.withUnsafeMutableBytes { raw in
                Glibc.read(descriptor, raw.baseAddress, min(raw.count, count - result.count))
            }
            guard readCount > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            result.append(buffer, count: readCount)
        }
        return result
    }

    private func makeSeqpacketServer(
        name: String,
        directoryMode: mode_t = 0o700
    ) throws -> SeqpacketServer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-attestation-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        guard chmod(directory.path, directoryMode) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let path = directory.appendingPathComponent("attestd.sock").path
        let type = Int32(SOCK_SEQPACKET.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        let descriptor = Glibc.socket(AF_UNIX, type, 0)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        do {
            var address = try Self.socketAddress(path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Glibc.listen(descriptor, 1) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            return SeqpacketServer(descriptor: descriptor, path: path, directory: directory)
        } catch {
            _ = Glibc.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        return address
    }

    private static func acceptPeer(_ server: Int32) throws -> Int32 {
        var pending = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, 2_000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        let peer = Glibc.accept(server, nil, nil)
        guard peer >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard fcntl(peer, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = Glibc.close(peer)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return peer
    }

    private static func receivePacket(_ peer: Int32) throws -> Data {
        var ready = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 2_000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        var buffer = [UInt8](repeating: 0, count: BurnBarLinuxAttestationBrokerClient.maximumFrameBytes + 5)
        let received = buffer.withUnsafeMutableBytes { raw in
            Glibc.recv(peer, raw.baseAddress, raw.count, 0)
        }
        guard received > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return Data(buffer.prefix(received))
    }

    private static func sendPacket(_ packet: Data, descriptor: Int32, peer: Int32) throws {
        let alignedHeader = align(MemoryLayout<cmsghdr>.size)
        let messageLength = alignedHeader + MemoryLayout<Int32>.size
        var control = [UInt8](repeating: 0, count: align(messageLength))
        var header = cmsghdr()
        header.cmsg_len = messageLength
        header.cmsg_level = SOL_SOCKET
        header.cmsg_type = Int32(SCM_RIGHTS)
        control.withUnsafeMutableBytes { raw in
            raw.baseAddress!.storeBytes(of: header, as: cmsghdr.self)
            raw.baseAddress!.advanced(by: alignedHeader).storeBytes(of: descriptor, as: Int32.self)
        }
        var message = msghdr()
        let sent = packet.withUnsafeBytes { packetBytes in
            control.withUnsafeMutableBytes { controlBytes in
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: packetBytes.baseAddress),
                    iov_len: packetBytes.count
                )
                return withUnsafeMutablePointer(to: &iov) { iovPointer in
                    message.msg_iov = iovPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBytes.baseAddress
                    message.msg_controllen = controlBytes.count
                    return Glibc.sendmsg(peer, &message, Int32(MSG_NOSIGNAL))
                }
            }
        }
        guard sent == packet.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private static func align(_ value: Int) -> Int {
        let alignment = MemoryLayout<Int>.size
        return (value + alignment - 1) & ~(alignment - 1)
    }

    private func goldenFixture() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: goldenFixtureURL())) as? [String: Any])
    }

    private func fixtureValue(at path: [String]) throws -> Any {
        var value: Any = try goldenFixture()
        for component in path {
            value = try XCTUnwrap((value as? [String: Any])?[component])
        }
        return value
    }

    private func fixtureObject(at path: [String]) throws -> [String: Any] {
        try XCTUnwrap(try fixtureValue(at: path) as? [String: Any])
    }

    private func decodedFixture<T: Decodable>(_ type: T.Type, at path: [String]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: try fixtureValue(at: path)))
    }

    private func framedFixture(at path: [String]) throws -> Data {
        try framedJSON(try fixtureValue(at: path))
    }

    private func framedJSON(_ object: Any) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(payload)
        return result
    }

    private func unframe(_ data: Data) throws -> Data {
        let length = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) == data.count - 4 else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        return Data(data.dropFirst(4))
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        try canonicalJSON(try JSONSerialization.jsonObject(with: data))
    }

    private func canonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func goldenFixtureURL() -> URL {
        if let root = ProcessInfo.processInfo.environment["OPENBURNBAR_REPO_ROOT"] {
            return URL(fileURLWithPath: root)
                .appendingPathComponent("tests/fixtures/linux-attestation/broker-v2-golden.json")
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/fixtures/linux-attestation/broker-v2-golden.json")
    }
}

private actor BrokerRequestRecorder {
    private var requests: [Data] = []

    func record(_ request: Data) {
        requests.append(request)
    }

    func onlyRequest() -> Data? {
        requests.count == 1 ? requests[0] : nil
    }
}

private struct SeqpacketServer: @unchecked Sendable {
    let descriptor: Int32
    let path: String
    let directory: URL

    func cleanup() {
        _ = Glibc.close(descriptor)
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
