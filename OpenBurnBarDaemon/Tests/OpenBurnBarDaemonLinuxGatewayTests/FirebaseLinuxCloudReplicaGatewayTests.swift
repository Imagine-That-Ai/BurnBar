import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenBurnBarDaemon
import XCTest

final class FirebaseLinuxCloudReplicaGatewayTests: XCTestCase {
    func testPushUsesExactCallableContractAndDaemonOwnedCredentials() async throws {
        let replica = LinuxCloudReplicaEngine.RemoteReplica(
            domain: .usage,
            recordID: "event-1",
            revision: 1,
            modifiedAtMillis: 100,
            sourceDeviceID: "linux-a",
            tombstone: true,
            sealedPayload: nil
        )
        let mutation = LinuxCloudReplicaEngine.OutboundMutation(
            sequence: 7,
            mutationID: "linux-a:7",
            replica: replica
        )
        let response = try JSONEncoder().encode(CallableResult(result: LinuxCloudReplicaEngine.PushResult(
            acknowledgedMutationIDs: [mutation.mutationID],
            authoritativeReplicas: [replica]
        )))
        let recorder = GatewayTransportRecorder(responseData: response)
        let gateway = FirebaseLinuxCloudReplicaGateway(
            credentials: { .init(idToken: "firebase-id-token", appCheckToken: "app-check-token") },
            transport: recorder.send
        )

        let result = try await gateway.push(uid: "must-not-cross-wire", mutations: [mutation])

        XCTAssertEqual(result.authoritativeReplicas, [replica])
        let request = try XCTUnwrap(recorder.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://us-central1-burnbar.cloudfunctions.net/pushLinuxCloudReplicas")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firebase-id-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check-token")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("\"mutations\""))
        XCTAssertFalse(body.contains("must-not-cross-wire"))
    }

    func testEndpointRequiresExactHTTPSAllowlistedHostAndRootPath() async throws {
        let mutation = LinuxCloudReplicaEngine.OutboundMutation(
            sequence: 1,
            mutationID: "linux-a:1",
            replica: .init(
                domain: .usage,
                recordID: "event",
                revision: 1,
                modifiedAtMillis: 1,
                sourceDeviceID: "linux-a",
                tombstone: true,
                sealedPayload: nil
            )
        )
        for rawURL in [
            "http://us-central1-burnbar.cloudfunctions.net",
            "https://us-central1-burnbar.cloudfunctions.net.evil.example",
            "https://us-central1-burnbar.cloudfunctions.net/untrusted",
            "https://user@us-central1-burnbar.cloudfunctions.net"
        ] {
            let baseURL = try XCTUnwrap(URL(string: rawURL))
            let gateway = FirebaseLinuxCloudReplicaGateway(
                baseURL: baseURL,
                credentials: { .init(idToken: "id", appCheckToken: "app") }
            )
            do {
                _ = try await gateway.push(uid: "user", mutations: [mutation])
                XCTFail("Expected endpoint rejection for \(rawURL)")
            } catch let error as FirebaseLinuxCloudReplicaGateway.GatewayError {
                XCTAssertEqual(error, .invalidConfiguration)
            }
        }
    }
}

private struct CallableResult<Value: Encodable>: Encodable { let result: Value }

private final class GatewayTransportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let responseData: Data
    private var request: URLRequest?

    init(responseData: Data) { self.responseData = responseData }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { self.request = request }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            throw URLError(.badURL)
        }
        return (responseData, response)
    }

    func lastRequest() -> URLRequest? { lock.withLock { request } }
}
