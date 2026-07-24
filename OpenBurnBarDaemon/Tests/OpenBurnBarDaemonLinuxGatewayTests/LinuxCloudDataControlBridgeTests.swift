#if os(Linux)
import Foundation
import XCTest
import OpenBurnBarLinuxSecurity
@testable import OpenBurnBarDaemon

final class LinuxCloudDataControlBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testMissingTrustedDeviceBridgeFailsClosedWithRedactedUnavailableStatus() async throws {
        let transportCalls = CallCounter()
        let authority = makeAuthority(transportCalls: transportCalls)

        do {
            _ = try await authority.requestCloudDataExport(domains: ["usage_spend"])
            XCTFail("Linux must not export without a trusted-device bridge")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .trustedDeviceBridgeUnavailable)
        }

        let status = await authority.cloudDataControlStatus()
        XCTAssertEqual(status.phase, .unavailable)
        XCTAssertEqual(status.detail, "trusted_device_bridge_unavailable")
        XCTAssertNil(status.requestID)
        let transportCallCount = await transportCalls.value()
        XCTAssertEqual(transportCallCount, 0)
        let encoded = try JSONEncoder().encode(status)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("nonce"))
        XCTAssertFalse(text.contains("proof"))
        XCTAssertFalse(text.contains("user-123"))
    }

    func testMalformedTrustedDeviceAuthorizationNeverReachesCloud() async throws {
        let requestProbe = CloudDataControlRequestProbe()
        let transportCalls = CallCounter()
        let authorizer = LinuxCloudTrustedDeviceActionAuthorizer { request in
            await requestProbe.record(request)
            return LinuxCloudTrustedDeviceAuthorization(
                nonce: "nonce-1",
                trustedDeviceID: "phone-device",
                actionProof: LinuxCloudTrustedDeviceActionProof(
                    deviceSignalIdentityKeyId: "phone-key",
                    deviceSignalIdentityPublicKeyFingerprint: "fingerprint",
                    issuedAtMillis: 2_000_000_000_000,
                    signature: "not-base64"
                )
            )
        }
        let authority = makeAuthority(
            transportCalls: transportCalls,
            trustedDeviceAuthorizer: authorizer
        )

        do {
            _ = try await authority.requestCloudDataExport(domains: ["usage_spend"])
            XCTFail("Malformed trusted-device material must fail closed")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .dataControlAuthorizationInvalid)
        }

        let capturedRequest = await requestProbe.value()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.operation, .export)
        XCTAssertEqual(request.actionKind, "data_export")
        XCTAssertEqual(request.subjectID, "all")
        XCTAssertEqual(request.domains, ["usage_spend"])
        XCTAssertFalse(request.requiresExplicitConfirmation)
        let transportCallCount = await transportCalls.value()
        XCTAssertEqual(transportCallCount, 0)
        let status = await authority.cloudDataControlStatus()
        XCTAssertEqual(status.phase, .failed)
        XCTAssertEqual(status.detail, "data_control_authorization_invalid")
    }

    func testDeletionConfirmationIsCheckedBeforeTrustedDevicePrompt() async throws {
        let promptCount = CallCounter()
        let authorizer = LinuxCloudTrustedDeviceActionAuthorizer { _ in
            await promptCount.increment()
            throw LinuxCloudTrustedDeviceActionAuthorizationError.rejected
        }
        let authority = makeAuthority(
            transportCalls: CallCounter(),
            trustedDeviceAuthorizer: authorizer
        )

        do {
            _ = try await authority.requestCloudDataDeletion(confirmationToken: "delete")
            XCTFail("An inexact deletion confirmation must fail closed")
        } catch let error as LinuxCloudAuthAuthorityError {
            XCTAssertEqual(error, .operationMismatch)
        }
        let promptCallCount = await promptCount.value()
        XCTAssertEqual(promptCallCount, 0)
        let status = await authority.cloudDataControlStatus()
        XCTAssertEqual(status.phase, .unavailable)
    }

    private func makeAuthority(
        transportCalls: CallCounter,
        trustedDeviceAuthorizer: (any LinuxCloudTrustedDeviceActionAuthorizing)? = nil
    ) -> LinuxDaemonCloudCredentialAuthority {
        let backend = LinuxInMemorySecretStoreBackend(secrets: [:])
        return LinuxDaemonCloudCredentialAuthority(
            configuration: LinuxCloudAuthConfiguration(
                googleOAuthClientID: "123456789012.apps.googleusercontent.com",
                firebaseAPIKey: "fixture",
                linuxAppCheckAppID: "1:123456789:linux:abcdef123456"
            ),
            custodian: LinuxSecretCustodian(backends: [backend]),
            httpTransport: { _, _ in
                await transportCalls.increment()
                throw URLError(.notConnectedToInternet)
            },
            now: { self.now },
            hostname: "cloud-data-control-test",
            trustedDeviceAuthorizer: trustedDeviceAuthorizer
        )
    }
}

private actor CallCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor CloudDataControlRequestProbe {
    private var request: LinuxCloudDataControlAuthorizationRequest?

    func record(_ request: LinuxCloudDataControlAuthorizationRequest) {
        self.request = request
    }

    func value() -> LinuxCloudDataControlAuthorizationRequest? { request }
}
#endif
