#if os(Linux)
import Foundation
import Glibc

protocol BurnBarLinuxAttestationBroker: Sendable {
    func describeBinding() async throws -> BurnBarLinuxAppCheckAttestationBinding
    func attest(
        challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding
    ) async throws -> BurnBarLinuxAttestationBrokerResult
}

extension BurnBarLinuxAttestationBrokerClient: BurnBarLinuxAttestationBroker {}

protocol BurnBarLinuxAttestationReceiptUploading: Sendable {
    func uploadEvidence(
        result: BurnBarLinuxAttestationBrokerResult,
        challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding,
        credential: BurnBarLinuxAttestationTicketCredential,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationUploadReceipt
}

protocol BurnBarLinuxAttestationUploadTicketIssuing: Sendable {
    func issueUploadTicket(
        challenge: BurnBarLinuxAppCheckChallenge,
        credential: BurnBarLinuxAttestationTicketCredential,
        expectedSHA256: String,
        expectedSize: Int,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationTicketIssue
}

extension EnvironmentBurnBarLinuxAppCheckCloudClient: BurnBarLinuxAttestationUploadTicketIssuing {}

protocol BurnBarLinuxAttestationIngressing: Sendable {
    func claimUpload(
        declaration: BurnBarLinuxAttestationUploadDeclaration,
        ticket: BurnBarLinuxAttestationTicketIssue,
        credential: BurnBarLinuxAttestationTicketCredential,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationUploadReservation

    func putEvidence(
        reservation: BurnBarLinuxAttestationUploadReservation,
        body: any BurnBarLinuxAttestationUploadBody,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationUploadReceipt
}

extension EnvironmentBurnBarLinuxAttestationIngressClient: BurnBarLinuxAttestationIngressing {}

private struct BurnBarLinuxAttestationDescriptorUploadBody: BurnBarLinuxAttestationUploadBody {
    let evidenceDescriptor: BurnBarLinuxAttestationEvidenceDescriptor

    var byteCount: Int { evidenceDescriptor.metadata.byteLength }
    var sha256: String { evidenceDescriptor.metadata.sha256 }

    func makeInputStream() throws -> InputStream {
        let duplicate = try evidenceDescriptor.duplicateForStreaming()
        defer { _ = Glibc.close(duplicate) }
        guard let stream = InputStream(fileAtPath: "/proc/self/fd/\(duplicate)") else {
            throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
        }
        stream.open()
        guard stream.streamStatus == .open || stream.streamStatus == .reading else {
            stream.close()
            throw BurnBarLinuxAttestationBrokerClientError.invalidEvidenceDescriptor
        }
        return stream
    }
}

struct EnvironmentBurnBarLinuxAttestationReceiptUploader: BurnBarLinuxAttestationReceiptUploading {
    typealias Clock = @Sendable () -> Int64
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let ticketIssuer: any BurnBarLinuxAttestationUploadTicketIssuing
    private let ingress: any BurnBarLinuxAttestationIngressing
    private let nowMillis: Clock
    private let sleep: Sleeper
    private let retryDelaysNanoseconds: [UInt64]

    init(
        ticketIssuer: any BurnBarLinuxAttestationUploadTicketIssuing,
        ingress: any BurnBarLinuxAttestationIngressing,
        nowMillis: @escaping Clock = { Int64(Date().timeIntervalSince1970 * 1_000) },
        sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) },
        retryDelaysNanoseconds: [UInt64] = [100_000_000, 300_000_000]
    ) {
        self.ticketIssuer = ticketIssuer
        self.ingress = ingress
        self.nowMillis = nowMillis
        self.sleep = sleep
        self.retryDelaysNanoseconds = Array(retryDelaysNanoseconds.prefix(2))
    }

