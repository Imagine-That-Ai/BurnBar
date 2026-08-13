import OpenBurnBarEngine
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(macOS)
import Security
#endif
import Dispatch
import Foundation

public protocol SafariHandoffProcessSupervising: Sendable {
    func launch(
        _ specification: SafariHandoffProcessSupervisor.LaunchSpecification
    ) async throws -> SafariHandoffProcessSupervisor.Observation
    func observation(
        for runID: BurnBarRunID
    ) async -> SafariHandoffProcessSupervisor.Observation?
    func cancel(
        runID: BurnBarRunID
    ) async -> SafariHandoffProcessSupervisor.Observation?
    func registerInterruptedRun(
        runID: BurnBarRunID,
        targetHarness: String,
        packageDirectory: URL,
        expectedPackageIdentity:
            SafariHandoffProcessSupervisor.FilesystemIdentity?,
        launchedAt: Date
    ) async -> SafariHandoffProcessSupervisor.Observation
    func cleanupEligiblePackages(now: Date) async
    func discard(runID: BurnBarRunID) async
    func shutdownAll() async
}

/// Owns the complete lifecycle of a read-only Safari → installed-CLI handoff.
///
/// The browser never supplies an executable, argv, working directory, output
/// path, receipt, or process identifier. The daemon prepares those values,
/// pins the exact owner-only package by device/inode, and delegates the child
/// process group to a tiny watchdog and a persistent, identity-bound sentinel.
/// The watchdog is the sole owner of the sentinel's lifetime writer. A daemon
/// crash closes the watchdog liveness pipe; a watchdog crash closes the
/// sentinel lifetime pipe. Either failure therefore contains the exact CLI
/// process group without trusting a reusable numeric PID or PGID.
public actor SafariHandoffProcessSupervisor:
    SafariHandoffProcessSupervising {
    public struct FilesystemIdentity: Sendable, Equatable, Codable {
        public let device: UInt64
        public let inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    public struct LaunchSpecification: Sendable, Equatable {
        public let runID: BurnBarRunID
        public let targetHarness: String
        public let packageDirectory: URL
        public let expectedPackageIdentity: FilesystemIdentity
        public let executableURL: URL
        public let arguments: [String]
        public let timeout: TimeInterval

        public init(
            runID: BurnBarRunID,
            targetHarness: String,
            packageDirectory: URL,
            expectedPackageIdentity: FilesystemIdentity,
            executableURL: URL,
            arguments: [String],
            timeout: TimeInterval = 30 * 60
        ) {
            self.runID = runID
            self.targetHarness = targetHarness
            self.packageDirectory = packageDirectory
            self.expectedPackageIdentity = expectedPackageIdentity
            self.executableURL = executableURL
            self.arguments = arguments
            self.timeout = timeout
        }
    }

    public enum TerminationReason: String, Codable, Sendable {
        case exit
        case uncaughtSignal = "uncaught_signal"
        case timeout
        case cancelled
        case interrupted
    }

    public enum Failure: String, Codable, Sendable {
        case nonzeroExit = "nonzero_exit"
        case signal
        case timeout
        case interrupted
        case missingReceipt = "missing_receipt"
        case malformedReceipt = "malformed_receipt"
        case invalidReceipt = "invalid_receipt"
        case outputPersistence = "output_persistence"
    }

    public struct Observation: Sendable, Equatable {
        public enum State: String, Sendable {
            case running
            case completed
            case failed
            case cancelled
            case interrupted
        }

        public let runID: BurnBarRunID
        public let targetHarness: String
        public let state: State
        public let launchedAt: Date
        public let observedAt: Date
        public let completedAt: Date?
        public let terminationReason: TerminationReason?
        public let exitStatus: Int32?
        /// Bytes durably retained in the owner-only package.
        public let stdoutBytes: Int
        /// Bytes durably retained in the owner-only package.
        public let stderrBytes: Int
        /// Total bytes observed before the bounded retention policy was
        /// applied. Saturates at `Int.max` on arithmetic overflow.
        public let stdoutObservedBytes: Int
        /// Total bytes observed before the bounded retention policy was
        /// applied. Saturates at `Int.max` on arithmetic overflow.
        public let stderrObservedBytes: Int
        public let stdoutTruncated: Bool
        public let stderrTruncated: Bool
        public let failure: Failure?
        public let packageDirectory: URL

        public var isTerminal: Bool {
            state != .running
        }

        public init(
            runID: BurnBarRunID,
            targetHarness: String,
            state: State,
            launchedAt: Date,
            observedAt: Date,
            completedAt: Date?,
            terminationReason: TerminationReason?,
            exitStatus: Int32?,
            stdoutBytes: Int,
            stderrBytes: Int,
            stdoutObservedBytes: Int? = nil,
            stderrObservedBytes: Int? = nil,
            stdoutTruncated: Bool,
            stderrTruncated: Bool,
            failure: Failure?,
            packageDirectory: URL
        ) {
            self.runID = runID
            self.targetHarness = targetHarness
            self.state = state
            self.launchedAt = launchedAt
            self.observedAt = observedAt
            self.completedAt = completedAt
            self.terminationReason = terminationReason
            self.exitStatus = exitStatus
            self.stdoutBytes = stdoutBytes
            self.stderrBytes = stderrBytes
            self.stdoutObservedBytes = stdoutObservedBytes ?? stdoutBytes
            self.stderrObservedBytes = stderrObservedBytes ?? stderrBytes
            self.stdoutTruncated = stdoutTruncated
            self.stderrTruncated = stderrTruncated
            self.failure = failure
            self.packageDirectory = packageDirectory
        }
    }

    enum SupervisorError: Error, LocalizedError {
        case unavailable
        case shuttingDown
        case duplicateRun(BurnBarRunID)
        case invalidSpecification(String)
        case unsafePackage(String)
        case unsafeExecutable(String)
        case outputPreparationFailed(String)
        case watchdogLaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Safari installed-agent hand-off is unavailable on this platform."
            case .shuttingDown:
                return "Safari installed-agent hand-off is shutting down."
            case .duplicateRun(let runID):
                return "Safari hand-off run \(runID.rawValue) is already supervised."
            case .invalidSpecification(let message),
                 .unsafePackage(let message),
                 .unsafeExecutable(let message),
                 .outputPreparationFailed(let message),
                 .watchdogLaunchFailed(let message):
                return message
            }
        }
    }

    struct CompletionReceipt: Codable, Equatable {
        static let schemaVersion = 4

        let schemaVersion: Int
        let runID: String
        let targetHarness: String
        let packageIdentity: FilesystemIdentity
        let launchedAt: Date
        let completedAt: Date
        let terminationReason: TerminationReason
        let exitStatus: Int32?
        let stdoutBytes: Int
        let stderrBytes: Int
        let stdoutObservedBytes: Int
        let stderrObservedBytes: Int
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
        let stdoutSHA256: String
        let stderrSHA256: String
        let authenticationCode: String

        func authenticationPayload() -> Data {
            var payload = Data()
            Self.append(
                "openburnbar-safari-handoff-completion-v1",
                to: &payload
            )
            Self.append(Int64(schemaVersion), to: &payload)
            Self.append(runID, to: &payload)
            Self.append(targetHarness, to: &payload)
            Self.append(packageIdentity.device, to: &payload)
            Self.append(packageIdentity.inode, to: &payload)
            Self.append(
                launchedAt.timeIntervalSinceReferenceDate.bitPattern,
                to: &payload
            )
            Self.append(
                completedAt.timeIntervalSinceReferenceDate.bitPattern,
                to: &payload
            )
            Self.append(terminationReason.rawValue, to: &payload)
            Self.append(exitStatus != nil, to: &payload)
            Self.append(Int64(exitStatus ?? 0), to: &payload)
            Self.append(Int64(stdoutBytes), to: &payload)
            Self.append(Int64(stderrBytes), to: &payload)
            Self.append(Int64(stdoutObservedBytes), to: &payload)
            Self.append(Int64(stderrObservedBytes), to: &payload)
            Self.append(stdoutTruncated, to: &payload)
            Self.append(stderrTruncated, to: &payload)
            Self.append(stdoutSHA256, to: &payload)
            Self.append(stderrSHA256, to: &payload)
            return payload
        }

        func authenticated(
            using authenticator: ReceiptAuthenticator
        ) throws -> CompletionReceipt {
            let code = try authenticator.authenticate(
                authenticationPayload()
            )
            return CompletionReceipt(
                schemaVersion: schemaVersion,
                runID: runID,
                targetHarness: targetHarness,
                packageIdentity: packageIdentity,
                launchedAt: launchedAt,
                completedAt: completedAt,
                terminationReason: terminationReason,
                exitStatus: exitStatus,
                stdoutBytes: stdoutBytes,
                stderrBytes: stderrBytes,
                stdoutObservedBytes: stdoutObservedBytes,
                stderrObservedBytes: stderrObservedBytes,
                stdoutTruncated: stdoutTruncated,
                stderrTruncated: stderrTruncated,
                stdoutSHA256: stdoutSHA256,
                stderrSHA256: stderrSHA256,
                authenticationCode: code
            )
        }

        private static func append(
            _ value: String,
            to payload: inout Data
        ) {
            let bytes = Data(value.utf8)
            append(UInt64(bytes.count), to: &payload)
            payload.append(bytes)
        }

        private static func append(
            _ value: Bool,
            to payload: inout Data
        ) {
            payload.append(value ? 1 : 0)
        }

        private static func append<T: FixedWidthInteger>(
            _ value: T,
            to payload: inout Data
        ) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
        }
    }

    struct ReceiptAuthenticator: Sendable {
        enum AuthenticationError: Error {
            case unavailable
            case invalidKey
        }

        private let authenticateOperation:
            @Sendable (_ payload: Data) throws -> String
        private let validateOperation:
            @Sendable (
                _ authenticationCode: String,
                _ payload: Data
            ) throws -> Bool

        init(
            authenticate:
                @escaping @Sendable (_ payload: Data) throws -> String,
            validate:
                @escaping @Sendable (
                    _ authenticationCode: String,
                    _ payload: Data
                ) throws -> Bool
        ) {
            authenticateOperation = authenticate
            validateOperation = validate
        }

        func authenticate(_ payload: Data) throws -> String {
            try authenticateOperation(payload)
        }

        func validate(
            _ authenticationCode: String,
            payload: Data
        ) throws -> Bool {
            try validateOperation(authenticationCode, payload)
        }

        static func hmacSHA256(key: Data) -> ReceiptAuthenticator {
            ReceiptAuthenticator(
                authenticate: { payload in
                    guard key.count == 32 else {
                        throw AuthenticationError.invalidKey
                    }
                    return try Self.authenticationCode(
                        payload: payload,
                        key: key
                    )
                },
                validate: { authenticationCode, payload in
                    guard key.count == 32,
                          let observed = Self.decodeAuthenticationCode(
                              authenticationCode
                          ) else {
                        return false
                    }
                    let expected = try PlatformCrypto.hmacSHA256(
                        payload,
                        keyData: key
                    )
                    return Self.constantTimeEqual(observed, expected)
                }
            )
        }

        static func production() -> ReceiptAuthenticator {
            #if os(macOS)
            return ReceiptAuthenticator(
                authenticate: { payload in
                    let key = try SafariHandoffReceiptKeyStore.loadOrCreate()
                    return try Self.authenticationCode(
                        payload: payload,
                        key: key
                    )
                },
                validate: { authenticationCode, payload in
                    guard let observed = Self.decodeAuthenticationCode(
                        authenticationCode
                    ) else {
                        return false
                    }
                    let key = try SafariHandoffReceiptKeyStore.loadExisting()
                    let expected = try PlatformCrypto.hmacSHA256(
                        payload,
                        keyData: key
                    )
                    return Self.constantTimeEqual(observed, expected)
                }
            )
            #else
            return ReceiptAuthenticator(
                authenticate: { _ in
                    throw AuthenticationError.unavailable
                },
                validate: { _, _ in
                    throw AuthenticationError.unavailable
                }
            )
            #endif
        }

        private static func authenticationCode(
            payload: Data,
            key: Data
        ) throws -> String {
            try PlatformCrypto.hmacSHA256Hex(payload, keyData: key)
        }

        private static func decodeAuthenticationCode(
            _ value: String
        ) -> Data? {
            guard value.utf8.count == 64,
                  value == value.lowercased() else {
                return nil
            }
            var decoded = Data()
            decoded.reserveCapacity(32)
            var index = value.startIndex
            for _ in 0..<32 {
                let next = value.index(index, offsetBy: 2)
                guard let byte = UInt8(value[index..<next], radix: 16)
                else {
                    return nil
                }
                decoded.append(byte)
                index = next
            }
            return decoded
        }

        private static func constantTimeEqual(
            _ lhs: Data,
            _ rhs: Data
        ) -> Bool {
            guard lhs.count == rhs.count else { return false }
            var difference: UInt8 = 0
            for index in lhs.indices {
                difference |= lhs[index] ^ rhs[index]
            }
            return difference == 0
        }
    }

    struct OutputSnapshot: Sendable, Equatable {
        let data: Data
        let observedBytes: Int
        let truncated: Bool
    }

    struct WatchdogTerminal: Sendable, Equatable {
        let waitStatus: Int32?
        let failure: String?
    }

    struct ProcessIdentity: Codable, Sendable, Equatable {
        let processID: Int32
        let processGroupID: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct WatchdogReady: Sendable, Equatable {
        let watchdogPID: Int32
        let processGroupID: Int32
        let containmentIdentity: ProcessIdentity
    }

    struct StatusFrameDecoder: Sendable {
        enum FrameError: Error, Equatable {
            case empty
            case oversized
            case malformed
            case partialAtEnd
        }

        private var buffer = Data()

        mutating func append(
            _ chunk: Data
        ) throws -> [SafariHandoffProcessWatchdog.Message] {
            guard chunk.isEmpty == false else { return [] }
            buffer.append(chunk)
            var messages: [SafariHandoffProcessWatchdog.Message] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard line.isEmpty == false else {
                    throw FrameError.empty
                }
                guard line.count
                        < SafariHandoffProcessWatchdog.maximumStatusBytes
                else {
                    throw FrameError.oversized
                }
                guard let message = try? JSONDecoder().decode(
                    SafariHandoffProcessWatchdog.Message.self,
                    from: line
                ) else {
                    throw FrameError.malformed
                }
                messages.append(message)
            }
            guard buffer.count
                    < SafariHandoffProcessWatchdog.maximumStatusBytes
            else {
                throw FrameError.oversized
            }
            return messages
        }

        func finish() throws {
            guard buffer.isEmpty else {
                throw FrameError.partialAtEnd
            }
        }
    }

    protocol WatchdogSession: AnyObject, Sendable {
        func start() throws -> WatchdogReady
        @discardableResult
        func requestTermination() -> Bool
        func forceContainment()
        func closeLiveness()
        func stdoutSnapshot() -> OutputSnapshot
        func stderrSnapshot() -> OutputSnapshot
        func finishDraining()
    }

    struct SessionLaunchContext: Sendable {
        let generation: UUID
        let packageDescriptor: Int32
        let packageIdentity: FilesystemIdentity
        let executable: ValidatedExecutable
        let arguments: [String]
        let environment: [String: String]
        let onTerminal: @Sendable (WatchdogTerminal) -> Void
        let onFailure: @Sendable (String) -> Void
    }

    typealias SessionFactory = @Sendable (
        _ context: SessionLaunchContext
    ) throws -> any WatchdogSession

    enum SynchronizationPoint: Sendable {
        case outputFile
        case receiptFile
        case packageDirectory
        case rootDirectory
    }

    struct Dependencies: Sendable {
        let environment: @Sendable () -> [String: String]
        let sleep: @Sendable (_ nanoseconds: UInt64) async -> Void
        let uptimeNanoseconds: @Sendable () -> UInt64
        let validateExecutable: @Sendable (
            _ url: URL,
            _ environment: [String: String]
        ) throws -> ValidatedExecutable
        let makeSession: SessionFactory
        let receiptAuthenticator: ReceiptAuthenticator
        let synchronize: @Sendable (
            _ descriptor: Int32,
            _ point: SynchronizationPoint
        ) -> Bool

        init(
            environment: @escaping @Sendable () -> [String: String],
            sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
                try? await Task.sleep(nanoseconds: nanoseconds)
            },
            uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
                DispatchTime.now().uptimeNanoseconds
            },
            validateExecutable: @escaping @Sendable (
                _ url: URL,
                _ environment: [String: String]
            ) throws -> ValidatedExecutable,
            makeSession: @escaping SessionFactory,
            receiptAuthenticator: ReceiptAuthenticator =
                .hmacSHA256(key: Data(repeating: 0xA5, count: 32)),
            synchronize: @escaping @Sendable (
                _ descriptor: Int32,
                _ point: SynchronizationPoint
            ) -> Bool
        ) {
            self.environment = environment
            self.sleep = sleep
            self.uptimeNanoseconds = uptimeNanoseconds
            self.validateExecutable = validateExecutable
            self.makeSession = makeSession
            self.receiptAuthenticator = receiptAuthenticator
            self.synchronize = synchronize
        }

        static func production() -> Dependencies {
            Dependencies(
                environment: { ProcessInfo.processInfo.environment },
                validateExecutable: { url, environment in
                    try ExecutableValidator.validate(
                        url: url,
                        environment: environment
                    )
                },
                makeSession: { context in
                    #if os(macOS)
                    return try POSIXWatchdogSession(context: context)
                    #else
                    _ = context
                    throw SupervisorError.unavailable
                    #endif
                },
                receiptAuthenticator: .production(),
                synchronize: { descriptor, _ in
                    fsyncRetrying(descriptor) == 0
                }
            )
        }
    }

    struct ValidatedExecutable: Codable, Sendable, Equatable {
        struct Component: Codable, Sendable, Equatable {
            let path: String
            let identity: FilesystemIdentity
            let size: Int64
            let modificationSeconds: Int64
            let modificationNanoseconds: Int64
        }

        let path: String
        let identity: FilesystemIdentity
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        /// Exact native executable passed to `posix_spawn`. For a script this
        /// is the final validated interpreter, never `/usr/bin/env`.
        let launchPath: String
        /// Arguments inserted before the caller-controlled, daemon-generated
        /// argument vector. For a script this pins the validated script path.
        let launchArguments: [String]
        /// Complete executable/interpreter identity chain. The watchdog
        /// revalidates this structure immediately before spawning.
        let components: [Component]

        init(
            path: String,
            identity: FilesystemIdentity,
            size: Int64,
            modificationSeconds: Int64,
            modificationNanoseconds: Int64,
            launchPath: String? = nil,
            launchArguments: [String] = [],
            components: [Component]? = nil
        ) {
            self.path = path
            self.identity = identity
            self.size = size
            self.modificationSeconds = modificationSeconds
            self.modificationNanoseconds = modificationNanoseconds
            self.launchPath = launchPath ?? path
            self.launchArguments = launchArguments
            self.components =
                components
                ?? [
                    Component(
                        path: path,
                        identity: identity,
                        size: size,
                        modificationSeconds: modificationSeconds,
                        modificationNanoseconds: modificationNanoseconds
                    )
                ]
        }
    }

    // AUDIT: This wrapper owns the hand-off process descriptors and closes them
    // exactly once with the package lifetime.
    // sendable-allowlist: process-handle
    private final class PackageHandle: @unchecked Sendable {
        let rootDescriptor: Int32
        let packageDescriptor: Int32
        let rootURL: URL
        let packageURL: URL
        let packageName: String
        let identity: FilesystemIdentity
        var stdoutDescriptor: Int32 = -1
        var stderrDescriptor: Int32 = -1

        init(
            rootDescriptor: Int32,
            packageDescriptor: Int32,
            rootURL: URL,
            packageURL: URL,
            packageName: String,
            identity: FilesystemIdentity
        ) {
            self.rootDescriptor = rootDescriptor
            self.packageDescriptor = packageDescriptor
            self.rootURL = rootURL
            self.packageURL = packageURL
            self.packageName = packageName
            self.identity = identity
        }

        deinit {
            if stdoutDescriptor >= 0 { close(stdoutDescriptor) }
            if stderrDescriptor >= 0 { close(stderrDescriptor) }
            close(packageDescriptor)
            close(rootDescriptor)
        }
    }

    private enum LivePhase: Equatable {
        case launching
        case running
        case terminating
    }

    private struct LiveRecord {
        let generation: UUID
        let specification: LaunchSpecification
        let launchedAt: Date
        let package: PackageHandle
        var session: (any WatchdogSession)?
        var phase: LivePhase
        var timeoutTask: Task<Void, Never>?
        var terminationTask: Task<Void, Never>?
        var requestedTermination: TerminationReason?
    }

    fileprivate static let outputLimitBytes = 1 * 1024 * 1024
    private static let receiptLimitBytes = 16 * 1024
    private static let receiptFileName = "completion.json"
    private static let stdoutFileName = "stdout.log"
    private static let stderrFileName = "stderr.log"
    private static let knownPackageFileNames = [
        "BRIEFING.md",
        "viewport.jpg",
        "opencode.json",
        stdoutFileName,
        stderrFileName,
        receiptFileName
    ]
    private static let terminalRetention: TimeInterval = 24 * 60 * 60
    private static let maximumClockSkew: TimeInterval = 5 * 60
    private static let shutdownGraceNanoseconds: UInt64 = 2_000_000_000
    private static let shutdownPollNanoseconds: UInt64 = 25_000_000
    private let rootURL: URL
    private let logger: BurnBarDaemonLogger
    private let now: @Sendable () -> Date
    private let dependencies: Dependencies
    private var canonicalRootIdentity: FilesystemIdentity?
    private var acceptingLaunches = true
    private var liveRecords: [BurnBarRunID: LiveRecord] = [:]
    private var observations: [BurnBarRunID: Observation] = [:]
    private var packageIdentities: [BurnBarRunID: FilesystemIdentity] = [:]
    private var terminalWaiters:
        [BurnBarRunID: [CheckedContinuation<Observation, Never>]] = [:]

    public init(
        rootURL: URL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(
            category: "safari-handoff-process"
        ),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.logger = logger
        self.now = now
        dependencies = .production()
    }

    init(
        rootURL: URL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(
            category: "safari-handoff-process"
        ),
        now: @escaping @Sendable () -> Date = Date.init,
        dependencies: Dependencies
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.logger = logger
        self.now = now
        self.dependencies = dependencies
    }

    public func launch(
        _ specification: LaunchSpecification
    ) async throws -> Observation {
        #if !os(macOS)
        _ = specification
        throw SupervisorError.unavailable
        #else
        guard acceptingLaunches else {
            throw SupervisorError.shuttingDown
        }
        guard observations[specification.runID] == nil,
              liveRecords[specification.runID] == nil else {
            throw SupervisorError.duplicateRun(specification.runID)
        }
        try validate(specification)

        let package = try openPackage(
            runID: specification.runID,
            packageURL: specification.packageDirectory,
            expectedIdentity: specification.expectedPackageIdentity
        )
        do {
            try prepareOutputFiles(package)
        } catch {
            try? removeExactPackage(package)
            throw SupervisorError.outputPreparationFailed(
                "The private Safari hand-off output could not be prepared."
            )
        }

        let environment = try childEnvironment(
            ambient: dependencies.environment(),
            packageURL: specification.packageDirectory,
            executableURL: specification.executableURL
        )
        let executable: ValidatedExecutable
        do {
            executable = try dependencies.validateExecutable(
                specification.executableURL,
                environment
            )
        } catch {
            try? removeExactPackage(package)
            throw SupervisorError.unsafeExecutable(
                "The selected installed agent failed launch-time trust validation."
            )
        }

        let launchedAt = now()
        let generation = UUID()
        let running = Observation(
            runID: specification.runID,
            targetHarness: specification.targetHarness,
            state: .running,
            launchedAt: launchedAt,
            observedAt: launchedAt,
            completedAt: nil,
            terminationReason: nil,
            exitStatus: nil,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutObservedBytes: 0,
            stderrObservedBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: nil,
            packageDirectory: specification.packageDirectory
        )
        observations[specification.runID] = running
        packageIdentities[specification.runID] =
            specification.expectedPackageIdentity
        liveRecords[specification.runID] = LiveRecord(
            generation: generation,
            specification: specification,
            launchedAt: launchedAt,
            package: package,
            session: nil,
            phase: .launching,
            timeoutTask: nil,
            terminationTask: nil,
            requestedTermination: nil
        )

        let runID = specification.runID
        let session: any WatchdogSession
        do {
            session = try dependencies.makeSession(
                SessionLaunchContext(
                    generation: generation,
                    packageDescriptor: package.packageDescriptor,
                    packageIdentity: specification.expectedPackageIdentity,
                    executable: executable,
                    arguments: specification.arguments,
                    environment: environment,
                    onTerminal: { [weak self] terminal in
                        Task {
                            await self?.watchdogDidTerminate(
                                runID: runID,
                                generation: generation,
                                terminal: terminal
                            )
                        }
                    },
                    onFailure: { [weak self] message in
                        Task {
                            await self?.watchdogDidFail(
                                runID: runID,
                                generation: generation,
                                message: message
                            )
                        }
                    }
                )
            )
            guard var record = liveRecords[runID],
                  record.generation == generation else {
                session.closeLiveness()
                throw SupervisorError.watchdogLaunchFailed(
                    "The installed-agent launch was interrupted."
                )
            }
            record.session = session
            liveRecords[runID] = record
            _ = try session.start()
        } catch {
            if let current = liveRecords[runID],
               current.generation == generation {
                liveRecords.removeValue(forKey: runID)
                observations.removeValue(forKey: runID)
                packageIdentities.removeValue(forKey: runID)
                current.session?.forceContainment()
                current.session?.closeLiveness()
                current.session?.finishDraining()
                try? removeExactPackage(package)
            }
            throw SupervisorError.watchdogLaunchFailed(
                "The installed-agent watchdog could not be launched."
            )
        }

        guard var record = liveRecords[runID],
              record.generation == generation else {
            return observations[runID] ?? running
        }
        record.phase = .running
        if specification.timeout > 0 {
            let nanoseconds = Self.timeoutNanoseconds(
                from: specification.timeout
            )
            record.timeoutTask = Task { [weak self] in
                await self?.dependencies.sleep(nanoseconds)
                guard Task.isCancelled == false,
                      let self else {
                    return
                }
                await self.requestTermination(
                    runID: runID,
                    generation: generation,
                    reason: .timeout
                )
            }
        }
        liveRecords[runID] = record
        return observations[runID] ?? running
        #endif
    }

    public func observation(for runID: BurnBarRunID) async -> Observation? {
        observations[runID]
    }

    public func cancel(runID: BurnBarRunID) async -> Observation? {
        guard let current = observations[runID] else {
            return nil
        }
        guard current.state == .running,
              let generation = liveRecords[runID]?.generation else {
            return current
        }
        await requestTermination(
            runID: runID,
            generation: generation,
            reason: .cancelled
        )
        return await waitForTerminal(runID: runID)
    }

    public func registerInterruptedRun(
        runID: BurnBarRunID,
        targetHarness: String,
        packageDirectory: URL,
        expectedPackageIdentity: FilesystemIdentity?,
        launchedAt: Date
    ) async -> Observation {
        if let existing = observations[runID] {
            return existing
        }
        let observedAt = now()
        guard let expectedPackageIdentity else {
            let observation = interruptedObservation(
                runID: runID,
                targetHarness: targetHarness,
                packageDirectory: packageDirectory,
                launchedAt: launchedAt,
                observedAt: observedAt,
                failure: .invalidReceipt
            )
            observations[runID] = observation
            return observation
        }

        let restoredObservation: Observation
        do {
            let package = try openPackage(
                runID: runID,
                packageURL: packageDirectory,
                expectedIdentity: expectedPackageIdentity
            )
            let receipt = try validatedReceipt(
                runID: runID,
                targetHarness: targetHarness,
                package: package,
                launchedAt: launchedAt,
                observedAt: observedAt
            )
            restoredObservation = observation(
                from: receipt,
                packageDirectory: packageDirectory,
                observedAt: observedAt
            )
            packageIdentities[runID] = expectedPackageIdentity
        } catch {
            restoredObservation = interruptedObservation(
                runID: runID,
                targetHarness: targetHarness,
                packageDirectory: packageDirectory,
                launchedAt: launchedAt,
                observedAt: observedAt,
                failure: Self.failureForReceiptError(error)
            )
            packageIdentities[runID] = expectedPackageIdentity
        }
        observations[runID] = restoredObservation
        return restoredObservation
    }

    public func cleanupEligiblePackages(now: Date = Date()) async {
        for (runID, observation) in observations
            where observation.isTerminal
                && now.timeIntervalSince(
                    observation.completedAt ?? observation.observedAt
                ) >= Self.terminalRetention {
            guard let identity = packageIdentities[runID] else {
                continue
            }
            do {
                let package = try openPackage(
                    runID: runID,
                    packageURL: observation.packageDirectory,
                    expectedIdentity: identity
                )
                try removeExactPackage(package)
                observations.removeValue(forKey: runID)
                packageIdentities.removeValue(forKey: runID)
            } catch {
                logger.warning(
                    "safari_handoff_cleanup_failed",
                    metadata: [
                        "run_id": runID.rawValue,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    public func discard(runID: BurnBarRunID) async {
        if let generation = liveRecords[runID]?.generation {
            await requestTermination(
                runID: runID,
                generation: generation,
                reason: .cancelled
            )
            guard let terminal = await waitForTerminal(runID: runID),
                  terminal.isTerminal,
                  liveRecords[runID] == nil else {
                return
            }
        }
        guard let observation = observations[runID],
              let identity = packageIdentities[runID] else {
            observations.removeValue(forKey: runID)
            packageIdentities.removeValue(forKey: runID)
            return
        }
        do {
            let package = try openPackage(
                runID: runID,
                packageURL: observation.packageDirectory,
                expectedIdentity: identity
            )
            try removeExactPackage(package)
            observations.removeValue(forKey: runID)
            packageIdentities.removeValue(forKey: runID)
        } catch {
            logger.warning(
                "safari_handoff_discard_failed",
                metadata: [
                    "run_id": runID.rawValue,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    public func shutdownAll() async {
        acceptingLaunches = false
        let live = liveRecords.map { ($0.key, $0.value.generation) }
        for (runID, generation) in live {
            await requestTermination(
                runID: runID,
                generation: generation,
                reason: .interrupted,
                overrideExistingReason: true
            )
        }
        // Closing the private liveness pipe makes shutdown independent of a
        // blocked command-pipe write and instructs the watchdog to contain its
        // exact process group.
        for (runID, generation) in live {
            guard let record = liveRecords[runID],
                  record.generation == generation else {
                continue
            }
            record.session?.closeLiveness()
        }
        let startedAt = dependencies.uptimeNanoseconds()
        let (candidateDeadline, overflowed) = startedAt.addingReportingOverflow(
            Self.shutdownGraceNanoseconds
        )
        let deadline = overflowed ? UInt64.max : candidateDeadline
        while live.contains(where: { entry in
            liveRecords[entry.0]?.generation == entry.1
        }) {
            let current = dependencies.uptimeNanoseconds()
            guard current < deadline else {
                break
            }
            await dependencies.sleep(
                min(Self.shutdownPollNanoseconds, deadline - current)
            )
        }
        for (runID, generation) in live {
            guard let record = liveRecords[runID],
                  record.generation == generation else {
                continue
            }
            record.session?.forceContainment()
            await terminalize(
                runID: runID,
                generation: generation,
                waitStatus: nil,
                watchdogFailure: "shutdown_deadline_exceeded"
            )
        }
    }

    private func requestTermination(
        runID: BurnBarRunID,
        generation: UUID,
        reason: TerminationReason,
        overrideExistingReason: Bool = false
    ) async {
        guard var record = liveRecords[runID],
              record.generation == generation else {
            return
        }
        let shouldRequestTermination = record.phase != .terminating
        if overrideExistingReason || record.requestedTermination == nil {
            record.requestedTermination = reason
        }
        record.phase = .terminating
        record.timeoutTask?.cancel()
        if shouldRequestTermination {
            record.terminationTask = Task { [weak self] in
                guard let self else { return }
                await self.dependencies.sleep(
                    Self.shutdownGraceNanoseconds
                )
                guard Task.isCancelled == false else { return }
                await self.terminationDeadlineReached(
                    runID: runID,
                    generation: generation
                )
            }
        }
        liveRecords[runID] = record
        if shouldRequestTermination {
            let delivered = record.session?.requestTermination() ?? false
            if delivered == false {
                record.session?.closeLiveness()
            }
        }
    }

    private func terminationDeadlineReached(
        runID: BurnBarRunID,
        generation: UUID
    ) async {
        guard let record = liveRecords[runID],
              record.generation == generation,
              record.phase == .terminating else {
            return
        }
        record.session?.forceContainment()
        await terminalize(
            runID: runID,
            generation: generation,
            waitStatus: nil,
            watchdogFailure: "termination_deadline_exceeded"
        )
    }

    private func watchdogDidTerminate(
        runID: BurnBarRunID,
        generation: UUID,
        terminal: WatchdogTerminal
    ) async {
        guard let record = liveRecords[runID],
              record.generation == generation else {
            return
        }
        await terminalize(
            runID: runID,
            generation: generation,
            waitStatus: terminal.waitStatus,
            watchdogFailure: terminal.failure
        )
    }

    private func watchdogDidFail(
        runID: BurnBarRunID,
        generation: UUID,
        message: String
    ) async {
        guard let record = liveRecords[runID],
              record.generation == generation else {
            return
        }
        record.session?.forceContainment()
        await terminalize(
            runID: runID,
            generation: generation,
            waitStatus: nil,
            watchdogFailure: message
        )
    }

    private func terminalize(
        runID: BurnBarRunID,
        generation: UUID,
        waitStatus: Int32?,
        watchdogFailure: String?
    ) async {
        guard let record = liveRecords[runID],
              record.generation == generation,
              observations[runID]?.state == .running else {
            return
        }
        liveRecords.removeValue(forKey: runID)
        record.timeoutTask?.cancel()
        record.terminationTask?.cancel()
        record.session?.finishDraining()
        defer { record.session?.closeLiveness() }

        let stdout = record.session?.stdoutSnapshot()
            ?? OutputSnapshot(data: Data(), observedBytes: 0, truncated: false)
        let stderr = record.session?.stderrSnapshot()
            ?? OutputSnapshot(data: Data(), observedBytes: 0, truncated: false)
        let completedAt = now()
        let native = Self.decodeWaitStatus(waitStatus)
        let terminationReason: TerminationReason
        if let requested = record.requestedTermination {
            terminationReason = requested
        } else if watchdogFailure != nil || waitStatus == nil {
            terminationReason = .interrupted
        } else {
            terminationReason = native.wasSignalled
                ? .uncaughtSignal
                : .exit
        }

        var failure: Failure?
        do {
            try persistBoundedOutput(
                stdout.data,
                descriptor: record.package.stdoutDescriptor,
                package: record.package
            )
            try persistBoundedOutput(
                stderr.data,
                descriptor: record.package.stderrDescriptor,
                package: record.package
            )
        } catch {
            failure = .outputPersistence
        }

        if failure == nil {
            do {
                let receipt = try CompletionReceipt(
                    schemaVersion: CompletionReceipt.schemaVersion,
                    runID: runID.rawValue,
                    targetHarness: record.specification.targetHarness,
                    packageIdentity:
                        record.specification.expectedPackageIdentity,
                    launchedAt: record.launchedAt,
                    completedAt: completedAt,
                    terminationReason: terminationReason,
                    exitStatus: native.exitStatus,
                    stdoutBytes: stdout.data.count,
                    stderrBytes: stderr.data.count,
                    stdoutObservedBytes: stdout.observedBytes,
                    stderrObservedBytes: stderr.observedBytes,
                    stdoutTruncated: stdout.truncated,
                    stderrTruncated: stderr.truncated,
                    stdoutSHA256: PlatformCrypto.sha256Hex(stdout.data),
                    stderrSHA256: PlatformCrypto.sha256Hex(stderr.data),
                    authenticationCode: ""
                )
                .authenticated(
                    using: dependencies.receiptAuthenticator
                )
                try writeAtomicReceipt(receipt, package: record.package)
                _ = try validatedReceipt(
                    runID: runID,
                    targetHarness: record.specification.targetHarness,
                    package: record.package,
                    launchedAt: record.launchedAt,
                    observedAt: completedAt
                )
            } catch {
                failure = Self.failureForReceiptError(error)
            }
        }

        let state: Observation.State
        if failure != nil {
            state = .failed
        } else {
            switch terminationReason {
            case .cancelled:
                state = .cancelled
            case .interrupted:
                state = .interrupted
                failure = .interrupted
            case .timeout:
                state = .failed
                failure = .timeout
            case .uncaughtSignal:
                state = .failed
                failure = .signal
            case .exit:
                if native.exitStatus == 0 {
                    state = .completed
                } else {
                    state = .failed
                    failure = .nonzeroExit
                }
            }
        }

        let observation = Observation(
            runID: runID,
            targetHarness: record.specification.targetHarness,
            state: state,
            launchedAt: record.launchedAt,
            observedAt: completedAt,
            completedAt: completedAt,
            terminationReason: terminationReason,
            exitStatus: native.exitStatus,
            stdoutBytes: stdout.data.count,
            stderrBytes: stderr.data.count,
            stdoutObservedBytes: stdout.observedBytes,
            stderrObservedBytes: stderr.observedBytes,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated,
            failure: failure,
            packageDirectory: record.specification.packageDirectory
        )
        observations[runID] = observation
        resumeTerminalWaiters(runID: runID, observation: observation)
    }

    private func waitForTerminal(runID: BurnBarRunID) async -> Observation? {
        guard let current = observations[runID] else {
            return nil
        }
        guard current.isTerminal == false else {
            return current
        }
        return await withCheckedContinuation { continuation in
            terminalWaiters[runID, default: []].append(continuation)
        }
    }

    private func resumeTerminalWaiters(
        runID: BurnBarRunID,
        observation: Observation
    ) {
        let waiters = terminalWaiters.removeValue(forKey: runID) ?? []
        for waiter in waiters {
            waiter.resume(returning: observation)
        }
    }

    private func validate(_ specification: LaunchSpecification) throws {
        let runName = specification.runID.rawValue
        let expectedURL = rootURL.appendingPathComponent(
            runName,
            isDirectory: true
        ).standardizedFileURL
        guard Self.isSafeChildName(runName),
              rootURL.isFileURL,
              (rootURL.host ?? "").isEmpty,
              rootURL.path.hasPrefix("/"),
              specification.packageDirectory.standardizedFileURL == expectedURL,
              Self.isSafeHarnessIdentifier(specification.targetHarness),
              specification.executableURL.isFileURL,
              (specification.executableURL.host ?? "").isEmpty,
              specification.executableURL.path.hasPrefix("/"),
              specification.arguments.count <= 256,
              specification.arguments.allSatisfy({
                  $0.utf8.count <= 64 * 1024 && $0.contains("\0") == false
              }),
              specification.arguments.reduce(0, {
                  $0 + $1.utf8.count + 1
              }) <= 512 * 1024,
              specification.timeout.isFinite,
              specification.timeout >= 0,
              specification.timeout <= 24 * 60 * 60 else {
            throw SupervisorError.invalidSpecification(
                "The Safari hand-off launch specification is invalid."
            )
        }
    }

    private func openPackage(
        runID: BurnBarRunID,
        packageURL: URL,
        expectedIdentity: FilesystemIdentity
    ) throws -> PackageHandle {
        let packageName = runID.rawValue
        let expectedURL = rootURL.appendingPathComponent(
            packageName,
            isDirectory: true
        ).standardizedFileURL
        guard Self.isSafeChildName(packageName),
              packageURL.standardizedFileURL == expectedURL else {
            throw SupervisorError.unsafePackage(
                "Safari hand-off storage is outside its canonical root."
            )
        }

        let rootDescriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw SupervisorError.unsafePackage(
                "Safari hand-off root storage could not be safely opened."
            )
        }
        var rootCommitted = false
        defer {
            if rootCommitted == false { close(rootDescriptor) }
        }
        let rootIdentity = try Self.validateDirectoryDescriptor(
            rootDescriptor,
            exactMode: 0o700
        )
        if let canonicalRootIdentity {
            guard rootIdentity == canonicalRootIdentity else {
                throw SupervisorError.unsafePackage(
                    "Safari hand-off root identity changed during this daemon lifetime."
                )
            }
        } else {
            canonicalRootIdentity = rootIdentity
        }

        var entryInfo = stat()
        guard fstatat(
            rootDescriptor,
            packageName,
            &entryInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              Self.identity(entryInfo) == expectedIdentity,
              Self.isDirectory(entryInfo),
              entryInfo.st_uid == geteuid(),
              entryInfo.st_nlink >= 2,
              entryInfo.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw SupervisorError.unsafePackage(
                "Safari hand-off package identity or permissions are unsafe."
            )
        }

        let packageDescriptor = openat(
            rootDescriptor,
            packageName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard packageDescriptor >= 0 else {
            throw SupervisorError.unsafePackage(
                "Safari hand-off package could not be safely opened."
            )
        }
        var packageCommitted = false
        defer {
            if packageCommitted == false { close(packageDescriptor) }
        }
        let openedIdentity = try Self.validateDirectoryDescriptor(
            packageDescriptor,
            exactMode: 0o700
        )
        guard openedIdentity == expectedIdentity else {
            throw SupervisorError.unsafePackage(
                "Safari hand-off package changed while being opened."
            )
        }

        var currentInfo = stat()
        guard fstatat(
            rootDescriptor,
            packageName,
            &currentInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              Self.identity(currentInfo) == expectedIdentity else {
            throw SupervisorError.unsafePackage(
                "Safari hand-off package entry changed while being opened."
            )
        }
        rootCommitted = true
        packageCommitted = true
        return PackageHandle(
            rootDescriptor: rootDescriptor,
            packageDescriptor: packageDescriptor,
            rootURL: rootURL,
            packageURL: packageURL,
            packageName: packageName,
            identity: expectedIdentity
        )
    }

    private func prepareOutputFiles(_ package: PackageHandle) throws {
        package.stdoutDescriptor = try createOwnerOnlyFile(
            named: Self.stdoutFileName,
            in: package
        )
        do {
            package.stderrDescriptor = try createOwnerOnlyFile(
                named: Self.stderrFileName,
                in: package
            )
        } catch {
            _ = unlinkat(package.packageDescriptor, Self.stdoutFileName, 0)
            throw error
        }
        guard dependencies.synchronize(
            package.packageDescriptor,
            .packageDirectory
        ) else {
            throw POSIXError(.EIO)
        }
    }

    private func createOwnerOnlyFile(
        named name: String,
        in package: PackageHandle
    ) throws -> Int32 {
        let descriptor = openat(
            package.packageDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try Self.validateOwnerOnlyFileDescriptor(
                descriptor,
                expectedDevice: package.identity.device,
                expectedSize: 0
            )
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EACCES
                )
            }
            return descriptor
        } catch {
            close(descriptor)
            _ = unlinkat(package.packageDescriptor, name, 0)
            throw error
        }
    }

    private func persistBoundedOutput(
        _ data: Data,
        descriptor: Int32,
        package: PackageHandle
    ) throws {
        guard descriptor >= 0,
              data.count <= Self.outputLimitBytes,
              lseek(descriptor, 0, SEEK_SET) == 0,
              ftruncate(descriptor, 0) == 0 else {
            throw POSIXError(.EIO)
        }
        try Self.writeAll(data, to: descriptor)
        guard fchmod(descriptor, mode_t(0o600)) == 0,
              dependencies.synchronize(descriptor, .outputFile) else {
            throw POSIXError(.EIO)
        }
        try Self.validateOwnerOnlyFileDescriptor(
            descriptor,
            expectedDevice: package.identity.device,
            expectedSize: data.count
        )
        guard dependencies.synchronize(
            package.packageDescriptor,
            .packageDirectory
        ) else {
            throw POSIXError(.EIO)
        }
    }

    private func writeAtomicReceipt(
        _ receipt: CompletionReceipt,
        package: PackageHandle
    ) throws {
        let data = try JSONEncoder().encode(receipt)
        guard data.isEmpty == false,
              data.count <= Self.receiptLimitBytes else {
            throw ReceiptValidationError.invalid
        }
        let temporaryName = ".completion-\(UUID().uuidString).tmp"
        guard Self.isSafeChildName(temporaryName) else {
            throw ReceiptValidationError.invalid
        }
        let descriptor = openat(
            package.packageDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var temporaryFileExists = true
        var receiptLinked = false
        var committed = false
        defer {
            close(descriptor)
            if temporaryFileExists {
                _ = unlinkat(package.packageDescriptor, temporaryName, 0)
            }
            if receiptLinked, committed == false {
                _ = unlinkat(
                    package.packageDescriptor,
                    Self.receiptFileName,
                    0
                )
                _ = dependencies.synchronize(
                    package.packageDescriptor,
                    .packageDirectory
                )
            }
        }
        try Self.validateOwnerOnlyFileDescriptor(
            descriptor,
            expectedDevice: package.identity.device,
            expectedSize: 0
        )
        try Self.writeAll(data, to: descriptor)
        guard fchmod(descriptor, mode_t(0o600)) == 0,
              dependencies.synchronize(descriptor, .receiptFile) else {
            throw POSIXError(.EIO)
        }
        guard linkat(
            package.packageDescriptor,
            temporaryName,
            package.packageDescriptor,
            Self.receiptFileName,
            0
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        receiptLinked = true
        guard unlinkat(
            package.packageDescriptor,
            temporaryName,
            0
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        temporaryFileExists = false
        guard dependencies.synchronize(
            package.packageDescriptor,
            .packageDirectory
        ) else {
            throw POSIXError(.EIO)
        }
        committed = true
    }

    private func validatedReceipt(
        runID: BurnBarRunID,
        targetHarness: String,
        package: PackageHandle,
        launchedAt: Date,
        observedAt: Date
    ) throws -> CompletionReceipt {
        let descriptor = openat(
            package.packageDescriptor,
            Self.receiptFileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw ReceiptValidationError.missing
            }
            throw ReceiptValidationError.invalid
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              Self.isRegularFile(info),
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & mode_t(0o777) == mode_t(0o600),
              Self.identity(info).device == package.identity.device,
              info.st_size > 0,
              info.st_size <= Self.receiptLimitBytes else {
            throw ReceiptValidationError.invalid
        }
        let data: Data
        do {
            data = try Self.readBounded(
                from: descriptor,
                limit: Self.receiptLimitBytes
            )
        } catch {
            throw ReceiptValidationError.malformed
        }
        let receipt: CompletionReceipt
        do {
            receipt = try JSONDecoder().decode(
                CompletionReceipt.self,
                from: data
            )
        } catch {
            throw ReceiptValidationError.malformed
        }
        guard receipt.schemaVersion == CompletionReceipt.schemaVersion,
              receipt.runID == runID.rawValue,
              receipt.targetHarness == targetHarness,
              receipt.packageIdentity == package.identity,
              receipt.launchedAt == launchedAt,
              receipt.completedAt >= launchedAt,
              receipt.completedAt <= observedAt.addingTimeInterval(
                  Self.maximumClockSkew
              ),
              receipt.stdoutBytes >= 0,
              receipt.stdoutBytes <= Self.outputLimitBytes,
              receipt.stdoutObservedBytes >= receipt.stdoutBytes,
              receipt.stdoutTruncated
                == (receipt.stdoutObservedBytes > receipt.stdoutBytes),
              receipt.stderrBytes >= 0,
              receipt.stderrBytes <= Self.outputLimitBytes,
              receipt.stderrObservedBytes >= receipt.stderrBytes,
              receipt.stderrTruncated
                == (receipt.stderrObservedBytes > receipt.stderrBytes),
              Self.isCanonicalSHA256(receipt.stdoutSHA256),
              Self.isCanonicalSHA256(receipt.stderrSHA256),
              Self.validReceiptTermination(receipt) else {
            throw ReceiptValidationError.invalid
        }
        let stdoutDigest = try validatePersistedOutput(
            name: Self.stdoutFileName,
            expectedSize: receipt.stdoutBytes,
            package: package
        )
        let stderrDigest = try validatePersistedOutput(
            name: Self.stderrFileName,
            expectedSize: receipt.stderrBytes,
            package: package
        )
        guard stdoutDigest == receipt.stdoutSHA256,
              stderrDigest == receipt.stderrSHA256,
              try dependencies.receiptAuthenticator.validate(
                  receipt.authenticationCode,
                  payload: receipt.authenticationPayload()
              ) else {
            throw ReceiptValidationError.invalid
        }
        return receipt
    }

    private func validatePersistedOutput(
        name: String,
        expectedSize: Int,
        package: PackageHandle
    ) throws -> String {
        let descriptor = openat(
            package.packageDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ReceiptValidationError.invalid
        }
        defer { close(descriptor) }
        do {
            try Self.validateOwnerOnlyFileDescriptor(
                descriptor,
                expectedDevice: package.identity.device,
                expectedSize: expectedSize
            )
            let data = try Self.readBounded(
                from: descriptor,
                limit: Self.outputLimitBytes
            )
            guard data.count == expectedSize else {
                throw ReceiptValidationError.invalid
            }
            return PlatformCrypto.sha256Hex(data)
        } catch {
            throw ReceiptValidationError.invalid
        }
    }

    private func removeExactPackage(_ package: PackageHandle) throws {
        try validateCurrentPackageEntry(package)
        for name in Self.knownPackageFileNames {
            if unlinkat(package.packageDescriptor, name, 0) != 0,
               errno != ENOENT {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
        }
        guard dependencies.synchronize(
            package.packageDescriptor,
            .packageDirectory
        ) else {
            throw POSIXError(.EIO)
        }
        try validateCurrentPackageEntry(package)
        guard unlinkat(
            package.rootDescriptor,
            package.packageName,
            AT_REMOVEDIR
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard dependencies.synchronize(
            package.rootDescriptor,
            .rootDirectory
        ) else {
            throw POSIXError(.EIO)
        }
    }

    private func validateCurrentPackageEntry(
        _ package: PackageHandle
    ) throws {
        var opened = stat()
        var current = stat()
        guard fstat(package.packageDescriptor, &opened) == 0,
              Self.identity(opened) == package.identity,
              fstatat(
                  package.rootDescriptor,
                  package.packageName,
                  &current,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.identity(current) == package.identity,
              Self.isDirectory(current),
              current.st_uid == geteuid(),
              current.st_mode & mode_t(0o777) == mode_t(0o700) else {
            throw SupervisorError.unsafePackage(
                "Refusing to alter a replaced Safari hand-off package."
            )
        }
    }

    private static func executableValidationEnvironment(
        ambient: [String: String],
        executableURL: URL
    ) throws -> [String: String] {
        #if os(macOS)
        var environment =
            CLILaunchAdapter.buildAllowlistedBaselineEnvironment(
                baseEnv: ambient
            )
        #else
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "SHELL", "LANG", "LC_ALL"] {
            if let value = ambient[key], value.contains("\n") == false {
                environment[key] = value
            }
        }
        #endif
        for key in [
            "SSH_AUTH_SOCK",
            "BROWSER",
            "EDITOR",
            "VISUAL",
            "PAGER",
            "GIT_EDITOR",
            "HG_EDITOR",
            "PWD",
            "TMPDIR"
        ] {
            environment.removeValue(forKey: key)
        }
        // External CLIs may use their normal account state under HOME; that is
        // an explicit installed-CLI product boundary. Do not, however, inherit
        // ambient per-process redirects that can silently point a
        // browser-originated hand-off at an unrelated configuration/history
        // tree selected by the daemon's launch environment.
        for key in [
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_CONFIG_PATH",
            "CODEX_HOME",
            "CODEX_CONFIG_PATH",
            "OPENCODE_CONFIG_PATH",
            "AGY_CONFIG_HOME",
            "ANTIGRAVITY_HOME",
            "GEMINI_HOME",
            "CURSOR_AGENT_HOME",
            "CURSOR_AGENT_CONFIG_PATH"
        ] {
            environment.removeValue(forKey: key)
        }
        let deterministicPath = try ExecutableValidator.deterministicPath(
            executableURL: executableURL,
            environment: ambient
        )
        environment["PATH"] = deterministicPath
        return environment
    }

    private func childEnvironment(
        ambient: [String: String],
        packageURL: URL,
        executableURL: URL
    ) throws -> [String: String] {
        var environment = try Self.executableValidationEnvironment(
            ambient: ambient,
            executableURL: executableURL
        )
        environment["PWD"] = packageURL.path
        environment["TMPDIR"] = "/tmp"
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["CI"] = "1"
        environment["PAGER"] = "/usr/bin/false"
        environment["GIT_PAGER"] = "/usr/bin/false"
        environment["GIT_EDITOR"] = "/usr/bin/false"
        environment["HG_EDITOR"] = "/usr/bin/false"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        return environment
    }

    private enum ReceiptValidationError: Error {
        case missing
        case malformed
        case invalid
    }

    private static func validReceiptTermination(
        _ receipt: CompletionReceipt
    ) -> Bool {
        switch receipt.terminationReason {
        case .exit:
            return receipt.exitStatus != nil
        case .uncaughtSignal:
            return (receipt.exitStatus ?? 0) > 0
        case .timeout, .cancelled, .interrupted:
            return true
        }
    }

    private static func failureForReceiptError(_ error: Error) -> Failure {
        switch error {
        case ReceiptValidationError.missing:
            return .missingReceipt
        case ReceiptValidationError.malformed:
            return .malformedReceipt
        case ReceiptValidationError.invalid:
            return .invalidReceipt
        default:
            return .invalidReceipt
        }
    }

    private func interruptedObservation(
        runID: BurnBarRunID,
        targetHarness: String,
        packageDirectory: URL,
        launchedAt: Date,
        observedAt: Date,
        failure: Failure
    ) -> Observation {
        Observation(
            runID: runID,
            targetHarness: targetHarness,
            state: .interrupted,
            launchedAt: launchedAt,
            observedAt: observedAt,
            completedAt: observedAt,
            terminationReason: .interrupted,
            exitStatus: nil,
            stdoutBytes: 0,
            stderrBytes: 0,
            stdoutTruncated: false,
            stderrTruncated: false,
            failure: failure,
            packageDirectory: packageDirectory
        )
    }

    private func observation(
        from receipt: CompletionReceipt,
        packageDirectory: URL,
        observedAt: Date
    ) -> Observation {
        let state: Observation.State
        let failure: Failure?
        switch receipt.terminationReason {
        case .cancelled:
            state = .cancelled
            failure = nil
        case .interrupted:
            state = .interrupted
            failure = .interrupted
        case .exit where receipt.exitStatus == 0:
            state = .completed
            failure = nil
        case .timeout:
            state = .failed
            failure = .timeout
        case .uncaughtSignal:
            state = .failed
            failure = .signal
        default:
            state = .failed
            failure = .nonzeroExit
        }
        return Observation(
            runID: BurnBarRunID(rawValue: receipt.runID),
            targetHarness: receipt.targetHarness,
            state: state,
            launchedAt: receipt.launchedAt,
            observedAt: observedAt,
            completedAt: receipt.completedAt,
            terminationReason: receipt.terminationReason,
            exitStatus: receipt.exitStatus,
            stdoutBytes: receipt.stdoutBytes,
            stderrBytes: receipt.stderrBytes,
            stdoutObservedBytes: receipt.stdoutObservedBytes,
            stderrObservedBytes: receipt.stderrObservedBytes,
            stdoutTruncated: receipt.stdoutTruncated,
            stderrTruncated: receipt.stderrTruncated,
            failure: failure,
            packageDirectory: packageDirectory
        )
    }

    private static func validateDirectoryDescriptor(
        _ descriptor: Int32,
        exactMode: mode_t
    ) throws -> FilesystemIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isDirectory(info),
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o777) == exactMode else {
            throw SupervisorError.unsafePackage(
                "Safari hand-off storage is not an owner-controlled directory."
            )
        }
        return identity(info)
    }

    private static func validateOwnerOnlyFileDescriptor(
        _ descriptor: Int32,
        expectedDevice: UInt64,
        expectedSize: Int
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegularFile(info),
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & mode_t(0o777) == mode_t(0o600),
              UInt64(info.st_dev) == expectedDevice,
              info.st_size == expectedSize else {
            throw POSIXError(.EPERM)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                offset += count
            }
        }
    }

    private static func readBounded(
        from descriptor: Int32,
        limit: Int
    ) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw POSIXError(.EIO)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, limit + 1))
        while result.count <= limit {
            let count = read(
                descriptor,
                &buffer,
                min(buffer.count, limit + 1 - result.count)
            )
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        guard result.count <= limit else {
            throw POSIXError(.EFBIG)
        }
        return result
    }

    private static func isSafeChildName(_ value: String) -> Bool {
        value.isEmpty == false
            && value != "."
            && value != ".."
            && value.utf8.count <= 255
            && value.contains("/") == false
            && value.contains("\0") == false
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x61...0x66).contains($0)
            }
    }

    private static func isSafeHarnessIdentifier(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= 128
            && value.utf8.allSatisfy {
                ($0 >= 0x61 && $0 <= 0x7A)
                    || ($0 >= 0x30 && $0 <= 0x39)
                    || $0 == 0x2D
                    || $0 == 0x5F
            }
    }

    private static func identity(_ info: stat) -> FilesystemIdentity {
        FilesystemIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isRegularFile(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func timeoutNanoseconds(
        from interval: TimeInterval
    ) -> UInt64 {
        UInt64(
            min(
                interval,
                TimeInterval(UInt64.max / 1_000_000_000)
            ) * 1_000_000_000
        )
    }

    private static func decodeWaitStatus(
        _ waitStatus: Int32?
    ) -> (exitStatus: Int32?, wasSignalled: Bool) {
        guard let waitStatus else {
            return (nil, false)
        }
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return ((waitStatus >> 8) & 0xff, false)
        }
        return (signal, true)
    }
}

// MARK: - Executable trust

extension SafariHandoffProcessSupervisor {
    enum ExecutableTrustFailure: String, Error, Sendable {
        case invalidURL = "invalid_url"
        case interpreterDepthExceeded = "interpreter_depth_exceeded"
        case entryUnavailable = "entry_unavailable"
        case entryNotRegularFile = "entry_not_regular_file"
        case untrustedParentDirectory = "untrusted_parent_directory"
        case openFailed = "open_failed"
        case metadataUnavailable = "metadata_unavailable"
        case untrustedOwner = "untrusted_owner"
        case writableByGroupOrOther = "writable_by_group_or_other"
        case notExecutable = "not_executable"
        case multipleHardLinks = "multiple_hard_links"
        case unreadableExecutable = "unreadable_executable"
        case malformedShebang = "malformed_shebang"
        case unsupportedEnvShebang = "unsupported_env_shebang"
        case interpreterNotFound = "interpreter_not_found"
        case relativeInterpreter = "relative_interpreter"
        case unsupportedExecutableFormat = "unsupported_executable_format"
        case invalidCodeSignature = "invalid_code_signature"
        case executableChanged = "executable_changed"
        case noTrustedSearchPath = "no_trusted_search_path"
        case unexpectedValidationFailure = "unexpected_validation_failure"
    }

    enum ExecutableTrustAssessment: Sendable, Equatable {
        case trusted
        case rejected(ExecutableTrustFailure)
    }

    enum ExecutableValidator {
        static func assessForLaunch(
            url: URL,
            ambientEnvironment: [String: String] =
                ProcessInfo.processInfo.environment
        ) -> ExecutableTrustAssessment {
            do {
                let environment = try SafariHandoffProcessSupervisor
                    .executableValidationEnvironment(
                        ambient: ambientEnvironment,
                        executableURL: url
                    )
                _ = try validate(url: url, environment: environment)
                return .trusted
            } catch let failure as ExecutableTrustFailure {
                return .rejected(failure)
            } catch {
                return .rejected(.unexpectedValidationFailure)
            }
        }

        static func validate(
            url: URL,
            environment: [String: String]
        ) throws -> ValidatedExecutable {
            try validate(
                url: url,
                environment: environment,
                depth: 0
            )
        }

        static func deterministicPath(
            executableURL: URL,
            environment: [String: String]
        ) throws -> String {
            let home = environment["HOME"] ?? NSHomeDirectory()
            let candidates = [
                executableURL.deletingLastPathComponent().path,
                executableURL.resolvingSymlinksInPath()
                    .deletingLastPathComponent().path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "\(home)/.local/bin",
                "\(home)/.codex/bin",
                "\(home)/.claude/bin",
                "\(home)/.opencode/bin",
                "\(home)/.antigravity/bin",
                "\(home)/.gemini/bin",
                "\(home)/.cursor-agent/bin",
                "\(home)/.pi/bin",
                "\(home)/.cargo/bin",
                "\(home)/.bun/bin",
                "\(home)/.volta/bin"
            ]
            var seen = Set<String>()
            let trusted = try candidates.compactMap { raw -> String? in
                let path = URL(fileURLWithPath: raw).standardizedFileURL.path
                guard seen.insert(path).inserted,
                      FileManager.default.fileExists(atPath: path) else {
                    return nil
                }
                do {
                    try validateParentDirectories(
                        of: path + "/placeholder"
                    )
                } catch ExecutableTrustFailure.untrustedParentDirectory {
                    return nil
                }
                return path
            }
            guard trusted.isEmpty == false else {
                throw ExecutableTrustFailure.noTrustedSearchPath
            }
            return trusted.joined(separator: ":")
        }

        private static func validate(
            url: URL,
            environment: [String: String],
            depth: Int
        ) throws -> ValidatedExecutable {
            guard depth <= 4 else {
                throw ExecutableTrustFailure.interpreterDepthExceeded
            }
            guard url.isFileURL,
                  url.path.hasPrefix("/"),
                  url.path.contains("\0") == false else {
                throw ExecutableTrustFailure.invalidURL
            }
            if depth == 0 {
                var supplied = stat()
                guard lstat(url.path, &supplied) == 0 else {
                    throw ExecutableTrustFailure.entryUnavailable
                }
                guard supplied.st_mode & mode_t(S_IFMT)
                    == mode_t(S_IFREG) else {
                    throw ExecutableTrustFailure.entryNotRegularFile
                }
            }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            try validateParentDirectories(of: canonical.path)
            let descriptor = open(
                canonical.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                throw ExecutableTrustFailure.openFailed
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw ExecutableTrustFailure.metadataUnavailable
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw ExecutableTrustFailure.entryNotRegularFile
            }
            guard info.st_uid == geteuid() || info.st_uid == 0 else {
                throw ExecutableTrustFailure.untrustedOwner
            }
            guard info.st_mode & mode_t(0o022) == 0 else {
                throw ExecutableTrustFailure.writableByGroupOrOther
            }
            guard info.st_mode & mode_t(0o111) != 0 else {
                throw ExecutableTrustFailure.notExecutable
            }
            guard info.st_nlink == 1 else {
                throw ExecutableTrustFailure.multipleHardLinks
            }
            let prefix = try readPrefix(descriptor: descriptor, limit: 4096)
            let modificationTime = modificationTime(info)
            let component = ValidatedExecutable.Component(
                path: canonical.path,
                identity: FilesystemIdentity(
                    device: UInt64(info.st_dev),
                    inode: UInt64(info.st_ino)
                ),
                size: Int64(info.st_size),
                modificationSeconds: modificationTime.seconds,
                modificationNanoseconds: modificationTime.nanoseconds
            )
            let launchPath: String
            let launchArguments: [String]
            let components: [ValidatedExecutable.Component]
            if prefix.starts(with: Data([0x23, 0x21])) {
                let interpreter = try validatedInterpreter(
                    prefix: prefix,
                    environment: environment,
                    depth: depth + 1
                )
                launchPath = interpreter.executable.launchPath
                launchArguments =
                    interpreter.executable.launchArguments
                    + interpreter.arguments
                    + [canonical.path]
                components =
                    [component]
                    + interpreter.validationComponents
            } else if isMachO(prefix) {
                try validateNativeCode(at: canonical)
                launchPath = canonical.path
                launchArguments = []
                components = [component]
            } else {
                throw ExecutableTrustFailure.unsupportedExecutableFormat
            }
            var current = stat()
            guard lstat(canonical.path, &current) == 0,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  UInt64(current.st_dev) == UInt64(info.st_dev),
                  UInt64(current.st_ino) == UInt64(info.st_ino),
                  current.st_size == info.st_size else {
                throw ExecutableTrustFailure.executableChanged
            }
            return ValidatedExecutable(
                path: canonical.path,
                identity: component.identity,
                size: component.size,
                modificationSeconds: component.modificationSeconds,
                modificationNanoseconds: component.modificationNanoseconds,
                launchPath: launchPath,
                launchArguments: launchArguments,
                components: components
            )
        }

        private static func modificationTime(
            _ info: stat
        ) -> (seconds: Int64, nanoseconds: Int64) {
            #if canImport(Darwin)
            return (
                Int64(info.st_mtimespec.tv_sec),
                Int64(info.st_mtimespec.tv_nsec)
            )
            #elseif canImport(Glibc)
            return (
                Int64(info.st_mtim.tv_sec),
                Int64(info.st_mtim.tv_nsec)
            )
            #else
            return (Int64(info.st_mtime), 0)
            #endif
        }

        private static func validateParentDirectories(
            of path: String
        ) throws {
            var directory = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .standardizedFileURL
            while true {
                var info = stat()
                guard lstat(directory.path, &info) == 0,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      info.st_uid == geteuid() || info.st_uid == 0,
                      info.st_mode & mode_t(0o022) == 0 else {
                    throw ExecutableTrustFailure.untrustedParentDirectory
                }
                if directory.path == "/" { break }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { break }
                directory = parent
            }
        }

        private static func validatedInterpreter(
            prefix: Data,
            environment: [String: String],
            depth: Int
        ) throws -> (
            executable: ValidatedExecutable,
            arguments: [String],
            validationComponents: [ValidatedExecutable.Component]
        ) {
            guard let line = String(
                data: prefix,
                encoding: .utf8
            )?.split(separator: "\n", maxSplits: 1).first else {
                throw ExecutableTrustFailure.malformedShebang
            }
            let fields = line.dropFirst(2).split(whereSeparator: {
                $0 == " " || $0 == "\t"
            })
            guard let first = fields.first else {
                throw ExecutableTrustFailure.malformedShebang
            }
            let interpreter = String(first)
            if interpreter == "/usr/bin/env" {
                let envExecutable = try validate(
                    url: URL(fileURLWithPath: interpreter),
                    environment: environment,
                    depth: depth
                )
                // Supporting only the ordinary `env command` form keeps
                // launch semantics exact. `env -S` requires shell-like
                // tokenization, and silently approximating it would weaken
                // interpreter pinning.
                guard fields.count == 2 else {
                    throw ExecutableTrustFailure.unsupportedEnvShebang
                }
                let command = String(fields[1])
                guard command.contains("/") == false else {
                    throw ExecutableTrustFailure.unsupportedEnvShebang
                }
                guard let resolved = resolve(
                          command: command,
                          path: environment["PATH"] ?? ""
                      ) else {
                    throw ExecutableTrustFailure.interpreterNotFound
                }
                let resolvedExecutable = try validate(
                    url: resolved,
                    environment: environment,
                    depth: depth
                )
                return (
                    resolvedExecutable,
                    [],
                    envExecutable.components
                        + resolvedExecutable.components
                )
            }
            guard interpreter.hasPrefix("/") else {
                throw ExecutableTrustFailure.relativeInterpreter
            }
            let executable = try validate(
                url: URL(fileURLWithPath: interpreter),
                environment: environment,
                depth: depth
            )
            return (
                executable,
                fields.dropFirst().map(String.init),
                executable.components
            )
        }

        private static func resolve(
            command: String,
            path: String
        ) -> URL? {
            for directory in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(command)
                var entry = stat()
                guard lstat(candidate.path, &entry) == 0 else {
                    continue
                }
                if entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                   entry.st_mode & mode_t(0o111) != 0 {
                    return candidate.standardizedFileURL
                }
                if entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    let canonical = candidate.resolvingSymlinksInPath()
                        .standardizedFileURL
                    var target = stat()
                    if lstat(canonical.path, &target) == 0,
                       target.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                       target.st_mode & mode_t(0o111) != 0 {
                        return canonical
                    }
                }
            }
            return nil
        }

        private static func readPrefix(
            descriptor: Int32,
            limit: Int
        ) throws -> Data {
            var bytes = [UInt8](repeating: 0, count: limit)
            let count = pread(descriptor, &bytes, limit, 0)
            guard count > 0 else {
                throw ExecutableTrustFailure.unreadableExecutable
            }
            return Data(bytes.prefix(count))
        }

        private static func isMachO(_ data: Data) -> Bool {
            guard data.count >= 4 else { return false }
            let value = data.prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            return [
                0xFEED_FACE,
                0xFEED_FACF,
                0xCEFA_EDFE,
                0xCFFA_EDFE,
                0xCAFE_BABE,
                0xBEBA_FECA,
                0xCAFE_BABF,
                0xBFBA_FECA
            ].contains(value)
        }

        private static func validateNativeCode(at url: URL) throws {
            #if os(macOS)
            var staticCode: SecStaticCode?
            let creation = SecStaticCodeCreateWithPath(
                url as CFURL,
                [],
                &staticCode
            )
            guard creation == errSecSuccess, let staticCode,
                  SecStaticCodeCheckValidity(staticCode, [], nil)
                    == errSecSuccess else {
                throw ExecutableTrustFailure.invalidCodeSignature
            }
            #else
            _ = url
            #endif
        }
    }
}

// MARK: - Production watchdog session

#if os(macOS)
// AUDIT: The watchdog owns POSIX process/session descriptors and serializes
// mutable observation state through its lock and dispatch queue.
// sendable-allowlist: process-handle
private final class POSIXWatchdogSession:
    SafariHandoffProcessSupervisor.WatchdogSession,
    @unchecked Sendable { // sendable-allowlist: process-handle
    typealias Supervisor = SafariHandoffProcessSupervisor

    // AUDIT: Output bytes and truncation counters are snapshots guarded by the
    // collector's NSLock while the watchdog reads pipes concurrently.
    // sendable-allowlist: internal-lock-snapshot-store
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var observed = 0
        private var truncated = false

        func append(_ chunk: Data) {
            guard chunk.isEmpty == false else { return }
            lock.lock()
            let addition = observed.addingReportingOverflow(chunk.count)
            observed = addition.overflow ? Int.max : addition.partialValue
            if data.count < Supervisor.outputLimitBytes {
                data.append(
                    chunk.prefix(Supervisor.outputLimitBytes - data.count)
                )
            }
            truncated = truncated
                || observed > Supervisor.outputLimitBytes
            lock.unlock()
        }

        func snapshot() -> Supervisor.OutputSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return Supervisor.OutputSnapshot(
                data: data,
                observedBytes: observed,
                truncated: truncated
            )
        }
    }

    private let context: Supervisor.SessionLaunchContext
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "com.openburnbar.safari-handoff-watchdog"
    )
    private let queueKey = DispatchSpecificKey<Void>()
    private let stdoutCollector = Collector()
    private let stderrCollector = Collector()
    private var livenessWrite: Int32 = -1
    private var commandWrite: Int32 = -1
    private var statusRead: Int32 = -1
    private var stdoutRead: Int32 = -1
    private var stderrRead: Int32 = -1
    private var statusSource: DispatchSourceRead?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var statusDecoder = Supervisor.StatusFrameDecoder()
    private var terminalDelivered = false
    private var ready: Supervisor.WatchdogReady?
    private var watchdogPID: pid_t = -1
    private var sentinelPID: pid_t = -1
    private var sentinelIdentity: Supervisor.ProcessIdentity?
    private var cleanupRequired = false

    init(context: Supervisor.SessionLaunchContext) throws {
        self.context = context
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        closeLiveness()
        if cleanupRequired {
            finishDraining()
        }
    }

    func start() throws -> Supervisor.WatchdogReady {
        var sentinelLifetime = try Self.makePipe()
        defer { Self.closePipe(&sentinelLifetime) }
        var sentinelReady = try Self.makePipe()
        defer { Self.closePipe(&sentinelReady) }
        var liveness = try Self.makePipe()
        defer { Self.closePipe(&liveness) }
        var command = try Self.makePipe()
        defer { Self.closePipe(&command) }
        var configuration = try Self.makePipe()
        defer { Self.closePipe(&configuration) }
        var status = try Self.makePipe()
        defer { Self.closePipe(&status) }
        var stdout = try Self.makePipe()
        defer { Self.closePipe(&stdout) }
        var stderr = try Self.makePipe()
        defer { Self.closePipe(&stderr) }
        let nullDescriptor = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullDescriptor >= 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog standard streams could not be isolated."
            )
        }
        defer { close(nullDescriptor) }

        guard let helperPath =
                DaemonSelfCodeSignatureVerifier.defaultExecutablePath(),
              helperPath.hasPrefix("/") else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The containment-helper executable path is unavailable."
            )
        }
        let launchedSentinelPID = try Self.spawnSentinel(
            executablePath: helperPath,
            lifetimeDescriptor: sentinelLifetime.read,
            readinessDescriptor: sentinelReady.write,
            nullDescriptor: nullDescriptor
        )
        cleanupRequired = true
        sentinelPID = launchedSentinelPID
        Self.closeDescriptor(&sentinelLifetime.read)
        Self.closeDescriptor(&sentinelReady.write)
        try Self.awaitSentinelReady(
            descriptor: sentinelReady.read
        )
        Self.closeDescriptor(&sentinelReady.read)
        let launchedSentinelIdentity = try Self.processIdentity(
            processID: launchedSentinelPID,
            processGroupID: launchedSentinelPID
        )
        sentinelIdentity = launchedSentinelIdentity

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog launch actions could not be initialized."
            )
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let rawMappings: [(source: Int32, target: Int32)] = [
            (nullDescriptor, STDIN_FILENO),
            (nullDescriptor, STDOUT_FILENO),
            (nullDescriptor, STDERR_FILENO),
            (context.packageDescriptor, SafariHandoffProcessWatchdog.packageFD),
            (liveness.read, SafariHandoffProcessWatchdog.livenessFD),
            (command.read, SafariHandoffProcessWatchdog.commandFD),
            (configuration.read, SafariHandoffProcessWatchdog.configurationFD),
            (status.write, SafariHandoffProcessWatchdog.statusFD),
            (stdout.write, SafariHandoffProcessWatchdog.stdoutFD),
            (stderr.write, SafariHandoffProcessWatchdog.stderrFD),
            (
                sentinelLifetime.write,
                SafariHandoffProcessWatchdog.sentinelLifetimeFD
            )
        ]
        // Pipe descriptors are commonly allocated inside the watchdog's
        // private target range (3...10). posix_spawn applies dup2 actions in
        // order, so mapping one target could otherwise overwrite the source
        // of a later mapping. Give every inherited source its own CLOEXEC copy
        // above the protocol range before constructing any file action.
        var mappings = try Self.makeSpawnMappings(rawMappings)
        defer {
            Self.closeSpawnMappings(&mappings)
        }
        for (source, target) in mappings {
            guard posix_spawn_file_actions_adddup2(
                &actions,
                source,
                target
            ) == 0 else {
                throw Supervisor.SupervisorError.watchdogLaunchFailed(
                    "The watchdog launch descriptors could not be isolated."
                )
            }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog launch attributes could not be initialized."
            )
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog launch descriptors could not be contained."
            )
        }

        let arguments = [
            helperPath,
            SafariHandoffProcessWatchdog.marker
        ]
        let environment = [
            "HOME=\(NSHomeDirectory())",
            "PATH=/usr/bin:/bin",
            "LANG=C",
            "TERM=dumb",
            "NO_COLOR=1"
        ]
        var pid = pid_t()
        let spawnStatus = try Self.withCStrings(
            arguments: arguments,
            environment: environment
        ) { argv, envp in
            posix_spawn(
                &pid,
                helperPath,
                &actions,
                &attributes,
                argv,
                envp
            )
        }
        // posix_spawn has consumed every file action. Drop all spawn-only
        // copies before inspecting the result or waiting for the handshake.
        Self.closeSpawnMappings(&mappings)
        // The raw writer was deliberately not transferred into session state.
        // Close it immediately too: from this point only the watchdog may keep
        // the sentinel alive.
        Self.closeDescriptor(&sentinelLifetime.write)
        guard spawnStatus == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog subprocess refused to start."
            )
        }
        var launchCommitted = false
        defer {
            if launchCommitted == false {
                Self.closeDescriptor(&configuration.write)
                closeLiveness()
                Self.reapOwnedWatchdog(pid)
                finishDraining()
            }
        }

        Self.closeDescriptor(&liveness.read)
        Self.closeDescriptor(&command.read)
        Self.closeDescriptor(&configuration.read)
        Self.closeDescriptor(&status.write)
        Self.closeDescriptor(&stdout.write)
        Self.closeDescriptor(&stderr.write)
        livenessWrite = Self.takeDescriptor(&liveness.write)
        commandWrite = Self.takeDescriptor(&command.write)
        statusRead = Self.takeDescriptor(&status.read)
        stdoutRead = Self.takeDescriptor(&stdout.read)
        stderrRead = Self.takeDescriptor(&stderr.read)
        try Self.makeNonblocking(statusRead)
        try Self.makeNonblocking(stdoutRead)
        try Self.makeNonblocking(stderrRead)
        startOutputSources()

        let envelope = SafariHandoffProcessWatchdog.Envelope(
            generation: context.generation,
            packageIdentity: context.packageIdentity,
            containmentIdentity: launchedSentinelIdentity,
            executable: context.executable,
            arguments: context.arguments,
            environment: context.environment
        )
        let encoded = try JSONEncoder().encode(envelope)
        guard encoded.count
                <= SafariHandoffProcessWatchdog.maximumEnvelopeBytes else {
            closeLiveness()
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog launch envelope exceeded its bound."
            )
        }
        try Self.writeAll(encoded, to: configuration.write)
        Self.closeDescriptor(&configuration.write)

        let firstMessage = try readInitialStatus()
        switch firstMessage.kind {
        case .ready:
            guard let processGroupID = firstMessage.processGroupID,
                  processGroupID > 1,
                  let containmentIdentity =
                    firstMessage.containmentIdentity,
                  containmentIdentity == launchedSentinelIdentity,
                  containmentIdentity.processID == processGroupID,
                  containmentIdentity.processGroupID == processGroupID,
                  Self.isCurrentProcess(containmentIdentity) else {
                closeLiveness()
                throw Supervisor.SupervisorError.watchdogLaunchFailed(
                    "The watchdog returned an invalid process identity."
                )
            }
            let result = Supervisor.WatchdogReady(
                watchdogPID: Int32(pid),
                processGroupID: processGroupID,
                containmentIdentity: containmentIdentity
            )
            watchdogPID = pid
            ready = result
            startStatusSource()
            launchCommitted = true
            return result
        case .terminal, .launchFailed:
            closeLiveness()
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                firstMessage.error
                    ?? "The watchdog rejected the installed agent."
            )
        }
    }

    @discardableResult
    func requestTermination() -> Bool {
        lock.lock()
        let descriptor = commandWrite
        lock.unlock()
        guard descriptor >= 0 else { return false }
        var byte: UInt8 = 1
        while true {
            let count = write(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            return count == 1
        }
    }

    func forceContainment() {
        lock.lock()
        let containmentIdentity =
            ready?.containmentIdentity ?? sentinelIdentity
        let expectedSentinelPID = sentinelPID
        lock.unlock()
        guard let containmentIdentity,
              containmentIdentity.processID > 1,
              containmentIdentity.processID
                == containmentIdentity.processGroupID,
              Self.isOwnedSentinel(
                  containmentIdentity,
                  expectedPID: expectedSentinelPID
              ) else {
            return
        }
        _ = kill(-containmentIdentity.processGroupID, SIGTERM)
        // The sentinel is the daemon's unreaped direct child and remains the
        // process-group leader for the whole run. Revalidate its exact start
        // identity before SIGKILL so a numeric PID/PGID can never be reused.
        guard Self.isOwnedSentinel(
            containmentIdentity,
            expectedPID: expectedSentinelPID
        ) else {
            return
        }
        _ = kill(-containmentIdentity.processGroupID, SIGKILL)
    }

    func closeLiveness() {
        lock.lock()
        let descriptor = livenessWrite
        livenessWrite = -1
        lock.unlock()
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    func stdoutSnapshot() -> Supervisor.OutputSnapshot {
        stdoutCollector.snapshot()
    }

    func stderrSnapshot() -> Supervisor.OutputSnapshot {
        stderrCollector.snapshot()
    }

    func finishDraining() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            finishDrainingOnQueue()
        } else {
            queue.sync {
                finishDrainingOnQueue()
            }
        }
    }

    private func finishDrainingOnQueue() {
        drainOutputPipesToEOF()

        lock.lock()
        let sources = [statusSource, stdoutSource, stderrSource]
        statusSource = nil
        stdoutSource = nil
        stderrSource = nil
        let descriptors = [
            statusRead,
            stdoutRead,
            stderrRead,
            commandWrite
        ]
        statusRead = -1
        stdoutRead = -1
        stderrRead = -1
        commandWrite = -1
        lock.unlock()
        sources.forEach { $0?.cancel() }
        descriptors.filter { $0 >= 0 }.forEach { descriptor in
            _ = close(descriptor)
        }
        reapWatchdog()
        reapSentinel()
        cleanupRequired = false
    }

    private func startOutputSources() {
        stdoutSource = Self.makeReadSource(
            descriptor: stdoutRead,
            queue: queue,
            consume: { [stdoutCollector] data in
                stdoutCollector.append(data)
            }
        )
        stderrSource = Self.makeReadSource(
            descriptor: stderrRead,
            queue: queue,
            consume: { [stderrCollector] data in
                stderrCollector.append(data)
            }
        )
    }

    private func startStatusSource() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: statusRead,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.consumeStatus()
        }
        source.setCancelHandler {}
        statusSource = source
        source.resume()
    }

    private func stopStatusSource() {
        lock.lock()
        let source = statusSource
        statusSource = nil
        let descriptor = statusRead
        statusRead = -1
        lock.unlock()
        source?.cancel()
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    private func consumeStatus() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(statusRead, &buffer, buffer.count)
        if count > 0 {
            do {
                let messages = try statusDecoder.append(
                    Data(buffer.prefix(count))
                )
                for message in messages {
                    switch message.kind {
                    case .terminal:
                        deliverTerminal(
                            Supervisor.WatchdogTerminal(
                                waitStatus: message.waitStatus,
                                failure: message.error
                            )
                        )
                    case .launchFailed:
                        deliverFailure(
                            message.error
                                ?? "The watchdog failed after launch."
                        )
                    case .ready:
                        break
                    }
                }
            } catch Supervisor.StatusFrameDecoder.FrameError.oversized {
                deliverFailure(
                    "The watchdog status exceeded its protocol bound."
                )
            } catch {
                deliverFailure("The watchdog emitted malformed status.")
            }
        } else if count == 0 {
            do {
                try statusDecoder.finish()
                deliverFailure(
                    "The watchdog status channel closed unexpectedly."
                )
            } catch {
                deliverFailure(
                    "The watchdog status channel closed with a partial frame."
                )
            }
        } else if errno != EINTR && errno != EAGAIN {
            deliverFailure("The watchdog status channel failed.")
        }
    }

    private func deliverTerminal(_ terminal: Supervisor.WatchdogTerminal) {
        lock.lock()
        guard terminalDelivered == false else {
            lock.unlock()
            return
        }
        terminalDelivered = true
        lock.unlock()
        stopStatusSource()
        context.onTerminal(terminal)
    }

    private func deliverFailure(_ message: String) {
        lock.lock()
        guard terminalDelivered == false else {
            lock.unlock()
            return
        }
        terminalDelivered = true
        lock.unlock()
        stopStatusSource()
        context.onFailure(message)
    }

    private func readInitialStatus()
        throws -> SafariHandoffProcessWatchdog.Message {
        var line = Data()
        let deadline = DispatchTime.now().uptimeNanoseconds
            + 10_000_000_000
        while line.count <= SafariHandoffProcessWatchdog.maximumStatusBytes {
            var descriptor = pollfd(
                fd: statusRead,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = poll(&descriptor, 1, 100)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else {
                throw Supervisor.SupervisorError.watchdogLaunchFailed(
                    "The watchdog launch handshake failed."
                )
            }
            if result == 0 {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw Supervisor.SupervisorError.watchdogLaunchFailed(
                        "The watchdog launch handshake timed out."
                    )
                }
                continue
            }
            var byte: UInt8 = 0
            let count = read(statusRead, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            guard count == 1 else {
                throw Supervisor.SupervisorError.watchdogLaunchFailed(
                    "The watchdog closed before launch was confirmed."
                )
            }
            if byte == 0x0A {
                return try JSONDecoder().decode(
                    SafariHandoffProcessWatchdog.Message.self,
                    from: line
                )
            }
            line.append(byte)
        }
        throw Supervisor.SupervisorError.watchdogLaunchFailed(
            "The watchdog launch status exceeded its bound."
        )
    }

    private static func makeReadSource(
        descriptor: Int32,
        queue: DispatchQueue,
        consume: @escaping @Sendable (Data) -> Void
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    consume(Data(buffer.prefix(count)))
                    continue
                }
                if count < 0, errno == EINTR { continue }
                break
            }
        }
        source.setCancelHandler {}
        source.resume()
        return source
    }

    private func drainOutputPipesToEOF() {
        var streams: [
            (
                descriptor: Int32,
                collector: Collector,
                reachedEOF: Bool
            )
        ] = [
            (stdoutRead, stdoutCollector, stdoutRead < 0),
            (stderrRead, stderrCollector, stderrRead < 0)
        ]
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ 2_500_000_000

        while streams.contains(where: { $0.reachedEOF == false }) {
            for index in streams.indices where streams[index].reachedEOF == false {
                streams[index].reachedEOF = Self.drainAvailable(
                    descriptor: streams[index].descriptor,
                    collector: streams[index].collector
                )
            }
            if streams.allSatisfy({ $0.reachedEOF }) {
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                return
            }
            var descriptors = streams
                .filter { $0.reachedEOF == false }
                .map {
                    pollfd(
                        fd: $0.descriptor,
                        events: Int16(POLLIN | POLLHUP | POLLERR),
                        revents: 0
                    )
                }
            let remainingMilliseconds = min(
                Int32((deadline - now) / 1_000_000),
                100
            )
            let result = poll(
                &descriptors,
                nfds_t(descriptors.count),
                max(remainingMilliseconds, 1)
            )
            if result < 0, errno == EINTR {
                continue
            }
            if result < 0 {
                return
            }
        }
    }

    private static func drainAvailable(
        descriptor: Int32,
        collector: Collector
    ) -> Bool {
        guard descriptor >= 0 else { return true }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                collector.append(Data(buffer.prefix(count)))
                continue
            }
            if count == 0 {
                return true
            }
            if errno == EINTR {
                continue
            }
            return false
        }
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard descriptors.allSatisfy({
            fcntl($0, F_SETFD, FD_CLOEXEC) == 0
        }),
        fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0 else {
            descriptors.forEach { descriptor in
                _ = close(descriptor)
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func duplicateForSpawn(_ descriptor: Int32) throws -> Int32 {
        let minimumDescriptor =
            SafariHandoffProcessWatchdog.sentinelLifetimeFD + 1
        let duplicate = fcntl(
            descriptor,
            F_DUPFD_CLOEXEC,
            minimumDescriptor
        )
        guard duplicate >= minimumDescriptor else {
            if duplicate >= 0 {
                close(duplicate)
            }
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog launch descriptors could not be isolated."
            )
        }
        return duplicate
    }

    private static func makeSpawnMappings(
        _ rawMappings: [(source: Int32, target: Int32)]
    ) throws -> [(source: Int32, target: Int32)] {
        var mappings: [(source: Int32, target: Int32)] = []
        mappings.reserveCapacity(rawMappings.count)
        do {
            for mapping in rawMappings {
                mappings.append(
                    (
                        source: try duplicateForSpawn(mapping.source),
                        target: mapping.target
                    )
                )
            }
            return mappings
        } catch {
            closeSpawnMappings(&mappings)
            throw error
        }
    }

    private static func closeSpawnMappings(
        _ mappings: inout [(source: Int32, target: Int32)]
    ) {
        mappings.forEach { close($0.source) }
        mappings.removeAll(keepingCapacity: false)
    }

    private static func spawnSentinel(
        executablePath: String,
        lifetimeDescriptor: Int32,
        readinessDescriptor: Int32,
        nullDescriptor: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The containment sentinel actions could not be initialized."
            )
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let rawMappings: [(source: Int32, target: Int32)] = [
            (nullDescriptor, STDIN_FILENO),
            (nullDescriptor, STDOUT_FILENO),
            (nullDescriptor, STDERR_FILENO),
            (
                lifetimeDescriptor,
                SafariHandoffProcessSentinel.livenessFD
            ),
            (
                readinessDescriptor,
                SafariHandoffProcessSentinel.readyFD
            )
        ]
        var mappings = try makeSpawnMappings(rawMappings)
        defer {
            closeSpawnMappings(&mappings)
        }
        for (source, target) in mappings {
            guard posix_spawn_file_actions_adddup2(
                &actions,
                source,
                target
            ) == 0 else {
                throw Supervisor.SupervisorError.watchdogLaunchFailed(
                    "The containment sentinel descriptors could not be isolated."
                )
            }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The containment sentinel attributes could not be initialized."
            )
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The containment sentinel process group could not be isolated."
            )
        }

        let arguments = [
            executablePath,
            SafariHandoffProcessSentinel.marker
        ]
        let environment = [
            "HOME=\(NSHomeDirectory())",
            "PATH=/usr/bin:/bin",
            "LANG=C",
            "TERM=dumb",
            "NO_COLOR=1"
        ]
        var pid = pid_t()
        let spawnStatus = try withCStrings(
            arguments: arguments,
            environment: environment
        ) { argv, envp in
            posix_spawn(
                &pid,
                executablePath,
                &actions,
                &attributes,
                argv,
                envp
            )
        }
        closeSpawnMappings(&mappings)
        guard spawnStatus == 0, pid > 1 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The containment sentinel refused to start."
            )
        }
        return pid
    }

    private static func awaitSentinelReady(
        descriptor: Int32
    ) throws {
        guard descriptor >= 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The containment sentinel readiness channel is unavailable."
            )
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let result = poll(&pollDescriptor, 1, 100)
            if result < 0, errno == EINTR {
                continue
            }
            guard result >= 0 else {
                break
            }
            if result == 0 {
                continue
            }
            if pollDescriptor.revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                while true {
                    let count = read(descriptor, &byte, 1)
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count == 1,
                          byte == SafariHandoffProcessSentinel.readyByte else {
                        throw Supervisor.SupervisorError.watchdogLaunchFailed(
                            "The containment sentinel readiness handshake was invalid."
                        )
                    }
                    return
                }
            }
            if pollDescriptor.revents & Int16(POLLHUP | POLLERR) != 0 {
                break
            }
        }
        throw Supervisor.SupervisorError.watchdogLaunchFailed(
            "The containment sentinel did not become ready."
        )
    }

    private static func makeNonblocking(_ descriptor: Int32) throws {
        guard descriptor >= 0 else {
            throw POSIXError(.EBADF)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func closePipe(
        _ pipe: inout (read: Int32, write: Int32)
    ) {
        closeDescriptor(&pipe.read)
        closeDescriptor(&pipe.write)
    }

    private static func closeDescriptor(_ descriptor: inout Int32) {
        let owned = takeDescriptor(&descriptor)
        if owned >= 0 {
            close(owned)
        }
    }

    private static func takeDescriptor(
        _ descriptor: inout Int32
    ) -> Int32 {
        let owned = descriptor
        descriptor = -1
        return owned
    }

    private func reapWatchdog() {
        lock.lock()
        let pid = watchdogPID
        watchdogPID = -1
        ready = nil
        lock.unlock()
        Self.reapOwnedWatchdog(pid)
    }

    private func reapSentinel() {
        lock.lock()
        let pid = sentinelPID
        let identity = sentinelIdentity
        sentinelPID = -1
        sentinelIdentity = nil
        lock.unlock()
        Self.reapOwnedSentinel(pid, identity: identity)
    }

    private static func processIdentity(
        processID: pid_t,
        processGroupID: pid_t
    ) throws -> Supervisor.ProcessIdentity {
        guard processID > 1, processID == processGroupID else {
            throw POSIXError(.EPERM)
        }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(size)
            )
        }
        guard result == Int32(size),
              Int32(info.pbi_pid) == processID,
              Int32(info.pbi_pgid) == processGroupID else {
            throw POSIXError(.ESRCH)
        }
        return Supervisor.ProcessIdentity(
            processID: Int32(processID),
            processGroupID: Int32(processGroupID),
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    private static func isCurrentProcess(
        _ expected: Supervisor.ProcessIdentity
    ) -> Bool {
        guard expected.processID > 1,
              expected.processID == expected.processGroupID else {
            return false
        }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                expected.processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(size)
            )
        }
        return result == Int32(size)
            && Int32(info.pbi_pid) == expected.processID
            && Int32(info.pbi_pgid) == expected.processGroupID
            && UInt64(info.pbi_start_tvsec) == expected.startSeconds
            && UInt64(info.pbi_start_tvusec) == expected.startMicroseconds
    }

    private static func isOwnedSentinel(
        _ expected: Supervisor.ProcessIdentity,
        expectedPID: pid_t
    ) -> Bool {
        guard expectedPID == expected.processID else {
            return false
        }
        if isCurrentProcess(expected) {
            return true
        }
        var info = siginfo_t()
        while true {
            let result = waitid(
                P_PID,
                id_t(expectedPID),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result < 0, errno == EINTR {
                continue
            }
            return result == 0 && info.si_pid == expectedPID
        }
    }

    private static func reapOwnedWatchdog(_ pid: pid_t) {
        guard pid > 1 else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ 3_000_000_000
        var status: Int32 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) {
                return
            }
            if result < 0, errno != EINTR {
                break
            }
            usleep(10_000)
        }
        _ = kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    private static func reapOwnedSentinel(
        _ pid: pid_t,
        identity: Supervisor.ProcessIdentity?
    ) {
        guard pid > 1 else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ 3_000_000_000
        var status: Int32 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) {
                return
            }
            if result < 0, errno != EINTR {
                break
            }
            usleep(10_000)
        }
        if let identity, isCurrentProcess(identity) {
            _ = kill(-identity.processGroupID, SIGKILL)
        } else {
            // This is still our unreaped direct child, so its numeric PID
            // cannot have been reused. During an early READY/identity failure
            // no CLI has joined the group yet; killing the child itself avoids
            // an unbounded wait without risking an unrelated process group.
            _ = kill(pid, SIGKILL)
        }
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                offset += count
            }
        }
    }

    private static func withCStrings<T>(
        arguments: [String],
        environment: [String],
        body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        ) -> T
    ) throws -> T {
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            for case let pointer? in argv {
                free(pointer)
            }
            for case let pointer? in envp {
                free(pointer)
            }
        }
        return argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                body(
                    UnsafeMutablePointer(
                        mutating: argvBuffer.baseAddress
                    ),
                    UnsafeMutablePointer(
                        mutating: envpBuffer.baseAddress
                    )
                )
            }
        }
    }
}
#endif

