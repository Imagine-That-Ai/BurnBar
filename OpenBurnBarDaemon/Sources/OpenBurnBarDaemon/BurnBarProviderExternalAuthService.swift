import Foundation
import OpenBurnBarCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public protocol BurnBarProviderExternalAuthServing: Sendable {
    func start(_ request: BurnBarProviderExternalAuthStartRequest) async -> BurnBarProviderExternalAuthResponse
    func status(_ request: BurnBarProviderExternalAuthStatusRequest) async throws -> BurnBarProviderExternalAuthResponse
    func cancel(_ request: BurnBarProviderExternalAuthFlowRequest) async throws -> BurnBarProviderExternalAuthResponse
}

enum BurnBarProviderExternalAuthServiceError: Error, LocalizedError, Equatable, Sendable {
    case invalidFlow

    var errorDescription: String? {
        switch self {
        case .invalidFlow:
            return "The provider sign-in flow is no longer active."
        }
    }
}

enum BurnBarProviderExternalAuthTerminalLaunchError: Error, Equatable, Sendable {
    case unavailable
    case failed
}

struct BurnBarProviderExternalAuthTerminalCandidate: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
}

enum BurnBarProviderExternalAuthLinuxTerminalLauncher {
    private enum StartedSentinelStatus {
        case absent
        case ready
        case unsafe
    }

    private static let startedSentinelFileName = "started.ready"
    private static let startedSentinelContents = Data("started\n".utf8)
    private static let acceptedSentinelContents = Data("accepted\n".utf8)
    private static let exitMarkerFileName = "exit.status"
    private static let candidateHandshakeTimeout: TimeInterval = 1
    private static let totalHandshakeTimeout: TimeInterval = 4
    private static let handshakePollInterval: TimeInterval = 0.025
    private static let environmentKeys: Set<String> = [
        "DBUS_SESSION_BUS_ADDRESS",
        "DESKTOP_STARTUP_ID",
        "DISPLAY",
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "SHELL",
        "USER",
        "WAYLAND_DISPLAY",
        "XAUTHORITY",
        "XDG_CURRENT_DESKTOP",
        "XDG_RUNTIME_DIR",
        "XDG_SESSION_TYPE"
    ]

    static func candidates(scriptURL: URL) -> [BurnBarProviderExternalAuthTerminalCandidate] {
        [
            BurnBarProviderExternalAuthTerminalCandidate(
                executableURL: URL(fileURLWithPath: "/usr/bin/x-terminal-emulator"),
                arguments: ["-e", scriptURL.path]
            ),
            BurnBarProviderExternalAuthTerminalCandidate(
                executableURL: URL(fileURLWithPath: "/usr/bin/gnome-terminal"),
                arguments: ["--wait", "--", scriptURL.path]
            ),
            BurnBarProviderExternalAuthTerminalCandidate(
                executableURL: URL(fileURLWithPath: "/usr/bin/konsole"),
                arguments: ["--separate", "-e", scriptURL.path]
            ),
            BurnBarProviderExternalAuthTerminalCandidate(
                executableURL: URL(fileURLWithPath: "/usr/bin/xfce4-terminal"),
                arguments: ["--disable-server", "--execute", scriptURL.path]
            ),
            BurnBarProviderExternalAuthTerminalCandidate(
                executableURL: URL(fileURLWithPath: "/usr/bin/xterm"),
                arguments: ["-e", scriptURL.path]
            )
        ]
    }

    static func launch(
        scriptURL: URL,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        #if os(Linux)
        try launchCandidates(
            scriptURL: scriptURL,
            candidates: candidates(scriptURL: scriptURL),
            fileManager: fileManager,
            environment: environment,
            processGroupExecutableURL: URL(fileURLWithPath: "/usr/bin/setsid")
        )
        #else
        _ = scriptURL
        _ = fileManager
        _ = environment
        throw BurnBarProviderExternalAuthTerminalLaunchError.unavailable
        #endif
    }

    static func launchCandidates(
        scriptURL: URL,
        candidates: [BurnBarProviderExternalAuthTerminalCandidate],
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidateTimeout: TimeInterval = candidateHandshakeTimeout,
        totalTimeout: TimeInterval = totalHandshakeTimeout,
        pollInterval: TimeInterval = handshakePollInterval,
        processGroupExecutableURL: URL? = nil,
        acceptancePrecommit: ((URL) throws -> Void)? = nil
    ) throws {
        guard candidateTimeout > 0, totalTimeout > 0, pollInterval > 0 else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        try prepareStartedSentinel(scriptURL: scriptURL, fileManager: fileManager)

        let installedCandidates = candidates.filter {
            fileManager.isExecutableFile(atPath: $0.executableURL.path)
        }
        guard !installedCandidates.isEmpty else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.unavailable
        }

        let totalDeadline = Date().addingTimeInterval(totalTimeout)
        let filteredEnvironment = environment.filter { environmentKeys.contains($0.key) }
        for candidate in installedCandidates {
            let remainingTotal = totalDeadline.timeIntervalSinceNow
            guard remainingTotal > 0 else { break }

            let attemptURL = attemptSentinelURL(scriptURL: scriptURL)
            let acceptedURL = acceptedSentinelURL(scriptURL: scriptURL)
            guard startedSentinelStatus(sentinelURL: attemptURL, fileManager: fileManager) == .absent else {
                throw BurnBarProviderExternalAuthTerminalLaunchError.failed
            }
            let candidateArguments = candidate.arguments + [attemptURL.path, acceptedURL.path]
            let process = Process()
            if let processGroupExecutableURL {
                guard fileManager.isExecutableFile(atPath: processGroupExecutableURL.path) else {
                    throw BurnBarProviderExternalAuthTerminalLaunchError.failed
                }
                process.executableURL = processGroupExecutableURL
                process.arguments = [candidate.executableURL.path] + candidateArguments
            } else {
                process.executableURL = candidate.executableURL
                process.arguments = candidateArguments
            }
            process.environment = filteredEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continue
            }

