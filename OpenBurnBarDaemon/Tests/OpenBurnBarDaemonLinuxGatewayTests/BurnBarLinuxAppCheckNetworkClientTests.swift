@testable import OpenBurnBarDaemon
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif
import Foundation
import XCTest

final class BurnBarLinuxAppCheckNetworkClientTests: XCTestCase {
    private let challengeEndpoint = URL(string: "https://example.com/issueLinuxAppCheckChallenge")!
    private let mintEndpoint = URL(string: "https://example.com/mintLinuxAppCheckToken")!
    private let ticketEndpoint = URL(string: "https://example.com/issueLinuxAttestationUploadTicket")!
    private let ingressEndpoint = URL(string: "https://ingress.example/internal/attestation")!
    private let ticketID = "AAECAwQFBgcICQoLDA0ODw"
    private let uploadID = "QEFCQ0RFRkdISUpLTE1OTw"
    private let nowMillis: Int64 = 1_900_000_000_000

    func testCallableBridgeUsesExactEnvelopesAndReceiptNativeMintEvidence() async throws {
        let recorder = AppCheckRequestRecorder()
        let challengeEndpoint = self.challengeEndpoint
        let ticketEndpoint = self.ticketEndpoint
        let mintEndpoint = self.mintEndpoint
        let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
            challengeEndpoint: challengeEndpoint,
            mintEndpoint: mintEndpoint,
            uploadTicketEndpoint: ticketEndpoint,
            nowMillis: { 1_900_000_000_000 }
        ) { request in
            await recorder.record(request)
            let responseBody: String
            switch request.url {
            case challengeEndpoint: responseBody = Self.challengeBody
            case ticketEndpoint: responseBody = Self.ticketBody
            default: responseBody = Self.mintBody
            }
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let credential = try ticketCredential()
        let digest = String(repeating: "c", count: 64)
        XCTAssertEqual(
            credential.secretHashSHA256,
            "1f19e5b47fa987a92f2c36048a53c385f87eb0b86762fe68a631ef9e55585f7f"
        )

        let challenge = try await client.issueChallenge(binding: binding(), idToken: "firebase-id-token")
        let ticket = try await client.issueUploadTicket(
            challenge: challenge,
            credential: credential,
            expectedSHA256: digest,
            expectedSize: 4_096,
            idToken: "firebase-id-token"
        )
        let response = try await client.mintToken(
            attestation: receiptNativeAttestation(uploadID: uploadID, sha256: digest, size: 4_096),
            idToken: "firebase-id-token"
        )

        XCTAssertEqual(ticket, .init(ticketID: ticketID, expiresAtMillis: 1_900_000_300_000))
        XCTAssertEqual(response.appCheckToken, "app-check-secret")
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-id-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        }

        let challengeRoot = try jsonObject(requests[0])
        XCTAssertEqual(Set(challengeRoot.keys), ["data"])
        let challengeData = try XCTUnwrap(challengeRoot["data"] as? [String: Any])
        XCTAssertEqual(challengeData["deviceId"] as? String, "device-1")
        XCTAssertEqual(challengeData["attestationKind"] as? String, "tpm2_ima_signed_verdict_v1")

        let ticketRoot = try jsonObject(requests[1])
        XCTAssertEqual(Set(ticketRoot.keys), ["data"])
        let ticketData = try XCTUnwrap(ticketRoot["data"] as? [String: Any])
        XCTAssertEqual(
            Set(ticketData.keys),
            ["challengeId", "challenge", "ticketSecretHashSha256", "expectedSha256", "expectedSize"]
        )
        XCTAssertEqual(ticketData["challengeId"] as? String, "challenge-0123456789abcdef")
        XCTAssertEqual(ticketData["ticketSecretHashSha256"] as? String, credential.secretHashSHA256)
        XCTAssertEqual(ticketData["expectedSha256"] as? String, digest)
        XCTAssertEqual(ticketData["expectedSize"] as? Int, 4_096)
        let ticketWireValue = try credential.wireValue(ticketID: ticketID)
        XCTAssertFalse(String(decoding: requests[1].httpBody!, as: UTF8.self).contains(ticketWireValue))

