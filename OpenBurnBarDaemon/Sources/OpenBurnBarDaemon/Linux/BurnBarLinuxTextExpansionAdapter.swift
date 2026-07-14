#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore

/// Native Linux text-expansion integration boundary.
///
/// IBus and Fcitx are input-method protocols, not global keyboard hooks.  The
/// daemon only probes their control commands and never reads evdev/uinput,
/// compositor events, clipboard contents, or surrounding text. A packaged
/// engine still has to be registered before external expansion can be enabled.
/// The registration gate is explicit opt-in plus a bounded, signed,
/// owner-safe manifest; without it the adapter reports a degraded/blocked
/// state instead of claiming an integration.
public struct BurnBarLinuxTextExpansionAdapter: Sendable {
    public enum Backend: String, Codable, Sendable {
        case ibus
        case fcitx5
        case fcitx
    }

    public enum SessionType: String, Codable, Sendable {
        case wayland
        case x11
        case unknown
    }

    public enum CapabilityState: String, Codable, Sendable {
        case available
        case degraded
        case blocked
    }

    /// Registration is an explicit, observable boundary.  `registered` is
    /// only returned after every manifest, trust, path, permission, and
    /// compositor check succeeds.
    public enum RegistrationState: String, Codable, Sendable {
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

    public enum SecureFieldPolicy: String, Codable, Sendable {
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

    public enum SecureFieldDecision: Equatable, Sendable {
        case allow
        case deniedSecureField
        case deniedExcludedApplication
        case deniedUninspectable
    }

    /// Metadata supplied by an IBus/Fcitx engine bridge. It contains only
    /// accessibility state and identifiers; it must never contain field text.
    public struct SecureFieldContext: Equatable, Sendable {
        public let inspectable: Bool
        public let isSecureField: Bool?
        public let applicationID: String?
        public let role: String?
        public let inputPurpose: String?

        public init(
            inspectable: Bool,
            isSecureField: Bool? = nil,
            applicationID: String? = nil,
            role: String? = nil,
            inputPurpose: String? = nil
        ) {
            self.inspectable = inspectable
            self.isSecureField = isSecureField
            self.applicationID = applicationID
            self.role = role
            self.inputPurpose = inputPurpose
        }
    }

    public typealias EnvironmentReader = @Sendable (_ name: String) -> String?
    public typealias ExecutableResolver = @Sendable (_ name: String) -> String?
    public typealias CommandRunner = @Sendable (_ executablePath: String, _ arguments: [String]) throws -> CommandResult
    public typealias ManifestReader = @Sendable (_ path: String) throws -> Data
    public typealias FileMetadataReader = @Sendable (_ path: String) -> FileMetadata?
    public typealias SignatureVerifier = @Sendable (_ manifest: EngineManifest) -> Bool

    public struct CommandResult: Equatable, Sendable {
        public let exitCode: Int32

        public init(exitCode: Int32) {
            self.exitCode = exitCode
        }
    }

    /// Default resolver used by the daemon. It only searches PATH for the
    /// named input-method control utility.
    public static func defaultExecutablePath(_ name: String) -> String? {
        which(name)
    }

    /// Default bounded control probe. Output is drained and discarded.
    public static func defaultCommandRunner(_ executablePath: String, _ arguments: [String]) throws -> CommandResult {
        try runProcess(executablePath: executablePath, arguments: arguments)
    }

    public static func defaultManifestReader(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxManifestBytes + 1) ?? Data()
        guard data.count <= Self.maxManifestBytes else {
            throw ManifestReadError.tooLarge
        }
        return data
    }

    public static func defaultFileMetadataReader(_ path: String) -> FileMetadata? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let mode = UInt16(info.st_mode & 0o7777)
        let fileType = info.st_mode & S_IFMT
        return FileMetadata(
            ownerUID: UInt32(info.st_uid),
            mode: mode,
            isRegularFile: fileType == S_IFREG,
            isSymlink: fileType == S_IFLNK
        )
    }