            let candidateDeadline = Date().addingTimeInterval(min(candidateTimeout, remainingTotal))
            while Date() < candidateDeadline, Date() < totalDeadline {
                switch startedSentinelStatus(sentinelURL: attemptURL, fileManager: fileManager) {
                case .ready:
                    do {
                        try promoteStartedSentinel(
                            from: attemptURL,
                            acceptedURL: acceptedURL,
                            scriptURL: scriptURL,
                            fileManager: fileManager,
                            acceptancePrecommit: acceptancePrecommit
                        )
                    } catch {
                        stop(process, processGroup: processGroupExecutableURL != nil)
                        try? removeFailedCandidateExitMarker(scriptURL: scriptURL, fileManager: fileManager)
                        try? removeFailedAttemptSentinel(at: attemptURL, fileManager: fileManager)
                        throw BurnBarProviderExternalAuthTerminalLaunchError.failed
                    }
                    return
                case .unsafe:
                    stop(process, processGroup: processGroupExecutableURL != nil)
                    try? removeFailedCandidateExitMarker(scriptURL: scriptURL, fileManager: fileManager)
                    throw BurnBarProviderExternalAuthTerminalLaunchError.failed
                case .absent:
                    break
                }
                let remaining = max(0, min(
                    pollInterval,
                    candidateDeadline.timeIntervalSinceNow,
                    totalDeadline.timeIntervalSinceNow
                ))
                if remaining > 0 {
                    Thread.sleep(forTimeInterval: remaining)
                }
            }