    func uploadEvidence(
        result: BurnBarLinuxAttestationBrokerResult,
        challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding,
        credential: BurnBarLinuxAttestationTicketCredential,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationUploadReceipt {
        let metadata = result.evidenceDescriptor.metadata
        guard result.challengeId == challenge.challengeId,
              result.challenge == challenge.challenge,
              result.kind == binding.attestationKind,
              challenge.appId == binding.appId,
              challenge.policyId == binding.policyId,
              (1...BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes).contains(metadata.byteLength),
              nowMillis() < challenge.expiresAtMillis else {
            throw BurnBarLinuxAppCheckError.invalidAttestation
        }

        let body = BurnBarLinuxAttestationDescriptorUploadBody(evidenceDescriptor: result.evidenceDescriptor)
        let ticket = try await retry(until: challenge.expiresAtMillis) {
            try await ticketIssuer.issueUploadTicket(
                challenge: challenge,
                credential: credential,
                expectedSHA256: body.sha256,
                expectedSize: body.byteCount,
                idToken: idToken
            )
        }
        guard nowMillis() < ticket.expiresAtMillis,
              ticket.expiresAtMillis <= challenge.expiresAtMillis else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }

        let declaration = BurnBarLinuxAttestationUploadDeclaration(
            appID: binding.appId,
            deviceID: binding.deviceId,
            challengeID: challenge.challengeId,
            releaseDigestSHA256: binding.releaseDigestSha256,
            expectedSHA256: body.sha256,
            expectedSize: body.byteCount
        )
        let reservation = try await retry(until: ticket.expiresAtMillis) {
            try await ingress.claimUpload(
                declaration: declaration,
                ticket: ticket,
                credential: credential,
                idToken: idToken
            )
        }
        guard BurnBarLinuxAttestationTicketCredential.isCanonicalIdentifier(reservation.uploadID),
              nowMillis() < reservation.expiresAtMillis,
              reservation.expiresAtMillis <= ticket.expiresAtMillis else {
            throw BurnBarLinuxAppCheckError.invalidResponse
        }

        return try await retry(until: reservation.expiresAtMillis) {
            try await ingress.putEvidence(reservation: reservation, body: body, idToken: idToken)
        }
    }

    private func retry<T>(until deadlineMillis: Int64, operation: () async throws -> T) async throws -> T {
        var retryIndex = 0
        while true {
            try Task.checkCancellation()
            guard nowMillis() < deadlineMillis else { throw BurnBarLinuxAppCheckError.invalidResponse }
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BurnBarLinuxAttestationIngressClientError {
                guard error.isRetryable, retryIndex < retryDelaysNanoseconds.count else { throw error }
                let delay = retryDelaysNanoseconds[retryIndex]
                retryIndex += 1
                try await waitForRetry(delay, deadlineMillis: deadlineMillis)
            } catch let error as BurnBarLinuxAppCheckError {
                guard error == .networkUnavailable, retryIndex < retryDelaysNanoseconds.count else { throw error }
                let delay = retryDelaysNanoseconds[retryIndex]
                retryIndex += 1
                try await waitForRetry(delay, deadlineMillis: deadlineMillis)
            }
        }
    }

    private func waitForRetry(_ delay: UInt64, deadlineMillis: Int64) async throws {
        let delayMillis = Int64((delay + 999_999) / 1_000_000)
        guard nowMillis() <= deadlineMillis - delayMillis else {
            throw BurnBarLinuxAppCheckError.networkUnavailable
        }
        try await sleep(delay)
    }
}

struct BurnBarLinuxProductionAppCheckAttestationProvider: BurnBarLinuxAppCheckAttestationProviding {
    typealias CredentialFactory = @Sendable () throws -> BurnBarLinuxAttestationTicketCredential

    private let broker: any BurnBarLinuxAttestationBroker
    private let uploader: any BurnBarLinuxAttestationReceiptUploading
    private let credentialFactory: CredentialFactory

    init(
        broker: any BurnBarLinuxAttestationBroker,
        uploader: any BurnBarLinuxAttestationReceiptUploading,
        credentialFactory: @escaping CredentialFactory = BurnBarLinuxAttestationTicketCredential.random
    ) {
        self.broker = broker
        self.uploader = uploader
        self.credentialFactory = credentialFactory
    }