    private let environment: EnvironmentReader
    private let resolveExecutable: ExecutableResolver
    private let runCommand: CommandRunner
    private let excludedApplicationIDs: Set<String>
    private let manifestPathOverride: String?
    private let externalExpansionEnabled: Bool?
    private let allowedManifestRoots: [String]
    private let allowedExecutableRoots: [String]
    private let trustedOwnerUIDs: Set<UInt32>
    private let readManifest: ManifestReader
    private let readFileMetadata: FileMetadataReader
    private let verifySignature: SignatureVerifier

    private enum ManifestReadError: Error {
        case tooLarge
    }

    private static let maxManifestBytes = 16 * 1024
    private static let maxEngineIDLength = 128

    public init(
        environment: @escaping EnvironmentReader = { ProcessInfo.processInfo.environment[$0] },
        resolveExecutable: @escaping ExecutableResolver = BurnBarLinuxTextExpansionAdapter.defaultExecutablePath,
        runCommand: @escaping CommandRunner = BurnBarLinuxTextExpansionAdapter.defaultCommandRunner,
        excludedApplicationIDs: Set<String> = [],
        manifestPath: String? = nil,
        externalExpansionEnabled: Bool? = nil,
        allowedManifestRoots: [String]? = nil,
        allowedExecutableRoots: [String]? = nil,
        trustedOwnerUIDs: Set<UInt32>? = nil,
        readManifest: @escaping ManifestReader = BurnBarLinuxTextExpansionAdapter.defaultManifestReader,
        readFileMetadata: @escaping FileMetadataReader = BurnBarLinuxTextExpansionAdapter.defaultFileMetadataReader,
        verifySignature: SignatureVerifier? = nil,
        trustedEnginePublicKeys: [Data]? = nil
    ) {
        self.environment = environment
        self.resolveExecutable = resolveExecutable
        self.runCommand = runCommand
        self.excludedApplicationIDs = Set(excludedApplicationIDs.map(Self.normalizeIdentifier))
        self.manifestPathOverride = manifestPath
        self.externalExpansionEnabled = externalExpansionEnabled
        self.allowedManifestRoots = allowedManifestRoots ?? Self.defaultManifestRoots(environment: environment)
        self.allowedExecutableRoots = allowedExecutableRoots ?? Self.defaultExecutableRoots(environment: environment)
        self.trustedOwnerUIDs = trustedOwnerUIDs ?? [UInt32(getuid()), 0]
        self.readManifest = readManifest
        self.readFileMetadata = readFileMetadata
        if let verifySignature {
            self.verifySignature = verifySignature
        } else {
            let trustedKeys = trustedEnginePublicKeys ?? Self.defaultTrustedEnginePublicKeys(environment: environment)
            self.verifySignature = { manifest in
                Self.defaultVerifySignature(manifest: manifest, trustedPublicKeys: trustedKeys)
            }
        }
    }

    /// Returns a capability snapshot suitable for the existing daemon text
    /// expansion response.  Health checks never include command output.
    public func status() -> BurnBarTextExpansionNativeStatus {
        typedStatus().wireValue
    }