// MARK: - Tiny daemon-executable containment sentinel mode

public enum SafariHandoffProcessSentinel {
    static let marker = "--safari-handoff-sentinel-v1"
    static let livenessFD: Int32 = 3
    static let readyFD: Int32 = 4
    static let readyByte: UInt8 = 0xA5
    private static let terminationGraceMicroseconds: useconds_t = 2_000_000

    // AUDIT: These closures are immutable POSIX C-API shims; no mutable state
    // crosses the sentinel boundary.
    // sendable-allowlist: foundation-sdk-shim
    struct Runtime: @unchecked Sendable {
        let pollEvents: @Sendable (
            _ descriptor: inout pollfd,
            _ timeoutMilliseconds: Int32
        ) -> Int32
        let readByte: @Sendable (
            _ descriptor: Int32,
            _ byte: UnsafeMutablePointer<UInt8>
        ) -> Int
        let signal: @Sendable (
            _ processOrGroup: pid_t,
            _ signal: Int32
        ) -> Int32
        let sleepMicroseconds: @Sendable (_ duration: useconds_t) -> Void
        let currentErrno: @Sendable () -> Int32
        let currentProcessGroup: @Sendable () -> pid_t

        static let production = Runtime(
            pollEvents: { descriptor, timeoutMilliseconds in
                poll(&descriptor, 1, timeoutMilliseconds)
            },
            readByte: { descriptor, byte in
                read(descriptor, byte, 1)
            },
            signal: { processOrGroup, signal in
                kill(processOrGroup, signal)
            },
            sleepMicroseconds: { duration in
                usleep(duration)
            },
            currentErrno: { errno },
            currentProcessGroup: { getpgrp() }
        )
    }

