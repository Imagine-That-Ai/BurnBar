#if os(Linux)
import Foundation
import FoundationNetworking
import OpenBurnBarIrohRelay
import XCTest
@testable import OpenBurnBarDaemon

private actor LinuxIrohRequestRecorder {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func snapshot() -> URLRequest? { request }
}

private actor LinuxIrohRequestList {
    private var requests: [URLRequest] = []
    private var providerCalls = 0

    func record(_ request: URLRequest) { requests.append(request) }
    func recordProviderCall() { providerCalls += 1 }
    func snapshot() -> [URLRequest] { requests }
    func credentialProviderCallCount() -> Int { providerCalls }
}

final class LinuxIrohControllerDirectoryClientTests: XCTestCase {
    func testPublishesHostKeyAndRecordWithFreshNonceAndBoundCredentials() async throws {
        let recorder = LinuxIrohRequestList()
        let context = LinuxIrohControllerCredentialContext(
            uid: "account-A",
            sessionGeneration: 7,
            idToken: "account-A-id-token",
            appCheckToken: "account-A-app-check",
            deviceID: "linux-device-A"
        )
        let client = LinuxIrohControllerDirectoryClient(
            credentials: { context },
            transport: { request in
                await recorder.record(request)
                let result: [String: Any]
                switch request.url?.path {
                case "/issueHighRiskActionNonce":
                    result = ["nonce": "fresh-nonce"]
                case "/publishIrohPairingPublicKey":
                    result = ["ok": true, "roleId": "host"]
                case "/publishIrohPairingRecord":
                    result = ["ok": true, "connectionId": "linux-host-A"]
                default:
                    throw LinuxIrohControllerDirectoryError.invalidRequest
                }
                let response = try JSONSerialization.data(withJSONObject: ["result": result])
                return (
                    response,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let keypair = IrohPairingKeypair()
        let record = IrohPairingRecord(
            uid: context.uid,
            connectionId: "linux-host-A",
            nodeId: String(repeating: "a", count: 64),
            relayURL: "https://relay.example",
            directAddresses: ["127.0.0.1:4433"],
            publishedAtMillis: 2_000_000_000_000,
            signature: "signature"
        )

        try await client.publishHostPublicKey(keypair)
        try await client.publishHostRecord(record)

        let requests = await recorder.snapshot()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/issueHighRiskActionNonce",
            "/publishIrohPairingPublicKey",
            "/issueHighRiskActionNonce",
            "/publishIrohPairingRecord"
        ])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer account-A-id-token"
                && $0.value(forHTTPHeaderField: "X-Firebase-AppCheck") == "account-A-app-check"
        })
        let payloads = try requests.map { request -> [String: Any] in
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(object["data"] as? [String: Any])
        }
        XCTAssertEqual(payloads[1]["roleId"] as? String, "host")
        XCTAssertEqual(payloads[1]["publicKeyBase64"] as? String, keypair.publicKeyBase64)
        XCTAssertEqual(payloads[3]["connectionId"] as? String, record.connectionId)
        XCTAssertEqual(payloads[3]["nonce"] as? String, "fresh-nonce")
    }

    func testScopedRevokeUsesOldCredentialSnapshotWithoutReacquiringProvider() async throws {
        let recorder = LinuxIrohRequestList()
        let oldContext = LinuxIrohControllerCredentialContext(
            uid: "account-A",
            sessionGeneration: 7,
            idToken: "account-A-id-token",
            appCheckToken: "account-A-app-check",
            deviceID: "linux-device-A"
        )
        let client = LinuxIrohControllerDirectoryClient(
            credentials: {
                await recorder.recordProviderCall()
                throw LinuxIrohControllerDirectoryError.invalidRequest
            },
            transport: { request in
                await recorder.record(request)
                let result: [String: Any]
                if request.url?.path == "/issueHighRiskActionNonce" {
                    result = ["nonce": "old-account-nonce"]
                } else {
                    result = ["ok": true, "connectionId": "linux-host-old"]
                }
                let response = try JSONSerialization.data(withJSONObject: ["result": result])
                return (
                    response,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        try await client.revokeHostRecord(
            connectionID: "linux-host-old",
            credentials: oldContext
        )

        let requests = await recorder.snapshot()
        let providerCalls = await recorder.credentialProviderCallCount()
        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/issueHighRiskActionNonce", "/revokeIrohPairingRecord"
        ])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer account-A-id-token"
                && $0.value(forHTTPHeaderField: "X-Firebase-AppCheck") == "account-A-app-check"
        })
    }

    func testResolveBindsAuthenticatedAccountAndCanonicalRoute() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recorder = LinuxIrohRequestRecorder()
        let context = LinuxIrohControllerCredentialContext(
            uid: "user-1",
            sessionGeneration: 9,
            idToken: "firebase-id-token",
            appCheckToken: "app-check-token",
            deviceID: "linux-device"
        )
        let transportNodeID = String(repeating: "a", count: 64)
        let response = try JSONSerialization.data(withJSONObject: [
            "result": [
                "uid": "user-1",
                "connectionId": "linux-host-1234",
                "resolvedAtMillis": 2_000_000_000_000,
                "routes": [[
                    "connectionId": "linux-host-1234",
                    "sourceDeviceId": "phone-device",
                    "transportNodeId": transportNodeID,
                    "authorityPeerNodeId": "ios-peer",
                    "generation": 4,
                    "registeredAtMillis": 1_999_999_900_000,
                    "expiresAtMillis": 2_000_000_600_000
                ]]
            ]
        ])
        let client = LinuxIrohControllerDirectoryClient(
            credentials: { context },
            transport: { request in
                await recorder.record(request)
                return (
                    response,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/2",
                        headerFields: nil
                    )!
                )
            },
            now: { now }
        )

        let resolvedRoute = try await client.resolveActiveRoute(connectionID: "linux-host-1234")
        let route = try XCTUnwrap(resolvedRoute)

        XCTAssertEqual(route.uid, context.uid)
        XCTAssertEqual(route.accountGeneration, context.sessionGeneration)
        XCTAssertEqual(route.transportNodeID, transportNodeID)
        XCTAssertEqual(route.authorityPeerNodeID, "ios-peer")
        XCTAssertEqual(route.expiresAt, now.addingTimeInterval(600))
        let recordedRequest = await recorder.snapshot()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://us-central1-burnbar.cloudfunctions.net/resolveActiveIrohControllerRoutes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-id-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check-token")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["connectionId"] as? String, "linux-host-1234")
    }

    func testResolveRejectsStaleServerTimeline() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let context = LinuxIrohControllerCredentialContext(
            uid: "user-1",
            sessionGeneration: 1,
            idToken: "id",
            appCheckToken: "app-check",
            deviceID: "linux-device"
        )
        let response = try JSONSerialization.data(withJSONObject: [
            "result": [
                "uid": context.uid,
                "connectionId": "connection",
                "resolvedAtMillis": 1_999_999_000_000,
                "routes": [[
                    "connectionId": "connection",
                    "sourceDeviceId": "phone-device",
                    "transportNodeId": String(repeating: "a", count: 64),
                    "authorityPeerNodeId": "ios-peer",
                    "generation": 1,
                    "registeredAtMillis": 1_999_998_999_000,
                    "expiresAtMillis": 1_999_999_600_000
                ]]
            ]
        ])
        let client = LinuxIrohControllerDirectoryClient(
            credentials: { context },
            transport: { request in
                (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            now: { now }
        )

        do {
            _ = try await client.resolveActiveRoute(connectionID: "connection")
            XCTFail("Expected stale resolver timeline rejection")
        } catch {
            XCTAssertEqual(error as? LinuxIrohControllerDirectoryError, .routeMismatch)
        }
    }

    func testResolveRejectsRouteFromDifferentAuthenticatedAccount() async throws {
        let context = LinuxIrohControllerCredentialContext(
            uid: "user-1",
            sessionGeneration: 1,
            idToken: "id",
            appCheckToken: "app-check",
            deviceID: "linux-device"
        )
        let response = try JSONSerialization.data(withJSONObject: [
            "result": [
                "uid": "user-2",
                "connectionId": "connection",
                "resolvedAtMillis": 2_000_000_000_000,
                "routes": []
            ]
        ])
        let client = LinuxIrohControllerDirectoryClient(
            credentials: { context },
            transport: { request in
                (
                    response,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        do {
            _ = try await client.resolveActiveRoute(connectionID: "connection")
            XCTFail("Expected account-bound route rejection")
        } catch {
            XCTAssertEqual(error as? LinuxIrohControllerDirectoryError, .routeMismatch)
        }
    }

    func testResolveReturnsAuthoritativeEmptyRoute() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let context = LinuxIrohControllerCredentialContext(
            uid: "user-1",
            sessionGeneration: 1,
            idToken: "id",
            appCheckToken: "app-check",
            deviceID: "linux-device"
        )
        let response = try JSONSerialization.data(withJSONObject: [
            "result": [
                "uid": context.uid,
                "connectionId": "connection",
                "resolvedAtMillis": 2_000_000_000_000,
                "routes": []
            ]
        ])
        let client = LinuxIrohControllerDirectoryClient(
            credentials: { context },
            transport: { request in
                (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            now: { now }
        )

        let route = try await client.resolveActiveRoute(connectionID: "connection")

        XCTAssertNil(route)
    }
}
#endif
