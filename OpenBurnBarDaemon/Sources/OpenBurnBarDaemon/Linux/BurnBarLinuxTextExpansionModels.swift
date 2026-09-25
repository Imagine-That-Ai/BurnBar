#if os(Linux)
import Foundation
import OpenBurnBarEngine

extension BurnBarLinuxTextExpansionAdapter {
    public enum Backend: String, Codable, Equatable, Sendable {
        case ibus
        case fcitx5
        case fcitx
    }

    public enum SessionType: String, Codable, Equatable, Sendable {
        case wayland
        case x11
        case unknown
    }

    public enum CapabilityState: String, Codable, Equatable, Sendable {
        case available
        case degraded
        case blocked
    }

    /// Registration is an explicit, observable boundary.  `registered` is
    /// only returned after every manifest, trust, path, permission, and
    /// compositor check succeeds.
    public enum RegistrationState: String, Codable, Equatable, Sendable {
        case optInRequired = "opt_in_required"
        case engineMissing = "engine_missing"
        case manifestPathRejected = "manifest_path_rejected"
        case manifestInvalid = "manifest_invalid"
        case signatureInvalid = "signature_invalid"
        case ownerPermissionsInvalid = "owner_permissions_invalid"
        case backendMismatch = "backend_mismatch"
        case sessionUnsupported = "session_unsupported"
        case registered
    }

    public enum SecureFieldPolicy: String, Codable, Equatable, Sendable {
        case denyUnlessInspectableAndExplicitlyNonsecure = "deny-unless-inspectable-and-explicitly-nonsecure"
    }

    /// The only manifest shape accepted by the external expansion boundary.
    /// Capability booleans are explicit so a missing safety declaration cannot
    /// accidentally opt an engine into clipboard, surrounding-text, or global
    /// keyboard access.
    public struct EngineManifest: Codable, Equatable, Sendable {
        public struct Signature: Codable, Equatable, Sendable {
            public let algorithm: String
            public let publicKeyBase64: String
            public let signatureBase64: String

            public init(
                algorithm: String = "ed25519",
                publicKeyBase64: String,
                signatureBase64: String
            ) {
                self.algorithm = algorithm
                self.publicKeyBase64 = publicKeyBase64
                self.signatureBase64 = signatureBase64
            }
        }

        public let schemaVersion: Int
        public let backend: Backend
        public let engineID: String
        public let executablePath: String
        public let executableSha256: String?
        public let supportsWayland: Bool
        public let supportsX11: Bool
        public let noGlobalCapture: Bool
        public let readsClipboard: Bool
        public let readsSurroundingText: Bool
        public let secureFieldPolicy: SecureFieldPolicy
        public let signature: Signature

        public init(
            schemaVersion: Int = 1,
            backend: Backend,
            engineID: String,
            executablePath: String,
            executableSha256: String? = nil,
            supportsWayland: Bool,
            supportsX11: Bool,
            noGlobalCapture: Bool = true,
            readsClipboard: Bool = false,
            readsSurroundingText: Bool = false,
            secureFieldPolicy: SecureFieldPolicy = .denyUnlessInspectableAndExplicitlyNonsecure,
            signature: Signature
        ) {
            self.schemaVersion = schemaVersion
            self.backend = backend
            self.engineID = engineID
            self.executablePath = executablePath
            self.executableSha256 = executableSha256
            self.supportsWayland = supportsWayland
            self.supportsX11 = supportsX11
            self.noGlobalCapture = noGlobalCapture
            self.readsClipboard = readsClipboard
            self.readsSurroundingText = readsSurroundingText
            self.secureFieldPolicy = secureFieldPolicy
            self.signature = signature
        }
    }

    /// Metadata read with `lstat(2)`. Symlinks are deliberately represented
    /// so a path swap cannot turn a trusted manifest or engine into another
    /// user's file between validation and launch.
    public struct FileMetadata: Equatable, Sendable {
        public let ownerUID: UInt32
        public let mode: UInt16
        public let isRegularFile: Bool
        public let isSymlink: Bool

        public init(ownerUID: UInt32, mode: UInt16, isRegularFile: Bool = true, isSymlink: Bool = false) {
            self.ownerUID = ownerUID
            self.mode = mode
            self.isRegularFile = isRegularFile
            self.isSymlink = isSymlink
        }
    }

    /// Typed snapshot used by Linux callers/tests. `status()` below keeps the
    /// existing daemon wire contract and serializes this snapshot to strings.
    public struct Status: Codable, Equatable, Sendable {
        public let state: CapabilityState
        public let backend: Backend?
        public let backendPath: String?
        public let sessionType: SessionType
        public let registration: RegistrationState
        public let supportsExternalExpansion: Bool
        public let secureFieldPolicy: SecureFieldPolicy
        public let noGlobalCapture: Bool
        public let detail: String
        public let checkedAt: String

        public var status: CapabilityState { state }

        public var wireValue: BurnBarTextExpansionNativeStatus {
            BurnBarTextExpansionNativeStatus(
                status: state.rawValue,
                backend: backend?.rawValue,
                backendPath: backendPath,
                sessionType: sessionType.rawValue,
                registration: registration.rawValue,
                supportsExternalExpansion: supportsExternalExpansion,
                secureFieldPolicy: secureFieldPolicy.rawValue,
                noGlobalCapture: noGlobalCapture,
                detail: detail,
                checkedAt: checkedAt
            )
        }
    }
}
#endif