    func makeBinding(appID: String) async throws -> BurnBarLinuxAppCheckAttestationBinding {
        do {
            let binding = try await broker.describeBinding()
            guard binding.appId == appID else { throw BurnBarLinuxAppCheckError.invalidAttestation }
            return binding
        } catch {
            throw map(error)
        }
    }

    func makeAttestation(
        challenge: BurnBarLinuxAppCheckChallenge,
        binding: BurnBarLinuxAppCheckAttestationBinding,
        idToken: String
    ) async throws -> BurnBarLinuxAppCheckAttestation {
        let result: BurnBarLinuxAttestationBrokerResult
        do {
            result = try await broker.attest(challenge: challenge, binding: binding)
        } catch {
            throw map(error)
        }
        defer { result.evidenceDescriptor.closeDescriptor() }

        let metadata = result.evidenceDescriptor.metadata
        guard (1...BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes).contains(metadata.byteLength),
              metadata.descriptorIndex == 0,
              metadata.format == BurnBarLinuxAttestationEvidenceBundleMetadata.formatV1,
              Self.isLowerSHA256(metadata.sha256) else {
            throw BurnBarLinuxAppCheckError.invalidAttestation
        }

        let credential: BurnBarLinuxAttestationTicketCredential
        do {
            credential = try credentialFactory()
        } catch {
            throw BurnBarLinuxAppCheckError.attestationUnavailable
        }
        defer { credential.erase() }

        let receipt: BurnBarLinuxAttestationUploadReceipt
        do {
            receipt = try await uploader.uploadEvidence(
                result: result,
                challenge: challenge,
                binding: binding,
                credential: credential,
                idToken: idToken
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BurnBarLinuxAttestationIngressClientError {
            throw error.isRetryable
                ? BurnBarLinuxAppCheckError.networkUnavailable
                : BurnBarLinuxAppCheckError.invalidAttestation
        } catch let error as BurnBarLinuxAppCheckError {
            throw error
        } catch {
            throw BurnBarLinuxAppCheckError.networkUnavailable
        }

        guard receipt.size == metadata.byteLength,
              receipt.sha256 == metadata.sha256,
              BurnBarLinuxAttestationTicketCredential.isCanonicalIdentifier(receipt.uploadId),
              Self.isIdentifier(receipt.generation) else {
            throw BurnBarLinuxAppCheckError.invalidAttestation
        }

        return BurnBarLinuxAppCheckAttestation(
            challengeId: result.challengeId,
            challenge: result.challenge,
            kind: result.kind,
            evidence: .object([
                "schemaVersion": .number(1),
                "quote": result.evidence,
                "evidenceBundle": .object([
                    "descriptorIndex": .number(Double(metadata.descriptorIndex)),
                    "format": .string(metadata.format),
                    "byteLength": .number(Double(metadata.byteLength)),
                    "sha256": .string(metadata.sha256),
                ]),
                "upload": .object([
                    "uploadId": .string(receipt.uploadId),
                    "generation": .string(receipt.generation),
                    "sha256": .string(receipt.sha256),
                    "size": .number(Double(receipt.size)),
                ]),
            ])
        )
    }

    private func map(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? BurnBarLinuxAppCheckError { return error }
        guard let error = error as? BurnBarLinuxAttestationBrokerClientError else {
            return BurnBarLinuxAppCheckError.attestationUnavailable
        }
        switch error {
        case .unsupported, .unavailable, .timedOut, .rateLimited:
            return BurnBarLinuxAppCheckError.attestationUnavailable
        case .invalidSocket, .unauthorizedPeer, .requestTooLarge, .invalidResponse,
             .attestationFailed, .installedReleaseInvalid, .protocolMismatch,
             .invalidEvidenceDescriptor:
            return BurnBarLinuxAppCheckError.invalidAttestation
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 128
            && value.utf8.allSatisfy { byte in
                (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A)
                    || (byte >= 0x30 && byte <= 0x39)
                    || byte == 0x2E
                    || byte == 0x5F
                    || byte == 0x3A
                    || byte == 0x2D
            }
    }

    private static func isLowerSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
            }
    }
}
#endif