    public static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.first == marker else {
            return false
        }
        #if os(macOS)
        guard arguments == [marker] else {
            return true
        }
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        guard getpid() > 1,
              getpid() == getpgrp(),
              writeReady() else {
            return true
        }
        monitor()
        return true
        #else
        return true
        #endif
    }

    #if os(macOS)
    private static func writeReady(
        descriptor: Int32 = readyFD
    ) -> Bool {
        var byte = readyByte
        while true {
            let count = write(descriptor, &byte, 1)
            if count < 0, errno == EINTR {
                continue
            }
            close(descriptor)
            return count == 1
        }
    }

    static func monitor(
        livenessDescriptor: Int32 = livenessFD,
        graceMicroseconds: useconds_t = terminationGraceMicroseconds,
        runtime: Runtime = .production
    ) {
        let processGroupID = runtime.currentProcessGroup()
        guard processGroupID > 1 else { return }
        while true {
            var descriptor = pollfd(
                fd: livenessDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let result = runtime.pollEvents(&descriptor, -1)
            if result < 0, runtime.currentErrno() == EINTR {
                continue
            }
            if result > 0,
               descriptor.revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                let count = runtime.readByte(
                    livenessDescriptor,
                    &byte
                )
                if count < 0, runtime.currentErrno() == EINTR {
                    continue
                }
            }
            contain(
                processGroupID: processGroupID,
                graceMicroseconds: graceMicroseconds,
                runtime: runtime
            )
            return
        }
    }

    static func contain(
        processGroupID: pid_t,
        graceMicroseconds: useconds_t,
        runtime: Runtime
    ) {
        guard processGroupID > 1,
              processGroupID == runtime.currentProcessGroup() else {
            return
        }
        _ = runtime.signal(-processGroupID, SIGTERM)
        runtime.sleepMicroseconds(graceMicroseconds)
        _ = runtime.signal(-processGroupID, SIGKILL)
    }
    #endif
}

