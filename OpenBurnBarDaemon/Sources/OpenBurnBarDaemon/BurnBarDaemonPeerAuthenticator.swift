import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if os(macOS)
public typealias BurnBarDaemonAuditToken = audit_token_t
public typealias BurnBarDaemonStatus = OSStatus
private let daemonTokenUnavailableStatus = errSecCSReqFailed
#elseif os(Linux)
public typealias BurnBarDaemonAuditToken = BurnBarLinuxPeerCredential
public typealias BurnBarDaemonStatus = Int32
private let daemonTokenUnavailableStatus: BurnBarDaemonStatus = -67050

struct BurnBarLinuxPeerSocketCredentials {
    var pid: pid_t = 0
    var uid: uid_t = 0
    var gid: gid_t = 0
}

public struct BurnBarLinuxPeerCredential: Equatable, Sendable {
    public let pid: pid_t
    public let uid: uid_t
    public let gid: gid_t
    public let executablePath: String
    public let executableSHA256: String

    public init(
        pid: pid_t,
        uid: uid_t,
        gid: gid_t,
        executablePath: String,
        executableSHA256: String
    ) {
        self.pid = pid
        self.uid = uid
        self.gid = gid
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
    }
}

public struct BurnBarLinuxPeerManifestTrustKey: Equatable, Sendable {
    public let keyID: String
    public let publicKeyRaw: Data

    public init(keyID: String, publicKeyRaw: Data) {
        self.keyID = keyID
        self.publicKeyRaw = publicKeyRaw
    }
}
#else
public typealias BurnBarDaemonAuditToken = Int32
public typealias BurnBarDaemonStatus = Int32
private let daemonTokenUnavailableStatus: BurnBarDaemonStatus = -67050
#endif

/// Failures raised when authenticating a peer of the main daemon JSON-RPC socket.
///
/// RR-3: the privileged HID/input sockets already gate accepted peers by
/// audit-token code signature (`PrivilegedPeerAuthenticator`). The main daemon
/// socket carries provider-credential-bearing RPCs (run dispatch, config writes,
/// computer-use), so it must hold the same bar: a same-user process that swaps
/// the user-writable installed daemon binary (re-exec'd by launchd `KeepAlive`)
/// or simply connects to the socket must be refused before any RPC is honored.
public enum BurnBarDaemonPeerAuthenticationFailure: Error, Equatable, Sendable {
    case auditTokenUnavailable
    case codeSignatureInvalid(status: BurnBarDaemonStatus)
}

/// First-party daemon RPC peer identity after code-signature validation.
public enum BurnBarDaemonPeerIdentity: String, CaseIterable, Codable, Sendable {
    case app = "com.openburnbar.app"
    case safariExtension = "com.openburnbar.app.safari-extension"
    case daemon = "com.openburnbar.daemon"
    case cli = "com.openburnbar.cli"

    public var capabilityProfile: BurnBarPeerCapabilityProfile {
        switch self {
        case .app, .daemon:
            return .full
        case .safariExtension:
            return .safariExtension
        case .cli:
            return .cliSupport
        }
    }

    public init?(bundleIdentifier: String) {
        self.init(rawValue: bundleIdentifier)
    }
}

/// Validates UNIX-socket peers of the main daemon control socket against the
/// first-party designated requirement.
///
/// On macOS, the accepted peer's audit-token code signature must satisfy the
/// canonical OpenBurnBar designated requirement. On Linux, `SO_PEERCRED` binds
/// the peer to `/proc/<pid>/exe`; installed peers must be exact root-owned package
/// paths, while AppImage peers must match a canonical manifest signed by the
/// pinned Linux release key inside a non-writable package filesystem.
///
/// This is the load-bearing RR-3 fix: the bearer token (checked separately in
/// `BurnBarDaemonServer.responseData`) remains as defense in depth, but the
/// signature gate is what makes a swapped/forged peer binary fail closed even
/// when it learned the token.
public struct BurnBarDaemonPeerAuthenticator: Sendable {
    public typealias CodeSignatureValidator = @Sendable (BurnBarDaemonAuditToken) throws -> BurnBarDaemonPeerIdentity

    /// `true` enforces the first-party code-signature gate on every accepted
    /// peer. `false` lets every peer through — used for local in-process tests
    /// and unsigned developer builds where no binary can carry the first-party
    /// identity (mirrors how `validateDaemonBinary` defaults to a no-op on the
    /// app side). Production wires `enforced: true` in `OpenBurnBarDaemonMain`.
    public let isEnforced: Bool
    private let validateCodeSignature: CodeSignatureValidator
    private let logger: BurnBarDaemonLogger

