import Foundation
import OpenBurnBarEngine

/// Errors returned by the Linux trusted-device bridge. The Linux installation
/// is a lower-trust principal: an absent bridge is an unavailable state, never
/// an implicit local approval or a synthetic device list.
public enum LinuxTrustedDeviceManagementError: Error, Equatable, Sendable {
    case unavailable
    case notAuthenticated
    case unauthorized
    case rejected
    case malformedResponse
    case transportFailure
    case invalidDeviceID
}

/// The daemon's only authority boundary for the trusted-device surface. A
/// concrete Iroh/mobile bridge can implement this protocol once its production
/// callable and companion-device transport are deployed. Keeping the protocol
/// here makes the RPC/UI contract stable without allowing the renderer to carry
/// Firebase credentials, nonces, action proofs, or public-key bytes.
public protocol LinuxTrustedDeviceManaging: Sendable {
    func listTrustedDevices() async throws -> [BurnBarLinuxTrustedDevice]
    func approveTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation
    func revokeTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation
}

public struct LinuxTrustedDeviceMutation: Equatable, Sendable {
    public let deviceID: String
    public let trustState: BurnBarLinuxTrustedDeviceTrustState
    public let alreadyInState: Bool

    public init(
        deviceID: String,
        trustState: BurnBarLinuxTrustedDeviceTrustState,
        alreadyInState: Bool = false
    ) throws {
        guard Self.isValidIdentifier(deviceID) else {
            throw LinuxTrustedDeviceManagementError.invalidDeviceID
        }
        self.deviceID = deviceID
        self.trustState = trustState
        self.alreadyInState = alreadyInState
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 160
            && value.contains("\n") == false
            && value.contains("\r") == false
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) }
    }
}

/// Closure adapter used by the eventual companion-device/Iroh integration and
/// by deterministic daemon tests. The closures receive only bounded IDs and
/// redacted records; all credential and proof handling stays outside this
/// adapter.
public struct LinuxTrustedDeviceBridgeAdapter: LinuxTrustedDeviceManaging {
    private let list: @Sendable () async throws -> [BurnBarLinuxTrustedDevice]
    private let approve: @Sendable (String) async throws -> LinuxTrustedDeviceMutation
    private let revoke: @Sendable (String) async throws -> LinuxTrustedDeviceMutation

    public init(
        list: @escaping @Sendable () async throws -> [BurnBarLinuxTrustedDevice],
        approve: @escaping @Sendable (String) async throws -> LinuxTrustedDeviceMutation,
        revoke: @escaping @Sendable (String) async throws -> LinuxTrustedDeviceMutation
    ) {
        self.list = list
        self.approve = approve
        self.revoke = revoke
    }

    public func listTrustedDevices() async throws -> [BurnBarLinuxTrustedDevice] {
        try Self.validate(try await list())
    }

    public func approveTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation {
        guard Self.isValidIdentifier(deviceID) else {
            throw LinuxTrustedDeviceManagementError.invalidDeviceID
        }
        let result = try await approve(deviceID)
        guard result.deviceID == deviceID, result.trustState == .trusted else {
            throw LinuxTrustedDeviceManagementError.malformedResponse
        }
        return result
    }

    public func revokeTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation {
        guard Self.isValidIdentifier(deviceID) else {
            throw LinuxTrustedDeviceManagementError.invalidDeviceID
        }
        let result = try await revoke(deviceID)
        guard result.deviceID == deviceID, result.trustState == .revoked else {
            throw LinuxTrustedDeviceManagementError.malformedResponse
        }
        return result
    }

    private static func validate(
        _ devices: [BurnBarLinuxTrustedDevice]
    ) throws -> [BurnBarLinuxTrustedDevice] {
        guard devices.count <= 128 else {
            throw LinuxTrustedDeviceManagementError.malformedResponse
        }
        var seen = Set<String>()
        for device in devices {
            guard isValidIdentifier(device.deviceID),
                  device.displayName.isEmpty == false,
                  device.displayName.utf8.count <= 256,
                  device.platform.isEmpty == false,
                  device.platform.utf8.count <= 64,
                  device.displayName.contains("\n") == false,
                  device.displayName.contains("\r") == false,
                  device.platform.contains("\n") == false,
                  device.platform.contains("\r") == false,
                  seen.insert(device.deviceID).inserted,
                  device.safetyFingerprint.map({ $0.utf8.count <= 256 && !$0.contains("\n") && !$0.contains("\r") }) ?? true
            else {
                throw LinuxTrustedDeviceManagementError.malformedResponse
            }
        }
        return devices
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 160
            && value.contains("\n") == false
            && value.contains("\r") == false
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._:+-/=".contains($0) }
    }
}

/// Explicit default used by production composition until the trusted-device
/// callable/companion bridge is installed. It preserves the UI's accurate
/// unavailable posture and makes accidental local mutation impossible.
public struct UnavailableLinuxTrustedDeviceManager: LinuxTrustedDeviceManaging {
    public init() {}

    public func listTrustedDevices() async throws -> [BurnBarLinuxTrustedDevice] {
        throw LinuxTrustedDeviceManagementError.unavailable
    }

    public func approveTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation {
        _ = deviceID
        throw LinuxTrustedDeviceManagementError.unavailable
    }

    public func revokeTrustedDevice(deviceID: String) async throws -> LinuxTrustedDeviceMutation {
        _ = deviceID
        throw LinuxTrustedDeviceManagementError.unavailable
    }
}
