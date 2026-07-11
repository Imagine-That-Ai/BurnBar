#if os(Linux)
@testable import OpenBurnBarDaemon
import Foundation
import Glibc
import OpenBurnBarCore
import XCTest

final class BurnBarLinuxProductionAppCheckAttestationProviderTests: XCTestCase {
    func testBuildsReceiptNativeEvidenceAndKeepsTicketSecretOutOfResult() async throws {
        let fixture = try Fixture()
        let uploader = RecordingUploader(receipt: fixture.receipt)
        let secret = Data((0..<32).map { UInt8($0) })
        let provider = BurnBarLinuxProductionAppCheckAttestationProvider(
            broker: fixture.broker,
            uploader: uploader,
            credentialFactory: { try BurnBarLinuxAttestationTicketCredential(secret: secret) }
        )

        let binding = try await provider.makeBinding(appID: fixture.binding.appId)
        XCTAssertEqual(binding, fixture.binding)
        let attestation = try await provider.makeAttestation(
            challenge: fixture.challenge,
            binding: fixture.binding,
            idToken: "firebase-id-token"
        )

        XCTAssertEqual(attestation.challengeId, fixture.challenge.challengeId)
        XCTAssertEqual(attestation.challenge, fixture.challenge.challenge)
        XCTAssertEqual(attestation.kind, fixture.binding.attestationKind)
        guard case let .object(evidence) = attestation.evidence,
              case let .object(upload)? = evidence["upload"],
              case let .object(bundle)? = evidence["evidenceBundle"] else {
            return XCTFail("Expected receipt-native evidence")
        }
        XCTAssertEqual(evidence["schemaVersion"], .number(1))
        XCTAssertEqual(evidence["quote"], fixture.quote)
        XCTAssertEqual(upload["uploadId"], .string(fixture.receipt.uploadId))
        XCTAssertEqual(upload["generation"], .string(fixture.receipt.generation))
        XCTAssertEqual(upload["sha256"], .string(fixture.receipt.sha256))
        XCTAssertEqual(upload["size"], .number(Double(fixture.receipt.size)))
        XCTAssertEqual(bundle["byteLength"], .number(Double(fixture.metadata.byteLength)))
        XCTAssertEqual(bundle["sha256"], .string(fixture.metadata.sha256))

        let capture = await uploader.capture()
        XCTAssertEqual(capture?.idToken, "firebase-id-token")
        XCTAssertEqual(capture?.secretHash, "1f19e5b47fa987a92f2c36048a53c385f87eb0b86762fe68a631ef9e55585f7f")
        XCTAssertEqual(
            capture?.wireValue,
            "obbat1_AAECAwQFBgcICQoLDA0ODw.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        )
        let encoded = try JSONEncoder().encode(attestation)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("obbat1_"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        XCTAssertEqual(fcntl(fixture.rawDescriptor, F_GETFD), -1)
    }

    func testUnsupportedBrokerMakesNoUploadCall() async throws {
        let uploader = RecordingUploader(receipt: Self.receipt())
        let provider = BurnBarLinuxProductionAppCheckAttestationProvider(
            broker: FailingBroker(error: BurnBarLinuxAttestationBrokerClientError.unsupported),
            uploader: uploader
        )
        do {
            _ = try await provider.makeBinding(appID: "1:123:web:linux")
            XCTFail("Unsupported broker must fail closed")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .attestationUnavailable)
        }
        let capture = await uploader.capture()
        XCTAssertNil(capture)
    }

    func testOversizedDescriptorFailsBeforeCredentialOrUploadAndClosesDescriptor() async throws {
        let fixture = try Fixture(byteLength: BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes + 1)
        let uploader = RecordingUploader(receipt: fixture.receipt)
        let credentialCalls = LockedCounter()
        let provider = BurnBarLinuxProductionAppCheckAttestationProvider(
            broker: fixture.broker,
            uploader: uploader,
            credentialFactory: {
                credentialCalls.increment()
                return try .random()
            }
        )
        do {
            _ = try await provider.makeAttestation(
                challenge: fixture.challenge,
                binding: fixture.binding,
                idToken: "firebase-id-token"
            )
            XCTFail("Oversized evidence must fail before upload")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .invalidAttestation)
        }
        XCTAssertEqual(credentialCalls.value, 0)
        let capture = await uploader.capture()
        XCTAssertNil(capture)
        XCTAssertEqual(fcntl(fixture.rawDescriptor, F_GETFD), -1)
    }

