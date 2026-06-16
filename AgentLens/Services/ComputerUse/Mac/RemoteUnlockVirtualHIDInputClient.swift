#if canImport(AppKit) && !DISTRIBUTION_MAS
import Darwin
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// User-session client for the privileged input leaf. Prefers XPC (native audit token); falls back to
/// the legacy Unix socket adapter until migration completes.
struct RemoteUnlockVirtualHIDInputClient: Sendable {
    private static let socketPath = RemoteUnlockSetupProbe.virtualHIDBridgeSocketPath
    private static let maximumResponseBytes = 16 * 1024
    private static let requestIOTimeoutSeconds: time_t = 4
    private static let sharedXPCClient = PrivilegedInputXPCClient()

    /// Performs a privileged-input envelope over the preferred (XPC/socket) lane.
    /// Injectable so tests can drive the trust-classification logic without a live helper.
    typealias EnvelopePerformer = @Sendable (PrivilegedInputDispatchEnvelope) throws -> Void

    private let performEnvelope: EnvelopePerformer

    /// Default production seam: dispatch through the shared `PrivilegedInputXPCClient`.
    init() {
        self.performEnvelope = { envelope in
            _ = try Self.sharedXPCClient.perform(envelope)
        }
    }

    /// Test seam: inject a custom envelope performer (e.g. one that throws a specific
    /// `PrivilegedInputXPCClient.ClientError`) to exercise the fail-closed classification.
    init(performEnvelope: @escaping EnvelopePerformer) {
        self.performEnvelope = performEnvelope
    }

    /// Blocking XPC/socket dispatch runs off the main actor: this is a
    /// `nonisolated` `async` method (the type is `Sendable`), so callers leave the
    /// main actor at the `await` (SE-0338).
    func dispatch(
        _ action: MacInputAction,
        capabilityToken: CapabilityToken? = nil,
        presentingEscrowDeviceId: String? = nil,
        requiredAttestationHashBlake3: String? = nil
    ) async throws -> BurnBarJSONValue {
        let request = PrivilegedInputDispatchRequest(
            operation: "input",
            kind: action.kind.rawValue,
            displayX: action.displayX,
            displayY: action.displayY,
            dragEndX: action.dragEndX,
            dragEndY: action.dragEndY,
            deltaX: action.deltaX,
            deltaY: action.deltaY,
            mouseButton: action.mouseButton,
            text: action.text,
            key: action.key,
            modifiers: action.modifiers
        )
        let envelope = PrivilegedInputDispatchEnvelope(
            request: request,
            capabilityToken: capabilityToken,
            presentingEscrowDeviceId: presentingEscrowDeviceId,
            requiredAttestationHashBlake3: requiredAttestationHashBlake3
        )
        // This method is `nonisolated async` (SE-0338), so the blocking dispatch
        // already runs off the main actor without a detached task.
        do {
            try performEnvelope(envelope)
            return Self.successPayload(for: action)
        } catch let error as PrivilegedInputXPCClient.ClientError {
            // Trust / authorization outcomes are TERMINAL — never silently downgrade
            // to the legacy socket. `rejected` means the authenticated helper refused
            // this action; `serverUntrusted` means the socket peer failed UID /
            // code-signature validation (something is impersonating the helper).
            // Retrying the SAME action — which can carry the macOS login credential —
            // on a weaker lane would convert a denial into a fail-open. Fail closed.
            switch error {
            case .rejected, .serverUntrusted:
                AppLogger.daemon.error(
                    "remote_unlock_privileged_input_trust_failure",
                    metadata: [
                        "errorClass": "\(String(describing: type(of: error)))",
                        "outcome": Self.trustOutcome(for: error)
                    ]
                )
                throw error
            case .connectionUnavailable, .remoteProxyUnavailable, .invalidResponse, .timedOut:
                // Genuine transport faults on the preferred lane are recoverable: the
                // helper may simply be absent on a legacy install. Record the
                // degradation, then attempt the legacy socket lane.
                AppLogger.daemon.notice(
                    "remote_unlock_privileged_input_lane_unavailable",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
            }
        } catch {
            // Any non-`ClientError` failure is a raw transport fault. Trust and
            // authorization decisions are expressed exclusively as ClientError
            // .rejected / .serverUntrusted, so these are safe to treat as
            // recoverable — log the degradation and try the legacy lane.
            AppLogger.daemon.notice(
                "remote_unlock_privileged_input_lane_unavailable",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
        }
        try Self.sendSocket(
            Self.legacyRequest(
                from: request,
                capabilityToken: capabilityToken,
                presentingEscrowDeviceId: presentingEscrowDeviceId,
                requiredAttestationHashBlake3: requiredAttestationHashBlake3
            )
        )
        return Self.successPayload(for: action)
    }

    private static func trustOutcome(for error: PrivilegedInputXPCClient.ClientError) -> String {
        switch error {
        case .rejected:
            return "rejected"
        case .serverUntrusted:
            return "server_untrusted"
        default:
            return "unknown"
        }
    }

    private static func successPayload(for action: MacInputAction) -> BurnBarJSONValue {
        .object([
            "ok": .bool(true),
            "kind": .string(action.kind.rawValue),
            "backend": .string("openburnbar_virtual_hid")
        ])
    }

    private static func legacyRequest(
        from request: PrivilegedInputDispatchRequest,
        capabilityToken: CapabilityToken?,
        presentingEscrowDeviceId: String?,
        requiredAttestationHashBlake3: String?
    ) -> RemoteUnlockVirtualHIDInputRequest {
        RemoteUnlockVirtualHIDInputRequest(
            operation: request.operation,
            password: request.password,
            kind: request.kind,
            displayX: request.displayX,
            displayY: request.displayY,
            dragEndX: request.dragEndX,
            dragEndY: request.dragEndY,
            deltaX: request.deltaX,
            deltaY: request.deltaY,
            mouseButton: request.mouseButton,
            text: request.text,
            key: request.key,
            modifiers: request.modifiers,
            capabilityToken: capabilityToken,
            presentingEscrowDeviceId: presentingEscrowDeviceId,
            requiredAttestationHashBlake3: requiredAttestationHashBlake3
        )
    }

    private static func sendSocket(_ request: RemoteUnlockVirtualHIDInputRequest) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socketUnavailable }
        defer { close(fd) }
        configureSocket(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try Self.socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw Error.socketPathTooLong }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Error.daemonUnavailable }

