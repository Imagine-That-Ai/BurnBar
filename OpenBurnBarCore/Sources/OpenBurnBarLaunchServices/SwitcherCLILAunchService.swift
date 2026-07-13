import Foundation
import OpenBurnBarKernel

// MARK: - CLI Launch Service (coordinator / invoker / store-coupled half)
//
// The Foundation-pure resolution + allowlisted-environment surface of this stack —
// `CLILaunchAdapter` and its `CLILaunchError` — was extracted DOWN into the
// cross-platform Kernel by core-decomposition P-15b
// (`OpenBurnBarKernel/Platform/CLILaunchAdapter.swift`) so the daemon (P-18) and the
// Quota adapters (P-13) can resolve executables + build launch environments without
// linking this Apple-only, AppKit-adjacent target. What remains here is the
// launch-coordinator / process-invoker / profile-store-coupled orchestration
// (`CLILaunchCoordinator`, `CLILaunchInvoker`, `SwitcherCLILAunchService`,
// `CLIFallback*`, `CLILaunchOutcome`, `CLILaunchRedactor`); it reaches `CLILaunchAdapter`
// and `CLILaunchError` through this target's declared `OpenBurnBarKernel` dependency.
#if os(macOS)

// MARK: - Concurrent Launch Serialization

/// A serial coordinator that ensures CLI launches are serialized,
/// preventing duplicate committed launches under concurrent requests.
/// Uses an actor to provide thread-safe serialization.
public actor CLILaunchCoordinator {
    private var pendingLaunches: Set<String> = []
    private var lastLaunchedProfileID: String?
    private var lastAttemptedProfileID: String?
    private var launchSequence: Int = 0

    public init() {}

    /// Records that a launch is about to occur for a profile.
    /// Returns the sequence number if the launch should proceed, nil if a launch
    /// for this profile is already in progress.
    public func beginLaunch(profileID: String) -> Int? {
        if pendingLaunches.contains(profileID) {
            return nil
        }
        pendingLaunches.insert(profileID)
        launchSequence += 1
        // Track the profile ID on every attempt (not just success) for test verification
        lastAttemptedProfileID = profileID
        return launchSequence
    }

    /// Records that a launch has completed for a profile.
    public func endLaunch(profileID: String, success: Bool) {
        pendingLaunches.remove(profileID)
        if success {
            lastLaunchedProfileID = profileID
        }
    }

    /// Returns the last successfully launched profile ID.
    public func getLastLaunchedProfileID() -> String? {
        return lastLaunchedProfileID
    }

    /// Returns the last attempted profile ID, regardless of success or failure.
    /// This is used for test verification to prove the correct profile was routed.
    public func getLastAttemptedProfileID() -> String? {
        return lastAttemptedProfileID
    }

    /// Returns true if there's a launch in progress for the given profile.
    public func isLaunchInProgress(profileID: String) -> Bool {
        return pendingLaunches.contains(profileID)
    }

    /// Clears all pending launches. Use for error recovery.
    public func clearPendingLaunches() {
        pendingLaunches.removeAll()
    }
}

// MARK: - Launch Invocation

/// Actually performs the CLI launch using Foundation Process.
/// Isolated to prevent direct invocation outside of the coordinator.
public struct CLILaunchInvoker {
    // nonisolated(unsafe): test-only injection seam, set during single-threaded test setup; reads are effectively immutable in production.
    /// Injectable launch handler for deterministic testing.
    /// When set, replaces the real Process-based launch with the provided handler.
    /// Receives the launch parameters and returns a Result.
    public nonisolated(unsafe) static var launchHandler: ((SwitcherCLIProfileType, URL, [String], [String: String], String?, (@Sendable (String) -> Void)?) async -> Result<Void, CLILaunchError>)?
    public static let defaultStartupObservationTimeout: TimeInterval = 0.35
    // nonisolated(unsafe): test-only tunable, set during single-threaded test setup; effectively a constant in production.
    nonisolated(unsafe) static var startupObservationTimeout: TimeInterval = defaultStartupObservationTimeout