    public init(
        enforced: Bool,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "daemon-peer-auth"),
        validateCodeSignature: @escaping CodeSignatureValidator = BurnBarDaemonPeerAuthenticator.defaultCodeSignatureValidation
    ) {
        self.isEnforced = enforced
        self.logger = logger
        self.validateCodeSignature = validateCodeSignature
    }

    /// A non-enforcing authenticator: every peer is admitted. Default for
    /// in-process tests and unsigned builds so the socket round-trip still works.
    public static let disabled = BurnBarDaemonPeerAuthenticator(enforced: false)

    /// T-DMN-05: pure, build-mode-aware decision for whether the launch
    /// environment may disable the first-party code-signature gate.
    ///
    /// The peer-codesig-disable env opt-out is a DEBUG-only convenience for
    /// unsigned developer builds. In release/distribution builds an attacker who
    /// controls the daemon's launch environment must NOT be able to strip the
    /// gate, so `resolveEnforcement` ignores the env entirely and always enforces.
    ///
    /// `isDebugBuild` is injected so the test target can prove both arms of the
    /// policy without recompiling under a different configuration. Production
    /// callers pass the real compile-time value via ``resolveEnforcementForCurrentBuild(environment:)``.
    public static func resolveEnforcement(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        guard isDebugBuild else {
            // Release/distribution: the env opt-out is compiled out — always enforce.
            return true
        }
        let disabled = environment["OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG"] == "1"
            || environment["BURNBAR_DAEMON_DISABLE_PEER_CODESIG"] == "1"
        return !disabled
    }

    /// Convenience that binds ``resolveEnforcement(environment:isDebugBuild:)`` to
    /// this build's compile-time `DEBUG` flag.
    public static func resolveEnforcementForCurrentBuild(environment: [String: String]) -> Bool {
        #if DEBUG
        return resolveEnforcement(environment: environment, isDebugBuild: true)
        #else
        return resolveEnforcement(environment: environment, isDebugBuild: false)
        #endif
    }

    /// Validate the accepted client socket. When enforcement is off this is a
    /// no-op returning `.full`. When on, the peer's audit token must satisfy the
    /// first-party designated requirement; any failure (token unreadable,
    /// signature invalid, or unavailable) is fail-closed and logged. The
    /// returned profile scopes the accepted peer's RPC authority.
    public func validatePeer(socketFD: Int32, peerPID: pid_t?) throws -> BurnBarPeerCapabilityProfile {
        guard isEnforced else { return .full }

        let auditToken: BurnBarDaemonAuditToken
        do {
            #if os(Linux)
            auditToken = try Self.linuxPeerCredential(socketFD: socketFD)
            #else
            auditToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: socketFD)
            #endif
        } catch {
            reject(.auditTokenUnavailable, peerPID: peerPID)
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }

        do {
            let identity = try validateCodeSignature(auditToken)
            return identity.capabilityProfile
        } catch let failure as BurnBarDaemonPeerAuthenticationFailure {
            reject(failure, peerPID: peerPID)
            throw failure
        } catch {
            #if os(macOS)
            if case let PrivilegedSocketTrustError.codeSignatureInvalid(status) = error {
                let wrapped = BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(
                    status: status
                )
                reject(wrapped, peerPID: peerPID)
                throw wrapped
            }
            #endif
            let wrapped = BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(
                status: daemonTokenUnavailableStatus
            )
            reject(wrapped, peerPID: peerPID)
            throw wrapped
        }
    }

    private func reject(_ failure: BurnBarDaemonPeerAuthenticationFailure, peerPID: pid_t?) {
        logger.warning(
            "rpc_peer_code_signature_rejected",
            metadata: [
                "detail": String(describing: failure),
                "peer_pid": peerPID.map(String.init) ?? "unknown"
            ]
        )
    }

    /// Production validator: delegate to the shared first-party trust primitive
    /// and re-map its error into the daemon-peer failure space.
    @Sendable
    public static func defaultCodeSignatureValidation(auditToken: BurnBarDaemonAuditToken) throws -> BurnBarDaemonPeerIdentity {
        #if os(macOS)
        do {
            let identifier = try OpenBurnBarPrivilegedTrust.validateCodeSignature(
                ofAuditToken: auditToken,
                requirementString: OpenBurnBarPrivilegedTrust.daemonRPCPeerDesignatedRequirement
            )
            guard let identity = BurnBarDaemonPeerIdentity(bundleIdentifier: identifier) else {
                throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: errSecCSReqFailed)
            }
            return identity
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: status)
        }
        #elseif os(Linux)
        return try validateLinuxPeerCredential(auditToken)
        #else
        _ = auditToken
        throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
        #endif
    }

    #if os(Linux)
    public static func validateLinuxPeerCredential(
        _ credential: BurnBarLinuxPeerCredential,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentUID: uid_t = geteuid(),
        trustedFilesystemOwnerUID: uid_t = 0,
        trustedManifestKeys: [BurnBarLinuxPeerManifestTrustKey]? = nil,
        allowDebugHashPins: Bool? = nil
    ) throws -> BurnBarDaemonPeerIdentity {
        guard credential.uid == currentUID else {
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
        }

        let executablePath = URL(fileURLWithPath: credential.executablePath).standardizedFileURL.path
        let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
        guard executablePath == credential.executablePath,
              executablePath.hasPrefix("/"),
              !executablePath.contains(" (deleted)") else {
            throw linuxPeerInvalid()
        }

        if let installedIdentity = try linuxInstalledPeerIdentity(
            executablePath: executablePath,
            executableSHA256: credential.executableSHA256,
            ownerUID: trustedFilesystemOwnerUID
        ) {
            return installedIdentity
        }

        if executableName == "openburnbar-linux-desktop" {
            if let appImageIdentity = try? linuxAppImagePeerIdentity(
                executablePath: executablePath,
                executableSHA256: credential.executableSHA256,
                ownerUID: trustedFilesystemOwnerUID,
                trustedKeys: trustedManifestKeys ?? linuxReleasePeerManifestTrustKeys
            ) {
                return appImageIdentity
            }
        }

        if allowDebugHashPins ?? linuxDebugHashPinsEnabled,
           let identity = linuxDebugPinnedPeerIdentity(
               executablePath: executablePath,
               executableName: executableName,
               executableSHA256: credential.executableSHA256,
               environment: environment
           ) {
            return identity
        }

        throw linuxPeerInvalid()
    }

    private struct LinuxPeerManifest {
        let keyID: String
        let identity: String
        let executableRelativePath: String
        let executableBasename: String
        let executableSHA256: String

        init(data: Data) throws {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any],
                  Set(dictionary.keys) == Set([
                      "schemaVersion", "kind", "keyId", "identity",
                      "executableRelativePath", "executableBasename", "executableSHA256"
                  ]),
                  dictionary["schemaVersion"] as? Int == 1,
                  dictionary["kind"] as? String == "openburnbar.appimage.peer.v1",
                  let keyID = dictionary["keyId"] as? String,
                  let identity = dictionary["identity"] as? String,
                  let executableRelativePath = dictionary["executableRelativePath"] as? String,
                  let executableBasename = dictionary["executableBasename"] as? String,
                  let executableSHA256 = dictionary["executableSHA256"] as? String else {
                throw linuxPeerInvalid()
            }
            self.keyID = keyID
            self.identity = identity
            self.executableRelativePath = executableRelativePath
            self.executableBasename = executableBasename
            self.executableSHA256 = executableSHA256
        }
    }

    private static let linuxReleasePeerManifestTrustKeys: [BurnBarLinuxPeerManifestTrustKey] = {
        guard let raw = Data(base64Encoded: "WPJHS2mAIVuX4A9POmB58154l2+c20up/WasNc9Tlng=") else { return [] }
        return [BurnBarLinuxPeerManifestTrustKey(
            keyID: "0e0fd1f52af308d96c71571ef7e94f3e183218abf531760dfcc8ef8e499e5c37",
            publicKeyRaw: raw
        )]
    }()

    private static var linuxDebugHashPinsEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func linuxInstalledPeerIdentity(
        executablePath: String,
        executableSHA256: String,
        ownerUID: uid_t
    ) throws -> BurnBarDaemonPeerIdentity? {
        let identities: [String: BurnBarDaemonPeerIdentity] = [
            "/usr/bin/openburnbar-linux-desktop": .app,
            "/usr/local/bin/openburnbar-linux-desktop": .app,
            "/opt/openburnbar/bin/openburnbar-linux-desktop": .app,
            "/usr/bin/openburnbar-cli": .cli,
            "/usr/local/bin/openburnbar-cli": .cli,
            "/opt/openburnbar/bin/openburnbar-cli": .cli,
            "/usr/bin/openburnbar": .cli,
            "/usr/local/bin/openburnbar": .cli,
            "/opt/openburnbar/bin/openburnbar": .cli,
            "/usr/bin/openburnbar-daemon": .daemon,
            "/usr/local/bin/openburnbar-daemon": .daemon,
            "/opt/openburnbar/bin/openburnbar-daemon": .daemon
        ]
        guard let identity = identities[executablePath] else { return nil }
        let bytes = try linuxReadBoundedRegularFile(
            path: executablePath,
            maximumBytes: 512 * 1024 * 1024,
            requiredOwnerUID: ownerUID,
            requireNoGroupOrWorldWrite: true
        )
        guard constantTimeTokensEqual(PlatformCrypto.sha256Hex(bytes), executableSHA256.lowercased()) else {
            throw linuxPeerInvalid()
        }
        return identity
    }

    private static func linuxAppImagePeerIdentity(
        executablePath: String,
        executableSHA256: String,
        ownerUID: uid_t,
        trustedKeys: [BurnBarLinuxPeerManifestTrustKey]
    ) throws -> BurnBarDaemonPeerIdentity {
        // The root is derived from the kernel-observed executable, never APPDIR.
        let relativePath = "usr/bin/openburnbar-linux-desktop"
        let executableSuffix = "/\(relativePath)"
        guard executablePath.hasSuffix(executableSuffix) else { throw linuxPeerInvalid() }
        let root = String(executablePath.dropLast(executableSuffix.count))
        guard !root.isEmpty, root.hasPrefix("/") else { throw linuxPeerInvalid() }
        try linuxValidateImmutableDirectory(path: root, requiredOwnerUID: ownerUID)

        let resourceRoot = root + "/usr/share/openburnbar"
        let manifestPath = resourceRoot + "/appimage-peer-manifest.json"
        let signaturePath = resourceRoot + "/appimage-peer-manifest.ed25519.sig"
        let manifestData = try linuxReadBoundedRegularFile(
            path: manifestPath,
            maximumBytes: 4096,
            requiredOwnerUID: ownerUID,
            requireNoGroupOrWorldWrite: true
        )
        let signature = try linuxReadBoundedRegularFile(
            path: signaturePath,
            minimumBytes: 64,
            maximumBytes: 64,
            requiredOwnerUID: ownerUID,
            requireNoGroupOrWorldWrite: true
        )
        let manifest = try LinuxPeerManifest(data: manifestData)
        guard manifest.identity == BurnBarDaemonPeerIdentity.app.rawValue,
              manifest.executableRelativePath == relativePath,
              manifest.executableBasename == "openburnbar-linux-desktop",
              manifest.keyID.count == 64,
              manifest.keyID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              manifest.executableSHA256.count == 64,
              manifest.executableSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              manifestData == linuxCanonicalPeerManifestData(manifest),
              constantTimeTokensEqual(manifest.executableSHA256, executableSHA256.lowercased()),
              let trustedKey = trustedKeys.first(where: { $0.keyID == manifest.keyID }),
              trustedKey.publicKeyRaw.count == 32,
              (try? PlatformCrypto.verifyEd25519Signature(
                  signature,
                  message: manifestData,
                  publicKeyRaw: trustedKey.publicKeyRaw
              )) == true else {
            throw linuxPeerInvalid()
        }

        let executableBytes = try linuxReadBoundedRegularFile(
            path: executablePath,
            maximumBytes: 512 * 1024 * 1024,
            requiredOwnerUID: ownerUID,
            requireNoGroupOrWorldWrite: true
        )
        guard constantTimeTokensEqual(PlatformCrypto.sha256Hex(executableBytes), manifest.executableSHA256) else {
            throw linuxPeerInvalid()
        }
        return .app
    }

    private static func linuxCanonicalPeerManifestData(_ manifest: LinuxPeerManifest) -> Data {
        let lines = [
            "{",
            "  \"schemaVersion\": 1,",
            "  \"kind\": \"openburnbar.appimage.peer.v1\",",
            "  \"keyId\": \"\(manifest.keyID)\",",
            "  \"identity\": \"\(manifest.identity)\",",
            "  \"executableRelativePath\": \"\(manifest.executableRelativePath)\",",
            "  \"executableBasename\": \"\(manifest.executableBasename)\",",
            "  \"executableSHA256\": \"\(manifest.executableSHA256)\"",
            "}"
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func linuxDebugPinnedPeerIdentity(
        executablePath: String,
        executableName: String,
        executableSHA256: String,
        environment: [String: String]
    ) -> BurnBarDaemonPeerIdentity? {
        let identity: BurnBarDaemonPeerIdentity
        switch executableName {
        case "OpenBurnBarCLI", "openburnbar-cli", "openburnbar": identity = .cli
        case "OpenBurnBarDaemon", "OpenBurnBarDaemonExecutable", "openburnbar-daemon": identity = .daemon
        case "OpenBurnBar", "OpenBurnBarApp", "openburnbar-linux-desktop": identity = .app
        default: return nil
        }
        let pins = linuxPeerHashPins(environment: environment)
        guard let expected = pins[executablePath] ?? pins[executableName],
              expected.count == 64,
              constantTimeTokensEqual(executableSHA256.lowercased(), expected.lowercased()) else {
            return nil
        }
        return identity
    }

    public static func linuxPeerCredential(socketFD: Int32) throws -> BurnBarLinuxPeerCredential {
        var credential = BurnBarLinuxPeerSocketCredentials()
        var length = socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size)
        let status = withUnsafeMutablePointer(to: &credential) { pointer in
            getsockopt(socketFD, SOL_SOCKET, SO_PEERCRED, pointer, &length)
        }
        guard status == 0, length == socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size) else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        // `/proc/<pid>/exe` is a kernel magic link, not a user-controlled
        // filesystem symlink. O_NOFOLLOW would reject the link with ELOOP on
        // Linux before we can bind the credential to the executable. The
        // descriptor is still hashed and fstat'ed below, while the PID and
        // executable path come from SO_PEERCRED and the kernel proc link.
        let executableFD = open("/proc/\(credential.pid)/exe", O_RDONLY | O_CLOEXEC)
        guard executableFD >= 0 else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        defer { close(executableFD) }
        var executableStat = stat()
        guard fstat(executableFD, &executableStat) == 0,
              (executableStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        let executablePath = try linuxExecutablePath(pid: credential.pid)
        let sha256 = try linuxExecutableSHA256(fileDescriptor: executableFD)
        return BurnBarLinuxPeerCredential(
            pid: credential.pid,
            uid: credential.uid,
            gid: credential.gid,
            executablePath: executablePath,
            executableSHA256: sha256
        )
    }

    private static func linuxExecutablePath(pid: pid_t) throws -> String {
        let linkPath = "/proc/\(pid)/exe"
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink(linkPath, &buffer, buffer.count - 1)
        guard count > 0, count < buffer.count - 1 else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        let bytes = Data(buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) })
        guard let path = String(data: bytes, encoding: .utf8), !path.contains("\0") else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        return path
    }

    private static func linuxExecutableSHA256(fileDescriptor: Int32) throws -> String {
        guard lseek(fileDescriptor, 0, SEEK_SET) >= 0 else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Glibc.read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
            }
            data.append(buffer, count: count)
            if data.count > 512 * 1024 * 1024 {
                throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
            }
        }
        return PlatformCrypto.sha256Hex(data)
    }

    private static func linuxValidateImmutableDirectory(path: String, requiredOwnerUID: uid_t) throws {
        var metadata = stat()
        var filesystem = statvfs()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == requiredOwnerUID,
              metadata.st_mode & mode_t(0o022) == 0,
              statvfs(path, &filesystem) == 0,
              metadata.st_mode & mode_t(0o200) == 0
                || filesystem.f_flag & UInt(ST_RDONLY) != 0 else {
            throw linuxPeerInvalid()
        }
    }

    private static func linuxReadBoundedRegularFile(
        path: String,
        minimumBytes: Int = 1,
        maximumBytes: Int,
        requiredOwnerUID: uid_t,
        requireNoGroupOrWorldWrite: Bool
    ) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw linuxPeerInvalid() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == requiredOwnerUID,
              !requireNoGroupOrWorldWrite || metadata.st_mode & mode_t(0o022) == 0,
              Int(metadata.st_size) >= minimumBytes,
              Int(metadata.st_size) <= maximumBytes else {
            throw linuxPeerInvalid()
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 64 * 1024))
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw linuxPeerInvalid()
            }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else { throw linuxPeerInvalid() }
        }
        guard data.count >= minimumBytes else { throw linuxPeerInvalid() }
        return data
    }

    private static func linuxPeerInvalid() -> BurnBarDaemonPeerAuthenticationFailure {
        .codeSignatureInvalid(status: daemonTokenUnavailableStatus)
    }

    private static func linuxPeerHashPins(environment: [String: String]) -> [String: String] {
        let raw = environment["OPENBURNBAR_DAEMON_LINUX_PEER_SHA256_PINS"]
            ?? environment["BURNBAR_DAEMON_LINUX_PEER_SHA256_PINS"]
            ?? ""
        var pins: [String: String] = [:]
        for entry in raw.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            pins[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pins
    }
    #endif
}
