#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarLinuxSecurity

private struct LinuxComputerUseDisabledPAMAuthenticator: LinuxPAMAuthenticating {
    func authenticate(serviceName: String, reason: String) async throws -> Bool {
        throw LinuxDesktopOwnerAuthenticationError.localAuthUnavailable(
            "Browser Computer Use requires an installed polkit authentication agent."
        )
    }
}

public enum LinuxComputerUseOwnerAuthorizationError: Error, Equatable, Sendable {
    case invalidPeer
    case unsupportedPeerExecutable
    case invalidOperation
    case authorizationAlreadyInProgress
    case peerChangedDuringAuthorization
    case invalidAuthorizationProof
}

public struct LinuxComputerUseOwnerPeerIdentity: Equatable, Sendable {
    public let processID: Int32
    public let userID: UInt32
    public let processStartTime: UInt64
    public let executablePath: String
    public let executableDevice: UInt64
    public let executableInode: UInt64

    public init(
        processID: Int32,
        userID: UInt32,
        processStartTime: UInt64,
        executablePath: String,
        executableDevice: UInt64,
        executableInode: UInt64
    ) {
        self.processID = processID
        self.userID = userID
        self.processStartTime = processStartTime
        self.executablePath = executablePath
        self.executableDevice = executableDevice
        self.executableInode = executableInode
    }
}

/// Performs a fresh Linux desktop-owner authorization for one authenticated
/// Tauri socket peer. The result is intentionally not reusable: callers must
/// complete the exact server-side operation in the same RPC after revalidating
/// its run or approval state.
public actor LinuxComputerUseOwnerAuthorizationCoordinator {
    public typealias Authenticator = @Sendable (
        _ processID: Int32,
        _ reason: String
    ) async throws -> LinuxDesktopOwnerAuthenticationProof
    public typealias PeerIdentityProvider = @Sendable (
        _ processID: Int32
    ) throws -> LinuxComputerUseOwnerPeerIdentity

    public static let authority = "polkit"
    public static let maximumReasonLength = 160
    public static let maximumOperationIDLength = 128

    private let authenticator: Authenticator
    private let peerIdentityProvider: PeerIdentityProvider
    private let nowMillis: @Sendable () -> Int64
    private var inFlightProcessIDs: Set<Int32> = []

    public init() {
        self.authenticator = { processID, reason in
            try await LinuxDesktopOwnerAuthenticator(
                pam: LinuxComputerUseDisabledPAMAuthenticator(),
                processID: processID
            ).authenticate(reason: reason)
        }
        self.peerIdentityProvider = { processID in
            try LinuxComputerUseOwnerAuthorizationCoordinator.readPeerIdentity(
                processID: processID
            )
        }
        self.nowMillis = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    }

    public init(
        authenticator: @escaping Authenticator,
        peerIdentityProvider: @escaping PeerIdentityProvider,
        nowMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.authenticator = authenticator
        self.peerIdentityProvider = peerIdentityProvider
        self.nowMillis = nowMillis
    }

    @discardableResult
    public func authorize(
        peerProcessID: Int32,
        operationID: String,
        reason: String
    ) async throws -> LinuxDesktopOwnerAuthenticationProof {
        guard Self.isValidOperationID(operationID) else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidOperation
        }
        let promptReason = Self.sanitizedReason(reason)
        guard !promptReason.isEmpty else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidOperation
        }

        let originalPeer = try peerIdentityProvider(peerProcessID)
        try Self.validatePeer(originalPeer)
        guard inFlightProcessIDs.insert(peerProcessID).inserted else {
            throw LinuxComputerUseOwnerAuthorizationError.authorizationAlreadyInProgress
        }
        defer { inFlightProcessIDs.remove(peerProcessID) }

        let startedAtMillis = nowMillis()
        let proof = try await authenticator(peerProcessID, promptReason)
        let completedAtMillis = nowMillis()
        let currentPeer = try peerIdentityProvider(peerProcessID)
        guard currentPeer == originalPeer else {
            throw LinuxComputerUseOwnerAuthorizationError.peerChangedDuringAuthorization
        }
        guard proof.localAuthenticationSatisfied,
              proof.authority == Self.authority,
              proof.actionID == LinuxDesktopOwnerAuthenticator.computerUseGrantActionID,
              proof.reason == promptReason,
              proof.authenticatedAtMillis >= startedAtMillis,
              proof.authenticatedAtMillis <= completedAtMillis + 5_000 else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidAuthorizationProof
        }
        return proof
    }

    public static func sanitizedReason(_ raw: String) -> String {
        let printable = raw.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                return Character(String(scalar))
            }
            return " "
        }
        let collapsed = String(printable)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(maximumReasonLength))
    }

    public static func readPeerIdentity(
        processID: Int32
    ) throws -> LinuxComputerUseOwnerPeerIdentity {
        guard processID > 1,
              let processStartTime = LinuxPolkitDBusAuthority.readLinuxProcessStartTime(pid: processID) else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidPeer
        }

        let processPath = "/proc/\(processID)"
        var processStatus = stat()
        guard stat(processPath, &processStatus) == 0 else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidPeer
        }

        let executableLink = "\(processPath)/exe"
        var executableStatus = stat()
        guard stat(executableLink, &executableStatus) == 0 else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidPeer
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = readlink(executableLink, &buffer, buffer.count - 1)
        guard count > 0 else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidPeer
        }
        buffer[Int(count)] = 0

        return LinuxComputerUseOwnerPeerIdentity(
            processID: processID,
            userID: UInt32(processStatus.st_uid),
            processStartTime: processStartTime,
            executablePath: String(cString: buffer),
            executableDevice: UInt64(executableStatus.st_dev),
            executableInode: UInt64(executableStatus.st_ino)
        )
    }

    private static func validatePeer(_ peer: LinuxComputerUseOwnerPeerIdentity) throws {
        guard peer.userID == UInt32(geteuid()) else {
            throw LinuxComputerUseOwnerAuthorizationError.invalidPeer
        }
        let executableName = URL(fileURLWithPath: peer.executablePath).lastPathComponent
        guard ["OpenBurnBar", "OpenBurnBarApp", "openburnbar-linux-desktop"].contains(executableName) else {
            throw LinuxComputerUseOwnerAuthorizationError.unsupportedPeerExecutable
        }
    }

    private static func isValidOperationID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumOperationIDLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar == "-" || scalar == "_" || scalar == ":" || scalar == "."
        }
    }
}
#endif