    /// Typed counterpart to the legacy wire snapshot. No input or clipboard
    /// APIs are called by this method; it only probes a control command and
    /// validates packaged, owner-safe registration metadata.
    public func typedStatus() -> Status {
        let session = sessionType()
        let configured = configuredBackend()
        let candidates = candidateBackends(preferred: configured)
        var discoveredPath: String?
        var discoveredBackend: Backend?
        var sawExecutable = false
        var failureDetail: String?

        for backend in candidates {
            guard let path = commandPath(for: backend) else { continue }
            sawExecutable = true
            let result: CommandResult
            do {
                result = try runCommand(path, commandArguments(for: backend))
            } catch {
                failureDetail = "\(backend.rawValue) control probe failed."
                continue
            }
            guard result.exitCode == 0 else {
                failureDetail = "\(backend.rawValue) control probe is not running."
                continue
            }
            discoveredBackend = backend
            discoveredPath = path
            break
        }

        guard let backend = discoveredBackend else {
            let detail: String
            if sawExecutable {
                detail = failureDetail ?? "An installed input method did not report a running session."
            } else {
                detail = "No IBus or Fcitx control executable is available in PATH."
            }
            return makeStatus(
                state: .blocked,
                backend: configured?.rawValue,
                backendPath: nil,
                sessionType: session,
                registration: .engineMissing,
                detail: detail
            )
        }

        guard session != .unknown else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .engineMissing,
                detail: "Input method is running, but the desktop session type is not provable."
            )
        }

        guard isExternalExpansionEnabled else {
            return makeStatus(
                state: .degraded,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .optInRequired,
                detail: "\(backend.rawValue) is reachable, but external expansion is opt-in and remains disabled."
            )
        }

        guard let path = engineManifestPath else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .engineMissing,
                detail: "External expansion is enabled, but no engine manifest is installed."
            )
        }
        guard isAllowedPath(path, roots: allowedManifestRoots) else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .manifestPathRejected,
                detail: "The external expansion manifest is outside a trusted OpenBurnBar data root."
            )
        }
        guard let manifestMetadata = readFileMetadata(path) else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .engineMissing,
                detail: "External expansion is enabled, but the engine manifest is not installed."
            )
        }
        guard isTrusted(metadata: manifestMetadata, executable: false) else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .ownerPermissionsInvalid,
                detail: "The external expansion manifest is missing or has unsafe owner permissions."
            )
        }

        let manifest: EngineManifest
        do {
            manifest = try JSONDecoder().decode(EngineManifest.self, from: readManifest(path))
        } catch {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .manifestInvalid,
                detail: "The external expansion manifest is invalid or exceeds the bounded format."
            )
        }

        guard isValidManifestShape(manifest) else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .manifestInvalid,
                detail: "The external expansion manifest does not prove a no-capture engine contract."
            )
        }
        guard manifest.backend == backend else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .backendMismatch,
                detail: "The external expansion manifest targets a different input-method backend."
            )
        }
        let supportsSession = session == .wayland ? manifest.supportsWayland : manifest.supportsX11
        guard supportsSession else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .sessionUnsupported,
                detail: "The registered input-method engine does not support this desktop session."
            )
        }
        guard verifySignature(manifest) else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .signatureInvalid,
                detail: "The external expansion manifest signature is missing or untrusted."
            )
        }
        guard isAllowedPath(manifest.executablePath, roots: allowedExecutableRoots),
              let executableMetadata = readFileMetadata(manifest.executablePath),
              isTrusted(metadata: executableMetadata, executable: true) else {
            return makeStatus(
                state: .blocked,
                backend: backend.rawValue,
                backendPath: discoveredPath,
                sessionType: session,
                registration: .ownerPermissionsInvalid,
                detail: "The registered input-method engine path or owner permissions are unsafe."
            )
        }

        return makeStatus(
            state: .available,
            backend: backend.rawValue,
            backendPath: manifest.executablePath,
            sessionType: session,
            registration: .registered,
            supportsExternalExpansion: true,
            detail: "\(backend.rawValue) engine \(manifest.engineID) is registered for \(session.rawValue); no global capture is enabled."
        )
    }

    /// Apply the native engine's secure-field signal without inspecting field
    /// text. Unknown or uninspectable contexts are denied by default.
    public func secureFieldDecision(for context: SecureFieldContext) -> SecureFieldDecision {
        if let applicationID = context.applicationID,
           excludedApplicationIDs.contains(Self.normalizeIdentifier(applicationID)) {
            return .deniedExcludedApplication
        }
        guard context.inspectable else { return .deniedUninspectable }
        if context.isSecureField == true || Self.looksSecure(role: context.role, purpose: context.inputPurpose) {
            return .deniedSecureField
        }
        guard context.isSecureField == false else { return .deniedUninspectable }
        return .allow
    }

    private func makeStatus(
        state: CapabilityState,
        backend: String?,
        backendPath: String?,
        sessionType: SessionType,
        registration: RegistrationState,
        supportsExternalExpansion: Bool = false,
        detail: String
    ) -> Status {
        Status(
            state: state,
            backend: backend.flatMap(Backend.init(rawValue:)),
            backendPath: backendPath,
            sessionType: sessionType,
            registration: registration,
            supportsExternalExpansion: supportsExternalExpansion,
            secureFieldPolicy: .denyUnlessInspectableAndExplicitlyNonsecure,
            noGlobalCapture: true,
            detail: detail,
            checkedAt: Self.isoNow()
        )
    }

    private func sessionType() -> SessionType {
        if let session = Self.nonEmpty(environment("XDG_SESSION_TYPE"))?.lowercased(),
           let parsed = SessionType(rawValue: session), parsed != .unknown {
            return parsed
        }
        if Self.nonEmpty(environment("WAYLAND_DISPLAY")) != nil { return .wayland }
        if Self.nonEmpty(environment("DISPLAY")) != nil { return .x11 }
        return .unknown
    }

    private var isExternalExpansionEnabled: Bool {
        if let externalExpansionEnabled { return externalExpansionEnabled }
        let value = Self.nonEmpty(environment("OPENBURNBAR_LINUX_TEXT_EXPANSION_EXTERNAL"))?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    private var engineManifestPath: String? {
        if let manifestPathOverride { return Self.standardizedPath(manifestPathOverride) }
        if let configured = Self.nonEmpty(environment("OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST")) {
            return Self.standardizedPath(configured)
        }
        guard let root = allowedManifestRoots.first else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("text-expansion-engine.json")
            .standardizedFileURL.path
    }

    private func isValidManifestShape(_ manifest: EngineManifest) -> Bool {
        guard manifest.schemaVersion == 1,
              !manifest.engineID.isEmpty,
              manifest.engineID.count <= Self.maxEngineIDLength,
              manifest.engineID.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && !$0.properties.isControl }),
              manifest.executablePath.hasPrefix("/"),
              !manifest.executablePath.contains("\n"),
              manifest.noGlobalCapture,
              !manifest.readsClipboard,
              !manifest.readsSurroundingText,
              manifest.secureFieldPolicy == .denyUnlessInspectableAndExplicitlyNonsecure else {
            return false
        }
        return manifest.signature.algorithm.lowercased() == "ed25519"
    }

    private func isTrusted(metadata: FileMetadata, executable: Bool) -> Bool {
        guard metadata.isRegularFile, !metadata.isSymlink,
              trustedOwnerUIDs.contains(metadata.ownerUID),
              metadata.mode & 0o022 == 0 else {
            return false
        }
        if executable {
            return metadata.mode & 0o111 != 0
        }
        return true
    }

    private func isAllowedPath(_ path: String, roots: [String]) -> Bool {
        let candidate = Self.standardizedPath(path)
        guard candidate.hasPrefix("/") else { return false }
        return roots.contains { root in
            let normalizedRoot = Self.standardizedPath(root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let normalizedCandidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return normalizedCandidate == normalizedRoot || normalizedCandidate.hasPrefix(normalizedRoot + "/")
        }
    }

    /// The package builder signs this exact, text-only representation. It
    /// intentionally excludes the signature itself and contains no field,
    /// clipboard, or surrounding-text data.
    public static func signingPayload(for manifest: EngineManifest) -> Data {
        let lines = [
            "schema_version=\(manifest.schemaVersion)",
            "backend=\(manifest.backend.rawValue)",
            "engine_id=\(manifest.engineID)",
            "executable_path=\(manifest.executablePath)",
            "supports_wayland=\(manifest.supportsWayland)",
            "supports_x11=\(manifest.supportsX11)",
            "no_global_capture=\(manifest.noGlobalCapture)",
            "reads_clipboard=\(manifest.readsClipboard)",
            "reads_surrounding_text=\(manifest.readsSurroundingText)",
            "secure_field_policy=\(manifest.secureFieldPolicy.rawValue)"
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func defaultVerifySignature(
        manifest: EngineManifest,
        trustedPublicKeys: [Data]
    ) -> Bool {
        guard manifest.signature.algorithm.lowercased() == "ed25519",
              let publicKey = Data(base64Encoded: manifest.signature.publicKeyBase64),
              let signature = Data(base64Encoded: manifest.signature.signatureBase64),
              publicKey.count == 32,
              signature.count == 64,
              trustedPublicKeys.contains(publicKey) else {
            return false
        }
        return (try? PlatformCrypto.verifyEd25519Signature(
            signature,
            message: signingPayload(for: manifest),
            publicKeyRaw: publicKey
        )) == true
    }

    private static func defaultTrustedEnginePublicKeys(environment: @escaping EnvironmentReader) -> [Data] {
        guard let encoded = nonEmpty(environment("OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_PUBLIC_KEY")) else {
            return []
        }
        return encoded
            .split(separator: ",")
            .compactMap { Data(base64Encoded: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0.count == 32 }
    }

    private static func defaultManifestRoots(environment: @escaping EnvironmentReader) -> [String] {
        let home = nonEmpty(environment("HOME")) ?? "/tmp"
        let dataHome = nonEmpty(environment("XDG_DATA_HOME")) ??
            URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".local/share").path
        let configHome = nonEmpty(environment("XDG_CONFIG_HOME")) ??
            URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config").path
        return [
            URL(fileURLWithPath: dataHome, isDirectory: true).appendingPathComponent("openburnbar").path,
            URL(fileURLWithPath: configHome, isDirectory: true).appendingPathComponent("openburnbar").path,
            "/usr/share/openburnbar",
            "/usr/local/share/openburnbar"
        ].map(standardizedPath)
    }

    private static func defaultExecutableRoots(environment: @escaping EnvironmentReader) -> [String] {
        let home = nonEmpty(environment("HOME")) ?? "/tmp"
        let dataHome = nonEmpty(environment("XDG_DATA_HOME")) ??
            URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".local/share").path
        return [
            URL(fileURLWithPath: dataHome, isDirectory: true).appendingPathComponent("openburnbar").path,
            "/usr/lib/openburnbar",
            "/usr/libexec/openburnbar",
            "/usr/local/libexec/openburnbar"
        ].map(standardizedPath)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func configuredBackend() -> Backend? {
        let values = ["GTK_IM_MODULE", "QT_IM_MODULE", "SDL_IM_MODULE", "CLUTTER_IM_MODULE", "XMODIFIERS"]
            .compactMap { Self.nonEmpty(environment($0))?.lowercased() }
        if values.contains(where: { $0.contains("fcitx5") }) { return .fcitx5 }
        if values.contains(where: { $0.contains("fcitx") }) { return .fcitx }
        if values.contains(where: { $0.contains("ibus") }) { return .ibus }
        return nil
    }

    private func candidateBackends(preferred: Backend?) -> [Backend] {
        let all: [Backend] = [.fcitx5, .fcitx, .ibus]
        guard let preferred else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    private func commandPath(for backend: Backend) -> String? {
        switch backend {
        case .ibus:
            return resolveExecutable("ibus")
        case .fcitx5:
            return resolveExecutable("fcitx5-remote")
        case .fcitx:
            return resolveExecutable("fcitx-remote")
        }
    }

    private func commandArguments(for backend: Backend) -> [String] {
        switch backend {
        case .ibus:
            // `ibus engine` reads the active engine and does not mutate input
            // state or retrieve surrounding/field text.
            return ["engine"]
        case .fcitx5, .fcitx:
            return ["--check"]
        }
    }

    private static func looksSecure(role: String?, purpose: String?) -> Bool {
        let words = [role, purpose]
            .compactMap { nonEmpty($0)?.lowercased() }
            .joined(separator: " ")
        return [
            "password", "passcode", "pin", "credential", "secret", "private",
            "secure", "protected", "authentication", "authorization", "polkit",
            "keyring", "kwallet", "login"
        ].contains { words.contains($0) }
    }

    private static func normalizeIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func which(_ name: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return pathValue.split(separator: ":").map(String.init)
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            // A broken helper must not be able to hold the daemon RPC actor
            // indefinitely by ignoring SIGTERM.
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            _ = error.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(exitCode: 124)
        }
        // Drain both pipes but intentionally discard their contents. Input
        // method commands must never make field text part of diagnostics.
        _ = output.fileHandleForReading.readDataToEndOfFile()
        _ = error.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(exitCode: process.terminationStatus)
    }
}
#endif
