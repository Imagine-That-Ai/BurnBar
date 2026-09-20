import Foundation
import OpenBurnBarKernel

public enum KeepAwakeToggleError: Error, Equatable, Sendable {
    case invalidPublicKey
    case invalidSignature
    case expired
    case replayed
    case malformed
}

/// Signed phone → Mac keep-awake toggle. Rides the existing iroh
/// `media.control` presence heartbeat as a capability token — not daemon
/// Unix-socket RPC. Mac verifies the Ed25519 signature against the
/// trusted-device public key before applying.
public struct KeepAwakeToggleCommand: Equatable, Sendable {
    public let deviceId: String
    public let enabled: Bool
    public let issuedAtMillis: Int64
    public let signature: String

    public static let maximumAgeSeconds: TimeInterval = 5 * 60

    public init(
        deviceId: String,
        enabled: Bool,
        issuedAtMillis: Int64,
        signature: String
    ) {
        self.deviceId = deviceId
        self.enabled = enabled
        self.issuedAtMillis = issuedAtMillis
        self.signature = signature
    }

    public static func canonicalPayload(
        deviceId: String,
        enabled: Bool,
        issuedAtMillis: Int64
    ) -> Data {
        let flag = enabled ? "1" : "0"
        return Data("openburnbar.keep_awake.toggle.v1|\(deviceId)|\(flag)|\(issuedAtMillis)".utf8)
    }

    public static func sign(
        deviceId: String,
        enabled: Bool,
        issuedAt: Date = Date(),
        with signingKey: PlatformEd25519SigningMaterial
    ) throws -> KeepAwakeToggleCommand {
        let issuedAtMillis = Int64(issuedAt.timeIntervalSince1970 * 1000)
        let payload = canonicalPayload(
            deviceId: deviceId,
            enabled: enabled,
            issuedAtMillis: issuedAtMillis
        )
        let signature = try PlatformCrypto.ed25519Signature(message: payload, privateKey: signingKey)
        return KeepAwakeToggleCommand(
            deviceId: deviceId,
            enabled: enabled,
            issuedAtMillis: issuedAtMillis,
            signature: signature.base64EncodedString()
        )
    }

    public static func verify(
        _ command: KeepAwakeToggleCommand,
        publicKey rawPublicKey: Data,
        now: Date = Date(),
        maximumAge: TimeInterval = KeepAwakeToggleCommand.maximumAgeSeconds
    ) throws {
        guard let signatureBytes = Data(base64Encoded: command.signature) else {
            throw KeepAwakeToggleError.malformed
        }
        let publicKey: PlatformEd25519PublicKey
        do {
            publicKey = try PlatformCrypto.ed25519PublicKey(rawRepresentation: rawPublicKey)
        } catch {
            throw KeepAwakeToggleError.invalidPublicKey
        }
        let payload = canonicalPayload(
            deviceId: command.deviceId,
            enabled: command.enabled,
            issuedAtMillis: command.issuedAtMillis
        )
        guard (try? PlatformCrypto.verifyEd25519Signature(
            signatureBytes,
            message: payload,
            publicKey: publicKey
        )) == true else {
            throw KeepAwakeToggleError.invalidSignature
        }
        let issuedAt = Date(timeIntervalSince1970: Double(command.issuedAtMillis) / 1000.0)
        if now.timeIntervalSince(issuedAt) > maximumAge {
            throw KeepAwakeToggleError.expired
        }
    }

    /// Compact token for `media.presence.heartbeat` capabilities.
    public var presenceCapability: String {
        let flag = enabled ? "1" : "0"
        return HostReachabilityCapability.togglePrefix
            + "\(deviceId)|\(flag)|\(issuedAtMillis)|\(signature)"
    }

    public static func parsePresenceCapability(_ capability: String) -> KeepAwakeToggleCommand? {
        guard capability.hasPrefix(HostReachabilityCapability.togglePrefix) else {
            return nil
        }
        let body = String(capability.dropFirst(HostReachabilityCapability.togglePrefix.count))
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              parts[1] == "0" || parts[1] == "1",
              let issuedAtMillis = Int64(parts[2]),
              !parts[0].isEmpty,
              !parts[3].isEmpty else {
            return nil
        }
        return KeepAwakeToggleCommand(
            deviceId: parts[0],
            enabled: parts[1] == "1",
            issuedAtMillis: issuedAtMillis,
            signature: parts[3]
        )
    }

    public static func parsePresenceCapabilities(_ capabilities: [String]) -> KeepAwakeToggleCommand? {
        for capability in capabilities.reversed() {
            if let command = parsePresenceCapability(capability) {
                return command
            }
        }
        return nil
    }
}

/// Rejects presenting the same signed toggle more than once.
public struct KeepAwakeToggleReplayGuard: Sendable {
    private var consumed: Set<String> = []

    public init() {}

    public mutating func consume(_ command: KeepAwakeToggleCommand) throws {
        let key = "\(command.deviceId)|\(command.issuedAtMillis)|\(command.signature)"
        if consumed.contains(key) {
            throw KeepAwakeToggleError.replayed
        }
        consumed.insert(key)
    }
}