        // Authenticate the SERVER peer BEFORE writing the envelope. The legacy
        // bridge envelope can carry the macOS login `password`, and connect(2)
        // by itself proves only that *something* is listening at the path. This
        // mirrors the preferred (XPC/socket) lane's `PrivilegedInputSocketClient`
        // check exactly: peer UID must match the expected owner AND the peer
        // process must satisfy the first-party designated requirement (audit-token
        // + `SecCodeCreateWithAuditToken`-class validation — never a PID check).
        //
        // The `/var/run/openburnbar-virtual-hid.sock` bridge is a launchd SYSTEM
        // daemon (plist in `/Library/LaunchDaemons`, no `UserName` key), so it
        // runs as root: the expected server UID is 0. Fail closed if the peer
        // fails either gate.
        do {
            try OpenBurnBarPrivilegedTrust.validateServerPeer(
                socketFD: fd,
                expectedUID: 0,
                codeSignatureValidator: OpenBurnBarPrivilegedTrust.validateCodeSignature(ofAuditToken:)
            )
        } catch {
            AppLogger.daemon.error(
                "remote_unlock_virtual_hid_legacy_server_untrusted",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            throw Error.serverUntrusted
        }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw Error.timedOut }
                    throw Error.writeFailed
                }
                written += count
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var responseData = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Error.timedOut }
                throw Error.readFailed
            }
            responseData.append(buffer, count: count)
            if responseData.count > maximumResponseBytes { throw Error.responseTooLarge }
            if responseData.last == 0x0A { break }
        }

        let response = try JSONDecoder().decode(RemoteUnlockVirtualHIDInputResponse.self, from: responseData)
        guard response.ok else { throw Error.rejected(response.error ?? "virtual_hid_bridge_rejected") }
    }

    private static func configureSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeout = timeval(tv_sec: requestIOTimeoutSeconds, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, timeoutLength)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, timeoutLength)
        }
    }

    enum Error: Swift.Error, Equatable {
        case daemonUnavailable
        case readFailed
        case rejected(String)
        case responseTooLarge
        /// The process listening at `/var/run/openburnbar-virtual-hid.sock`
        /// failed server authentication (wrong UID or code signature) — something
        /// is impersonating the privileged bridge. Terminal by design: the legacy
        /// envelope can carry the login credential, so we never write to an
        /// unauthenticated peer.
        case serverUntrusted
        case socketPathTooLong
        case socketUnavailable
        case timedOut
        case writeFailed
    }
}

private struct RemoteUnlockVirtualHIDInputRequest: Encodable, Sendable {
    var operation: String
    var password: String?
    var kind: String?
    var displayX: Int?
    var displayY: Int?
    var dragEndX: Int?
    var dragEndY: Int?
    var deltaX: Int?
    var deltaY: Int?
    var mouseButton: Int?
    var text: String?
    var key: String?
    var modifiers: [String]?
    var capabilityToken: CapabilityToken?
    var presentingEscrowDeviceId: String?
    var requiredAttestationHashBlake3: String?
}

private struct RemoteUnlockVirtualHIDInputResponse: Decodable, Sendable {
    var ok: Bool
    var error: String?
}
#endif
