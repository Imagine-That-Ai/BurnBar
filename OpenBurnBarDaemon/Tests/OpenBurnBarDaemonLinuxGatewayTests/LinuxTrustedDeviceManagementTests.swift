#if os(Linux)
import Foundation
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxTrustedDeviceManagementTests: XCTestCase {
    func testUnavailableManagerNeverTurnsMissingBridgeIntoLocalState() async throws {
        let manager = UnavailableLinuxTrustedDeviceManager()
        do {
            _ = try await manager.listTrustedDevices()
            XCTFail("A missing trusted-device bridge must fail closed")
        } catch let error as LinuxTrustedDeviceManagementError {
            XCTAssertEqual(error, .unavailable)
        }

        do {
            _ = try await manager.approveTrustedDevice(deviceID: "ipad-1")
            XCTFail("A missing trusted-device bridge must not approve locally")
        } catch let error as LinuxTrustedDeviceManagementError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testBridgeAdapterValidatesRedactedListAndMutationBinding() async throws {
        let device = BurnBarLinuxTrustedDevice(
            deviceID: "ipad-1",
            displayName: "Alberto's iPad",
            platform: "iPadOS",
            trustState: .trusted,
            safetyFingerprint: "fingerprint-1"
        )
        let manager = LinuxTrustedDeviceBridgeAdapter(
            list: { [device] },
            approve: { deviceID in
                try LinuxTrustedDeviceMutation(deviceID: deviceID, trustState: .trusted)
            },
            revoke: { deviceID in
                try LinuxTrustedDeviceMutation(deviceID: deviceID, trustState: .revoked)
            }
        )

        XCTAssertEqual(try await manager.listTrustedDevices(), [device])
        let approved = try await manager.approveTrustedDevice(deviceID: "ipad-1")
        XCTAssertEqual(approved.trustState, .trusted)
        let revoked = try await manager.revokeTrustedDevice(deviceID: "ipad-1")
        XCTAssertEqual(revoked.trustState, .revoked)

        let malformed = LinuxTrustedDeviceBridgeAdapter(
            list: {
                [device, device]
            },
            approve: { _ in
                try LinuxTrustedDeviceMutation(deviceID: "ipad-1", trustState: .revoked)
            },
            revoke: { _ in
                try LinuxTrustedDeviceMutation(deviceID: "other-device", trustState: .revoked)
            }
        )
        do {
            _ = try await malformed.listTrustedDevices()
            XCTFail("Duplicate device IDs must be rejected")
        } catch let error as LinuxTrustedDeviceManagementError {
            XCTAssertEqual(error, .malformedResponse)
        }
        do {
            _ = try await malformed.approveTrustedDevice(deviceID: "ipad-1")
            XCTFail("An approve response in revoked state must be rejected")
        } catch let error as LinuxTrustedDeviceManagementError {
            XCTAssertEqual(error, .malformedResponse)
        }
        do {
            _ = try await malformed.revokeTrustedDevice(deviceID: "ipad-1")
            XCTFail("A response for a different device must be rejected")
        } catch let error as LinuxTrustedDeviceManagementError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testAuthRPCReturnsRedactedUnavailableErrorWithoutBridge() async throws {
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(startsMissionControlBackgroundLoops: false)
        )
        let request = BurnBarRPCRequestEnvelope(
            id: "trusted-list-unavailable",
            method: .linuxTrustedDeviceList
        )
        let data = try await server.handleLinuxAuthRPC(
            method: .linuxTrustedDeviceList,
            decoder: JSONDecoder(),
            requestData: JSONEncoder().encode(request)
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxTrustedDeviceListResponse>.self,
            from: data
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.unavailable)
        XCTAssertEqual(
            response.error?.message,
            "Trusted-device management is not configured on this Linux installation."
        )
        let text = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("nonce"))
        XCTAssertFalse(text.contains("proof"))
        XCTAssertFalse(text.contains("firebase"))
    }

    func testAuthRPCUsesInjectedBridgeForListAndMutations() async throws {
        let device = BurnBarLinuxTrustedDevice(
            deviceID: "ipad-1",
            displayName: "Alberto's iPad",
            platform: "iPadOS",
            trustState: .pending
        )
        let manager = LinuxTrustedDeviceBridgeAdapter(
            list: { [device] },
            approve: { id in try LinuxTrustedDeviceMutation(deviceID: id, trustState: .trusted) },
            revoke: { id in try LinuxTrustedDeviceMutation(deviceID: id, trustState: .revoked) }
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(startsMissionControlBackgroundLoops: false),
            linuxTrustedDeviceManager: manager
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let listRequest = BurnBarRPCRequestEnvelope(id: "trusted-list", method: .linuxTrustedDeviceList)
        let listData = try await server.handleLinuxAuthRPC(
            method: .linuxTrustedDeviceList,
            decoder: decoder,
            requestData: encoder.encode(listRequest)
        )
        let listResponse = try decoder.decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxTrustedDeviceListResponse>.self,
            from: listData
        )
        XCTAssertNil(listResponse.error)
        XCTAssertEqual(listResponse.result?.devices, [device])

        let approveRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "trusted-approve",
            method: .linuxTrustedDeviceApprove,
            params: BurnBarLinuxTrustedDeviceMutationRequest(deviceID: "ipad-1")
        )
        let approveData = try await server.handleLinuxAuthRPC(
            method: .linuxTrustedDeviceApprove,
            decoder: decoder,
            requestData: encoder.encode(approveRequest)
        )
        let approveResponse = try decoder.decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxTrustedDeviceMutationResponse>.self,
            from: approveData
        )
        XCTAssertNil(approveResponse.error)
        XCTAssertEqual(approveResponse.result?.trustState, .trusted)

        let revokeRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "trusted-revoke",
            method: .linuxTrustedDeviceRevoke,
            params: BurnBarLinuxTrustedDeviceMutationRequest(deviceID: "ipad-1")
        )
        let revokeData = try await server.handleLinuxAuthRPC(
            method: .linuxTrustedDeviceRevoke,
            decoder: decoder,
            requestData: encoder.encode(revokeRequest)
        )
        let revokeResponse = try decoder.decode(
            BurnBarRPCResponseEnvelope<BurnBarLinuxTrustedDeviceMutationResponse>.self,
            from: revokeData
        )
        XCTAssertNil(revokeResponse.error)
        XCTAssertEqual(revokeResponse.result?.trustState, .revoked)
    }
}
#endif