    func testReceiptMismatchFailsAndClosesDescriptor() async throws {
        let fixture = try Fixture()
        let mismatched = BurnBarLinuxAttestationUploadReceipt(
            uploadId: fixture.receipt.uploadId,
            generation: fixture.receipt.generation,
            sha256: String(repeating: "f", count: 64),
            size: fixture.receipt.size
        )
        let provider = BurnBarLinuxProductionAppCheckAttestationProvider(
            broker: fixture.broker,
            uploader: RecordingUploader(receipt: mismatched)
        )
        do {
            _ = try await provider.makeAttestation(
                challenge: fixture.challenge,
                binding: fixture.binding,
                idToken: "firebase-id-token"
            )
            XCTFail("Mismatched receipt must fail")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .invalidAttestation)
        }
        XCTAssertEqual(fcntl(fixture.rawDescriptor, F_GETFD), -1)
    }

    func testProductionUploaderReusesCredentialReservationAndFreshDescriptorStreamAcrossRetries() async throws {
        let evidence = Data("sealed-tpm-ima-evidence".utf8)
        let descriptor = try makeTemporaryDescriptor(bytes: evidence)
        let metadata = BurnBarLinuxAttestationEvidenceBundleMetadata(
            descriptorIndex: 0,
            format: BurnBarLinuxAttestationEvidenceBundleMetadata.formatV1,
            byteLength: evidence.count,
            sha256: PlatformCrypto.sha256Hex(evidence)
        )
        let evidenceDescriptor = BurnBarLinuxAttestationEvidenceDescriptor(
            fileDescriptor: descriptor,
            metadata: metadata
        )
        let binding = try Fixture().binding
        let challenge = BurnBarLinuxAppCheckChallenge(
            challengeId: "challenge-1",
            challenge: String(repeating: "A", count: 43),
            expiresAtMillis: 2_000,
            appId: binding.appId,
            policyId: binding.policyId,
            protocolVersion: 1
        )
        let result = BurnBarLinuxAttestationBrokerResult(
            challengeId: challenge.challengeId,
            challenge: challenge.challenge,
            kind: binding.attestationKind,
            evidence: .object(["schemaVersion": .number(1)]),
            evidenceDescriptor: evidenceDescriptor
        )
        let ticketIssuer = RetryingTicketIssuer(expiresAtMillis: 1_900)
        let ingress = RetryingIngress(
            expectedEvidence: evidence,
            receipt: .init(
                uploadId: "QEFCQ0RFRkdISUpLTE1OTw",
                generation: "123456789",
                sha256: metadata.sha256,
                size: metadata.byteLength
            ),
            reservationExpiresAtMillis: 1_800
        )
        let uploader = EnvironmentBurnBarLinuxAttestationReceiptUploader(
            ticketIssuer: ticketIssuer,
            ingress: ingress,
            nowMillis: { 1_000 },
            sleep: { _ in },
            retryDelaysNanoseconds: [0, 0]
        )
        let credential = try BurnBarLinuxAttestationTicketCredential(secret: Data(repeating: 0x5A, count: 32))

        let receipt = try await uploader.uploadEvidence(
            result: result,
            challenge: challenge,
            binding: binding,
            credential: credential,
            idToken: "firebase-id-token"
        )

        XCTAssertEqual(receipt.uploadId, "QEFCQ0RFRkdISUpLTE1OTw")
        let ticketCallCount = await ticketIssuer.callCount()
        XCTAssertEqual(ticketCallCount, 2)
        let counts = await ingress.callCounts()
        XCTAssertEqual(counts.claims, 2)
        XCTAssertEqual(counts.puts, 3)
        XCTAssertEqual(counts.payloads, [evidence, evidence, evidence])
    }

    func testInvalidIngressEndpointFailsBeforeIssuingUploadTicket() async throws {
        let fixture = try Fixture()
        let ticketIssuer = RetryingTicketIssuer(expiresAtMillis: 1_900)
        let ingress = EnvironmentBurnBarLinuxAttestationIngressClient(
            environment: [:],
            nowMillis: { 1_000 }
        )
        let uploader = EnvironmentBurnBarLinuxAttestationReceiptUploader(
            ticketIssuer: ticketIssuer,
            ingress: ingress,
            nowMillis: { 1_000 },
            sleep: { _ in }
        )

        do {
            _ = try await uploader.uploadEvidence(
                result: fixture.broker.result,
                challenge: fixture.challenge,
                binding: fixture.binding,
                credential: try .random(),
                idToken: "firebase-id-token"
            )
            XCTFail("Invalid ingress endpoint must fail before ticket issuance")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(await ticketIssuer.callCount(), 0)
    }

    private static func receipt(size: Int = 8, sha256: String = String(repeating: "a", count: 64))
        -> BurnBarLinuxAttestationUploadReceipt {
        .init(uploadId: "QEFCQ0RFRkdISUpLTE1OTw", generation: "123456789", sha256: sha256, size: size)
    }

    private func makeTemporaryDescriptor(bytes: Data) throws -> Int32 {
        var template = Array("/tmp/openburnbar-attestation-client.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = template.withUnsafeBufferPointer { unlink($0.baseAddress!) }
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Glibc.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    offset += count
                }
            }
            guard lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            return descriptor
        } catch {
            _ = Glibc.close(descriptor)
            throw error
        }
    }

    private struct Fixture {
        let binding: BurnBarLinuxAppCheckAttestationBinding
        let challenge: BurnBarLinuxAppCheckChallenge
        let quote: BurnBarLinuxAppCheckJSONValue
        let metadata: BurnBarLinuxAttestationEvidenceBundleMetadata
        let receipt: BurnBarLinuxAttestationUploadReceipt
        let rawDescriptor: Int32
        let broker: FakeBroker

        init(byteLength: Int = 8) throws {
            binding = .init(
                appId: "1:123:web:linux",
                deviceId: "ak-sha256:" + String(repeating: "b", count: 64),
                appVersion: "1.0.30",
                architecture: "x86_64",
                releaseDigestSha256: String(repeating: "c", count: 64),
                policyId: "openburnbar-linux-tpm2-ima-v1",
                attestationKind: BurnBarLinuxAttestationIngressContract.attestationKind
            )
            challenge = .init(
                challengeId: "challenge-1",
                challenge: String(repeating: "A", count: 43),
                expiresAtMillis: 1_900_000_300_000,
                appId: binding.appId,
                policyId: binding.policyId,
                protocolVersion: 1
            )
            quote = .object([
                "schemaVersion": .number(1),
                "deviceId": .string(binding.deviceId),
                "quoteAttestationBase64": .string("AQIDBA=="),
                "quoteSignatureBase64": .string("BQYHCA=="),
                "quotePcrValuesBase64": .string("CQoLDA=="),
                "pcrBank": .string("sha256"),
                "pcrSelection": .array([.number(0), .number(2), .number(4), .number(7), .number(10)]),
                "qualifyingDataSha256": .string(String(repeating: "d", count: 64)),
            ])
            metadata = .init(
                descriptorIndex: 0,
                format: BurnBarLinuxAttestationEvidenceBundleMetadata.formatV1,
                byteLength: byteLength,
                sha256: String(repeating: "a", count: 64)
            )
            receipt = BurnBarLinuxProductionAppCheckAttestationProviderTests.receipt(
                size: byteLength,
                sha256: metadata.sha256
            )
            rawDescriptor = Glibc.open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard rawDescriptor >= 0 else { throw POSIXError(.EIO) }
            let result = BurnBarLinuxAttestationBrokerResult(
                challengeId: challenge.challengeId,
                challenge: challenge.challenge,
                kind: binding.attestationKind,
                evidence: quote,
                evidenceDescriptor: .init(fileDescriptor: rawDescriptor, metadata: metadata)
            )
            broker = FakeBroker(binding: binding, result: result)
        }
    }
}

