#if os(Linux)
import Foundation
import FoundationNetworking
import XCTest
@testable import OpenBurnBarDaemon

private actor LinuxIrohRequestRecorder {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func snapshot() -> URLRequest? { request }
}

final class LinuxIrohControllerDirectoryClientTests: XCTestCase {
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
