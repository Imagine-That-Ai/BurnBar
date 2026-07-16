#if os(Linux)
import Foundation
import FoundationNetworking
import XCTest
@testable import OpenBurnBarDaemon

final class LinuxCloudDataControlTests: XCTestCase {
    private let baseURL = URL(string: "https://us-central1-burnbar.cloudfunctions.net")!

    private func proof() -> LinuxCloudTrustedDeviceActionProof {
        LinuxCloudTrustedDeviceActionProof(
            deviceSignalIdentityKeyId: "phone-device_1",
            deviceSignalIdentityPublicKeyFingerprint: "fingerprint",
            issuedAtMillis: 2_000_000_000_000,
            signature: String(repeating: "s", count: 88)
        )
    }

    private func exportRequest() -> LinuxCloudDataExportRequest {
        LinuxCloudDataExportRequest(
            domains: ["usage_spend"],
            nonce: "nonce-1",
            trustedDeviceId: "phone-device",
            actionProof: proof()
        )
    }

    private func client(
        response: [String: Any],
        statusCode: Int = 200,
        now: Date = Date(timeIntervalSince1970: 2_000_000_000),
        assertCallableEnvelope: Bool = false
    ) throws -> LinuxCloudAuthHTTPClient {
        let data = try JSONSerialization.data(withJSONObject: response)
        return LinuxCloudAuthHTTPClient(
            allowedHosts: [baseURL.host!],
            transport: { request, _ in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check")
                if assertCallableEnvelope {
                    let body = try XCTUnwrap(request.httpBody)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    XCTAssertNotNil(object["data"])
                }
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: statusCode,
                        httpVersion: "HTTP/2",
                        headerFields: nil
                    )!
                )
            },
            now: { now }
        )
    }

    func testExportForwardsProofHeadersAndReturnsOnlyCallablePayload() async throws {
        let envelope: [String: Any] = [
            "ok": true,
            "generatedAt": "2033-05-18T03:33:20.000Z",
            "schemaVersion": 2,
            "domains": [[
                "id": "usage_spend",
                "encryptionTier": "server_readable",
                "inlineJson": ["count": 1]
            ]]
        ]
        let client = try client(response: ["result": envelope], assertCallableEnvelope: true)
        let output = try await client.exportUserData(
            functionsBaseURL: baseURL,
            idToken: "id-token",
            appCheckToken: "app-check",
            request: exportRequest()
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertNil(object["result"])
    }

    func testExportRejectsSignedOutTokenBeforeTransport() async throws {
        let client = try client(response: ["result": ["ok": true]])
        do {
            _ = try await client.exportUserData(
                functionsBaseURL: baseURL,
                idToken: "",
                appCheckToken: "app-check",
                request: exportRequest()
            )
            XCTFail("signed-out export must fail closed")
        } catch let error as LinuxCloudAuthHTTPError {
            XCTAssertEqual(error, .invalidRequest)
        }
    }

    func testExportRejectsOversizedDomainSelectionBeforeTransport() async throws {
        let transportCalls = DataControlTransportCounter()
        let endpoint = baseURL
        let data = try JSONSerialization.data(withJSONObject: ["result": ["ok": true]])
        let client = LinuxCloudAuthHTTPClient(
            allowedHosts: [endpoint.host!],
            transport: { _, _ in
                await transportCalls.increment()
                return (
                    data,
                    HTTPURLResponse(
                        url: endpoint,
                        statusCode: 200,
                        httpVersion: "HTTP/2",
                        headerFields: nil
                    )!
                )
            },
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        let request = LinuxCloudDataExportRequest(
            domains: (0..<25).map { "domain_\($0)" },
            nonce: "nonce-1",
            trustedDeviceId: "phone-device",
            actionProof: proof()
        )
        do {
            _ = try await client.exportUserData(
                functionsBaseURL: baseURL,
                idToken: "id-token",
                appCheckToken: "app-check",
                request: request
            )
            XCTFail("oversized domain selections must fail before transport")
        } catch let error as LinuxCloudAuthHTTPError {
            XCTAssertEqual(error, .invalidRequest)
        }
        XCTAssertEqual(await transportCalls.value(), 0)
    }

    func testExportRejectsExpiredJWTBeforeTransport() async throws {
        let client = try client(response: ["result": ["ok": true]])
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLEncodedString()
        let payload = Data(#"{"exp":1999999999}"#.utf8).base64URLEncodedString()
        let expired = "\(header).\(payload).signature"
        do {
            _ = try await client.exportUserData(
                functionsBaseURL: baseURL,
                idToken: expired,
                appCheckToken: "app-check",
                request: exportRequest()
            )
            XCTFail("expired token must fail closed")
        } catch let error as LinuxCloudAuthHTTPError {
            guard case let .rejected(stage, status, reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(stage, "data_export")
            XCTAssertEqual(status, 401)
            XCTAssertEqual(reason, "expired_token")
        }
    }

    func testExportRejectsMalformedCallableResponse() async throws {
        let client = try client(response: ["result": ["ok": true, "schemaVersion": 1]])
        do {
            _ = try await client.exportUserData(
                functionsBaseURL: baseURL,
                idToken: "id-token",
                appCheckToken: "app-check",
                request: exportRequest()
            )
            XCTFail("malformed export must fail closed")
        } catch let error as LinuxCloudAuthHTTPError {
            XCTAssertEqual(error, .malformedResponse(stage: "data_export"))
        }
    }

    func testDeleteRequiresExactConfirmationToken() async throws {
        let client = try client(response: ["result": [
            "success": true,
            "cloudDataDeleted": true,
            "retryRequired": false,
            "deletedDocuments": 4,
            "destroyedSecrets": 1,
            "failedSecretDestroys": 0,
            "deletedStoragePrefixes": 2,
            "failedStorageDeletes": 0,
            "deletedAuthUser": true,
            "authUserAlreadyMissing": false
        ]])
        let bad = LinuxCloudDataDeletionRequest(
            confirmation: "delete",
            nonce: "nonce-1",
            trustedDeviceId: "phone-device",
            actionProof: proof()
        )
        do {
            _ = try await client.deleteUserCloudData(
                functionsBaseURL: baseURL,
                idToken: "id-token",
                appCheckToken: "app-check",
                request: bad
            )
            XCTFail("account deletion must require the exact confirmation token")
        } catch let error as LinuxCloudAuthHTTPError {
            XCTAssertEqual(error, .invalidRequest)
        }
    }

    func testDeleteDecodesAuthoritativeSummaryAfterConfirmation() async throws {
        let client = try client(response: ["result": [
            "success": true,
            "cloudDataDeleted": true,
            "retryRequired": false,
            "deletedDocuments": 4,
            "destroyedSecrets": 1,
            "failedSecretDestroys": 0,
            "deletedStoragePrefixes": 2,
            "failedStorageDeletes": 0,
            "deletedAuthUser": true,
            "authUserAlreadyMissing": false
        ]])
        let request = LinuxCloudDataDeletionRequest(
            confirmation: LinuxCloudDataDeletionRequest.confirmationToken,
            nonce: "nonce-1",
            trustedDeviceId: "phone-device",
            actionProof: proof()
        )
        let result = try await client.deleteUserCloudData(
            functionsBaseURL: baseURL,
            idToken: "id-token",
            appCheckToken: "app-check",
            request: request
        )
        XCTAssertEqual(result.deletedDocuments, 4)
        XCTAssertTrue(result.deletedAuthUser)
    }
}

private actor DataControlTransportCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