private struct FakeBroker: BurnBarLinuxAttestationBroker {
    let binding: BurnBarLinuxAppCheckAttestationBinding
    let result: BurnBarLinuxAttestationBrokerResult
    func describeBinding() async throws -> BurnBarLinuxAppCheckAttestationBinding { binding }
    func attest(
        challenge _: BurnBarLinuxAppCheckChallenge,
        binding _: BurnBarLinuxAppCheckAttestationBinding
    ) async throws -> BurnBarLinuxAttestationBrokerResult { result }
}

private struct FailingBroker: BurnBarLinuxAttestationBroker {
    let error: Error
    func describeBinding() async throws -> BurnBarLinuxAppCheckAttestationBinding { throw error }
    func attest(
        challenge _: BurnBarLinuxAppCheckChallenge,
        binding _: BurnBarLinuxAppCheckAttestationBinding
    ) async throws -> BurnBarLinuxAttestationBrokerResult { throw error }
}

private actor RecordingUploader: BurnBarLinuxAttestationReceiptUploading {
    struct Capture: Sendable {
        let idToken: String
        let secretHash: String
        let wireValue: String
    }

    private let receipt: BurnBarLinuxAttestationUploadReceipt
    private var captured: Capture?

    init(receipt: BurnBarLinuxAttestationUploadReceipt) { self.receipt = receipt }

    func uploadEvidence(
        result _: BurnBarLinuxAttestationBrokerResult,
        challenge _: BurnBarLinuxAppCheckChallenge,
        binding _: BurnBarLinuxAppCheckAttestationBinding,
        credential: BurnBarLinuxAttestationTicketCredential,
        idToken: String
    ) async throws -> BurnBarLinuxAttestationUploadReceipt {
        captured = Capture(
            idToken: idToken,
            secretHash: credential.secretHashSHA256,
            wireValue: try credential.wireValue(ticketID: "AAECAwQFBgcICQoLDA0ODw")
        )
        return receipt
    }

    func capture() -> Capture? { captured }
}

