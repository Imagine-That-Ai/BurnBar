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
/// process group to a tiny watchdog subprocess. Closing the daemon's private
/// liveness pipe is therefore sufficient to terminate the CLI and descendants
/// after a daemon crash.
public actor SafariHandoffProcessSupervisor:
    SafariHandoffProcessSupervising
{
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

    private struct CompletionReceipt: Codable, Equatable {
        static let schemaVersion = 3

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

    struct WatchdogReady: Sendable, Equatable {
        let watchdogPID: Int32
        let processGroupID: Int32
    }

    protocol WatchdogSession: AnyObject, Sendable {
        func start() throws -> WatchdogReady
        func requestTermination()
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
        let synchronize: @Sendable (
            _ descriptor: Int32,
            _ point: SynchronizationPoint
        ) -> Bool

        init(
            environment: @escaping @Sendable () -> [String: String],
            sleep: @escaping @Sendable (UInt64) async -> Void = {
                nanoseconds in
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

    private enum LivePhase {
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
        var requestedTermination: TerminationReason?
    }

    private static let outputLimitBytes = 1 * 1024 * 1024
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
                await self?.requestTermination(
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

        let observation: Observation
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
            observation = observation(
                from: receipt,
                packageDirectory: packageDirectory,
                observedAt: observedAt
            )
            packageIdentities[runID] = expectedPackageIdentity
        } catch {
            observation = interruptedObservation(
                runID: runID,
                targetHarness: targetHarness,
                packageDirectory: packageDirectory,
                launchedAt: launchedAt,
                observedAt: observedAt,
                failure: Self.failureForReceiptError(error)
            )
            packageIdentities[runID] = expectedPackageIdentity
        }
        observations[runID] = observation
        return observation
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
        liveRecords[runID] = record
        if shouldRequestTermination {
            record.session?.requestTermination()
        }
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

        let receipt = CompletionReceipt(
            schemaVersion: CompletionReceipt.schemaVersion,
            runID: runID.rawValue,
            targetHarness: record.specification.targetHarness,
            packageIdentity: record.specification.expectedPackageIdentity,
            launchedAt: record.launchedAt,
            completedAt: completedAt,
            terminationReason: terminationReason,
            exitStatus: native.exitStatus,
            stdoutBytes: stdout.data.count,
            stderrBytes: stderr.data.count,
            stdoutObservedBytes: stdout.observedBytes,
            stderrObservedBytes: stderr.observedBytes,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated
        )
        do {
            try writeAtomicReceipt(receipt, package: record.package)
            _ = try validatedReceipt(
                runID: runID,
                targetHarness: record.specification.targetHarness,
                package: record.package,
                launchedAt: record.launchedAt,
                observedAt: completedAt
            )
        } catch {
            if failure == nil {
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
        var published = false
        defer {
            close(descriptor)
            if published == false {
                _ = unlinkat(package.packageDescriptor, temporaryName, 0)
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
        guard unlinkat(
            package.packageDescriptor,
            temporaryName,
            0
        ) == 0 else {
            _ = unlinkat(
                package.packageDescriptor,
                Self.receiptFileName,
                0
            )
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        published = true
        guard dependencies.synchronize(
            package.packageDescriptor,
            .packageDirectory
        ) else {
            throw POSIXError(.EIO)
        }
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
              Self.validReceiptTermination(receipt) else {
            throw ReceiptValidationError.invalid
        }
        try validatePersistedOutput(
            name: Self.stdoutFileName,
            expectedSize: receipt.stdoutBytes,
            package: package
        )
        try validatePersistedOutput(
            name: Self.stderrFileName,
            expectedSize: receipt.stderrBytes,
            package: package
        )
        return receipt
    }

    private func validatePersistedOutput(
        name: String,
        expectedSize: Int,
        package: PackageHandle
    ) throws {
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

    private func childEnvironment(
        ambient: [String: String],
        packageURL: URL,
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
        let deterministicPath = try ExecutableValidator.deterministicPath(
            executableURL: executableURL,
            environment: ambient
        )
        environment["PATH"] = deterministicPath
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

private enum SafariHandoffExecutableValidationError: Error {
    case unsafe
}

extension SafariHandoffProcessSupervisor {
    enum ExecutableValidator {
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
                try validateParentDirectories(of: path + "/placeholder")
                return path
            }
            guard trusted.isEmpty == false else {
                throw SafariHandoffExecutableValidationError.unsafe
            }
            return trusted.joined(separator: ":")
        }

        private static func validate(
            url: URL,
            environment: [String: String],
            depth: Int
        ) throws -> ValidatedExecutable {
            guard depth <= 4,
                  url.isFileURL,
                  url.path.hasPrefix("/"),
                  url.path.contains("\0") == false else {
                throw SafariHandoffExecutableValidationError.unsafe
            }
            if depth == 0 {
                var supplied = stat()
                guard lstat(url.path, &supplied) == 0,
                      supplied.st_mode & mode_t(S_IFMT)
                        == mode_t(S_IFREG) else {
                    throw SafariHandoffExecutableValidationError.unsafe
                }
            }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            try validateParentDirectories(of: canonical.path)
            let descriptor = open(
                canonical.path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                throw SafariHandoffExecutableValidationError.unsafe
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == geteuid() || info.st_uid == 0,
                  info.st_mode & mode_t(0o022) == 0,
                  info.st_mode & mode_t(0o111) != 0,
                  info.st_nlink == 1 else {
                throw SafariHandoffExecutableValidationError.unsafe
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
                throw SafariHandoffExecutableValidationError.unsafe
            }
            var current = stat()
            guard lstat(canonical.path, &current) == 0,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  UInt64(current.st_dev) == UInt64(info.st_dev),
                  UInt64(current.st_ino) == UInt64(info.st_ino),
                  current.st_size == info.st_size else {
                throw SafariHandoffExecutableValidationError.unsafe
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
                    throw SafariHandoffExecutableValidationError.unsafe
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
                throw SafariHandoffExecutableValidationError.unsafe
            }
            let fields = line.dropFirst(2).split(whereSeparator: {
                $0 == " " || $0 == "\t"
            })
            guard let first = fields.first else {
                throw SafariHandoffExecutableValidationError.unsafe
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
                    throw SafariHandoffExecutableValidationError.unsafe
                }
                let command = String(fields[1])
                guard command.contains("/") == false,
                      let resolved = resolve(
                          command: command,
                          path: environment["PATH"] ?? ""
                      ) else {
                    throw SafariHandoffExecutableValidationError.unsafe
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
                throw SafariHandoffExecutableValidationError.unsafe
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
                throw SafariHandoffExecutableValidationError.unsafe
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
                throw SafariHandoffExecutableValidationError.unsafe
            }
            #else
            _ = url
            #endif
        }
    }
}

// MARK: - Production watchdog session

#if os(macOS)
private final class POSIXWatchdogSession:
    SafariHandoffProcessSupervisor.WatchdogSession,
    @unchecked Sendable
{
    private typealias Supervisor = SafariHandoffProcessSupervisor

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
    private var statusBuffer = Data()
    private var terminalDelivered = false
    private var ready: Supervisor.WatchdogReady?
    private var watchdogPID: pid_t = -1

    init(context: Supervisor.SessionLaunchContext) throws {
        self.context = context
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        finishDraining()
        closeLiveness()
    }

    func start() throws -> Supervisor.WatchdogReady {
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

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog launch actions could not be initialized."
            )
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let mappings: [(Int32, Int32)] = [
            (nullDescriptor, STDIN_FILENO),
            (nullDescriptor, STDOUT_FILENO),
            (nullDescriptor, STDERR_FILENO),
            (context.packageDescriptor, SafariHandoffProcessWatchdog.packageFD),
            (liveness.read, SafariHandoffProcessWatchdog.livenessFD),
            (command.read, SafariHandoffProcessWatchdog.commandFD),
            (configuration.read, SafariHandoffProcessWatchdog.configurationFD),
            (status.write, SafariHandoffProcessWatchdog.statusFD),
            (stdout.write, SafariHandoffProcessWatchdog.stdoutFD),
            (stderr.write, SafariHandoffProcessWatchdog.stderrFD)
        ]
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

        guard let watchdogPath =
                DaemonSelfCodeSignatureVerifier.defaultExecutablePath(),
              watchdogPath.hasPrefix("/") else {
            throw Supervisor.SupervisorError.watchdogLaunchFailed(
                "The watchdog executable path is unavailable."
            )
        }
        let arguments = [
            watchdogPath,
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
                watchdogPath,
                &actions,
                &attributes,
                argv,
                envp
            )
        }
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
                  processGroupID > 1 else {
                closeLiveness()
                throw Supervisor.SupervisorError.watchdogLaunchFailed(
                    "The watchdog returned an invalid process group."
                )
            }
            let result = Supervisor.WatchdogReady(
                watchdogPID: Int32(pid),
                processGroupID: processGroupID
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

    func requestTermination() {
        lock.lock()
        let descriptor = commandWrite
        lock.unlock()
        guard descriptor >= 0 else { return }
        var byte: UInt8 = 1
        while write(descriptor, &byte, 1) < 0, errno == EINTR {}
    }

    func forceContainment() {
        lock.lock()
        let watchdogPID = watchdogPID
        let processGroupID = ready?.processGroupID ?? -1
        lock.unlock()
        guard watchdogPID > 1,
              processGroupID > 1,
              Self.isOwnedChildStillRunning(watchdogPID) else {
            return
        }
        _ = kill(-processGroupID, SIGTERM)
        // This path is used only after the watchdog's private status channel
        // failed. Do not retain a numeric process-group identifier in a
        // delayed closure: the original group could exit and the identifier
        // could be reused before the closure runs. Immediate fail-closed
        // containment keeps the signal bound to the still-current failure
        // observation.
        _ = kill(-processGroupID, SIGKILL)
    }

    func closeLiveness() {
        lock.lock()
        let descriptor = livenessWrite
        livenessWrite = -1
        lock.unlock()
        if descriptor >= 0 { close(descriptor) }
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
        descriptors.filter { $0 >= 0 }.forEach(close)
        reapWatchdog()
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
            statusBuffer.append(buffer, count: count)
            while let newline = statusBuffer.firstIndex(of: 0x0A) {
                let line = statusBuffer.prefix(upTo: newline)
                statusBuffer.removeSubrange(...newline)
                guard let message = try? JSONDecoder().decode(
                    SafariHandoffProcessWatchdog.Message.self,
                    from: line
                ) else {
                    deliverFailure("The watchdog emitted malformed status.")
                    return
                }
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
                        message.error ?? "The watchdog failed after launch."
                    )
                case .ready:
                    break
                }
            }
        } else if count == 0 {
            deliverFailure("The watchdog status channel closed unexpectedly.")
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
        throws -> SafariHandoffProcessWatchdog.Message
    {
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
            descriptors.forEach(close)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
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

    private static func isOwnedChildStillRunning(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var info = siginfo_t()
        while true {
            let result = waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0 {
                return info.si_pid == 0
            }
            if errno == EINTR {
                continue
            }
            return false
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
            argv.compactMap { $0 }.forEach(free)
            envp.compactMap { $0 }.forEach(free)
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
    static let maximumEnvelopeBytes = 512 * 1024
    static let maximumStatusBytes = 16 * 1024
    private static let terminationGraceNanoseconds: UInt64 = 2_000_000_000

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
            }
        )
    }

    struct Envelope: Codable, Sendable {
        let generation: UUID
        let packageIdentity:
            SafariHandoffProcessSupervisor.FilesystemIdentity
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
        let waitStatus: Int32?
        let error: String?
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
                throw SafariHandoffExecutableValidationError.unsafe
            }
            let processGroupID = try spawnTarget(
                envelope: envelope
            )
            guard isSafeProcessGroup(
                processGroupID,
                currentGroup: getpgrp()
            ) else {
                _ = kill(processGroupID, SIGKILL)
                var rejectedStatus: Int32 = 0
                while waitpid(processGroupID, &rejectedStatus, 0) < 0,
                      errno == EINTR {}
                throw POSIXError(.EPERM)
            }
            writeMessage(
                Message(
                    kind: .ready,
                    processGroupID: processGroupID,
                    waitStatus: nil,
                    error: nil
                )
            )
            guard let waitStatus = monitor(
                childPID: processGroupID,
                processGroupID: processGroupID
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
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
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
        processGroupID: pid_t,
        livenessDescriptor: Int32 = livenessFD,
        commandDescriptor: Int32 = commandFD,
        graceNanoseconds: UInt64 = terminationGraceNanoseconds,
        runtime: MonitorRuntime = .production
    ) -> Int32? {
        guard childPID > 1,
              childPID == processGroupID,
              isSafeProcessGroup(
                  processGroupID,
                  currentGroup: runtime.currentProcessGroup()
              ) else {
            return nil
        }
        var status: Int32 = 0
        var terminationRequested = false
        var killDeadline: UInt64?
        while true {
            let result = runtime.waitNoHang(childPID, &status)
            if result == childPID {
                terminateRemainingGroup(
                    processGroupID,
                    excludingReapedChild: true,
                    runtime: runtime
                )
                return status
            }
            if result < 0, runtime.currentErrno() != EINTR {
                terminateRemainingGroup(
                    processGroupID,
                    excludingReapedChild: false,
                    runtime: runtime
                )
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
                terminateRemainingGroup(
                    processGroupID,
                    excludingReapedChild: false,
                    runtime: runtime
                )
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
                    _ = runtime.signal(-processGroupID, SIGTERM)
                    killDeadline =
                        runtime.uptimeNanoseconds()
                        &+ graceNanoseconds
                }
            }
            if let killDeadline,
               runtime.uptimeNanoseconds() >= killDeadline {
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
        _ processGroupID: pid_t,
        excludingReapedChild: Bool,
        runtime: MonitorRuntime = .production
    ) {
        guard isSafeProcessGroup(
            processGroupID,
            currentGroup: runtime.currentProcessGroup()
        ) else {
            return
        }
        _ = runtime.signal(-processGroupID, SIGTERM)
        if excludingReapedChild {
            runtime.sleepMicroseconds(100_000)
        }
        _ = runtime.signal(-processGroupID, SIGKILL)
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
            argv.compactMap { $0 }.forEach(free)
            envp.compactMap { $0 }.forEach(free)
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

private func fsyncRetrying(_ descriptor: Int32) -> Int32 {
    while true {
        let result = fsync(descriptor)
        if result < 0, errno == EINTR { continue }
        return result
    }
}
