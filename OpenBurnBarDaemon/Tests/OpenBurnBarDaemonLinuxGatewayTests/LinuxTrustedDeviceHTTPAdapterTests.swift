#if os(Linux)
import Foundation
import FoundationNetworking
import OpenBurnBarKernel
import XCTest
@testable import OpenBurnBarDaemon

final class LinuxTrustedDeviceHTTPAdapterTests: XCTestCase {
    private let baseURL = URL(string: "https://us-central1-burnbar.cloudfunctions.net")!

    private func credentials() throws -> LinuxCloudTrustedDeviceManagerCredentials {
        try LinuxCloudTrustedDeviceManagerCredentials(
            idToken: "id-token",
            appCheckToken: "native-app-check",
            approverDeviceID: "ipad-1"
        )
    }

    private func authorization() throws -> LinuxCloudTrustedDeviceMutationAuthorization {
        try LinuxCloudTrustedDeviceMutationAuthorization(
            nonce: "nonce-0123456789",
            actionProof: LinuxCloudTrustedDeviceActionProof(
                deviceSignalIdentityKeyId: "signal-key-1",
                deviceSignalIdentityPublicKeyFingerprint: "fingerprint-1",
                issuedAtMillis: 2_000_000_000_000,
                signature: Data(repeating: 7, count: 88).base64EncodedString()
            )
        )
    }

    func testListUsesNativeManagerCredentialsAndReturnsRedactedDevices() async throws {
        let recorder = HTTPRequestRecorder()
        let managerCredentials = try credentials()
        let mutationAuthorization = try authorization()
        let publicKey = Data(repeating: 5, count: 32).base64EncodedString()
        let response = try JSONSerialization.data(withJSONObject: [
            "result": [
                "ok": true,
                "devices": [[
                    "deviceId": "linux-device-1",
                    "deviceName": "OpenBurnBar Linux",
                    "platform": "Linux",
                    "publicKeyBase64": publicKey,
                    "safetyFingerprint": "ABCD EFGH",
                    "trustState": "approved",
                    "createdAtMillis": 2_000_000_000_000
                ]]
            ]
        ])
        let adapter = makeAdapter(
            response: response,
            recorder: recorder,
            credentials: { managerCredentials },
            authorizeMutation: { _, _ in mutationAuthorization }
        )

        let devices = try await adapter.listTrustedDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].deviceID, "linux-device-1")
        XCTAssertEqual(devices[0].trustState, .trusted)

        let requestValue = await recorder.last()
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(request.url?.lastPathComponent, "listLinuxAppCheckDevices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "native-app-check")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["approverDeviceId"] as? String, "ipad-1")
        XCTAssertNil(data["publicKeyBase64"])
    }

    func testApproveInjectsNonceAndActionProofAndMapsResult() async throws {
        let recorder = HTTPRequestRecorder()
        let managerCredentials = try credentials()
        let mutationAuthorization = try authorization()
        let response = try JSONSerialization.data(withJSONObject: [
            "result": [
                "ok": true,
                "deviceId": "linux-device-1",
                "trustState": "approved",
                "alreadyInState": false
            ]
        ])
        let actionKinds = ActionKindRecorder()
        let adapter = makeAdapter(
            response: response,
            recorder: recorder,
            credentials: { managerCredentials },
            authorizeMutation: { kind, subject in
                await actionKinds.record(kind: kind, subject: subject)
                return mutationAuthorization
            }
        )

        let mutation = try await adapter.approveTrustedDevice(deviceID: "linux-device-1")
        XCTAssertEqual(mutation.deviceID, "linux-device-1")
        XCTAssertEqual(mutation.trustState, .trusted)
        XCTAssertFalse(mutation.alreadyInState)
        let actionValue = await actionKinds.value()
        let action = try XCTUnwrap(actionValue)
        XCTAssertEqual(action.kind, "linux_app_check_device_approve")
        XCTAssertEqual(action.subject, "linux-device-1")

        let requestValue = await recorder.last()
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(request.url?.lastPathComponent, "approveLinuxAppCheckDevice")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(data["nonce"] as? String, "nonce-0123456789")
        XCTAssertEqual(data["approverDeviceId"] as? String, "ipad-1")
        XCTAssertEqual(data["deviceId"] as? String, "linux-device-1")
        let proof = try XCTUnwrap(data["actionProof"] as? [String: Any])
        XCTAssertEqual(proof["algorithm"] as? String, "signal-identity-xeddsa-v1")
        XCTAssertEqual(proof["deviceSignalIdentityKeyId"] as? String, "signal-key-1")
    }

    func testMalformedMutationProofFailsBeforeTransport() async throws {
        let recorder = HTTPRequestRecorder()
        let managerCredentials = try credentials()
        let response = Data(#"{"result":{"ok":true}}"#.utf8)
        let expired = try LinuxCloudTrustedDeviceMutationAuthorization(
            nonce: "nonce-0123456789",
            actionProof: LinuxCloudTrustedDeviceActionProof(
                deviceSignalIdentityKeyId: "signal-key-1",
                deviceSignalIdentityPublicKeyFingerprint: "fingerprint-1",
                issuedAtMillis: 1,
                signature: Data(repeating: 7, count: 88).base64EncodedString()
            )
        )
        let adapter = makeAdapter(
            response: response,
            recorder: recorder,
            credentials: { managerCredentials },
            authorizeMutation: { _, _ in expired }
        )

        do {
            _ = try await adapter.revokeTrustedDevice(deviceID: "linux-device-1")
            XCTFail("expired trusted-device proof must fail closed")
        } catch let error as LinuxTrustedDeviceManagementError {
            XCTAssertEqual(error, .rejected)
        }
        let request = await recorder.last()
        XCTAssertNil(request)
    }

    private func makeAdapter(
        response: Data,
        recorder: HTTPRequestRecorder,
        credentials: @escaping LinuxCloudTrustedDeviceCredentialsProvider,
        authorizeMutation: @escaping LinuxCloudTrustedDeviceMutationAuthorizationProvider
    ) -> LinuxCloudTrustedDeviceHTTPAdapter {
        LinuxCloudTrustedDeviceHTTPAdapter(
            functionsBaseURL: baseURL,
            credentials: credentials,
            authorizeMutation: authorizeMutation,
            allowedHosts: [baseURL.host!],
            transport: { request, _ in
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
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }
}

private actor HTTPRequestRecorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func last() -> URLRequest? { requests.last }
}

private actor ActionKindRecorder {
    struct Value: Sendable {
        let kind: String
        let subject: String
    }

    private var valueStorage: Value?

    func record(kind: String, subject: String) {
        valueStorage = Value(kind: kind, subject: subject)
    }

    func value() -> Value? { valueStorage }
}

#endif