    /// Launches a CLI process with the given configuration.
    /// Returns after the startup observation window passes or a startup failure is detected.
    ///
    /// Testability: If `launchHandler` is set, it is called instead of spawning
    /// a real process, allowing tests to simulate launch outcomes deterministically.
    public static func launchCLI(
        cliType: SwitcherCLIProfileType,
        executable: URL,
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil,
        postLaunchQuotaObserver: (@Sendable (String) -> Void)? = nil
    ) async -> Result<Void, CLILaunchError> {
        // Use injected handler if available (for deterministic testing)
        if let handler = launchHandler {
            return await handler(cliType, executable, args, env, workingDirectory, postLaunchQuotaObserver)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args

        // Set environment - build from allowlisted baseline only, then merge profile-specific keys.
        // Security: We do NOT start with ProcessInfo.processInfo.environment (full ambient env).
        // This prevents sensitive ambient variables (API keys, tokens, etc.) from leaking to CLI.
        var finalEnv = CLILaunchAdapter.buildAllowlistedBaselineEnvironment()
        for (key, value) in env {
            finalEnv[key] = value
        }
        process.environment = finalEnv

        // Set working directory if specified
        if let wd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let quotaRecorder = QuotaSignalRecorder()
        let supervisor = CLITerminalSessionSupervisor(cliType: cliType) { event in
            guard case .quotaExhausted(let detail, _) = event else { return }
            quotaRecorder.record(detail)
            if process.isRunning {
                process.terminate()
            }
        }
        let observationQueue = DispatchQueue(label: "com.openburnbar.clilaunchinvoker.observation")
        let stdoutObserver = supervisor.attach(
            to: stdoutPipe,
            source: .stdout,
            queue: observationQueue
        )
        let stderrObserver = supervisor.attach(
            to: stderrPipe,
            source: .stderr,
            queue: observationQueue
        )

        let cleanup = LaunchObservationCleanup {
            stdoutObserver.cancel()
            stderrObserver.cancel()
        }

        func finish(_ result: Result<Void, CLILaunchError>) -> Result<Void, CLILaunchError> {
            cleanup.perform()
            return result
        }

        do {
            try process.run()
        } catch {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            let detail = stderrStr.isEmpty ? error.localizedDescription : "\(error.localizedDescription): \(stderrStr)"
            return finish(.failure(.launchSpawnFailed(CLILaunchRedactor.redactSensitiveData(detail))))
        }

        func classifyObservedOutput() -> String? {
            let combinedOutput = supervisor.snapshot()
            return quotaRecorder.snapshot()
                ?? CLIQuotaExhaustionClassifier.classify(for: cliType, in: combinedOutput)
        }

        /// Gives dispatch observers a brief window to deliver fast-failing stderr before classification.
        func settleStartupOutput(maxAttempts: Int = 40) async -> String? {
            for attempt in 0..<maxAttempts {
                if let detail = classifyObservedOutput() {
                    return detail
                }
                if attempt + 1 == maxAttempts {
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return classifyObservedOutput()
        }

        func finishAfterProcessExit() async -> Result<Void, CLILaunchError> {
            process.waitUntilExit()
            if let detail = await settleStartupOutput() {
                return finish(.failure(.quotaExhausted(CLILaunchRedactor.redactSensitiveData(detail))))
            }
            if process.terminationStatus == 0 {
                return finish(.success(()))
            }

            let trimmedOutput = supervisor.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmedOutput.isEmpty
                ? (process.terminationStatus == 127
                    ? "\(cliType.displayName) command not found in app PATH (exit 127). Install \(cliType.displayName) or ensure its runtime dependencies are available."
                    : "\(cliType.displayName) exited during startup with status \(process.terminationStatus).")
                : trimmedOutput
            return finish(.failure(.launchFailed(CLILaunchRedactor.redactSensitiveData(detail))))
        }

        let deadline = Date().addingTimeInterval(startupObservationTimeout)
        while true {
            if let detail = quotaRecorder.snapshot() {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                return finish(.failure(.quotaExhausted(CLILaunchRedactor.redactSensitiveData(detail))))
            }

            if !process.isRunning {
                return await finishAfterProcessExit()
            }

            if Date() >= deadline {
                if !process.isRunning {
                    return await finishAfterProcessExit()
                }

                Task.detached(priority: .utility) {
                    while true {
                        if let detail = quotaRecorder.snapshot() {
                            if process.isRunning {
                                process.terminate()
                                process.waitUntilExit()
                            }
                            cleanup.perform()
                            postLaunchQuotaObserver?(CLILaunchRedactor.redactSensitiveData(detail))
                            return
                        }

                        if !process.isRunning {
                            if let detail = await settleStartupOutput() {
                                postLaunchQuotaObserver?(CLILaunchRedactor.redactSensitiveData(detail))
                            }
                            cleanup.perform()
                            return
                        }

                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                return .success(())
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func classifyQuotaExhaustion(for cliType: SwitcherCLIProfileType, in output: String) -> String? {
        CLIQuotaExhaustionClassifier.classify(for: cliType, in: output)
    }
}

private final class QuotaSignalRecorder: Sendable {
    private let state = Locked<String?>(nil)

    func record(_ detail: String) {
        state.withLock { current in
            if current == nil { current = detail }
        }
    }

    func snapshot() -> String? {
        state.read()
    }
}

private final class LaunchObservationCleanup: Sendable {
    private let didCleanup = Locked(false)
    private let action: @Sendable () -> Void

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func perform() {
        let shouldRun = didCleanup.withLock { flag -> Bool in
            guard !flag else { return false }
            flag = true
            return true
        }

        guard shouldRun else { return }
        action()
    }
}

// MARK: - CLI Fallback Planning

public enum CLIFallbackEligibility: Equatable, Sendable {
    case eligible
    case quotaExhausted(reason: String)
    case ineligible(reason: String)
}

public protocol CLIFallbackPlanning: Sendable {
    func orderedCandidates(
        for requestedProfile: SwitcherProfileRecord,
        allProfiles: [SwitcherProfileRecord]
    ) async -> [SwitcherProfileRecord]

    func eligibility(for profile: SwitcherProfileRecord) async -> CLIFallbackEligibility
}

public struct DefaultCLIFallbackPlanner: CLIFallbackPlanning {
    public init() {}

    public func orderedCandidates(
        for requestedProfile: SwitcherProfileRecord,
        allProfiles: [SwitcherProfileRecord]
    ) async -> [SwitcherProfileRecord] {
        [requestedProfile]
    }

    public func eligibility(for profile: SwitcherProfileRecord) async -> CLIFallbackEligibility {
        .eligible
    }
}

public enum CLILaunchServiceEvent: Equatable, Sendable {
    case postLaunchFallbackSucceeded(
        exhaustedProfileID: String,
        recoveredProfileID: String,
        detail: String,
        attemptedProfileIDs: [String]
    )
    case postLaunchFallbackFailed(
        exhaustedProfileID: String,
        detail: String,
        attemptedProfileIDs: [String]
    )
}

// MARK: - Switcher CLI Launch Service

/// High-level service for CLI launch orchestration.
/// Combines profile resolution, launch validation, concurrency handling, and error typing.
///
/// Security invariants:
/// - Uses only trusted executable paths
/// - Uses only allowlisted environment variables
/// - No shell interpolation in argument construction
/// - Typed errors for all failure modes
/// - Serialized launches via coordinator
public final class SwitcherCLILAunchService: Sendable {
    private let profileStore: SwitcherProfileStoreAdapter
    private let coordinator: CLILaunchCoordinator
    private let fallbackPlanner: any CLIFallbackPlanning
    private let eventHandler: (@MainActor @Sendable (CLILaunchServiceEvent) -> Void)?

    /// Creates a new CLI launch service.
    public init(
        profileStore: SwitcherProfileStoreAdapter,
        fallbackPlanner: any CLIFallbackPlanning = DefaultCLIFallbackPlanner(),
        eventHandler: (@MainActor @Sendable (CLILaunchServiceEvent) -> Void)? = nil
    ) {
        self.profileStore = profileStore
        self.coordinator = CLILaunchCoordinator()
        self.fallbackPlanner = fallbackPlanner
        self.eventHandler = eventHandler
    }

    // MARK: - Launch Methods

    /// Launches the CLI for the given profile.
    /// Returns immediately if a launch is already in progress for this profile.
    public func launchCLI(for profileID: String) async -> CLILaunchOutcome {
        guard let profile = profileStore.fetchProfile(id: profileID) else {
            return CLILaunchOutcome(
                success: false,
                error: .profileNotFound(profileID)
            )
        }

        guard profile.targetKind == .cli else {
            return CLILaunchOutcome(
                success: false,
                error: .profileKindMismatch(expected: .cli, actual: profile.targetKind)
            )
        }

        guard profile.cliType != nil else {
            return CLILaunchOutcome(
                success: false,
                error: .missingProfileMetadata(profileID)
            )
        }

        let allProfiles = profileStore.fetchAllProfiles()
        let plannerCandidates = await fallbackPlanner.orderedCandidates(
            for: profile,
            allProfiles: allProfiles
        )
        let candidates = prioritizedCandidates(
            requestedProfile: profile,
            plannerCandidates: plannerCandidates
        )

        return await launchCandidates(
            requestedProfile: profile,
            candidates: candidates,
            attemptedProfileIDs: []
        )
    }

    /// Launches a specific CLI type (Codex/Claude/OpenCode) using a profile.
    public func launchCLI(
        cliType: SwitcherCLIProfileType,
        profileID: String
    ) async -> CLILaunchOutcome {
        guard let profile = profileStore.fetchProfile(id: profileID) else {
            return CLILaunchOutcome(
                success: false,
                error: .profileNotFound(profileID)
            )
        }

        // Validate profile matches expected CLI type
        let validationResult = CLILaunchAdapter.validateProfileCLITypeMatch(
            profile: profile,
            targetCLI: cliType
        )

        switch validationResult {
        case .failure(let error):
            return CLILaunchOutcome(success: false, error: error)
        case .success:
            return await launchCLI(for: profileID)
        }
    }

    /// Launches the CLI for the current active profile.
    /// This method reads the active profile ID from the store and launches it
    /// without requiring an explicit profile ID override.
    ///
    /// This is the key method for active-state routing - it proves that
    /// the launch adapter consumes the final committed global active profile.
    ///
    /// Returns `.noActiveProfile` if no profile is currently active.
    public func launchUsingActiveProfile() async -> CLILaunchOutcome {
        // Fetch the active profile ID from global state
        guard let activeProfileID = profileStore.fetchActiveProfileID() else {
            return CLILaunchOutcome(
                success: false,
                error: .noActiveProfile
            )
        }

        // Launch using the active profile ID
        return await launchCLI(for: activeProfileID)
    }

    /// Launches the CLI using the per-provider drain target — the account the
    /// user has chosen to burn quota from for `providerID`. Returns
    /// `.noActiveProfile` if no drain target is set for that provider.
    ///
    /// This is the per-provider counterpart to `launchUsingActiveProfile()`:
    /// switching the Claude drain target never disturbs the Codex one.
    public func launchUsingDrainTarget(for providerID: ProviderID) async -> CLILaunchOutcome {
        guard let drainProfileID = profileStore.fetchActiveProfileID(for: providerID) else {
            return CLILaunchOutcome(
                success: false,
                error: .noActiveProfile
            )
        }

        return await launchCLI(for: drainProfileID)
    }

    // MARK: - Availability Checking

    /// Checks if a CLI executable is available.
    public func isCLIAvailable(_ cliType: SwitcherCLIProfileType) -> Bool {
        return CLILaunchAdapter.isExecutableAvailable(cliType)
    }

    /// Returns the resolved executable path for a CLI type.
    public func executablePath(for cliType: SwitcherCLIProfileType) -> String? {
        return CLILaunchAdapter.executablePath(for: cliType)
    }

    /// Returns the last attempted profile ID from the coordinator, for test verification.
    /// This allows tests to verify that the correct profile ID was routed through
    /// the launch service, not just that an error occurred.
    public func getLastAttemptedProfileID() async -> String? {
        return await coordinator.getLastAttemptedProfileID()
    }

    private func prioritizedCandidates(
        requestedProfile: SwitcherProfileRecord,
        plannerCandidates: [SwitcherProfileRecord]
    ) -> [SwitcherProfileRecord] {
        var seen = Set<String>()
        var ordered: [SwitcherProfileRecord] = []

        let requestedAndPlanned = [requestedProfile] + plannerCandidates
        for candidate in requestedAndPlanned where seen.insert(candidate.id).inserted {
            ordered.append(candidate)
        }

        return ordered
    }

    private func launchCandidates(
        requestedProfile: SwitcherProfileRecord,
        candidates: [SwitcherProfileRecord],
        attemptedProfileIDs initialAttemptedProfileIDs: [String]
    ) async -> CLILaunchOutcome {
        var attemptedProfileIDs = initialAttemptedProfileIDs
        var lastError: CLILaunchError?

        for (index, candidate) in candidates.enumerated() {
            attemptedProfileIDs.append(candidate.id)
            let eligibility = await fallbackPlanner.eligibility(for: candidate)
            switch eligibility {
            case .eligible:
                break
            case .quotaExhausted(let reason):
                lastError = .quotaExhausted(reason)
                continue
            case .ineligible(let reason):
                lastError = .launchFailed(reason)
                if candidate.id == requestedProfile.id && index == 0 {
                    return CLILaunchOutcome(
                        success: false,
                        error: lastError,
                        launchedProfileID: nil,
                        attemptedProfileIDs: attemptedProfileIDs
                    )
                }
                continue
            }

            let attemptedSnapshot = attemptedProfileIDs
            let remainingCandidates = index + 1 < candidates.count
                ? Array(candidates[(index + 1)...])
                : []

            let outcome = await attemptLaunch(
                profile: candidate,
                postLaunchQuotaObserver: { [weak self] detail in
                    guard let self else { return }
                    Task {
                        await self.handlePostLaunchQuotaExhaustion(
                            exhaustedProfile: candidate,
                            remainingCandidates: remainingCandidates,
                            attemptedProfileIDs: attemptedSnapshot,
                            detail: detail
                        )
                    }
                }
            )
            if outcome.success {
                clearQuotaExhaustion(for: candidate)
                if candidate.id != requestedProfile.id {
                    profileStore.setActiveProfileID(candidate.id)
                }
                return CLILaunchOutcome(
                    success: true,
                    error: nil,
                    launchedProfileID: candidate.id,
                    attemptedProfileIDs: attemptedProfileIDs
                )
            }

            if case .quotaExhausted(let detail) = outcome.error {
                persistQuotaExhaustion(for: candidate, detail: detail)
                lastError = outcome.error
                continue
            }

            return CLILaunchOutcome(
                success: false,
                error: outcome.error,
                launchedProfileID: nil,
                attemptedProfileIDs: attemptedProfileIDs
            )
        }

        return CLILaunchOutcome(
            success: false,
            error: lastError ?? .launchFailed("No eligible CLI profiles are available in the current priority order."),
            launchedProfileID: nil,
            attemptedProfileIDs: attemptedProfileIDs
        )
    }

    private func attemptLaunch(
        profile: SwitcherProfileRecord,
        postLaunchQuotaObserver: (@Sendable (String) -> Void)? = nil
    ) async -> CLILaunchOutcome {
        let profileID = profile.id
        guard let cliType = profile.cliType else {
            return CLILaunchOutcome(
                success: false,
                error: .missingProfileMetadata(profileID),
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )
        }
        let sequence = await coordinator.beginLaunch(profileID: profileID)
        guard sequence != nil else {
            return CLILaunchOutcome(
                success: false,
                error: .launchFailed("Launch already in progress for this profile"),
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )
        }

        defer {
            Task {
                await coordinator.endLaunch(profileID: profileID, success: false)
            }
        }

        guard profile.targetKind == .cli else {
            return CLILaunchOutcome(
                success: false,
                error: .profileKindMismatch(expected: .cli, actual: profile.targetKind),
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )
        }

        let buildResult = CLILaunchAdapter.buildCLILaunch(profile: profile)

        switch buildResult {
        case .failure(let error):
            return CLILaunchOutcome(
                success: false,
                error: error,
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )

        case .success(let (executable, args, env, workingDirectory)):
            let launchResult = await CLILaunchInvoker.launchCLI(
                cliType: cliType,
                executable: executable,
                args: args,
                env: env,
                workingDirectory: workingDirectory,
                postLaunchQuotaObserver: postLaunchQuotaObserver
            )

            switch launchResult {
            case .success:
                await coordinator.endLaunch(profileID: profileID, success: true)
                return CLILaunchOutcome(
                    success: true,
                    error: nil,
                    launchedProfileID: profileID,
                    attemptedProfileIDs: [profileID]
                )
            case .failure(let error):
                return CLILaunchOutcome(
                    success: false,
                    error: error,
                    launchedProfileID: nil,
                    attemptedProfileIDs: [profileID]
                )
            }
        }
    }

    private func handlePostLaunchQuotaExhaustion(
        exhaustedProfile: SwitcherProfileRecord,
        remainingCandidates: [SwitcherProfileRecord],
        attemptedProfileIDs: [String],
        detail: String
    ) async {
        persistQuotaExhaustion(for: exhaustedProfile, detail: detail)
        let outcome = await launchCandidates(
            requestedProfile: exhaustedProfile,
            candidates: remainingCandidates,
            attemptedProfileIDs: attemptedProfileIDs
        )

        if outcome.success, let recoveredProfileID = outcome.launchedProfileID {
            profileStore.setActiveProfileID(recoveredProfileID)
            notifyEvent(.postLaunchFallbackSucceeded(
                exhaustedProfileID: exhaustedProfile.id,
                recoveredProfileID: recoveredProfileID,
                detail: detail,
                attemptedProfileIDs: outcome.attemptedProfileIDs
            ))
        } else {
            notifyEvent(.postLaunchFallbackFailed(
                exhaustedProfileID: exhaustedProfile.id,
                detail: outcome.error?.errorDescription ?? detail,
                attemptedProfileIDs: outcome.attemptedProfileIDs.isEmpty ? attemptedProfileIDs : outcome.attemptedProfileIDs
            ))
        }
    }

    private func persistQuotaExhaustion(for profile: SwitcherProfileRecord, detail: String) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return
        }

        let safeDetail = CLILaunchRedactor.redactSensitiveData(detail)
        let now = Date()
        let exhaustedUntil = exhaustionWindowEnd(from: safeDetail, now: now)
        let existingMetadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()
        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription,
                providerID: existingMetadata.providerID,
                runtimeAccountID: existingMetadata.runtimeAccountID,
                subscriptionTierID: existingMetadata.subscriptionTierID,
                modelCapabilityClassID: existingMetadata.modelCapabilityClassID,
                linkedHarnessIDs: existingMetadata.linkedHarnessIDs,
                neverAutoSwitch: existingMetadata.neverAutoSwitch,
                lastQuotaExhaustedAt: now,
                exhaustedUntil: exhaustedUntil,
                lastQuotaExhaustionDetail: safeDetail,
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )

        profileStore.updateProfile(updatedProfile)
    }

    private func clearQuotaExhaustion(for profile: SwitcherProfileRecord) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType,
              let existingMetadata = profile.cliMetadata,
              existingMetadata.lastQuotaExhaustedAt != nil
                || existingMetadata.exhaustedUntil != nil
                || existingMetadata.lastQuotaExhaustionDetail != nil else {
            return
        }

        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription,
                providerID: existingMetadata.providerID,
                runtimeAccountID: existingMetadata.runtimeAccountID,
                subscriptionTierID: existingMetadata.subscriptionTierID,
                modelCapabilityClassID: existingMetadata.modelCapabilityClassID,
                linkedHarnessIDs: existingMetadata.linkedHarnessIDs,
                neverAutoSwitch: existingMetadata.neverAutoSwitch,
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )

        profileStore.updateProfile(updatedProfile)
    }

    private func exhaustionWindowEnd(from detail: String, now: Date) -> Date? {
        CLIQuotaExhaustionClassifier.exhaustionWindowEnd(from: detail, now: now)
    }

    private func notifyEvent(_ event: CLILaunchServiceEvent) {
        guard let eventHandler else { return }
        Task { @MainActor in
            eventHandler(event)
        }
    }
}

// MARK: - Launch Outcome

/// Result of a CLI launch attempt with typed error.
public struct CLILaunchOutcome: Equatable, Sendable {
    public let success: Bool
    public let error: CLILaunchError?
    public let launchedProfileID: String?
    public let attemptedProfileIDs: [String]

    public var didUseFallback: Bool {
        guard let launchedProfileID,
              let firstAttempt = attemptedProfileIDs.first else {
            return false
        }
        return launchedProfileID != firstAttempt || attemptedProfileIDs.count > 1
    }

    public init(
        success: Bool,
        error: CLILaunchError?,
        launchedProfileID: String? = nil,
        attemptedProfileIDs: [String] = []
    ) {
        self.success = success
        self.error = error
        self.launchedProfileID = launchedProfileID
        self.attemptedProfileIDs = attemptedProfileIDs
    }

    public static func == (lhs: CLILaunchOutcome, rhs: CLILaunchOutcome) -> Bool {
        lhs.success == rhs.success
            && lhs.error == rhs.error
            && lhs.launchedProfileID == rhs.launchedProfileID
            && lhs.attemptedProfileIDs == rhs.attemptedProfileIDs
    }
}

// MARK: - Environment Redaction

/// Provides secret-safe logging and redaction utilities for CLI launch operations.
public struct CLILaunchRedactor {
    /// Keys that are considered sensitive and should never appear in logs.
    private static let sensitiveKeys: Set<String> = [
        "API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "AUTH",
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY"
    ]

    /// Redacts sensitive patterns from a string for safe logging.
    public static func redactSensitiveData(_ input: String) -> String {
        var result = input

        // Redact sensitive environment key patterns (key=value or key:value)
        // We look for patterns that indicate a secret is present:
        // 1. API key patterns (sk-ant-, sk- followed by 20+ chars, etc.)
        // Note: Longer patterns must come first in alternation to match correctly
        result = result.replacingOccurrences(
            of: #"(?i)(sk-[a-zA-Z0-9]{20,}|sk-ant-)"#,
            with: "[API_KEY_REDACTED]",
            options: .regularExpression
        )

        // 2. Bearer token patterns
        result = result.replacingOccurrences(
            of: #"(?i)Bearer[_\s]+[A-Za-z0-9_\-\.]+"#,
            with: "[TOKEN_REDACTED]",
            options: .regularExpression
        )

        // 3. Generic key=value patterns where value looks like a secret
        // Pattern: word characters followed by = or : followed by what looks like a token/secret
        result = result.replacingOccurrences(
            of: #"(?i)(api_key|apikey|secret|password|token|auth|access_token)[=:][^,\s]+"#,
            with: "[SECRET_REDACTED]",
            options: .regularExpression
        )

        return result
    }

    /// Redacts sensitive environment variables from a dictionary for safe logging.
    public static func redactEnvironment(_ env: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        for (key, value) in env {
            let isSensitive = sensitiveKeys.contains { key.uppercased().contains($0) }
            if isSensitive {
                result[key] = "[REDACTED]"
            } else {
                result[key] = redactSensitiveData(value)
            }
        }

        return result
    }
}

#endif