// MARK: - Tiny daemon-executable watchdog mode

public enum SafariHandoffProcessWatchdog {
    static let marker = "--safari-handoff-watchdog-v1"
    static let packageFD: Int32 = 3
    static let livenessFD: Int32 = 4
    static let commandFD: Int32 = 5
    static let configurationFD: Int32 = 6
    static let statusFD: Int32 = 7
    static let stdoutFD: Int32 = 8
    static let stderrFD: Int32 = 9
    static let sentinelLifetimeFD: Int32 = 10
    static let maximumEnvelopeBytes = 512 * 1024
    static let maximumStatusBytes = 16 * 1024
    private static let terminationGraceNanoseconds: UInt64 = 2_000_000_000

    // AUDIT: These closures are immutable POSIX C-API shims; process/session
    // state remains owned by the watchdog implementation.
    // sendable-allowlist: foundation-sdk-shim
    struct MonitorRuntime: @unchecked Sendable {
        let waitNoHang: @Sendable (
            _ childPID: pid_t,
            _ status: UnsafeMutablePointer<Int32>
        ) -> pid_t
        let waitBlocking: @Sendable (
            _ childPID: pid_t,
            _ status: UnsafeMutablePointer<Int32>
        ) -> pid_t
        let pollEvents: @Sendable (
            _ descriptors: inout [pollfd],
            _ timeoutMilliseconds: Int32
        ) -> Int32
        let readByte: @Sendable (
            _ descriptor: Int32,
            _ byte: UnsafeMutablePointer<UInt8>
        ) -> Int
        let signal: @Sendable (
            _ processOrGroup: pid_t,
            _ signal: Int32
        ) -> Int32
        let uptimeNanoseconds: @Sendable () -> UInt64
        let sleepMicroseconds: @Sendable (_ duration: useconds_t) -> Void
        let currentErrno: @Sendable () -> Int32
        let currentProcessGroup: @Sendable () -> pid_t
        let processMatches: @Sendable (
            _ identity: SafariHandoffProcessSupervisor.ProcessIdentity
        ) -> Bool