private actor RetryingTicketIssuer: BurnBarLinuxAttestationUploadTicketIssuing {
    private let expiresAtMillis: Int64
    private var calls = 0
    private var hashes: [String] = []

    init(expiresAtMillis: Int64) { self.expiresAtMillis = expiresAtMillis }

    func issueUploadTicket(
        challenge _: BurnBarLinuxAppCheckChallenge,
        credential: BurnBarLinuxAttestationTicketCredential,
        expectedSHA256 _: String,
        expectedSize _: Int,
        idToken _: String
    ) async throws -> BurnBarLinuxAttestationTicketIssue {
        calls += 1
        hashes.append(credential.secretHashSHA256)
        if calls == 1 { throw BurnBarLinuxAppCheckError.networkUnavailable }
        guard Set(hashes).count == 1 else { throw BurnBarLinuxAppCheckError.invalidAttestation }
        return .init(ticketID: "AAECAwQFBgcICQoLDA0ODw", expiresAtMillis: expiresAtMillis)
    }

    func callCount() -> Int { calls }
}

private actor RetryingIngress: BurnBarLinuxAttestationIngressing {
    private let expectedEvidence: Data
    private let receipt: BurnBarLinuxAttestationUploadReceipt
    private let reservationExpiresAtMillis: Int64
    private var claimCalls = 0
    private var putCalls = 0
    private var credentialHashes: [String] = []
    private var payloads: [Data] = []

    init(
        expectedEvidence: Data,
        receipt: BurnBarLinuxAttestationUploadReceipt,
        reservationExpiresAtMillis: Int64
    ) {
        self.expectedEvidence = expectedEvidence
        self.receipt = receipt
        self.reservationExpiresAtMillis = reservationExpiresAtMillis
    }

    func claimUpload(
        declaration _: BurnBarLinuxAttestationUploadDeclaration,
        ticket _: BurnBarLinuxAttestationTicketIssue,
        credential: BurnBarLinuxAttestationTicketCredential,
        idToken _: String
    ) async throws -> BurnBarLinuxAttestationUploadReservation {
        claimCalls += 1
        credentialHashes.append(credential.secretHashSHA256)
        if claimCalls == 1 { throw BurnBarLinuxAppCheckError.networkUnavailable }
        guard Set(credentialHashes).count == 1 else { throw BurnBarLinuxAppCheckError.invalidAttestation }
        return .init(uploadID: receipt.uploadId, expiresAtMillis: reservationExpiresAtMillis)
    }

    func putEvidence(
        reservation _: BurnBarLinuxAttestationUploadReservation,
        body: any BurnBarLinuxAttestationUploadBody,
        idToken _: String
    ) async throws -> BurnBarLinuxAttestationUploadReceipt {
        putCalls += 1
        let stream = try body.makeInputStream()
        defer { stream.close() }
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 7)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw BurnBarLinuxAppCheckError.invalidAttestation }
            if count == 0 { break }
            payload.append(buffer, count: count)
        }
        guard payload == expectedEvidence else { throw BurnBarLinuxAppCheckError.invalidAttestation }
        payloads.append(payload)
        if putCalls < 3 { throw BurnBarLinuxAppCheckError.networkUnavailable }
        return receipt
    }

    func callCounts() -> (claims: Int, puts: Int, payloads: [Data]) {
        (claimCalls, putCalls, payloads)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
#endif
