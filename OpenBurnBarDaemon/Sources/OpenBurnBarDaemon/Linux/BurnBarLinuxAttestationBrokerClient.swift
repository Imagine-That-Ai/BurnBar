#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore

enum BurnBarLinuxAttestationBrokerClientError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case invalidSocket
    case unauthorizedPeer
    case requestTooLarge
    case invalidResponse
    case unsupported
    case rateLimited
    case attestationFailed
    case installedReleaseInvalid
    case protocolMismatch
    case invalidEvidenceDescriptor
}

struct BurnBarLinuxAttestationEvidenceBundleMetadata: Codable, Equatable, Sendable {
    static let formatV1 = "openburnbar_tpm_evidence_bundle_v1"
    static let maximumBytes = 16 * 1_024 * 1_024

    let descriptorIndex: Int
    let format: String
    let byteLength: Int
    let sha256: String
}

// AUDIT: the owned descriptor lifecycle is serialized by the private lock. sendable-allowlist: process-handle
final class BurnBarLinuxAttestationEvidenceDescriptor: @unchecked Sendable {
    let metadata: BurnBarLinuxAttestationEvidenceBundleMetadata
    private let lock = NSLock()
    private var fileDescriptor: Int32

    init(fileDescriptor: Int32, metadata: BurnBarLinuxAttestationEvidenceBundleMetadata) {
        self.fileDescriptor = fileDescriptor
        self.metadata = metadata
    }

    deinit { closeDescriptor() }

    func duplicateForStreaming() throws -> Int32 {
        try lock.withLock {
            guard fileDescriptor >= 0 else {
                throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
            }
            let descriptorPath = "/proc/self/fd/\(fileDescriptor)"
            let duplicate = descriptorPath.withCString {
                Glibc.open($0, O_RDONLY | O_CLOEXEC)
            }
            guard duplicate >= 0 else {
                throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
            }
            guard lseek(duplicate, 0, SEEK_SET) == 0 else {
                _ = Glibc.close(duplicate)
                throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
            }
            return duplicate
        }
    }