        static let production = MonitorRuntime(
            waitNoHang: { childPID, status in
                waitpid(childPID, status, WNOHANG)
            },
            waitBlocking: { childPID, status in
                waitpid(childPID, status, 0)
            },
            pollEvents: { descriptors, timeoutMilliseconds in
                poll(
                    &descriptors,
                    nfds_t(descriptors.count),
                    timeoutMilliseconds
                )
            },
            readByte: { descriptor, byte in
                read(descriptor, byte, 1)
            },
            signal: { processOrGroup, signal in
                kill(processOrGroup, signal)
            },
            uptimeNanoseconds: {
                DispatchTime.now().uptimeNanoseconds
            },
            sleepMicroseconds: { duration in
                usleep(duration)
            },
            currentErrno: {
                errno
            },
            currentProcessGroup: {
                getpgrp()
            },
            processMatches: { identity in
                #if os(macOS)
                SafariHandoffProcessWatchdog.processMatches(identity)
                #else
                false
                #endif
            }
        )
    }

    struct Envelope: Codable, Sendable {
        let generation: UUID
        let packageIdentity:
            SafariHandoffProcessSupervisor.FilesystemIdentity
        let containmentIdentity:
            SafariHandoffProcessSupervisor.ProcessIdentity
        let executable:
            SafariHandoffProcessSupervisor.ValidatedExecutable
        let arguments: [String]
        let environment: [String: String]
    }

