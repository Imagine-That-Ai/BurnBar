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

    /// The versioned protocol spoken by a packaged external expansion engine.
    /// The engine receives a handshake and trigger-only expansion requests;
    /// field, clipboard, keyboard, and surrounding-text data are intentionally
    /// not representable in this contract.
    public struct EngineHandshake: Codable, Equatable, Sendable {
        public let protocolName: String
        public let protocolVersion: Int
        public let engineID: String
        public let noGlobalCapture: Bool
        public let readsClipboard: Bool
        public let readsSurroundingText: Bool
        public let secureFieldPolicy: SecureFieldPolicy

        public init(
            protocolName: String = "openburnbar.text-expansion",
            protocolVersion: Int = 1,
            engineID: String,
            noGlobalCapture: Bool,
            readsClipboard: Bool,
            readsSurroundingText: Bool,
            secureFieldPolicy: SecureFieldPolicy
        ) {
            self.protocolName = protocolName
            self.protocolVersion = protocolVersion
            self.engineID = engineID
            self.noGlobalCapture = noGlobalCapture
            self.readsClipboard = readsClipboard
            self.readsSurroundingText = readsSurroundingText
            self.secureFieldPolicy = secureFieldPolicy
        }

        private enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
            case protocolVersion
            case engineID
            case noGlobalCapture
            case readsClipboard
            case readsSurroundingText
            case secureFieldPolicy
        }
    }

    public enum EngineRuntimeState: String, Codable, Equatable, Sendable {
        case ready
        case stopped
        case timedOut = "timed_out"
        case cancelled
        case killSwitchActive = "kill_switch_active"
    }

    public struct EngineRuntimeStatus: Codable, Equatable, Sendable {
        public let state: EngineRuntimeState
        public let engineID: String
        public let executablePath: String
        public let detail: String
        public let checkedAt: String

        public init(
            state: EngineRuntimeState,
            engineID: String,
            executablePath: String,
            detail: String,
            checkedAt: String
        ) {
            self.state = state
            self.engineID = engineID
            self.executablePath = executablePath
            self.detail = detail
            self.checkedAt = checkedAt
        }
    }

    public enum EngineRuntimeError: Error, Equatable, CustomStringConvertible, Sendable {
        case notRegistered(RegistrationState)
        case manifestUnavailable
        case launchFailed
        case handshakeTimedOut
        case handshakeCancelled
        case killSwitchActive
        case handshakeInvalid
        case sessionStopped
        case expansionInvalid
        case expansionDenied(SecureFieldDecision)
        case expansionTimedOut
        case expansionCancelled
        case expansionResponseInvalid
        case expansionResponseTooLarge
        case expansionFailed

        public var description: String {
            switch self {
            case .notRegistered(let registration):
                return "linux_text_expansion_not_registered: \(registration.rawValue)"
            case .manifestUnavailable:
                return "linux_text_expansion_manifest_unavailable"
            case .launchFailed:
                return "linux_text_expansion_engine_launch_failed"
            case .handshakeTimedOut:
                return "linux_text_expansion_engine_handshake_timed_out"
            case .handshakeCancelled:
                return "linux_text_expansion_engine_handshake_cancelled"
            case .killSwitchActive:
                return "linux_text_expansion_engine_kill_switch_active"
            case .handshakeInvalid:
                return "linux_text_expansion_engine_handshake_invalid"
            case .sessionStopped:
                return "linux_text_expansion_engine_session_stopped"
            case .expansionInvalid:
                return "linux_text_expansion_engine_expansion_request_invalid"
            case .expansionDenied(let decision):
                return "linux_text_expansion_engine_expansion_denied: \(decision.rawValue)"
            case .expansionTimedOut:
                return "linux_text_expansion_engine_expansion_timed_out"
            case .expansionCancelled:
                return "linux_text_expansion_engine_expansion_cancelled"
            case .expansionResponseInvalid:
                return "linux_text_expansion_engine_expansion_response_invalid"
            case .expansionResponseTooLarge:
                return "linux_text_expansion_engine_expansion_response_too_large"
            case .expansionFailed:
                return "linux_text_expansion_engine_expansion_failed"
            }
        }
    }

    /// A live external engine process. Callers must make a secure-field
    /// decision for each target context. Expansion requests contain only a
    /// bounded trigger key; the process is never given keyboard events,
    /// clipboard contents, surrounding text, or field contents.
    public actor ExternalEngineSession {
        public nonisolated let engineID: String
        public nonisolated let executablePath: String
        public nonisolated let manifestPublicKeyBase64: String

        private let process: Process
        private let input: FileHandle
        private let output: FileHandle
        private let error: FileHandle
        private let killSwitch: @Sendable () -> Bool
        private let secureFieldEvaluator: @Sendable (SecureFieldContext) -> SecureFieldDecision
        private var state: EngineRuntimeState = .ready

        fileprivate init(
            process: Process,
            input: FileHandle,
            output: FileHandle,
            error: FileHandle,
            engineID: String,
            executablePath: String,
            manifestPublicKeyBase64: String,
            killSwitch: @escaping @Sendable () -> Bool,
            secureFieldEvaluator: @escaping @Sendable (SecureFieldContext) -> SecureFieldDecision
        ) {
            self.process = process
            self.input = input
            self.output = output
            self.error = error
            self.engineID = engineID
            self.executablePath = executablePath
            self.manifestPublicKeyBase64 = manifestPublicKeyBase64
            self.killSwitch = killSwitch
            self.secureFieldEvaluator = secureFieldEvaluator
        }

        deinit {
            if process.isRunning {
                process.terminate()
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }

        /// Reports lifecycle state and enforces the kill switch at every
        /// status boundary.  No engine output is surfaced in diagnostics.
        public func status() -> EngineRuntimeStatus {
            if state == .ready, killSwitch() {
                terminateProcess(timeoutMillis: 100)
                state = .killSwitchActive
            } else if state == .ready, !process.isRunning {
                state = .stopped
                input.closeFile()
                _ = output.readDataToEndOfFile()
                _ = error.readDataToEndOfFile()
            }
            return makeStatus(detail: detail(for: state))
        }

        /// Applies the same fail-closed policy as the adapter without ever
        /// forwarding the context or any field content to the engine.
        public func secureFieldDecision(for context: SecureFieldContext) -> SecureFieldDecision {
            secureFieldEvaluator(context)
        }

        /// Requests one expansion using only a canonical trigger key. The
        /// secure-field context is evaluated inside the daemon and is never
        /// serialized to the engine. A non-cooperative or malformed engine is
        /// terminated before the error is returned.
        public func expand(
            trigger: String,
            context: SecureFieldContext,
            timeoutMillis: Int = 1_000,
            requestID: String = UUID().uuidString
        ) async throws -> String? {
            guard !Task.isCancelled else {
                throw EngineRuntimeError.expansionCancelled
            }
            guard state == .ready, process.isRunning else {
                state = .stopped
                throw EngineRuntimeError.sessionStopped
            }
            guard (100...30_000).contains(timeoutMillis),
                  let canonicalTrigger = BurnBarLinuxTextExpansionAdapter.canonicalTrigger(trigger),
                  BurnBarLinuxTextExpansionAdapter.isValidRequestID(requestID) else {
                throw EngineRuntimeError.expansionInvalid
            }
            let decision = secureFieldEvaluator(context)
            guard decision == .allow else {
                throw EngineRuntimeError.expansionDenied(decision)
            }
            guard !killSwitch() else {
                terminateProcess(timeoutMillis: 100)
                state = .killSwitchActive
                throw EngineRuntimeError.killSwitchActive
            }
            guard !Task.isCancelled else {
                throw EngineRuntimeError.expansionCancelled
            }

            do {
                let request = try BurnBarLinuxTextExpansionAdapter.expansionRequest(
                    requestID: requestID,
                    trigger: canonicalTrigger
                )
                try input.write(contentsOf: request)
                let data = try BurnBarLinuxTextExpansionAdapter.readExpansionResponse(
                    from: output,
                    timeoutMillis: timeoutMillis,
                    killSwitch: killSwitch
                )
                try Task.checkCancellation()
                let response: ExpansionResponse
                do {
                    response = try JSONDecoder().decode(ExpansionResponse.self, from: data)
                } catch {
                    throw EngineRuntimeError.expansionResponseInvalid
                }
                guard BurnBarLinuxTextExpansionAdapter.isValidExpansionResponse(response, requestID: requestID) else {
                    throw EngineRuntimeError.expansionResponseInvalid
                }
                switch response.status {
                case .expanded:
                    guard let replacement = response.replacement else {
                        throw EngineRuntimeError.expansionResponseInvalid
                    }
                    guard replacement.utf8.count <= BurnBarLinuxTextExpansionAdapter.maxExpansionBytes else {
                        throw EngineRuntimeError.expansionResponseTooLarge
                    }
                    return replacement
                case .notFound:
                    guard response.replacement == nil else {
                        throw EngineRuntimeError.expansionResponseInvalid
                    }
                    return nil
                }
            } catch let error as EngineRuntimeError {
                switch error {
                case .expansionResponseInvalid, .expansionResponseTooLarge:
                    terminateProcess(timeoutMillis: 100)
                    state = .stopped
                default:
                    break
                }
                throw error
            } catch ExpansionWaitError.timedOut {
                terminateProcess(timeoutMillis: 100)
                state = .timedOut
                throw EngineRuntimeError.expansionTimedOut
            } catch ExpansionWaitError.killSwitchActive {
                terminateProcess(timeoutMillis: 100)
                state = .killSwitchActive
                throw EngineRuntimeError.killSwitchActive
            } catch ExpansionWaitError.responseTooLarge {
                terminateProcess(timeoutMillis: 100)
                state = .stopped
                throw EngineRuntimeError.expansionResponseTooLarge
            } catch is CancellationError {
                terminateProcess(timeoutMillis: 100)
                state = .cancelled
                throw EngineRuntimeError.expansionCancelled
            } catch {
                terminateProcess(timeoutMillis: 100)
                state = .stopped
                throw EngineRuntimeError.expansionFailed
            }
        }

        /// Sends a text-free stop request, then terminates a non-cooperative
        /// process within the bounded deadline.  Kill-switch termination is
        /// distinguished from an ordinary user stop.
        public func stop(timeoutMillis: Int = 500) async -> EngineRuntimeStatus {
            guard state == .ready else { return status() }
            if killSwitch() {
                terminateProcess(timeoutMillis: min(timeoutMillis, 100))
                state = .killSwitchActive
                return makeStatus(detail: detail(for: state))
            }
            let stopRequest = Data("{\"operation\":\"stop\",\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1}\n".utf8)
            try? input.write(contentsOf: stopRequest)
            terminateProcess(timeoutMillis: max(1, timeoutMillis))
            state = .stopped
            return makeStatus(detail: detail(for: state))
        }

        private func makeStatus(detail: String) -> EngineRuntimeStatus {
            EngineRuntimeStatus(
                state: state,
                engineID: engineID,
                executablePath: executablePath,
                detail: detail,
                checkedAt: BurnBarLinuxTextExpansionAdapter.isoNow()
            )
        }

        private func detail(for state: EngineRuntimeState) -> String {
            switch state {
            case .ready:
                return "Signed external text-expansion engine handshake completed."
            case .stopped:
                return "External text-expansion engine stopped."
            case .timedOut:
                return "External text-expansion engine handshake or expansion request timed out."
            case .cancelled:
                return "External text-expansion engine handshake or expansion request was cancelled."
            case .killSwitchActive:
                return "External text-expansion engine stopped by the Linux kill switch."
            }
        }

        private func terminateProcess(timeoutMillis: Int) {
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(Double(max(1, timeoutMillis)) / 1_000)
                while process.isRunning, Date() < deadline {
                    usleep(5_000)
                }
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }
            input.closeFile()
            _ = output.readDataToEndOfFile()
            _ = error.readDataToEndOfFile()
        }
    }

    public enum SecureFieldDecision: Equatable, Sendable {
        case allow
        case deniedSecureField
        case deniedExcludedApplication
        case deniedUninspectable

        fileprivate var rawValue: String {
            switch self {
            case .allow: return "allow"
            case .deniedSecureField: return "denied_secure_field"
            case .deniedExcludedApplication: return "denied_excluded_application"
            case .deniedUninspectable: return "denied_uninspectable"
            }
        }
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
    private static let maxHandshakeBytes = 4 * 1024
    private static let maxExpansionBytes = 128 * 1024
    private static let maxRequestIDBytes = 128
    private static let engineProtocolName = "openburnbar.text-expansion"
    private static let engineProtocolVersion = 1
    private static let engineLaunchArguments = [
        "--openburnbar-text-expansion-engine",
        "--protocol",
        engineProtocolName,
        "--protocol-version",
        "1"
    ]

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

    /// Launches the explicitly opted-in, signed engine using only the exact
    /// executable path from its validated manifest.  The engine protocol is
    /// intentionally lifecycle-only: no API here accepts keyboard events,
    /// clipboard data, surrounding text, or field contents.
    public func startExternalEngine(
        timeoutMillis: Int = 1_000,
        killSwitch: @escaping @Sendable () -> Bool = { false }
    ) async throws -> ExternalEngineSession {
        try Task.checkCancellation()
        guard !killSwitch() else { throw EngineRuntimeError.killSwitchActive }

        let registration = typedStatus()
        guard registration.registration == .registered,
              registration.supportsExternalExpansion,
              let executablePath = registration.backendPath,
              let manifestPath = engineManifestPath else {
            throw EngineRuntimeError.notRegistered(registration.registration)
        }

        let manifest: EngineManifest
        do {
            guard isAllowedPath(manifestPath, roots: allowedManifestRoots),
                  let manifestMetadata = readFileMetadata(manifestPath),
                  isTrusted(metadata: manifestMetadata, executable: false),
                  let executableMetadata = readFileMetadata(executablePath),
                  isTrusted(metadata: executableMetadata, executable: true) else {
                throw EngineRuntimeError.notRegistered(.ownerPermissionsInvalid)
            }
            manifest = try JSONDecoder().decode(EngineManifest.self, from: readManifest(manifestPath))
        } catch let error as EngineRuntimeError {
            throw error
        } catch {
            throw EngineRuntimeError.manifestUnavailable
        }
        guard isValidManifestShape(manifest),
              Self.standardizedPath(manifest.executablePath) == Self.standardizedPath(executablePath),
              isAllowedPath(manifest.executablePath, roots: allowedExecutableRoots),
              verifySignature(manifest) else {
            throw EngineRuntimeError.notRegistered(.signatureInvalid)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = Self.engineLaunchArguments + ["--engine-id", manifest.engineID]
        process.environment = runtimeEnvironment()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            let request = try Self.handshakeRequest(for: manifest)
            try inputPipe.fileHandleForWriting.write(contentsOf: request)
            let data = try Self.readHandshake(
                from: outputPipe.fileHandleForReading,
                timeoutMillis: max(1, timeoutMillis),
                killSwitch: killSwitch
            )
            try Task.checkCancellation()
            let handshake = try JSONDecoder().decode(EngineHandshake.self, from: data)
            guard Self.isValidHandshake(handshake, for: manifest), process.isRunning else {
                throw EngineRuntimeError.handshakeInvalid
            }
            return ExternalEngineSession(
                process: process,
                input: inputPipe.fileHandleForWriting,
                output: outputPipe.fileHandleForReading,
                error: errorPipe.fileHandleForReading,
                engineID: manifest.engineID,
                executablePath: Self.standardizedPath(executablePath),
                manifestPublicKeyBase64: manifest.signature.publicKeyBase64,
                killSwitch: killSwitch,
                secureFieldEvaluator: secureFieldDecision
            )
        } catch let error as EngineRuntimeError {
            Self.terminateProcess(process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw error
        } catch HandshakeWaitError.timedOut {
            Self.terminateProcess(process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw EngineRuntimeError.handshakeTimedOut
        } catch HandshakeWaitError.killSwitchActive {
            Self.terminateProcess(process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw EngineRuntimeError.killSwitchActive
        } catch is CancellationError {
            Self.terminateProcess(process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw EngineRuntimeError.handshakeCancelled
        } catch {
            Self.terminateProcess(process, input: inputPipe, output: outputPipe, error: errorPipe)
            throw EngineRuntimeError.launchFailed
        }
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

    private func runtimeEnvironment() -> [String: String] {
        // Do not inherit arbitrary environment entries: provider credentials
        // and other secrets must never be copied into an external engine.
        let allowedNames = [
            "HOME", "PATH", "LANG", "LC_ALL", "LC_MESSAGES",
            "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE", "WAYLAND_DISPLAY", "DISPLAY",
            "DBUS_SESSION_BUS_ADDRESS", "XDG_CURRENT_DESKTOP", "XDG_CONFIG_HOME",
            "XDG_DATA_HOME", "GTK_IM_MODULE", "QT_IM_MODULE", "SDL_IM_MODULE",
            "CLUTTER_IM_MODULE", "XMODIFIERS"
        ]
        return allowedNames.reduce(into: [String: String]()) { result, name in
            if let value = Self.nonEmpty(environment(name)) {
                result[name] = value
            }
        }
    }

    private struct HandshakeRequest: Codable, Sendable {
        let operation: String
        let `protocol`: String
        let protocolVersion: Int
        let engineID: String
        let noGlobalCapture: Bool
        let readsClipboard: Bool
        let readsSurroundingText: Bool
        let secureFieldPolicy: SecureFieldPolicy
    }

    private enum ExpansionStatus: String, Codable, Sendable {
        case expanded
        case notFound = "not_found"
    }

    private struct ExpansionRequest: Codable, Sendable {
        let operation: String
        let `protocol`: String
        let protocolVersion: Int
        let requestID: String
        let trigger: String
    }

    private struct ExpansionResponse: Codable, Sendable {
        let operation: String
        let `protocol`: String
        let protocolVersion: Int
        let requestID: String
        let status: ExpansionStatus
        let replacement: String?
    }

    private enum HandshakeWaitError: Error {
        case timedOut
        case killSwitchActive
    }

    private enum ExpansionWaitError: Error {
        case timedOut
        case killSwitchActive
        case responseTooLarge
        case closed
    }

    private static func handshakeRequest(for manifest: EngineManifest) throws -> Data {
        let request = HandshakeRequest(
            operation: "handshake",
            protocol: engineProtocolName,
            protocolVersion: engineProtocolVersion,
            engineID: manifest.engineID,
            noGlobalCapture: true,
            readsClipboard: false,
            readsSurroundingText: false,
            secureFieldPolicy: .denyUnlessInspectableAndExplicitlyNonsecure
        )
        return try JSONEncoder().encode(request) + Data([0x0A])
    }

    private static func isValidHandshake(
        _ handshake: EngineHandshake,
        for manifest: EngineManifest
    ) -> Bool {
        handshake.protocolName == engineProtocolName &&
            handshake.protocolVersion == engineProtocolVersion &&
            handshake.engineID == manifest.engineID &&
            handshake.noGlobalCapture &&
            !handshake.readsClipboard &&
            !handshake.readsSurroundingText &&
            handshake.secureFieldPolicy == .denyUnlessInspectableAndExplicitlyNonsecure
    }

    private static func expansionRequest(requestID: String, trigger: String) throws -> Data {
        let request = ExpansionRequest(
            operation: "expand",
            protocol: engineProtocolName,
            protocolVersion: engineProtocolVersion,
            requestID: requestID,
            trigger: trigger
        )
        return try JSONEncoder().encode(request) + Data([0x0A])
    }

    private static func isValidExpansionResponse(
        _ response: ExpansionResponse,
        requestID: String
    ) -> Bool {
        response.operation == "expand_result" &&
            response.protocol == engineProtocolName &&
            response.protocolVersion == engineProtocolVersion &&
            response.requestID == requestID
    }

    private static func canonicalTrigger(_ raw: String) -> String? {
        var trigger = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trigger.hasPrefix("&&") {
            trigger.removeFirst(2)
        }
        guard isValidTrigger(trigger) else { return nil }
        return trigger
    }

    private static func isValidTrigger(_ trigger: String) -> Bool {
        let length = trigger.utf8.count
        guard (2...64).contains(length) else { return false }
        return trigger.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
        }
    }

    private static func isValidRequestID(_ requestID: String) -> Bool {
        let bytes = requestID.utf8
        guard !bytes.isEmpty, bytes.count <= maxRequestIDBytes else { return false }
        return bytes.allSatisfy { byte in
            byte >= 0x21 && byte <= 0x7E && byte != 0x22 && byte != 0x5C
        }
    }

    /// Reads only one bounded JSONL handshake line. `poll(2)` keeps the read
    /// cancellable without a detached blocking task; the caller terminates
    /// the process before surfacing any failure.
    private static func readHandshake(
        from handle: FileHandle,
        timeoutMillis: Int,
        killSwitch: @escaping @Sendable () -> Bool
    ) throws -> Data {
        let deadline = Date().addingTimeInterval(Double(max(1, timeoutMillis)) / 1_000)
        var data = Data()
        while data.count <= maxHandshakeBytes {
            try Task.checkCancellation()
            if killSwitch() { throw HandshakeWaitError.killSwitchActive }
            let remainingSeconds = deadline.timeIntervalSinceNow
            guard remainingSeconds > 0 else { throw HandshakeWaitError.timedOut }

            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let waitMillis = Int32(max(1, min(20, Int((remainingSeconds * 1_000).rounded(.up)))))
            let result = poll(&descriptor, 1, waitMillis)
            if result < 0 {
                if errno == EINTR { continue }
                return data
            }
            guard result > 0 else { continue }
            let readable = Int16(POLLIN | POLLHUP | POLLERR)
            guard descriptor.revents & readable != 0 else { continue }

            let remaining = min(512, maxHandshakeBytes + 1 - data.count)
            let chunk = try handle.read(upToCount: remaining) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
            if let newline = data.firstIndex(of: 0x0A) {
                return Data(data[..<newline])
            }
        }
        return data
    }

    /// Reads one bounded JSONL response. Polling keeps the request path
    /// cancellable without a detached blocking task; the caller tears down
    /// the process before surfacing any I/O failure.
    private static func readExpansionResponse(
        from handle: FileHandle,
        timeoutMillis: Int,
        killSwitch: @escaping @Sendable () -> Bool
    ) throws -> Data {
        let deadline = Date().addingTimeInterval(Double(max(1, timeoutMillis)) / 1_000)
        var data = Data()
        while true {
            try Task.checkCancellation()
            if killSwitch() { throw ExpansionWaitError.killSwitchActive }
            let remainingSeconds = deadline.timeIntervalSinceNow
            guard remainingSeconds > 0 else { throw ExpansionWaitError.timedOut }

            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let waitMillis = Int32(max(1, min(20, Int((remainingSeconds * 1_000).rounded(.up)))))
            let result = poll(&descriptor, 1, waitMillis)
            if result < 0 {
                if errno == EINTR { continue }
                throw ExpansionWaitError.closed
            }
            guard result > 0 else { continue }
            let readable = Int16(POLLIN | POLLHUP | POLLERR)
            guard descriptor.revents & readable != 0 else { continue }

            let remaining = min(512, maxExpansionBytes + 1 - data.count)
            guard remaining > 0 else { throw ExpansionWaitError.responseTooLarge }
            let chunk = try handle.read(upToCount: remaining) ?? Data()
            if chunk.isEmpty { throw ExpansionWaitError.closed }
            data.append(chunk)
            if let newline = data.firstIndex(of: 0x0A) {
                let line = Data(data[..<newline])
                guard line.count <= maxExpansionBytes else { throw ExpansionWaitError.responseTooLarge }
                return line
            }
            if data.count > maxExpansionBytes { throw ExpansionWaitError.responseTooLarge }
        }
    }

    private static func terminateProcess(
        _ process: Process,
        input: Pipe,
        output: Pipe,
        error: Pipe
    ) {
        if process.isRunning {
            process.terminate()
            usleep(20_000)
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        input.fileHandleForWriting.closeFile()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        _ = error.fileHandleForReading.readDataToEndOfFile()
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