        let mintRoot = try jsonObject(requests[2])
        let mintData = try XCTUnwrap(mintRoot["data"] as? [String: Any])
        let attestation = try XCTUnwrap(mintData["attestation"] as? [String: Any])
        let evidence = try XCTUnwrap(attestation["evidence"] as? [String: Any])
        XCTAssertEqual(Set(evidence.keys), ["schemaVersion", "quote", "evidenceBundle", "upload"])
        let upload = try XCTUnwrap(evidence["upload"] as? [String: Any])
        XCTAssertEqual(upload["uploadId"] as? String, uploadID)
        XCTAssertEqual(upload["generation"] as? String, "generation:prod-1")
        XCTAssertEqual(upload["sha256"] as? String, digest)
        XCTAssertEqual(upload["size"] as? Int, 4_096)
        XCTAssertNil(evidence["bundleBytes"])
    }

    func testIngressClaimAndStreamedPUTUseExactHeadersPathsAndBodies() async throws {
        let recorder = AppCheckRequestRecorder()
        let ingressEndpoint = self.ingressEndpoint
        let uploadID = self.uploadID
        let evidence = Data((0..<4_096).map { UInt8($0 % 251) })
        let body = try BurnBarLinuxAttestationDataUploadBody(data: evidence)
        let client = EnvironmentBurnBarLinuxAttestationIngressClient(
            baseEndpoint: ingressEndpoint,
            nowMillis: { 1_900_000_000_000 }
        ) { request in
            await recorder.record(request)
            let isClaim = request.httpMethod == "POST"
            let responseBody = isClaim
                ? #"{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","expiresAtMillis":1900000300000}"#
                : #"{"receipt":{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","generation":"generation:prod-1","sha256":"\#(body.sha256)","size":4096}}"#
            return (
                Data(responseBody.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: isClaim ? 201 : 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        let credential = try ticketCredential()
        let declaration = uploadDeclaration(sha256: body.sha256, size: body.byteCount)
        let ticket = BurnBarLinuxAttestationTicketIssue(
            ticketID: ticketID,
            expiresAtMillis: 1_900_000_300_000
        )

        let reservation = try await client.claimUpload(
            declaration: declaration,
            ticket: ticket,
            credential: credential,
            idToken: "firebase-id-token"
        )
        let receipt = try await client.putEvidence(
            reservation: reservation,
            body: body,
            idToken: "firebase-id-token"
        )

        XCTAssertEqual(reservation, .init(uploadID: uploadID, expiresAtMillis: 1_900_000_300_000))
        XCTAssertEqual(receipt.uploadId, uploadID)
        XCTAssertEqual(receipt.generation, "generation:prod-1")
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 2)
        let claim = requests[0]
        XCTAssertEqual(claim.httpMethod, "POST")
        XCTAssertEqual(claim.url?.path, "/internal/attestation/v1/evidence-uploads")
        XCTAssertEqual(claim.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-id-token")
        XCTAssertEqual(claim.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(claim.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            claim.value(forHTTPHeaderField: EnvironmentBurnBarLinuxAttestationIngressClient.ticketHeader),
            try credential.wireValue(ticketID: ticketID)
        )
        let claimBody = try jsonObject(claim)
        XCTAssertEqual(
            Set(claimBody.keys),
            [
                "protocolVersion", "attestationKind", "appId", "deviceId", "challengeId",
                "releaseDigestSha256", "expectedSha256", "expectedSize",
            ]
        )
        XCTAssertEqual(claimBody["expectedSha256"] as? String, body.sha256)
        XCTAssertEqual(claimBody["expectedSize"] as? Int, body.byteCount)

        let put = requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, "/internal/attestation/v1/evidence-uploads/\(uploadID)")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-id-token")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Length"), "4096")
        XCTAssertNil(put.value(forHTTPHeaderField: EnvironmentBurnBarLinuxAttestationIngressClient.ticketHeader))
        XCTAssertFalse(put.url!.absoluteString.contains(try credential.wireValue(ticketID: ticketID)))
        XCTAssertEqual(put.httpBody, evidence)
    }

    func testIngressExpiryCanonicalIDsAndResponseSchemaFailClosed() async throws {
        let credential = try ticketCredential()
        let dataBody = try BurnBarLinuxAttestationDataUploadBody(data: Data("evidence".utf8))
        let declaration = uploadDeclaration(sha256: dataBody.sha256, size: dataBody.byteCount)
        let validTicket = BurnBarLinuxAttestationTicketIssue(ticketID: ticketID, expiresAtMillis: nowMillis + 1)

        let expiredTicketClient = ingressClient(response: Self.reservationBody)
        await assertIngressError(.invalidRequest) {
            _ = try await expiredTicketClient.claimUpload(
                declaration: declaration,
                ticket: .init(ticketID: self.ticketID, expiresAtMillis: self.nowMillis),
                credential: credential,
                idToken: "id-token"
            )
        }

        for responseBody in [
            #"{"uploadId":"not-canonical","expiresAtMillis":1900000300000}"#,
            #"{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","expiresAtMillis":1900000000000}"#,
            #"{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","expiresAtMillis":1900000300000,"extra":true}"#,
        ] {
            let client = ingressClient(response: responseBody)
            await assertIngressError(.invalidResponse) {
                _ = try await client.claimUpload(
                    declaration: declaration,
                    ticket: validTicket,
                    credential: credential,
                    idToken: "id-token"
                )
            }
        }

        let expiredReservation = BurnBarLinuxAttestationUploadReservation(
            uploadID: uploadID,
            expiresAtMillis: nowMillis
        )
        await assertIngressError(.invalidRequest) {
            _ = try await expiredTicketClient.putEvidence(
                reservation: expiredReservation,
                body: dataBody,
                idToken: "id-token"
            )
        }
    }

    func testIngressClassifiesTerminalAndRetryableHTTPStatuses() async throws {
        let credential = try ticketCredential()
        let body = try BurnBarLinuxAttestationDataUploadBody(data: Data("evidence".utf8))
        let declaration = uploadDeclaration(sha256: body.sha256, size: body.byteCount)
        let ticket = BurnBarLinuxAttestationTicketIssue(ticketID: ticketID, expiresAtMillis: nowMillis + 1)

        for status in [400, 401, 403, 409, 413, 422] {
            let client = ingressClient(response: #"{"error":"rejected"}"#, status: status)
            await assertIngressError(.terminalHTTPStatus(status), retryable: false) {
                _ = try await client.claimUpload(
                    declaration: declaration,
                    ticket: ticket,
                    credential: credential,
                    idToken: "id-token"
                )
            }
        }
        for status in [408, 425, 429, 500, 503] {
            let client = ingressClient(response: #"{"error":"retry"}"#, status: status)
            await assertIngressError(.retryableHTTPStatus(status), retryable: true) {
                _ = try await client.claimUpload(
                    declaration: declaration,
                    ticket: ticket,
                    credential: credential,
                    idToken: "id-token"
                )
            }
        }
        XCTAssertTrue(BurnBarLinuxAttestationIngressClientError.networkUnavailable.isRetryable)
    }

    func testIngressReceiptRequiresExactMatchingFieldsAndSchemaGeneration() async throws {
        let body = try BurnBarLinuxAttestationDataUploadBody(data: Data("evidence".utf8))
        let reservation = BurnBarLinuxAttestationUploadReservation(
            uploadID: uploadID,
            expiresAtMillis: nowMillis + 1
        )
        let validReceipt = #"{"receipt":{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","generation":"A.b_c:d-1","sha256":"\#(body.sha256)","size":8}}"#
        let validClient = ingressClient(response: validReceipt, status: 200)
        let receipt = try await validClient.putEvidence(reservation: reservation, body: body, idToken: "id-token")
        XCTAssertEqual(receipt.generation, "A.b_c:d-1")

        let invalidBodies = [
            #"{"receipt":{"uploadId":"AAECAwQFBgcICQoLDA0ODw","generation":"1","sha256":"\#(body.sha256)","size":8}}"#,
            #"{"receipt":{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","generation":"1","sha256":"\#(String(repeating: "f", count: 64))","size":8}}"#,
            #"{"receipt":{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","generation":"bad/generation","sha256":"\#(body.sha256)","size":8}}"#,
            #"{"receipt":{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","generation":"1","sha256":"\#(body.sha256)","size":9}}"#,
            #"{"receipt":{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","generation":"1","sha256":"\#(body.sha256)","size":8,"extra":true}}"#,
        ]
        for response in invalidBodies {
            let client = ingressClient(response: response, status: 200)
            await assertIngressError(.invalidResponse) {
                _ = try await client.putEvidence(reservation: reservation, body: body, idToken: "id-token")
            }
        }
    }

    func testStrictEndpointsRequiredOverridesAndRedirectsFailClosed() async throws {
        XCTAssertNil(EnvironmentBurnBarLinuxAppCheckCloudClient.validEndpoint(" https://example.com/mint "))
        for endpoint in [
            "http://example.com/mint",
            "https://user@example.com/mint",
            "https://example.com/mint?query=1",
            "https://example.com/mint#fragment",
        ] {
            XCTAssertNil(EnvironmentBurnBarLinuxAppCheckCloudClient.validEndpoint(endpoint))
            XCTAssertNil(EnvironmentBurnBarLinuxAttestationIngressClient.validBaseEndpoint(endpoint))
        }
        XCTAssertNil(EnvironmentBurnBarLinuxAttestationIngressClient.validBaseEndpoint(" https://example.com/ingress "))

        AppCheckSuspendedURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppCheckSuspendedURLProtocol.self]
        let invalidCloud = EnvironmentBurnBarLinuxAppCheckCloudClient(
            environment: ["OPENBURNBAR_LINUX_APP_CHECK_MINT_ENDPOINT": "http://example.com/mint"],
            session: URLSession(configuration: configuration)
        )
        await assertAppCheckError(.invalidResponse) {
            _ = try await invalidCloud.mintToken(attestation: self.attestation(), idToken: "id-token")
        }
        let invalidChallenge = EnvironmentBurnBarLinuxAppCheckCloudClient(
            environment: ["OPENBURNBAR_LINUX_APP_CHECK_CHALLENGE_ENDPOINT": "https://example.com/challenge?bad=1"],
            session: URLSession(configuration: configuration)
        )
        await assertAppCheckError(.invalidResponse) {
            _ = try await invalidChallenge.issueChallenge(binding: self.binding(), idToken: "id-token")
        }
        let invalidTicket = EnvironmentBurnBarLinuxAppCheckCloudClient(
            environment: ["OPENBURNBAR_LINUX_ATTESTATION_UPLOAD_TICKET_ENDPOINT": " https://example.com/ticket"],
            session: URLSession(configuration: configuration)
        )
        await assertAppCheckError(.invalidResponse) {
            _ = try await invalidTicket.issueUploadTicket(
                challenge: self.challenge(),
                credential: try self.ticketCredential(),
                expectedSHA256: String(repeating: "c", count: 64),
                expectedSize: 4_096,
                idToken: "id-token"
            )
        }
        XCTAssertFalse(AppCheckSuspendedURLProtocol.started)

        let missingIngress = EnvironmentBurnBarLinuxAttestationIngressClient(
            environment: [:],
            session: URLSession(configuration: configuration),
            nowMillis: { 1_900_000_000_000 }
        )
        let body = try BurnBarLinuxAttestationDataUploadBody(data: Data("evidence".utf8))
        await assertIngressError(.invalidConfiguration) {
            _ = try await missingIngress.putEvidence(
                reservation: .init(uploadID: self.uploadID, expiresAtMillis: self.nowMillis + 1),
                body: body,
                idToken: "id-token"
            )
        }
        XCTAssertFalse(AppCheckSuspendedURLProtocol.started)

        let redirected = EnvironmentBurnBarLinuxAttestationIngressClient(
            baseEndpoint: ingressEndpoint,
            nowMillis: { 1_900_000_000_000 }
        ) { _ in
            (
                Data(Self.reservationBody.utf8),
                HTTPURLResponse(
                    url: URL(string: "https://redirect.example/v1/evidence-uploads")!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        await assertIngressError(.invalidResponse) {
            _ = try await redirected.claimUpload(
                declaration: self.uploadDeclaration(sha256: body.sha256, size: body.byteCount),
                ticket: .init(ticketID: self.ticketID, expiresAtMillis: self.nowMillis + 1),
                credential: try self.ticketCredential(),
                idToken: "id-token"
            )
        }
    }

    func testCallableMalformedOversizedAndFalseSuccessResponsesFailClosed() async throws {
        let cases: [(Data, HTTPURLResponse, BurnBarLinuxAppCheckError)] = [
            (
                Data(Self.mintBody.utf8),
                HTTPURLResponse(
                    url: URL(string: "https://redirect.example/mint")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                .invalidResponse
            ),
            (
                Data(repeating: 0x61, count: EnvironmentBurnBarLinuxAppCheckCloudClient.maximumResponseBytes + 1),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                .invalidResponse
            ),
            (
                Data(#"{"result":{"ok":true}}"#.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                .invalidResponse
            ),
            (
                Data(#"{"result":{"ok":false,"appCheckToken":"token","issuedAtMillis":1,"expireTimeMillis":2,"appId":"app","trustClass":"linux_lower_trust"}}"#.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                .invalidResponse
            ),
            (
                Data(#"{"result":{"ok":true,"appCheckToken":"token","issuedAtMillis":1,"expireTimeMillis":2,"appId":"app","trustClass":"linux_lower_trust"},"extra":true}"#.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                .invalidResponse
            ),
            (
                Data(#"{"error":{"status":"UNAUTHENTICATED"}}"#.utf8),
                HTTPURLResponse(url: mintEndpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                .invalidResponse
            ),
        ]

        for (body, response, expectedError) in cases {
            let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
                challengeEndpoint: challengeEndpoint,
                mintEndpoint: mintEndpoint
            ) { _ in (body, response) }
            await assertAppCheckError(expectedError) {
                _ = try await client.mintToken(attestation: self.attestation(), idToken: "id-token")
            }
        }

        for status in [400, 401, 403, 409, 413, 422] {
            let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
                challengeEndpoint: challengeEndpoint,
                mintEndpoint: mintEndpoint
            ) { request in
                (
                    Data(#"{"error":{"status":"REJECTED"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            }
            await assertAppCheckError(.invalidResponse) {
                _ = try await client.mintToken(attestation: self.attestation(), idToken: "id-token")
            }
        }
        for status in [408, 425, 429, 500, 503] {
            let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
                challengeEndpoint: challengeEndpoint,
                mintEndpoint: mintEndpoint
            ) { request in
                (
                    Data(#"{"error":{"status":"RETRYABLE"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            }
            await assertAppCheckError(.networkUnavailable) {
                _ = try await client.mintToken(attestation: self.attestation(), idToken: "id-token")
            }
        }

        let expiredTicketClient = EnvironmentBurnBarLinuxAppCheckCloudClient(
            challengeEndpoint: challengeEndpoint,
            mintEndpoint: mintEndpoint,
            uploadTicketEndpoint: ticketEndpoint,
            nowMillis: { 1_900_000_300_000 }
        ) { request in
            (
                Data(Self.ticketBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        await assertAppCheckError(.invalidResponse) {
            _ = try await expiredTicketClient.issueUploadTicket(
                challenge: self.challenge(),
                credential: try self.ticketCredential(),
                expectedSHA256: String(repeating: "c", count: 64),
                expectedSize: 4_096,
                idToken: "id-token"
            )
        }

        for ticketResponse in [
            #"{"result":{"ok":false,"ticketId":"AAECAwQFBgcICQoLDA0ODw","expiresAtMillis":1900000300000}}"#,
            #"{"result":{"ok":true,"ticketId":"AAECAwQFBgcICQoLDA0ODw","expiresAtMillis":1900000300000,"extra":true}}"#,
            #"{"result":{"ok":true,"ticketId":"AAECAwQFBgcICQoLDA0ODw","expiresAtMillis":1900000300000},"extra":true}"#,
        ] {
            let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
                challengeEndpoint: challengeEndpoint,
                mintEndpoint: mintEndpoint,
                uploadTicketEndpoint: ticketEndpoint,
                nowMillis: { 1_900_000_000_000 }
            ) { request in
                (
                    Data(ticketResponse.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            await assertAppCheckError(.invalidResponse) {
                _ = try await client.issueUploadTicket(
                    challenge: self.challenge(),
                    credential: try self.ticketCredential(),
                    expectedSHA256: String(repeating: "c", count: 64),
                    expectedSize: 4_096,
                    idToken: "id-token"
                )
            }
        }
    }

    func testRequestAndEvidenceBoundsRejectBeforeTransport() async throws {
        let recorder = AppCheckRequestRecorder()
        let client = EnvironmentBurnBarLinuxAppCheckCloudClient(
            challengeEndpoint: challengeEndpoint,
            mintEndpoint: mintEndpoint
        ) { request in
            await recorder.record(request)
            return (
                Data(Self.mintBody.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let oversized = String(repeating: "a", count: EnvironmentBurnBarLinuxAppCheckCloudClient.maximumRequestBytes)
        await assertAppCheckError(.invalidAttestation) {
            _ = try await client.mintToken(
                attestation: .init(
                    challengeId: "challenge-0123456789abcdef",
                    challenge: "nonce-0123456789abcdef0123456789",
                    kind: "tpm2_ima_signed_verdict_v1",
                    evidence: .object(["quote": .string(oversized)])
                ),
                idToken: "id-token"
            )
        }
        let callableRequests = await recorder.requests()
        XCTAssertEqual(callableRequests.count, 0)

        let ingressRecorder = AppCheckRequestRecorder()
        let ingress = EnvironmentBurnBarLinuxAttestationIngressClient(
            baseEndpoint: ingressEndpoint,
            nowMillis: { 1_900_000_000_000 }
        ) { request in
            await ingressRecorder.record(request)
            throw URLError(.badServerResponse)
        }
        await assertIngressError(.invalidRequest) {
            _ = try await ingress.putEvidence(
                reservation: .init(uploadID: self.uploadID, expiresAtMillis: self.nowMillis + 1),
                body: DeclaredUploadBody(
                    byteCount: BurnBarLinuxAttestationIngressContract.maximumEvidenceBytes + 1,
                    sha256: String(repeating: "a", count: 64)
                ),
                idToken: "id-token"
            )
        }
        let ingressRequests = await ingressRecorder.requests()
        XCTAssertEqual(ingressRequests.count, 0)
    }

    func testBoundedResponseBufferAndMemoryOnlySession() {
        var buffer = BurnBarLinuxAppCheckBoundedResponseBuffer(maximumBytes: 8)
        XCTAssertTrue(buffer.append(Data(repeating: 0x61, count: 5)))
        XCTAssertFalse(buffer.append(Data(repeating: 0x62, count: 4)))
        XCTAssertEqual(buffer.data, Data(repeating: 0x61, count: 5))

        let source = URLSessionConfiguration.default
        source.urlCache = URLCache(memoryCapacity: 1_024, diskCapacity: 1_024, diskPath: nil)
        source.httpShouldSetCookies = true
        let hardened = EnvironmentBurnBarLinuxAppCheckCloudClient.hardenedConfiguration(from: source)
        XCTAssertNil(hardened.urlCache)
        XCTAssertNil(hardened.httpCookieStorage)
        XCTAssertFalse(hardened.httpShouldSetCookies)
        XCTAssertNil(hardened.urlCredentialStorage)
        XCTAssertEqual(hardened.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testTaskCancellationStopsUnderlyingCallableAndIngressTasks() async throws {
        try await assertCancellationStopsURLSessionTask {
            EnvironmentBurnBarLinuxAppCheckCloudClient(
                environment: [
                    "OPENBURNBAR_LINUX_APP_CHECK_CHALLENGE_ENDPOINT": self.challengeEndpoint.absoluteString,
                    "OPENBURNBAR_LINUX_APP_CHECK_MINT_ENDPOINT": self.mintEndpoint.absoluteString,
                ],
                session: $0
            )
        } operation: { client in
            _ = try await client.mintToken(attestation: self.attestation(), idToken: "id-token")
        }

        AppCheckSuspendedURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppCheckSuspendedURLProtocol.self]
        let ingress = EnvironmentBurnBarLinuxAttestationIngressClient(
            environment: ["OPENBURNBAR_LINUX_ATTESTATION_INGRESS_ENDPOINT": ingressEndpoint.absoluteString],
            session: URLSession(configuration: configuration),
            nowMillis: { 1_900_000_000_000 }
        )
        let body = try BurnBarLinuxAttestationDataUploadBody(data: Data("evidence".utf8))
        let request = Task {
            try await ingress.putEvidence(
                reservation: .init(uploadID: uploadID, expiresAtMillis: nowMillis + 1),
                body: body,
                idToken: "id-token"
            )
        }
        try await waitUntil { AppCheckSuspendedURLProtocol.started }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Cancellation must escape as CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { AppCheckSuspendedURLProtocol.stopped }
    }

    private static let challengeBody = #"{"result":{"challengeId":"challenge-0123456789abcdef","challenge":"nonce-0123456789abcdef0123456789","expiresAtMillis":1900000300000,"appId":"1:123:web:linux","policyId":"openburnbar-linux-tpm2-ima-v1","protocolVersion":1}}"#
    private static let ticketBody = #"{"result":{"ok":true,"ticketId":"AAECAwQFBgcICQoLDA0ODw","expiresAtMillis":1900000300000}}"#
    private static let reservationBody = #"{"uploadId":"QEFCQ0RFRkdISUpLTE1OTw","expiresAtMillis":1900000300000}"#
    private static let mintBody = #"{"result":{"ok":true,"appCheckToken":"app-check-secret","issuedAtMillis":1900000000000,"expireTimeMillis":1900001800000,"appId":"1:123:web:linux","trustClass":"linux_lower_trust"}}"#

    private func binding() -> BurnBarLinuxAppCheckAttestationBinding {
        .init(
            appId: "1:123:web:linux",
            deviceId: "device-1",
            appVersion: "1.0.0",
            architecture: "x86_64",
            releaseDigestSha256: String(repeating: "a", count: 64),
            policyId: "openburnbar-linux-tpm2-ima-v1",
            attestationKind: "tpm2_ima_signed_verdict_v1"
        )
    }

    private func challenge() -> BurnBarLinuxAppCheckChallenge {
        .init(
            challengeId: "challenge-0123456789abcdef",
            challenge: "nonce-0123456789abcdef0123456789",
            expiresAtMillis: 1_900_000_300_000,
            appId: "1:123:web:linux",
            policyId: "openburnbar-linux-tpm2-ima-v1",
            protocolVersion: 1
        )
    }

    private func attestation() -> BurnBarLinuxAppCheckAttestation {
        .init(
            challengeId: "challenge-0123456789abcdef",
            challenge: "nonce-0123456789abcdef0123456789",
            kind: "tpm2_ima_signed_verdict_v1",
            evidence: .object(["quote": .string("signed-quote")])
        )
    }

    private func receiptNativeAttestation(uploadID: String, sha256: String, size: Int) -> BurnBarLinuxAppCheckAttestation {
        .init(
            challengeId: "challenge-0123456789abcdef",
            challenge: "nonce-0123456789abcdef0123456789",
            kind: "tpm2_ima_signed_verdict_v1",
            evidence: .object([
                "schemaVersion": .number(1),
                "quote": .object([
                    "schemaVersion": .number(1),
                    "deviceId": .string("device-1"),
                ]),
                "evidenceBundle": .object([
                    "descriptorIndex": .number(0),
                    "format": .string("openburnbar_tpm_evidence_bundle_v1"),
                    "byteLength": .number(Double(size)),
                    "sha256": .string(sha256),
                ]),
                "upload": .object([
                    "uploadId": .string(uploadID),
                    "generation": .string("generation:prod-1"),
                    "sha256": .string(sha256),
                    "size": .number(Double(size)),
                ]),
            ])
        )
    }

    private func ticketCredential() throws -> BurnBarLinuxAttestationTicketCredential {
        try .init(secret: Data((0..<32).map(UInt8.init)))
    }

    private func uploadDeclaration(sha256: String, size: Int) -> BurnBarLinuxAttestationUploadDeclaration {
        .init(
            appID: "1:123:web:linux",
            deviceID: "device-1",
            challengeID: "challenge-0123456789abcdef",
            releaseDigestSHA256: String(repeating: "a", count: 64),
            expectedSHA256: sha256,
            expectedSize: size
        )
    }

    private func ingressClient(
        response: String,
        status: Int = 201
    ) -> EnvironmentBurnBarLinuxAttestationIngressClient {
        EnvironmentBurnBarLinuxAttestationIngressClient(
            baseEndpoint: ingressEndpoint,
            nowMillis: { 1_900_000_000_000 }
        ) { request in
            (
                Data(response.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func assertAppCheckError(
        _ expected: BurnBarLinuxAppCheckError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Operation should fail closed")
        } catch let error as BurnBarLinuxAppCheckError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertIngressError(
        _ expected: BurnBarLinuxAttestationIngressClientError,
        retryable: Bool? = nil,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Operation should fail closed")
        } catch let error as BurnBarLinuxAttestationIngressClientError {
            XCTAssertEqual(error, expected)
            if let retryable { XCTAssertEqual(error.isRetryable, retryable) }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertCancellationStopsURLSessionTask<Client>(
        makeClient: (URLSession) -> Client,
        operation: @escaping (Client) async throws -> Void
    ) async throws {
        AppCheckSuspendedURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppCheckSuspendedURLProtocol.self]
        let client = makeClient(URLSession(configuration: configuration))
        let request = Task { try await operation(client) }
        try await waitUntil { AppCheckSuspendedURLProtocol.started }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Cancellation must escape as CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { AppCheckSuspendedURLProtocol.stopped }
    }

    private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<100 where predicate() == false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate())
    }
}

private struct DeclaredUploadBody: BurnBarLinuxAttestationUploadBody {
    let byteCount: Int
    let sha256: String
    func makeInputStream() throws -> InputStream { InputStream(data: Data()) }
}

private actor AppCheckRequestRecorder {
    private var captured: [URLRequest] = []
    func record(_ request: URLRequest) { captured.append(request) }
    func requests() -> [URLRequest] { captured }
}

private final class AppCheckSuspendedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var state = (started: false, stopped: false)

    static var started: Bool { lock.withLock { state.started } }
    static var stopped: Bool { lock.withLock { state.stopped } }

    static func reset() {
        lock.withLock { state = (false, false) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        _ = request
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.state.started = true }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.state.stopped = true }
    }
}