    enum MessageKind: String, Codable {
        case ready
        case terminal
        case launchFailed = "launch_failed"
    }

    struct Message: Codable {
        let kind: MessageKind
        let processGroupID: Int32?
        let containmentIdentity:
            SafariHandoffProcessSupervisor.ProcessIdentity?
        let waitStatus: Int32?
        let error: String?

        init(
            kind: MessageKind,
            processGroupID: Int32?,
            containmentIdentity:
                SafariHandoffProcessSupervisor.ProcessIdentity? = nil,
            waitStatus: Int32?,
            error: String?
        ) {
            self.kind = kind
            self.processGroupID = processGroupID
            self.containmentIdentity = containmentIdentity
            self.waitStatus = waitStatus
            self.error = error
        }
    }

    /// Returns `false` only when this is a normal daemon invocation. An
    /// attempted watchdog marker is always consumed, including malformed
    /// shapes, so invalid private-mode arguments can never fall through into a
    /// second fully initialized daemon.
    public static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.first == marker else {
            return false
        }
        #if os(macOS)
        guard arguments == [marker] else {
            writeMessage(
                Message(
                    kind: .launchFailed,
                    processGroupID: nil,
                    waitStatus: nil,
                    error: "invalid_watchdog_arguments"
                )
            )
            return true
        }
        run()
        return true
        #else
        return true
        #endif
    }

    #if os(macOS)
    private static func run() {
        do {
            let data = try readEnvelope()
            let envelope = try JSONDecoder().decode(
                Envelope.self,
                from: data
            )
            try validatePackage(envelope.packageIdentity)
            let executable =
                try SafariHandoffProcessSupervisor.ExecutableValidator
                    .validate(
                        url: URL(fileURLWithPath: envelope.executable.path),
                        environment: envelope.environment
                    )
            guard executable == envelope.executable else {
                throw SafariHandoffProcessSupervisor.ExecutableTrustFailure
                    .executableChanged
            }
            guard processMatches(envelope.containmentIdentity) else {
                throw POSIXError(.ESRCH)
            }
            let processGroupID = pid_t(
                envelope.containmentIdentity.processGroupID
            )
            let childPID = try spawnTarget(
                envelope: envelope
            )
            guard isSafeProcessGroup(
                processGroupID,
                currentGroup: getpgrp()
            ) else {
                _ = kill(childPID, SIGKILL)
                var rejectedStatus: Int32 = 0
                while waitpid(childPID, &rejectedStatus, 0) < 0,
                      errno == EINTR {}
                throw POSIXError(.EPERM)
            }
            writeMessage(
                Message(
                    kind: .ready,
                    processGroupID: processGroupID,
                    containmentIdentity: envelope.containmentIdentity,
                    waitStatus: nil,
                    error: nil
                )
            )
            guard let waitStatus = monitor(
                childPID: childPID,
                containmentIdentity: envelope.containmentIdentity
            ) else {
                throw POSIXError(.EPERM)
            }
            writeMessage(
                Message(
                    kind: .terminal,
                    processGroupID: processGroupID,
                    waitStatus: waitStatus,
                    error: nil
                )
            )
        } catch {
            writeMessage(
                Message(
                    kind: .launchFailed,
                    processGroupID: nil,
                    waitStatus: nil,
                    error: "watchdog_launch_rejected"
                )
            )
        }
    }

    private static func readEnvelope() throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumEnvelopeBytes {
            let count = read(configurationFD, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        guard data.isEmpty == false,
              data.count <= maximumEnvelopeBytes else {
            throw POSIXError(.EFBIG)
        }
        return data
    }

    private static func validatePackage(
        _ expected:
            SafariHandoffProcessSupervisor.FilesystemIdentity
    ) throws {
        var info = stat()
        guard fstat(packageFD, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o700),
              UInt64(info.st_dev) == expected.device,
              UInt64(info.st_ino) == expected.inode else {
            throw POSIXError(.EPERM)
        }
    }

    private static func processIdentity(
        processID: pid_t,
        processGroupID: pid_t
    ) throws -> SafariHandoffProcessSupervisor.ProcessIdentity {
        guard processID > 1, processID == processGroupID else {
            throw POSIXError(.EPERM)
        }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(size)
            )
        }
        guard result == Int32(size),
              Int32(info.pbi_pid) == processID,
              Int32(info.pbi_pgid) == processGroupID else {
            throw POSIXError(.ESRCH)
        }
        return SafariHandoffProcessSupervisor.ProcessIdentity(
            processID: Int32(processID),
            processGroupID: Int32(processGroupID),
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    private static func processMatches(
        _ expected: SafariHandoffProcessSupervisor.ProcessIdentity
    ) -> Bool {
        guard let actual = try? processIdentity(
            processID: expected.processID,
            processGroupID: expected.processGroupID
        ) else {
            return false
        }
        return actual == expected
    }

    private static func spawnTarget(envelope: Envelope) throws -> pid_t {
        let nullDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullDescriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(nullDescriptor) }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let chdirStatus: Int32
        if #available(macOS 26.0, *) {
            chdirStatus = posix_spawn_file_actions_addfchdir(
                &actions,
                packageFD
            )
        } else {
            chdirStatus = posix_spawn_file_actions_addfchdir_np(
                &actions,
                packageFD
            )
        }
        guard chdirStatus == 0,
              posix_spawn_file_actions_adddup2(
                  &actions,
                  nullDescriptor,
                  STDIN_FILENO
              ) == 0,
              posix_spawn_file_actions_adddup2(
                  &actions,
                  stdoutFD,
                  STDOUT_FILENO
              ) == 0,
              posix_spawn_file_actions_adddup2(
                  &actions,
                  stderrFD,
                  STDERR_FILENO
              ) == 0 else {
            throw POSIXError(.EIO)
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(
                  &attributes,
                  pid_t(envelope.containmentIdentity.processGroupID)
              ) == 0 else {
            throw POSIXError(.EIO)
        }

        let arguments =
            [envelope.executable.launchPath]
            + envelope.executable.launchArguments
            + envelope.arguments
        let environment = envelope.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var pid = pid_t()
        let status = withCStrings(
            arguments: arguments,
            environment: environment
        ) { argv, envp in
            posix_spawn(
                &pid,
                envelope.executable.launchPath,
                &actions,
                &attributes,
                argv,
                envp
            )
        }
        guard status == 0, pid > 1 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: status) ?? .EIO
            )
        }
        close(stdoutFD)
        close(stderrFD)
        return pid
    }

    static func monitor(
        childPID: pid_t,
        containmentIdentity:
            SafariHandoffProcessSupervisor.ProcessIdentity,
        livenessDescriptor: Int32 = livenessFD,
        commandDescriptor: Int32 = commandFD,
        graceNanoseconds: UInt64 = terminationGraceNanoseconds,
        runtime: MonitorRuntime = .production
    ) -> Int32? {
        let processGroupID = pid_t(
            containmentIdentity.processGroupID
        )
        guard childPID > 1,
              containmentIdentity.processID
                == containmentIdentity.processGroupID,
              isSafeProcessGroup(
                  processGroupID,
                  currentGroup: runtime.currentProcessGroup()
              ),
              runtime.processMatches(containmentIdentity) else {
            return nil
        }
        var status: Int32 = 0
        var terminationRequested = false
        var killDeadline: UInt64?
        while true {
            let result = runtime.waitNoHang(childPID, &status)
            if result == childPID {
                guard terminateRemainingGroup(
                    containmentIdentity,
                    excludingReapedChild: true,
                    runtime: runtime
                ) else {
                    return nil
                }
                return status
            }
            if result < 0, runtime.currentErrno() != EINTR {
                guard terminateRemainingGroup(
                    containmentIdentity,
                    excludingReapedChild: false,
                    runtime: runtime
                ) else {
                    return nil
                }
                return waitForChild(
                    childPID,
                    runtime: runtime
                )
            }

            var descriptors = [
                pollfd(
                    fd: livenessDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                ),
                pollfd(
                    fd: commandDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
            ]
            let pollResult = runtime.pollEvents(&descriptors, 50)
            if pollResult < 0 {
                if runtime.currentErrno() == EINTR { continue }
                guard terminateRemainingGroup(
                    containmentIdentity,
                    excludingReapedChild: false,
                    runtime: runtime
                ) else {
                    return nil
                }
                return waitForChild(
                    childPID,
                    runtime: runtime
                )
            }
            if terminationRequested == false {
                let livenessClosed =
                    descriptors[0].revents & Int16(POLLHUP | POLLERR) != 0
                let commandReady =
                    descriptors[1].revents & Int16(
                        POLLIN | POLLHUP | POLLERR
                    ) != 0
                if livenessClosed || commandReady {
                    if commandReady {
                        var byte: UInt8 = 0
                        _ = runtime.readByte(commandDescriptor, &byte)
                    }
                    terminationRequested = true
                    guard runtime.processMatches(containmentIdentity) else {
                        return nil
                    }
                    _ = runtime.signal(-processGroupID, SIGTERM)
                    killDeadline =
                        runtime.uptimeNanoseconds()
                        &+ graceNanoseconds
                }
            }
            if let killDeadline,
               runtime.uptimeNanoseconds() >= killDeadline {
                guard runtime.processMatches(containmentIdentity) else {
                    return nil
                }
                _ = runtime.signal(-processGroupID, SIGKILL)
                return waitForChild(
                    childPID,
                    runtime: runtime
                )
            }
        }
    }

    static func isSafeProcessGroup(
        _ processGroupID: pid_t,
        currentGroup: pid_t
    ) -> Bool {
        processGroupID > 1 && processGroupID != currentGroup
    }

    private static func waitForChild(
        _ childPID: pid_t,
        runtime: MonitorRuntime
    ) -> Int32? {
        var finalStatus: Int32 = 0
        while true {
            let waited = runtime.waitBlocking(childPID, &finalStatus)
            if waited == childPID { return finalStatus }
            if waited < 0, runtime.currentErrno() == EINTR { continue }
            return nil
        }
    }

    static func terminateRemainingGroup(
        _ containmentIdentity:
            SafariHandoffProcessSupervisor.ProcessIdentity,
        excludingReapedChild: Bool,
        runtime: MonitorRuntime = .production
    ) -> Bool {
        let processGroupID = pid_t(
            containmentIdentity.processGroupID
        )
        guard isSafeProcessGroup(
            processGroupID,
            currentGroup: runtime.currentProcessGroup()
        ),
        containmentIdentity.processID
            == containmentIdentity.processGroupID,
        runtime.processMatches(containmentIdentity) else {
            return false
        }
        _ = runtime.signal(-processGroupID, SIGTERM)
        if excludingReapedChild {
            runtime.sleepMicroseconds(100_000)
        }
        guard runtime.processMatches(containmentIdentity) else {
            return false
        }
        _ = runtime.signal(-processGroupID, SIGKILL)
        return true
    }

    private static func writeMessage(_ message: Message) {
        guard var data = try? JSONEncoder().encode(message),
              data.count < maximumStatusBytes else {
            return
        }
        data.append(0x0A)
        try? writeAll(data, to: statusFD)
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw POSIXError(
                        POSIXErrorCode(rawValue: errno) ?? .EIO
                    )
                }
                offset += count
            }
        }
    }

    private static func withCStrings<T>(
        arguments: [String],
        environment: [String],
        body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        ) -> T
    ) -> T {
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            for case let pointer? in argv {
                free(pointer)
            }
            for case let pointer? in envp {
                free(pointer)
            }
        }
        return argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                body(
                    UnsafeMutablePointer(
                        mutating: argvBuffer.baseAddress
                    ),
                    UnsafeMutablePointer(
                        mutating: envpBuffer.baseAddress
                    )
                )
            }
        }
    }
    #endif
}