    func closeDescriptor() {
        lock.withLock {
            guard fileDescriptor >= 0 else { return }
            _ = Glibc.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

struct BurnBarLinuxAttestationBrokerResult: Sendable {
    let challengeId: String
    let challenge: String
    let kind: String
    let evidence: BurnBarLinuxAppCheckJSONValue
    let evidenceDescriptor: BurnBarLinuxAttestationEvidenceDescriptor
}

struct BurnBarLinuxAttestationBrokerPacket: Sendable {
    let payload: Data
    let descriptors: [Int32]
}

typealias BurnBarLinuxAttestationBrokerExchange = @Sendable (Data) async throws -> BurnBarLinuxAttestationBrokerPacket

struct BurnBarLinuxAttestationBrokerClient: Sendable {
    static let protocolVersion = 2
    static let maximumFrameBytes = 64 * 1_024
    static let productionSocketPath = "/run/openburnbar/attestd.sock"

    private struct DescribeBindingRequest: Encodable {
        let protocolVersion = BurnBarLinuxAttestationBrokerClient.protocolVersion
        let requestId: String
        let operation = "describe_binding"
    }

    private struct AttestRequest: Encodable {
        let protocolVersion = BurnBarLinuxAttestationBrokerClient.protocolVersion
        let requestId: String
        let operation = "attest"
        let challenge: BurnBarLinuxAppCheckChallenge
        let binding: BurnBarLinuxAppCheckAttestationBinding
    }

    private struct BrokerErrorResponse: Decodable {
        let code: String
        let message: String
        let retryable: Bool
    }

    private struct QuoteEvidence: Codable {
        let schemaVersion: Int
        let deviceId: String
        let quoteAttestationBase64: String
        let quoteSignatureBase64: String
        let quotePcrValuesBase64: String
        let pcrBank: String
        let pcrSelection: [Int]
        let qualifyingDataSha256: String
    }

    private struct AttestationResponse: Decodable {
        let challengeId: String
        let challenge: String
        let kind: String
        let evidence: QuoteEvidence
        let evidenceBundle: BurnBarLinuxAttestationEvidenceBundleMetadata
    }

    private struct Response: Decodable {
        let protocolVersion: Int
        let requestId: String
        let ok: Bool
        let binding: BurnBarLinuxAppCheckAttestationBinding?
        let attestation: AttestationResponse?
        let error: BrokerErrorResponse?
    }

    // Swift's Glibc module does not expose Linux's `struct ucred`.
    private struct PeerCredentials {
        var pid: pid_t = 0
        var uid: uid_t = 0
        var gid: gid_t = 0
    }

    private let exchange: BurnBarLinuxAttestationBrokerExchange
    private let requestID: @Sendable () -> String

    init(
        socketPath: String = Self.productionSocketPath,
        timeout: TimeInterval = 35,
        expectedOwnerUID: uid_t = 0,
        expectedOwnerGID: gid_t = 0,
        requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.requestID = requestID
        exchange = { request in
            let worker = Task.detached(priority: nil) {
                try Self.performSocketExchange(
                    request,
                    socketPath: socketPath,
                    timeout: timeout,
                    expectedOwnerUID: expectedOwnerUID,
                    expectedOwnerGID: expectedOwnerGID
                )
            }
            return try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    }

    init(
        exchange: @escaping BurnBarLinuxAttestationBrokerExchange,
        requestID: @escaping @Sendable () -> String
    ) {
        self.exchange = exchange
        self.requestID = requestID
    }

    func describeBinding() async throws -> BurnBarLinuxAppCheckAttestationBinding {
        let id = try nextRequestID()
        let packet = try await exchange(try encode(DescribeBindingRequest(requestId: id)))
        defer { Self.closeDescriptors(packet.descriptors) }
        let response = try decodeResponse(packet.payload, requestID: id, expected: .binding)
        guard packet.descriptors.isEmpty, let binding = response.binding else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        try Self.validateBinding(binding)
        return binding
    }

    func attest(
        challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding
    ) async throws -> BurnBarLinuxAttestationBrokerResult {
        try Self.validateChallenge(challenge, binding: binding)
        try Self.validateBinding(binding)
        let id = try nextRequestID()
        let packet = try await exchange(try encode(AttestRequest(
            requestId: id,
            challenge: challenge,
            binding: binding
        )))
        var descriptors = packet.descriptors
        do {
            let response = try decodeResponse(packet.payload, requestID: id, expected: .attestation)
            guard let attestation = response.attestation,
                  descriptors.count == 1,
                  attestation.challengeId == challenge.challengeId,
                  attestation.challenge == challenge.challenge,
                  attestation.kind == binding.attestationKind,
                  attestation.evidence.deviceId == binding.deviceId else {
                throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
            }
            try Self.validateQuoteEvidence(attestation.evidence)
            let descriptor = descriptors[0]
            try Self.validateEvidenceDescriptor(descriptor, metadata: attestation.evidenceBundle)
            let evidence = try Self.jsonValue(attestation.evidence)
            descriptors.removeAll(keepingCapacity: false)
            return BurnBarLinuxAttestationBrokerResult(
                challengeId: attestation.challengeId,
                challenge: attestation.challenge,
                kind: attestation.kind,
                evidence: evidence,
                evidenceDescriptor: BurnBarLinuxAttestationEvidenceDescriptor(
                    fileDescriptor: descriptor,
                    metadata: attestation.evidenceBundle
                )
            )
        } catch {
            Self.closeDescriptors(descriptors)
            throw error
        }
    }

    private enum ExpectedResponse { case binding, attestation }

    private func nextRequestID() throws -> String {
        let value = requestID()
        guard Self.isASCIIWireLabel(value, maximum: 128) else {
            throw BurnBarLinuxAttestationBrokerClientError.protocolMismatch
        }
        return value
    }

    private func encode<T: Encodable>(_ request: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(request)
        guard !payload.isEmpty, payload.count <= Self.maximumFrameBytes else {
            throw BurnBarLinuxAttestationBrokerClientError.requestTooLarge
        }
        return Self.frame(payload)
    }

    private func decodeResponse(
        _ packet: Data,
        requestID: String,
        expected: ExpectedResponse
    ) throws -> Response {
        let payload = try Self.unframe(packet)
        let raw = try Self.strictJSONObject(payload)
        let response = try JSONDecoder().decode(Response.self, from: payload)
        guard response.protocolVersion == Self.protocolVersion,
              response.requestId == requestID else {
            throw BurnBarLinuxAttestationBrokerClientError.protocolMismatch
        }
        if response.ok {
            switch expected {
            case .binding:
                try Self.requireExactKeys(raw, ["protocolVersion", "requestId", "ok", "binding"])
                guard response.binding != nil, response.attestation == nil, response.error == nil else {
                    throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
                }
                try Self.validateBindingObject(raw["binding"])
            case .attestation:
                try Self.requireExactKeys(raw, ["protocolVersion", "requestId", "ok", "attestation"])
                guard response.binding == nil, response.attestation != nil, response.error == nil else {
                    throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
                }
                try Self.validateAttestationObject(raw["attestation"])
            }
            return response
        }
        try Self.requireExactKeys(raw, ["protocolVersion", "requestId", "ok", "error"])
        guard response.binding == nil, response.attestation == nil, let brokerError = response.error else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        try Self.validateErrorObject(raw["error"], decoded: brokerError)
        throw Self.mapBrokerError(brokerError)
    }

    private static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }

    private static func unframe(_ packet: Data) throws -> Data {
        guard packet.count >= 5, packet.count <= maximumFrameBytes + 4 else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        let declared = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard declared > 0, Int(declared) == packet.count - 4 else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        return packet.dropFirst(4)
    }

    private static func strictJSONObject(_ payload: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        return object
    }

    private static func requireExactKeys(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
    }

    private static func validateBindingObject(_ value: Any?) throws {
        guard let object = value as? [String: Any] else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        try requireExactKeys(object, [
            "appId", "deviceId", "appVersion", "architecture", "releaseDigestSha256", "policyId", "attestationKind",
        ])
    }

    private static func validateAttestationObject(_ value: Any?) throws {
        guard let object = value as? [String: Any] else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        try requireExactKeys(object, ["challengeId", "challenge", "kind", "evidence", "evidenceBundle"])
        guard let evidence = object["evidence"] as? [String: Any],
              let bundle = object["evidenceBundle"] as? [String: Any] else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        try requireExactKeys(evidence, [
            "schemaVersion", "deviceId", "quoteAttestationBase64", "quoteSignatureBase64", "quotePcrValuesBase64",
            "pcrBank", "pcrSelection", "qualifyingDataSha256",
        ])
        try requireExactKeys(bundle, ["descriptorIndex", "format", "byteLength", "sha256"])
    }

    private static func validateErrorObject(_ value: Any?, decoded: BrokerErrorResponse) throws {
        guard let object = value as? [String: Any] else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
        try requireExactKeys(object, ["code", "message", "retryable"])
        guard isASCIIWireLabel(decoded.code, maximum: 160),
              !decoded.message.isEmpty, decoded.message.utf8.count <= 512 else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
    }

    private static func mapBrokerError(_ error: BrokerErrorResponse) -> BurnBarLinuxAttestationBrokerClientError {
        switch (error.code, error.retryable) {
        case ("attestation_unsupported", false), ("not_enrolled", false), ("rollout_disabled", false): .unsupported
        case ("rate_limited", true): .rateLimited
        case ("unauthorized_peer", false), ("manifest_signature_invalid", false): .installedReleaseInvalid
        case ("attestation_failed", _), ("internal", _): .attestationFailed
        case ("invalid_frame", false), ("request_too_large", false), ("response_too_large", false),
             ("malformed_request", false), ("unsupported_protocol", false), ("invalid_request", false): .protocolMismatch
        default: .protocolMismatch
        }
    }

    private static func validateBinding(_ binding: BurnBarLinuxAppCheckAttestationBinding) throws {
        guard isASCIIWireLabel(binding.appId, maximum: 160),
              isASCIIWireLabel(binding.deviceId, maximum: 160),
              isASCIIWireLabel(binding.appVersion, maximum: 80),
              ["aarch64", "x86_64"].contains(binding.architecture),
              isLowerHex(binding.releaseDigestSha256, count: 64),
              isASCIIWireLabel(binding.policyId, maximum: 160),
              binding.attestationKind == "tpm2_ima_signed_verdict_v1" else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
    }

    private static func validateChallenge(
        _ challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding
    ) throws {
        guard challenge.protocolVersion == 1,
              challenge.expiresAtMillis > 0,
              challenge.appId == binding.appId,
              challenge.policyId == binding.policyId,
              isASCIIWireLabel(challenge.challengeId, maximum: 160),
              isCanonicalBase64URL(challenge.challenge, decodedByteCount: 32) else {
            throw BurnBarLinuxAttestationBrokerClientError.protocolMismatch
        }
    }

    private static func validateQuoteEvidence(_ evidence: QuoteEvidence) throws {
        guard evidence.schemaVersion == 1,
              isASCIIWireLabel(evidence.deviceId, maximum: 160),
              isBase64(evidence.quoteAttestationBase64, maximum: 16_384),
              isBase64(evidence.quoteSignatureBase64, maximum: 4_096),
              isBase64(evidence.quotePcrValuesBase64, maximum: 16_384),
              evidence.pcrBank == "sha256",
              evidence.pcrSelection == [0, 2, 4, 7, 10],
              isLowerHex(evidence.qualifyingDataSha256, count: 64) else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
        }
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> BurnBarLinuxAppCheckJSONValue {
        try JSONDecoder().decode(BurnBarLinuxAppCheckJSONValue.self, from: JSONEncoder().encode(value))
    }

    private static func isASCIIWireLabel(_ value: String, maximum: Int) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= maximum && bytes.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39)
                || [0x2e, 0x5f, 0x3a, 0x2b, 0x2f, 0x3d, 0x2d].contains($0)
        }
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == count && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func isBase64(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximum, value.utf8.allSatisfy({
            ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39)
                || $0 == 0x2b || $0 == 0x2f || $0 == 0x3d
        }), let decoded = Data(base64Encoded: value), !decoded.isEmpty else { return false }
        return decoded.base64EncodedString() == value
    }