            if startedSentinelStatus(sentinelURL: attemptURL, fileManager: fileManager) == .ready {
                do {
                    try promoteStartedSentinel(
                        from: attemptURL,
                        acceptedURL: acceptedURL,
                        scriptURL: scriptURL,
                        fileManager: fileManager,
                        acceptancePrecommit: acceptancePrecommit
                    )
                } catch {
                    stop(process, processGroup: processGroupExecutableURL != nil)
                    try? removeFailedCandidateExitMarker(scriptURL: scriptURL, fileManager: fileManager)
                    try? removeFailedAttemptSentinel(at: attemptURL, fileManager: fileManager)
                    throw BurnBarProviderExternalAuthTerminalLaunchError.failed
                }
                return
            }
            stop(process, processGroup: processGroupExecutableURL != nil)
            try removeFailedCandidateExitMarker(scriptURL: scriptURL, fileManager: fileManager)
            try removeFailedAttemptSentinel(at: attemptURL, fileManager: fileManager)
        }

        throw BurnBarProviderExternalAuthTerminalLaunchError.failed
    }

    static func prepareStartedSentinel(
        scriptURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directoryURL = scriptURL.deletingLastPathComponent()
        guard isSafePrivateDirectory(directoryURL, fileManager: fileManager),
              isSafePrivateRegularFile(scriptURL, fileManager: fileManager) else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        let sentinelURL = startedSentinelURL(scriptURL: scriptURL)
        if (try? fileManager.attributesOfItem(atPath: sentinelURL.path)) != nil {
            guard isSafePrivateRegularFile(sentinelURL, fileManager: fileManager) else {
                throw BurnBarProviderExternalAuthTerminalLaunchError.failed
            }
            try fileManager.removeItem(at: sentinelURL)
        }
    }

    static func isStartedSentinelReady(
        scriptURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        startedSentinelStatus(scriptURL: scriptURL, fileManager: fileManager) == .ready
    }

    private static func startedSentinelURL(scriptURL: URL) -> URL {
        scriptURL.deletingLastPathComponent()
            .appendingPathComponent(startedSentinelFileName, isDirectory: false)
    }

    private static func attemptSentinelURL(scriptURL: URL) -> URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent(
            "started.attempt.\(UUID().uuidString)",
            isDirectory: false
        )
    }

    private static func acceptedSentinelURL(scriptURL: URL) -> URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent(
            "launch.accepted.\(UUID().uuidString)",
            isDirectory: false
        )
    }

    private static func startedSentinelStatus(
        scriptURL: URL,
        fileManager: FileManager
    ) -> StartedSentinelStatus {
        startedSentinelStatus(
            sentinelURL: startedSentinelURL(scriptURL: scriptURL),
            fileManager: fileManager
        )
    }

    private static func startedSentinelStatus(
        sentinelURL: URL,
        fileManager: FileManager
    ) -> StartedSentinelStatus {
        guard let attributes = try? fileManager.attributesOfItem(atPath: sentinelURL.path) else {
            return fileManager.fileExists(atPath: sentinelURL.path) ? .unsafe : .absent
        }
        guard isSafePrivateRegularFile(attributes: attributes),
              (attributes[.size] as? NSNumber)?.intValue == startedSentinelContents.count,
              (try? Data(contentsOf: sentinelURL)) == startedSentinelContents else {
            return .unsafe
        }
        return .ready
    }

    private static func promoteStartedSentinel(
        from attemptURL: URL,
        acceptedURL: URL,
        scriptURL: URL,
        fileManager: FileManager,
        acceptancePrecommit: ((URL) throws -> Void)?
    ) throws {
        guard startedSentinelStatus(sentinelURL: attemptURL, fileManager: fileManager) == .ready else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        let startedURL = startedSentinelURL(scriptURL: scriptURL)
        guard startedSentinelStatus(sentinelURL: startedURL, fileManager: fileManager) == .absent,
              (try? fileManager.attributesOfItem(atPath: acceptedURL.path)) == nil else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        try fileManager.moveItem(at: attemptURL, to: startedURL)
        let acceptedTemporaryURL = acceptedURL.deletingLastPathComponent().appendingPathComponent(
            ".\(acceptedURL.lastPathComponent).tmp.\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            guard startedSentinelStatus(sentinelURL: startedURL, fileManager: fileManager) == .ready else {
                throw BurnBarProviderExternalAuthTerminalLaunchError.failed
            }
            try acceptedSentinelContents.write(to: acceptedTemporaryURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: acceptedTemporaryURL.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: acceptedTemporaryURL.path),
                  isSafePrivateRegularFile(attributes: attributes),
                  (attributes[.size] as? NSNumber)?.intValue == acceptedSentinelContents.count,
                  (try? Data(contentsOf: acceptedTemporaryURL)) == acceptedSentinelContents else {
                throw BurnBarProviderExternalAuthTerminalLaunchError.failed
            }
            try acceptancePrecommit?(acceptedURL)
            try fileManager.moveItem(at: acceptedTemporaryURL, to: acceptedURL)
        } catch {
            try? fileManager.removeItem(at: acceptedTemporaryURL)
            if isSafePrivateRegularFile(startedURL, fileManager: fileManager) {
                try? fileManager.removeItem(at: startedURL)
            }
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
    }

    private static func removeFailedAttemptSentinel(
        at attemptURL: URL,
        fileManager: FileManager
    ) throws {
        switch startedSentinelStatus(sentinelURL: attemptURL, fileManager: fileManager) {
        case .absent:
            return
        case .ready:
            try fileManager.removeItem(at: attemptURL)
        case .unsafe:
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
    }

    private static func removeFailedCandidateExitMarker(
        scriptURL: URL,
        fileManager: FileManager
    ) throws {
        let markerURL = scriptURL.deletingLastPathComponent()
            .appendingPathComponent(exitMarkerFileName, isDirectory: false)
        guard (try? fileManager.attributesOfItem(atPath: markerURL.path)) != nil else { return }
        guard isSafePrivateRegularFile(markerURL, fileManager: fileManager) else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        try fileManager.removeItem(at: markerURL)
    }

    private static func isSafePrivateDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            return false
        }
        return hasPrivatePermissions(attributes)
    }

    private static func isSafePrivateRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return isSafePrivateRegularFile(attributes: attributes)
    }

    private static func isSafePrivateRegularFile(attributes: [FileAttributeKey: Any]) -> Bool {
        attributes[.type] as? FileAttributeType == .typeRegular && hasPrivatePermissions(attributes)
    }

    private static func hasPrivatePermissions(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            return false
        }
        return permissions & 0o077 == 0
    }

    private static func stop(_ process: Process, processGroup: Bool) {
        let processID = process.processIdentifier
        if processGroup {
            _ = kill(-processID, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline {
            let stillRunning = processGroup ? kill(-processID, 0) == 0 : process.isRunning
            guard stillRunning else { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if processGroup {
            if kill(-processID, 0) == 0 {
                _ = kill(-processID, SIGKILL)
            }
        } else if process.isRunning {
            _ = kill(processID, SIGKILL)
        }
        if process.isRunning {
            let killDeadline = Date().addingTimeInterval(0.1)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        process.waitUntilExit()
    }
}

actor BurnBarProviderExternalAuthService: BurnBarProviderExternalAuthServing {
    struct Dependencies: Sendable {
        var now: @Sendable () -> Date = Date.init
        var makeUUID: @Sendable () -> UUID = UUID.init
        var resolveExecutable: @Sendable (SwitcherCLIProfileType) -> URL? = {
            CLILaunchAdapter.resolvePinnedExecutable(for: $0)
        }
        var discoverAuth: @Sendable (SwitcherCLIProfileType, URL?) -> CLIAuthInfo = {
            CLIAuthDiscovery.discoverAuthState(for: $0, executableURLOverride: $1)
        }
        var launchTerminal: @Sendable (URL) throws -> Void = {
            try BurnBarProviderExternalAuthLinuxTerminalLauncher.launch(scriptURL: $0)
        }
    }

    private struct ResolvedMethod: Sendable {
        let descriptor: BurnBarProviderAuthDescriptor
        let method: BurnBarProviderAuthMethod
        let cliType: SwitcherCLIProfileType
    }

    private struct PersistedFlow: Codable, Sendable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let flowID: String
        let providerID: String
        let authMethodID: String
        let cliType: SwitcherCLIProfileType
        var state: BurnBarProviderExternalAuthState
        let startedAt: Date
        let expiresAt: Date
        var completedAt: Date?
        var problem: BurnBarProviderExternalAuthProblem?
        var verifiedConnected: Bool
        var verificationStartedAt: Date?
        var verificationDeadline: Date?
    }

    private static let flowLifetime: TimeInterval = 5 * 60
    private static let sessionDirectoryName = "sessions"
    private static let stateFileName = "current-flow.json"
    private static let scriptFileName = "login.sh"
    private static let cancelFileName = "cancel.requested"
    private static let timeoutFileName = "timeout.expired"
    private static let markerFileName = "exit.status"
    private static let startedFileName = "started.ready"
    private static let maximumProviderIDLength = 128
    private static let maximumAuthMethodIDLength = 128
    private static let maximumFlowIDLength = 64
    private static let verificationGrace: TimeInterval = 15

    private let rootDirectoryURL: URL
    private let stateURL: URL
    private let dependencies: Dependencies
    private let fileManager: FileManager
    private var persistedFlow: PersistedFlow?
    private var recoveredFlowID: String?

    init(
        rootDirectoryURL: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("provider-external-auth", isDirectory: true),
        dependencies: Dependencies = Dependencies(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.stateURL = rootDirectoryURL.appendingPathComponent(Self.stateFileName, isDirectory: false)
        self.dependencies = dependencies
        self.fileManager = fileManager
        let recovered = Self.loadPersistedFlow(
            from: rootDirectoryURL.appendingPathComponent(Self.stateFileName, isDirectory: false),
            fileManager: fileManager
        )
        self.persistedFlow = recovered
        self.recoveredFlowID = recovered.map(\.flowID)
    }

    func start(_ request: BurnBarProviderExternalAuthStartRequest) async -> BurnBarProviderExternalAuthResponse {
        let now = dependencies.now()
        guard isValidSelector(request.providerID, maximumLength: Self.maximumProviderIDLength),
              isValidSelector(request.authMethodID, maximumLength: Self.maximumAuthMethodIDLength),
              let resolved = resolveMethod(providerID: request.providerID, authMethodID: request.authMethodID) else {
            return unsupportedResponse(
                providerID: request.providerID,
                authMethodID: request.authMethodID,
                state: .failed,
                now: now
            )
        }

        if let existing = persistedFlow {
            let evaluation = refresh(existing, resolved: resolveMethod(for: existing), now: now)
            persistedFlow = evaluation.flow
            if isInProgress(evaluation.flow.state) {
                if evaluation.flow.providerID == resolved.descriptor.providerID,
                   evaluation.flow.authMethodID == resolved.method.id,
                   let auth = evaluation.auth {
                    return response(for: evaluation.flow, resolved: resolved, auth: auth, now: now)
                }
                return failedResponse(
                    resolved: resolved,
                    code: .anotherFlowActive,
                    message: "Finish or cancel the current provider sign-in before starting another one.",
                    now: now
                )
            }
            if cleanupMayStillBeActive(for: evaluation.flow, now: now) {
                let matchingAuth = evaluation.flow.providerID == resolved.descriptor.providerID
                    && evaluation.flow.authMethodID == resolved.method.id
                    ? evaluation.auth
                    : nil
                return failedResponse(
                    resolved: resolved,
                    code: .anotherFlowActive,
                    message: "OpenBurnBar is still stopping the previous provider sign-in.",
                    now: now,
                    auth: matchingAuth
                )
            }
        }

        guard dependencies.resolveExecutable(resolved.cliType) != nil else {
            return unavailableExecutableResponse(resolved: resolved, state: .failed, now: now)
        }

        let flowID = dependencies.makeUUID().uuidString.uppercased()
        let flow = PersistedFlow(
            schemaVersion: PersistedFlow.currentSchemaVersion,
            flowID: flowID,
            providerID: resolved.descriptor.providerID,
            authMethodID: resolved.method.id,
            cliType: resolved.cliType,
            state: .launching,
            startedAt: now,
            expiresAt: now.addingTimeInterval(Self.flowLifetime),
            completedAt: nil,
            problem: nil,
            verifiedConnected: false,
            verificationStartedAt: nil,
            verificationDeadline: nil
        )
        persistedFlow = flow
        recoveredFlowID = nil

        do {
            try prepareRootDirectory()
            let scriptURL = try writeScript(for: flow)
            var awaiting = flow
            awaiting.state = .awaitingUser
            persistedFlow = awaiting
            try persist(awaiting)
            try dependencies.launchTerminal(scriptURL)
            let auth = discoverAuth(for: resolved)
            return response(for: awaiting, resolved: resolved, auth: auth, now: now)
        } catch let error as BurnBarProviderExternalAuthTerminalLaunchError {
            let code: BurnBarProviderExternalAuthProblemCode = error == .unavailable
                ? .terminalUnavailable
                : .launchFailed
            return finishLaunchFailure(flow: flow, resolved: resolved, code: code, now: now)
        } catch {
            return finishLaunchFailure(flow: flow, resolved: resolved, code: .launchFailed, now: now)
        }
    }

    func status(_ request: BurnBarProviderExternalAuthStatusRequest) async throws -> BurnBarProviderExternalAuthResponse {
        let now = dependencies.now()
        guard isValidSelector(request.providerID, maximumLength: Self.maximumProviderIDLength),
              isValidOptionalSelector(request.authMethodID, maximumLength: Self.maximumAuthMethodIDLength) else {
            return unsupportedResponse(
                providerID: request.providerID,
                authMethodID: request.authMethodID,
                state: .idle,
                now: now
            )
        }
        if request.flowID != nil,
           !isValidFlowID(request.flowID) {
            throw BurnBarProviderExternalAuthServiceError.invalidFlow
        }
        guard let resolved = resolveMethod(providerID: request.providerID, authMethodID: request.authMethodID) else {
            return unsupportedResponse(
                providerID: request.providerID,
                authMethodID: request.authMethodID,
                state: .idle,
                now: now
            )
        }

        if let requestedFlowID = request.flowID {
            guard let current = persistedFlow, current.flowID == requestedFlowID else {
                throw BurnBarProviderExternalAuthServiceError.invalidFlow
            }
            guard current.providerID == resolved.descriptor.providerID,
                  current.authMethodID == resolved.method.id else {
                throw BurnBarProviderExternalAuthServiceError.invalidFlow
            }
        }

        guard let current = persistedFlow,
              current.providerID == resolved.descriptor.providerID,
              current.authMethodID == resolved.method.id else {
            return idleResponse(resolved: resolved, now: now)
        }

        let evaluation = refresh(current, resolved: resolved, now: now)
        persistedFlow = evaluation.flow
        if request.flowID == nil, isTerminal(evaluation.flow.state) {
            return idleResponse(resolved: resolved, now: now)
        }
        guard let auth = evaluation.auth else {
            return failedResponse(
                resolved: resolved,
                code: .verificationFailed,
                message: "OpenBurnBar could not verify the provider sign-in state.",
                now: now
            )
        }
        return response(for: evaluation.flow, resolved: resolved, auth: auth, now: now)
    }

    func cancel(_ request: BurnBarProviderExternalAuthFlowRequest) async throws -> BurnBarProviderExternalAuthResponse {
        let now = dependencies.now()
        guard isValidFlowID(request.flowID) else {
            throw BurnBarProviderExternalAuthServiceError.invalidFlow
        }
        guard var flow = persistedFlow,
              flow.flowID == request.flowID,
              let resolved = resolveMethod(for: flow) else {
            throw BurnBarProviderExternalAuthServiceError.invalidFlow
        }

        if isInProgress(flow.state) {
            do {
                try writeCancelSentinel(for: flow)
            } catch {
                flow.problem = problem(
                    code: .launchFailed,
                    message: "OpenBurnBar could not cancel the provider sign-in safely.",
                    recoverable: true
                )
                persistedFlow = flow
                try? persist(flow)
                return response(for: flow, resolved: resolved, auth: discoverAuth(for: resolved), now: now)
            }
            flow.state = .cancelled
            flow.completedAt = now
            flow.verificationStartedAt = nil
            flow.verificationDeadline = nil
            flow.problem = problem(
                code: .cancelled,
                message: "Provider sign-in was cancelled.",
                recoverable: true
            )
            recoveredFlowID = nil
            persistedFlow = flow
            try? persist(flow)
        }

        return response(for: flow, resolved: resolved, auth: discoverAuth(for: resolved), now: now)
    }

    private func refresh(
        _ flow: PersistedFlow,
        resolved: ResolvedMethod?,
        now: Date
    ) -> (flow: PersistedFlow, auth: CLIAuthInfo?) {
        guard var current = persistedFlow, current.flowID == flow.flowID else {
            return (flow, resolved.map(discoverAuth))
        }
        guard let resolved else {
            current.state = .failed
            current.completedAt = now
            current.verificationStartedAt = nil
            current.verificationDeadline = nil
            current.problem = problem(
                code: .unsupportedAuthMethod,
                message: "This provider sign-in method is no longer supported.",
                recoverable: false
            )
            try? persist(current)
            return (current, nil)
        }

        if isTerminal(current.state) {
            return (current, discoverAuth(for: resolved))
        }

        var successfulExitRequiresVerification = current.state == .verifying
        if successfulExitRequiresVerification {
            recoveredFlowID = nil
        } else if let exitStatus = readExitStatus(for: current) {
            recoveredFlowID = nil
            if exitStatus == 0 {
                current.state = .verifying
                current.completedAt = nil
                current.problem = nil
                current.verificationStartedAt = now
                current.verificationDeadline = now.addingTimeInterval(Self.verificationGrace)
                successfulExitRequiresVerification = true
            } else {
                current.completedAt = now
                current.verificationStartedAt = nil
                current.verificationDeadline = nil
                if exitStatus == 124 {
                    current.state = .timedOut
                    current.problem = problem(
                        code: .timeout,
                        message: "Provider sign-in timed out. Start a new sign-in to try again.",
                        recoverable: true
                    )
                } else if exitStatus == 130 || exitStatus == 143 {
                    current.state = .cancelled
                    current.problem = problem(
                        code: .cancelled,
                        message: "Provider sign-in was cancelled.",
                        recoverable: true
                    )
                } else {
                    current.state = .failed
                    current.problem = problem(
                        code: .processFailed,
                        message: "The provider login command exited before sign-in completed.",
                        recoverable: true
                    )
                }
            }
        } else if cancelRequested(for: current) {
            current.state = .cancelled
            current.completedAt = current.completedAt ?? now
            current.verificationStartedAt = nil
            current.verificationDeadline = nil
            current.problem = problem(
                code: .cancelled,
                message: "Provider sign-in was cancelled.",
                recoverable: true
            )
            recoveredFlowID = nil
        } else if now >= current.expiresAt, isInProgress(current.state) {
            try? writeCancelSentinel(for: current)
            current.state = .timedOut
            current.completedAt = now
            current.verificationStartedAt = nil
            current.verificationDeadline = nil
            current.problem = problem(
                code: .timeout,
                message: "Provider sign-in timed out. Start a new sign-in to try again.",
                recoverable: true
            )
            recoveredFlowID = nil
        } else if isInProgress(current.state) {
            current.state = .awaitingUser
            if recoveredFlowID == current.flowID {
                current.problem = problem(
                    code: .daemonRestarted,
                    message: "OpenBurnBar reconnected to the sign-in flow after restarting.",
                    recoverable: true
                )
            }
        }

        let auth = discoverAuth(for: resolved)
        if successfulExitRequiresVerification {
            if isConnected(auth) {
                current.state = .succeeded
                current.completedAt = now
                current.problem = nil
                current.verifiedConnected = true
            } else if now >= (current.verificationDeadline ?? now) {
                current.state = .failed
                current.completedAt = now
                current.problem = problem(
                    code: .verificationFailed,
                    message: "The login command finished, but OpenBurnBar could not verify the account.",
                    recoverable: true
                )
            }
        }
        try? persist(current)
        return (current, auth)
    }

    private func resolveMethod(providerID: String, authMethodID: String?) -> ResolvedMethod? {
        guard let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: providerID) else {
            return nil
        }
        let supported: (methodID: String, cliType: SwitcherCLIProfileType)
        switch descriptor.providerID {
        case "openai":
            supported = ("openai-codex-oauth", .codex)
        case "anthropic":
            supported = ("anthropic-claude-code-login", .claude)
        default:
            return nil
        }

        if let authMethodID {
            guard isValidSelector(authMethodID, maximumLength: Self.maximumAuthMethodIDLength),
                  authMethodID == supported.methodID else {
                return nil
            }
        }
        guard let method = descriptor.method(id: supported.methodID), method.kind == .browserLogin else {
            return nil
        }
        return ResolvedMethod(descriptor: descriptor, method: method, cliType: supported.cliType)
    }

    private func resolveMethod(for flow: PersistedFlow) -> ResolvedMethod? {
        resolveMethod(providerID: flow.providerID, authMethodID: flow.authMethodID)
    }

    private func idleResponse(resolved: ResolvedMethod, now: Date) -> BurnBarProviderExternalAuthResponse {
        guard dependencies.resolveExecutable(resolved.cliType) != nil else {
            return unavailableExecutableResponse(resolved: resolved, state: .idle, now: now)
        }
        let auth = discoverAuth(for: resolved)
        return BurnBarProviderExternalAuthResponse(flow: snapshot(
            flowID: nil,
            resolved: resolved,
            state: .idle,
            availability: .available,
            auth: auth,
            problem: nil,
            startedAt: nil,
            expiresAt: nil,
            completedAt: nil,
            now: now
        ))
    }

    private func response(
        for flow: PersistedFlow,
        resolved: ResolvedMethod,
        auth: CLIAuthInfo,
        now: Date
    ) -> BurnBarProviderExternalAuthResponse {
        let installed = dependencies.resolveExecutable(resolved.cliType) != nil
        return BurnBarProviderExternalAuthResponse(flow: snapshot(
            flowID: flow.flowID,
            resolved: resolved,
            state: flow.state,
            availability: installed ? .available : .unavailable,
            auth: auth,
            problem: flow.problem,
            verifiedConnected: flow.verifiedConnected,
            startedAt: flow.startedAt,
            expiresAt: flow.expiresAt,
            completedAt: flow.completedAt,
            now: now
        ))
    }

    private func snapshot(
        flowID: String?,
        resolved: ResolvedMethod,
        state: BurnBarProviderExternalAuthState,
        availability: BurnBarProviderExternalAuthAvailability,
        auth: CLIAuthInfo,
        problem: BurnBarProviderExternalAuthProblem?,
        verifiedConnected: Bool = false,
        startedAt: Date?,
        expiresAt: Date?,
        completedAt: Date?,
        now: Date
    ) -> BurnBarProviderExternalAuthFlowSnapshot {
        BurnBarProviderExternalAuthFlowSnapshot(
            flowID: flowID,
            providerID: resolved.descriptor.providerID,
            providerDisplayName: resolved.descriptor.displayName,
            authMethodID: resolved.method.id,
            authMethodDisplayName: resolved.method.displayName,
            cliDisplayName: resolved.cliType.displayName,
            state: state,
            availability: availability,
            cliInstalled: auth.isInstalled,
            connected: verifiedConnected || isConnected(auth),
            accountDescription: normalized(auth.accountDescription),
            problem: problem,
            startedAt: startedAt.map(iso),
            expiresAt: expiresAt.map(iso),
            completedAt: completedAt.map(iso),
            updatedAt: iso(now)
        )
    }

    private func unsupportedResponse(
        providerID: String,
        authMethodID: String?,
        state: BurnBarProviderExternalAuthState,
        now: Date
    ) -> BurnBarProviderExternalAuthResponse {
        let descriptor = isValidSelector(providerID, maximumLength: Self.maximumProviderIDLength)
            ? BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: providerID)
            : nil
        let providerSupported = descriptor.map { $0.providerID == "openai" || $0.providerID == "anthropic" } ?? false
        let code: BurnBarProviderExternalAuthProblemCode = providerSupported
            ? .unsupportedAuthMethod
            : .unsupportedProvider
        let canonicalProviderID = descriptor?.providerID
            ?? safeResponseSelector(providerID, maximumLength: Self.maximumProviderIDLength)
            ?? "unknown"
        let methodID = safeResponseSelector(authMethodID, maximumLength: Self.maximumAuthMethodIDLength)
            ?? "unsupported"
        return BurnBarProviderExternalAuthResponse(flow: BurnBarProviderExternalAuthFlowSnapshot(
            providerID: canonicalProviderID,
            providerDisplayName: descriptor?.displayName ?? "Unsupported provider",
            authMethodID: methodID,
            authMethodDisplayName: "Unsupported sign-in method",
            cliDisplayName: "Unavailable",
            state: state,
            availability: .unavailable,
            cliInstalled: false,
            connected: false,
            problem: problem(
                code: code,
                message: providerSupported
                    ? "This provider sign-in method is not supported."
                    : "This provider does not support external CLI sign-in.",
                recoverable: false
            ),
            updatedAt: iso(now)
        ))
    }

    private func unavailableExecutableResponse(
        resolved: ResolvedMethod,
        state: BurnBarProviderExternalAuthState,
        now: Date
    ) -> BurnBarProviderExternalAuthResponse {
        BurnBarProviderExternalAuthResponse(flow: BurnBarProviderExternalAuthFlowSnapshot(
            providerID: resolved.descriptor.providerID,
            providerDisplayName: resolved.descriptor.displayName,
            authMethodID: resolved.method.id,
            authMethodDisplayName: resolved.method.displayName,
            cliDisplayName: resolved.cliType.displayName,
            state: state,
            availability: .unavailable,
            cliInstalled: false,
            connected: false,
            problem: problem(
                code: .executableNotFound,
                message: "Install \(resolved.cliType.displayName) before starting sign-in.",
                recoverable: true
            ),
            updatedAt: iso(now)
        ))
    }

    private func failedResponse(
        resolved: ResolvedMethod,
        code: BurnBarProviderExternalAuthProblemCode,
        message: String,
        now: Date,
        auth providedAuth: CLIAuthInfo? = nil
    ) -> BurnBarProviderExternalAuthResponse {
        let auth = providedAuth ?? discoverAuth(for: resolved)
        return BurnBarProviderExternalAuthResponse(flow: snapshot(
            flowID: nil,
            resolved: resolved,
            state: .failed,
            availability: dependencies.resolveExecutable(resolved.cliType) == nil ? .unavailable : .available,
            auth: auth,
            problem: problem(code: code, message: message, recoverable: true),
            startedAt: nil,
            expiresAt: nil,
            completedAt: now,
            now: now
        ))
    }

    private func finishLaunchFailure(
        flow: PersistedFlow,
        resolved: ResolvedMethod,
        code: BurnBarProviderExternalAuthProblemCode,
        now: Date
    ) -> BurnBarProviderExternalAuthResponse {
        var failed = flow
        failed.state = .failed
        failed.completedAt = now
        failed.problem = problem(
            code: code,
            message: code == .terminalUnavailable
                ? "Install a supported terminal emulator before starting sign-in."
                : "OpenBurnBar could not open the provider sign-in terminal.",
            recoverable: true
        )
        persistedFlow = failed
        try? persist(failed)
        return response(for: failed, resolved: resolved, auth: discoverAuth(for: resolved), now: now)
    }

    private func prepareRootDirectory() throws {
        if (try? fileManager.attributesOfItem(atPath: rootDirectoryURL.path)) != nil,
           !Self.isSafeDirectory(rootDirectoryURL, fileManager: fileManager) {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        try fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectoryURL.path)
        let sessionsURL = rootDirectoryURL.appendingPathComponent(Self.sessionDirectoryName, isDirectory: true)
        if (try? fileManager.attributesOfItem(atPath: sessionsURL.path)) != nil,
           !Self.isSafeDirectory(sessionsURL, fileManager: fileManager) {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        try fileManager.createDirectory(
            at: sessionsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionsURL.path)
    }

    private func writeScript(for flow: PersistedFlow) throws -> URL {
        guard let executableURL = dependencies.resolveExecutable(flow.cliType) else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        #if os(Linux)
        guard fileManager.isExecutableFile(atPath: "/usr/bin/setsid") else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        #endif
        let directory = sessionURL(for: flow)
        if (try? fileManager.attributesOfItem(atPath: directory.path)) != nil,
           !Self.isSafeDirectory(directory, fileManager: fileManager) {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard safeSessionURL(for: flow) != nil else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }

        let scriptURL = directory.appendingPathComponent(Self.scriptFileName, isDirectory: false)
        let startedPath = shellQuote(startedURL(for: flow).path)
        let startedDirectoryPath = shellQuote(directory.path)
        let markerPath = shellQuote(markerURL(for: flow).path)
        let cancelPath = shellQuote(cancelURL(for: flow).path)
        let timeoutPath = shellQuote(timeoutURL(for: flow).path)
        let executablePath = shellQuote(executableURL.path)
        let executableDirectory = shellQuote(executableURL.deletingLastPathComponent().path)
        let commands: [[String]] = flow.cliType == .codex
            ? [["login"], ["auth", "login"]]
            : [["auth", "login"], ["login"]]
        let first = ([executablePath] + commands[0].map(shellQuote)).joined(separator: " ")
        let second = ([executablePath] + commands[1].map(shellQuote)).joined(separator: " ")
        let unsetLine = flow.cliType == .codex
            ? "unset CODEX_HOME CODEX_CONFIG_PATH"
            : "unset CLAUDE_CONFIG_DIR CLAUDE_CONFIG_PATH"

        let script = """
        #!/bin/sh
        umask 077
        STARTED_DEFAULT=\(startedPath)
        STARTED="${1:-$STARTED_DEFAULT}"
        ACCEPTED="${2:-}"
        case "$STARTED" in
          "$STARTED_DEFAULT"|\(startedDirectoryPath)/started.attempt.*) ;;
          *) exit 125 ;;
        esac
        started_tmp="${STARTED}.tmp.$$"
        printf 'started\\n' > "$started_tmp" || exit 125
        /bin/chmod 600 "$started_tmp" || exit 125
        /bin/mv -f -- "$started_tmp" "$STARTED" || exit 125
        PRELAUNCH_MARKER=\(markerPath)
        prelaunch_complete=0
        write_prelaunch_marker() {
          prelaunch_status="$1"
          prelaunch_tmp="${PRELAUNCH_MARKER}.tmp.$$"
          printf '%s\\n' "$prelaunch_status" > "$prelaunch_tmp"
          /bin/chmod 600 "$prelaunch_tmp" 2>/dev/null
          /bin/mv -f -- "$prelaunch_tmp" "$PRELAUNCH_MARKER" 2>/dev/null
        }
        prelaunch_exit() {
          prelaunch_status=$?
          if [ "$prelaunch_complete" -eq 0 ]; then
            write_prelaunch_marker "$prelaunch_status"
          fi
        }
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'prelaunch_exit' EXIT
        if [ "$STARTED" != "$STARTED_DEFAULT" ]; then
          case "$ACCEPTED" in
            \(startedDirectoryPath)/launch.accepted.*) ;;
            *) exit 125 ;;
          esac
          ack_deadline=$(( $(/bin/date +%s) + 5 ))
          while [ ! -f "$ACCEPTED" ]; do
            if [ "$(/bin/date +%s)" -ge "$ack_deadline" ]; then
              exit 125
            fi
            /bin/sleep 0.05
          done
        fi
        prelaunch_complete=1
        trap - HUP INT TERM EXIT
        set +e
        PATH=\(executableDirectory):/usr/local/bin:/usr/bin:/bin
        export PATH
        \(unsetLine)
        CANCEL=\(cancelPath)
        TIMEOUT=\(timeoutPath)
        MARKER=\(markerPath)

        write_marker() {
          marker_status="$1"
          marker_tmp="${MARKER}.tmp.$$"
          printf '%s\n' "$marker_status" > "$marker_tmp"
          /bin/mv -f -- "$marker_tmp" "$MARKER"
        }

        login_pid=""
        login_group=""
        watcher_pid=""
        started_epoch=$(/bin/date +%s)
        deadline_epoch=$((started_epoch + 300))

        cleanup_processes() {
          if [ -n "$watcher_pid" ]; then
            /bin/kill -TERM "$watcher_pid" 2>/dev/null
            wait "$watcher_pid" 2>/dev/null
          fi
          if [ -n "$login_group" ]; then
            /bin/kill -TERM -- "$login_group" 2>/dev/null
            /bin/sleep 1
            /bin/kill -KILL -- "$login_group" 2>/dev/null
          fi
        }

        handle_signal() {
          signal_status="$1"
          cleanup_processes
          write_marker "$signal_status"
          trap - HUP INT TERM EXIT
          exit "$signal_status"
        }

        trap 'handle_signal 129' HUP
        trap 'handle_signal 130' INT
        trap 'handle_signal 143' TERM
        trap 'cleanup_processes' EXIT

        run_login() {
          /usr/bin/setsid "$@" </dev/tty >/dev/tty 2>&1 &
          login_pid=$!
          login_group="-$login_pid"

          (
            while /bin/kill -0 "$login_pid" 2>/dev/null; do
              if [ -e "$CANCEL" ]; then
                /bin/kill -TERM -- "$login_group" 2>/dev/null
                /bin/sleep 1
                /bin/kill -KILL -- "$login_group" 2>/dev/null
                exit 0
              fi
              now_epoch=$(/bin/date +%s)
              if [ "$now_epoch" -ge "$deadline_epoch" ]; then
                : > "$TIMEOUT"
                /bin/kill -TERM -- "$login_group" 2>/dev/null
                /bin/sleep 1
                /bin/kill -KILL -- "$login_group" 2>/dev/null
                exit 0
              fi
              /bin/sleep 1
            done
          ) &
          watcher_pid=$!

          wait "$login_pid"
          login_status=$?
          /bin/kill -TERM "$watcher_pid" 2>/dev/null
          wait "$watcher_pid" 2>/dev/null
          login_pid=""
          login_group=""
          watcher_pid=""
          if [ -e "$TIMEOUT" ]; then
            return 124
          fi
          if [ -e "$CANCEL" ]; then
            return 130
          fi
          return "$login_status"
        }

        if [ ! -x /usr/bin/setsid ]; then
          status=125
        elif [ -e "$CANCEL" ]; then
          status=130
        else
          run_login \(first)
          status=$?
          if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$status" -ne 130 ] && [ "$status" -ne 143 ]; then
            run_login \(second)
            status=$?
          fi
        fi

        write_marker "$status"
        exit "$status"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try BurnBarProviderExternalAuthLinuxTerminalLauncher.prepareStartedSentinel(
            scriptURL: scriptURL,
            fileManager: fileManager
        )
        return scriptURL
    }

    private func persist(_ flow: PersistedFlow) throws {
        try prepareRootDirectory()
        if (try? fileManager.attributesOfItem(atPath: stateURL.path)) != nil,
           !Self.isSafeRegularFile(stateURL, fileManager: fileManager) {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(flow)
        try data.write(to: stateURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private static func loadPersistedFlow(from url: URL, fileManager: FileManager) -> PersistedFlow? {
        let rootURL = url.deletingLastPathComponent()
        guard isSafeDirectory(rootURL, fileManager: fileManager),
              isSafeRegularFile(url, fileManager: fileManager),
              let stateAttributes = try? fileManager.attributesOfItem(atPath: url.path),
              ((stateAttributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 64 * 1_024 else {
            return nil
        }
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let flow = try? decoder.decode(PersistedFlow.self, from: data),
              isValidPersistedFlow(flow) else {
            return nil
        }
        let sessionsURL = rootURL.appendingPathComponent(sessionDirectoryName, isDirectory: true)
        let sessionURL = sessionsURL.appendingPathComponent(flow.flowID, isDirectory: true)
        guard isSafeDirectory(sessionsURL, fileManager: fileManager),
              isSafeDirectory(sessionURL, fileManager: fileManager) else {
            return nil
        }
        return flow
    }

    private func writeCancelSentinel(for flow: PersistedFlow) throws {
        guard let directory = safeSessionURL(for: flow) else {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        let url = directory.appendingPathComponent(Self.cancelFileName, isDirectory: false)
        if (try? fileManager.attributesOfItem(atPath: url.path)) != nil,
           !Self.isSafeRegularFile(url, fileManager: fileManager) {
            throw BurnBarProviderExternalAuthTerminalLaunchError.failed
        }
        try Data().write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readExitStatus(for flow: PersistedFlow) -> Int32? {
        guard let directory = safeSessionURL(for: flow) else { return nil }
        let markerURL = directory.appendingPathComponent(Self.markerFileName, isDirectory: false)
        guard Self.isSafeRegularFile(markerURL, fileManager: fileManager),
              let markerAttributes = try? fileManager.attributesOfItem(atPath: markerURL.path),
              ((markerAttributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32,
              let data = fileManager.contents(atPath: markerURL.path),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let status = Int32(raw) else {
            return nil
        }
        return status
    }

    private func sessionURL(for flow: PersistedFlow) -> URL {
        rootDirectoryURL
            .appendingPathComponent(Self.sessionDirectoryName, isDirectory: true)
            .appendingPathComponent(flow.flowID, isDirectory: true)
    }

    private func markerURL(for flow: PersistedFlow) -> URL {
        sessionURL(for: flow).appendingPathComponent(Self.markerFileName, isDirectory: false)
    }

    private func startedURL(for flow: PersistedFlow) -> URL {
        sessionURL(for: flow).appendingPathComponent(Self.startedFileName, isDirectory: false)
    }

    private func cancelURL(for flow: PersistedFlow) -> URL {
        sessionURL(for: flow).appendingPathComponent(Self.cancelFileName, isDirectory: false)
    }

    private func timeoutURL(for flow: PersistedFlow) -> URL {
        sessionURL(for: flow).appendingPathComponent(Self.timeoutFileName, isDirectory: false)
    }

    private func safeSessionURL(for flow: PersistedFlow) -> URL? {
        guard Self.isValidFlowIDValue(flow.flowID),
              Self.isSafeDirectory(rootDirectoryURL, fileManager: fileManager) else {
            return nil
        }
        let sessionsURL = rootDirectoryURL.appendingPathComponent(Self.sessionDirectoryName, isDirectory: true)
        let sessionURL = sessionsURL.appendingPathComponent(flow.flowID, isDirectory: true)
        guard Self.isSafeDirectory(sessionsURL, fileManager: fileManager),
              Self.isSafeDirectory(sessionURL, fileManager: fileManager) else {
            return nil
        }
        return sessionURL
    }

    private func cancelRequested(for flow: PersistedFlow) -> Bool {
        guard let directory = safeSessionURL(for: flow) else { return false }
        return Self.isSafeRegularFile(
            directory.appendingPathComponent(Self.cancelFileName, isDirectory: false),
            fileManager: fileManager
        )
    }

    private func isConnected(_ auth: CLIAuthInfo) -> Bool {
        switch auth.authState {
        case .authenticated, .apiKeyPresent:
            return true
        case .notAuthenticated, .notInstalled:
            return false
        }
    }

    private func isInProgress(_ state: BurnBarProviderExternalAuthState) -> Bool {
        state == .launching || state == .awaitingUser || state == .verifying
    }

    private func isTerminal(_ state: BurnBarProviderExternalAuthState) -> Bool {
        state == .succeeded || state == .failed || state == .cancelled || state == .timedOut
    }

    private func cleanupMayStillBeActive(for flow: PersistedFlow, now: Date) -> Bool {
        guard flow.state == .cancelled || flow.state == .timedOut,
              readExitStatus(for: flow) == nil else {
            return false
        }
        return now < flow.expiresAt.addingTimeInterval(2)
    }

    private func discoverAuth(for resolved: ResolvedMethod) -> CLIAuthInfo {
        let executableURL = dependencies.resolveExecutable(resolved.cliType)
        return dependencies.discoverAuth(resolved.cliType, executableURL)
    }

    private func isValidSelector(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private func isValidOptionalSelector(_ value: String?, maximumLength: Int) -> Bool {
        guard let value else { return true }
        return isValidSelector(value, maximumLength: maximumLength)
    }

    private func isValidFlowID(_ value: String?) -> Bool {
        guard let value else { return false }
        return Self.isValidFlowIDValue(value)
    }

    private func safeResponseSelector(_ value: String?, maximumLength: Int) -> String? {
        guard let value, isValidSelector(value, maximumLength: maximumLength) else { return nil }
        return value
    }

    private static func isValidFlowIDValue(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumFlowIDLength,
              !value.contains("/"),
              !value.contains("\\"),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString == value
    }

    private static func isValidPersistedFlow(_ flow: PersistedFlow) -> Bool {
        guard flow.schemaVersion == PersistedFlow.currentSchemaVersion,
              isValidFlowIDValue(flow.flowID),
              flow.startedAt.timeIntervalSinceReferenceDate.isFinite,
              flow.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              flow.expiresAt >= flow.startedAt,
              flow.expiresAt.timeIntervalSince(flow.startedAt) <= flowLifetime,
              flow.expiresAt.timeIntervalSince(flow.startedAt) > 0 else {
            return false
        }
        if let completedAt = flow.completedAt {
            guard completedAt.timeIntervalSinceReferenceDate.isFinite,
                  completedAt >= flow.startedAt else {
                return false
            }
        }
        guard (flow.verificationStartedAt == nil) == (flow.verificationDeadline == nil) else {
            return false
        }
        if let verificationStartedAt = flow.verificationStartedAt,
           let verificationDeadline = flow.verificationDeadline {
            guard verificationStartedAt.timeIntervalSinceReferenceDate.isFinite,
                  verificationDeadline.timeIntervalSinceReferenceDate.isFinite,
                  verificationStartedAt >= flow.startedAt,
                  verificationDeadline > verificationStartedAt,
                  verificationDeadline.timeIntervalSince(verificationStartedAt) <= verificationGrace,
                  flow.completedAt.map({ $0 >= verificationStartedAt }) ?? true else {
                return false
            }
            let verificationStateIsValid = flow.state == .verifying
                || flow.state == .succeeded
                || (flow.state == .failed && flow.problem?.code == .verificationFailed)
            guard verificationStateIsValid else { return false }
        } else if flow.state == .verifying {
            return false
        }

        let methodMatchesCLI = switch (flow.providerID, flow.authMethodID, flow.cliType) {
        case ("openai", "openai-codex-oauth", .codex),
             ("anthropic", "anthropic-claude-code-login", .claude):
            true
        default:
            false
        }
        guard methodMatchesCLI else { return false }

        let terminal = flow.state == .succeeded
            || flow.state == .failed
            || flow.state == .cancelled
            || flow.state == .timedOut
        guard terminal == (flow.completedAt != nil) else { return false }
        return flow.state == .succeeded ? flow.verifiedConnected : !flow.verifiedConnected
    }

    private static func isSafeDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeDirectory
    }

    private static func isSafeRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func problem(
        code: BurnBarProviderExternalAuthProblemCode,
        message: String,
        recoverable: Bool
    ) -> BurnBarProviderExternalAuthProblem {
        BurnBarProviderExternalAuthProblem(code: code, message: message, recoverable: recoverable)
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