#if os(macOS)
private enum SafariHandoffReceiptKeyStore {
    private static let service =
        "com.openburnbar.daemon.safari-handoff-receipt"
    private static let account = "device-hmac-sha256-v1"
    private static let keySize = 32

    enum KeyStoreError: Error {
        case unavailable
        case invalidKey
    }

    static func loadExisting() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String:
                nonInteractiveKeychainAuthenticationContext()
        ]
        var item: CFTypeRef?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.unavailable
        }
        guard let key = item as? Data, key.count == keySize else {
            throw KeyStoreError.invalidKey
        }
        return key
    }

    static func loadOrCreate() throws -> Data {
        do {
            return try loadExisting()
        } catch KeyStoreError.invalidKey {
            throw KeyStoreError.invalidKey
        } catch {
            let key = try PlatformCrypto.secureRandomBytes(count: keySize)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: key,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let addStatus = withKeychainUserInteractionDisabled {
                SecItemAdd(query as CFDictionary, nil)
            }
            if addStatus == errSecSuccess {
                return try requireReadback(key)
            }
            if addStatus == errSecDuplicateItem {
                return try loadExisting()
            }
            throw KeyStoreError.unavailable
        }
    }

    private static func requireReadback(_ expected: Data) throws -> Data {
        let stored = try loadExisting()
        guard constantTimeEqual(stored, expected) else {
            throw KeyStoreError.invalidKey
        }
        return stored
    }

    private static func constantTimeEqual(
        _ lhs: Data,
        _ rhs: Data
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
#endif

private func fsyncRetrying(_ descriptor: Int32) -> Int32 {
    while true {
        let result = fsync(descriptor)
        if result < 0, errno == EINTR { continue }
        return result
    }
}