    private static func isCanonicalBase64URL(_ value: String, decodedByteCount: Int) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({
                  ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a)
                      || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x5f
              }) else {
            return false
        }
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let decoded = Data(base64Encoded: standard + padding),
              decoded.count == decodedByteCount else {
            return false
        }
        return decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") == value
    }

    private static func validateEvidenceDescriptor(
        _ fd: Int32,
        metadata: BurnBarLinuxAttestationEvidenceBundleMetadata
    ) throws {
        guard metadata.descriptorIndex == 0,
              metadata.format == BurnBarLinuxAttestationEvidenceBundleMetadata.formatV1,
              (1...BurnBarLinuxAttestationEvidenceBundleMetadata.maximumBytes).contains(metadata.byteLength),
              isLowerHex(metadata.sha256, count: 64),
              fcntl(fd, F_GETFD) & FD_CLOEXEC != 0 else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
        }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 0,
              status.st_size == metadata.byteLength,
              status.st_blocks * 512 >= status.st_size else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
        }
        let requiredSeals = Int32(0x0001 | 0x0002 | 0x0004 | 0x0008)
        let seals = fcntl(fd, 1_034)
        guard seals >= 0, seals & requiredSeals == requiredSeals else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
        }
        var contents = Data()
        contents.reserveCapacity(metadata.byteLength)
        var offset: Int = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < metadata.byteLength {
            let count = min(buffer.count, metadata.byteLength - offset)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                pread(fd, bytes.baseAddress, count, off_t(offset))
            }
            guard readCount > 0 else { throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor }
            contents.append(buffer, count: readCount)
            offset += readCount
        }
        guard contents.count == metadata.byteLength,
              PlatformCrypto.sha256Hex(contents) == metadata.sha256,
              lseek(fd, 0, SEEK_SET) == 0 else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
        }
    }

    private static func performSocketExchange(
        _ request: Data,
        socketPath: String,
        timeout: TimeInterval,
        expectedOwnerUID: uid_t,
        expectedOwnerGID: gid_t
    ) throws -> BurnBarLinuxAttestationBrokerPacket {
        guard timeout > 0, request.count <= maximumFrameBytes + 4 else {
            throw BurnBarLinuxAttestationBrokerClientError.requestTooLarge
        }
        try validateSocketPath(socketPath, expectedOwnerUID: expectedOwnerUID, expectedOwnerGID: expectedOwnerGID)
        let type = Int32(SOCK_SEQPACKET.rawValue) | Int32(SOCK_CLOEXEC.rawValue) | Int32(SOCK_NONBLOCK.rawValue)
        let fd = Glibc.socket(AF_UNIX, type, 0)
        guard fd >= 0 else { throw BurnBarLinuxAttestationBrokerClientError.unavailable }
        defer { _ = Glibc.close(fd) }
        let deadline = monotonicNow() + timeout
        var address = try socketAddress(socketPath)
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN,
                  try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) else {
                throw BurnBarLinuxAttestationBrokerClientError.unavailable
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                throw BurnBarLinuxAttestationBrokerClientError.unavailable
            }
        }
        try validatePeer(fd, expectedUID: expectedOwnerUID, expectedGID: expectedOwnerGID)
        try validateSocketPath(socketPath, expectedOwnerUID: expectedOwnerUID, expectedOwnerGID: expectedOwnerGID)

        try sendAtomic(request, fd: fd, deadline: deadline)
        return try receivePacket(fd: fd, deadline: deadline)
    }

    private static func validateSocketPath(
        _ path: String,
        expectedOwnerUID: uid_t,
        expectedOwnerGID: gid_t
    ) throws {
        guard path == productionSocketPath || path.hasPrefix("/"),
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidSocket
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var parentStatus = stat()
        var socketStatus = stat()
        guard lstat(parent, &parentStatus) == 0,
              parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == expectedOwnerUID,
              parentStatus.st_gid == expectedOwnerGID,
              parentStatus.st_mode & 0o022 == 0,
              lstat(path, &socketStatus) == 0,
              socketStatus.st_mode & S_IFMT == S_IFSOCK,
              socketStatus.st_uid == expectedOwnerUID,
              socketStatus.st_gid == expectedOwnerGID else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidSocket
        }
    }

    private static func validatePeer(_ fd: Int32, expectedUID: uid_t, expectedGID: gid_t) throws {
        var credentials = PeerCredentials()
        var length = socklen_t(MemoryLayout<PeerCredentials>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0,
              length == socklen_t(MemoryLayout<PeerCredentials>.size),
              credentials.pid > 0,
              credentials.uid == expectedUID,
              credentials.gid == expectedGID else {
            throw BurnBarLinuxAttestationBrokerClientError.unauthorizedPeer
        }
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidSocket
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        return address
    }

    private static func sendAtomic(_ data: Data, fd: Int32, deadline: TimeInterval) throws {
        while true {
            try Task.checkCancellation()
            let sent = data.withUnsafeBytes { raw in
                Glibc.send(fd, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            }
            if sent == data.count { return }
            if sent >= 0 { throw BurnBarLinuxAttestationBrokerClientError.invalidSocket }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline) else {
                    throw BurnBarLinuxAttestationBrokerClientError.timedOut
                }
                continue
            }
            throw BurnBarLinuxAttestationBrokerClientError.unavailable
        }
    }

    private static func receivePacket(fd: Int32, deadline: TimeInterval) throws -> BurnBarLinuxAttestationBrokerPacket {
        var payload = [UInt8](repeating: 0, count: maximumFrameBytes + 5)
        var control = [UInt8](repeating: 0, count: 128)
        while true {
            try Task.checkCancellation()
            var message = msghdr()
            let received = payload.withUnsafeMutableBytes { payloadBytes in
                control.withUnsafeMutableBytes { controlBytes in
                    var iov = iovec(iov_base: payloadBytes.baseAddress, iov_len: payloadBytes.count)
                    return withUnsafeMutablePointer(to: &iov) { iovPointer in
                        message.msg_iov = iovPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlBytes.baseAddress
                        message.msg_controllen = controlBytes.count
                        return recvmsg(fd, &message, Int32(MSG_CMSG_CLOEXEC))
                    }
                }
            }
            if received >= 0 {
                let descriptors = try receivedDescriptors(control: control, length: message.msg_controllen)
                guard message.msg_flags & Int32(MSG_TRUNC | MSG_CTRUNC) == 0,
                      received <= maximumFrameBytes + 4 else {
                    closeDescriptors(descriptors)
                    throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
                }
                return BurnBarLinuxAttestationBrokerPacket(
                    payload: Data(payload.prefix(received)),
                    descriptors: descriptors
                )
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                guard try wait(fd: fd, events: Int16(POLLIN), deadline: deadline) else {
                    throw BurnBarLinuxAttestationBrokerClientError.timedOut
                }
                continue
            }
            throw BurnBarLinuxAttestationBrokerClientError.unavailable
        }
    }

    private static func receivedDescriptors(control: [UInt8], length: Int) throws -> [Int32] {
        let headerBytes = MemoryLayout<cmsghdr>.size
        let alignedHeader = align(headerBytes)
        var descriptors: [Int32] = []
        var offset = 0
        while offset + headerBytes <= length {
            let header: cmsghdr = control.withUnsafeBytes { raw in
                raw.baseAddress!.advanced(by: offset).loadUnaligned(as: cmsghdr.self)
            }
            let cmsgLength = Int(header.cmsg_len)
            guard cmsgLength >= alignedHeader, offset + cmsgLength <= length else {
                closeDescriptors(descriptors)
                throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
            }
            if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS {
                let dataLength = cmsgLength - alignedHeader
                guard dataLength > 0, dataLength % MemoryLayout<Int32>.size == 0 else {
                    closeDescriptors(descriptors)
                    throw BurnBarLinuxAttestationBrokerClientError.invalidResponse
                }
                let count = dataLength / MemoryLayout<Int32>.size
                for index in 0..<count {
                    let descriptor: Int32 = control.withUnsafeBytes { raw in
                        raw.baseAddress!.advanced(by: offset + alignedHeader + index * MemoryLayout<Int32>.size)
                            .loadUnaligned(as: Int32.self)
                    }
                    descriptors.append(descriptor)
                }
            }
            offset += align(cmsgLength)
        }
        guard descriptors.count <= 1 else {
            closeDescriptors(descriptors)
            throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
        }
        return descriptors
    }

    private static func align(_ value: Int) -> Int {
        let alignment = MemoryLayout<Int>.size
        return (value + alignment - 1) & ~(alignment - 1)
    }

    private static func wait(fd: Int32, events: Int16, deadline: TimeInterval) throws -> Bool {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - monotonicNow()
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(max(1, min(50, Int(remaining * 1_000))))
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                    throw BurnBarLinuxAttestationBrokerClientError.unavailable
                }
                if descriptor.revents & events != 0 { return true }
                if descriptor.revents & Int16(POLLHUP) != 0 { return true }
            } else if result < 0, errno != EINTR {
                throw BurnBarLinuxAttestationBrokerClientError.unavailable
            }
        }
    }

    private static func monotonicNow() -> TimeInterval {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &value) == 0 else { return 0 }
        return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { _ = Glibc.close(descriptor) }
    }
}
#endif
