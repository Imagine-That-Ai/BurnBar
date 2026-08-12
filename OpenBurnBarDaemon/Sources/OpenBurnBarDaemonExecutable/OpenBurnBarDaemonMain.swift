import OpenBurnBarDaemon
import OpenBurnBarEngine
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

#if canImport(Sentry)
import Sentry
#endif

@main
struct OpenBurnBarDaemonExecutable {
    static func main() async throws {
        // Safari hand-off containment helpers are deliberately tiny subprocess
        // modes, not second daemons. Handle them before caches, telemetry,
        // credentials, code-signature policy, or socket configuration.
        if SafariHandoffProcessSentinel.runIfRequested(
            arguments: Array(CommandLine.arguments.dropFirst())
        ) {
            return
        }
        if SafariHandoffProcessWatchdog.runIfRequested(
            arguments: Array(CommandLine.arguments.dropFirst())
        ) {
            return
        }

        // Disable the shared URLCache disk store. URLSession.shared uses a
        // persistent disk cache at ~/Library/Caches/OpenBurnBarDaemon/Cache.db
        // that is prone to SQLite WAL corruption when the daemon is restarted
        // by launchd while the cache is still active.  A nil URLCache forces
        // all URLSession.shared requests to use an in-memory or no-cache policy,
        // preventing the disk I/O error loop that blocks the socket RPC thread.
        #if canImport(Darwin)
        URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
        #endif

        #if canImport(Sentry)
        try configureSentryIfAvailable(environment: ProcessInfo.processInfo.environment)
        #endif
        let configuration = try BurnBarDaemonCommandLine.makeConfiguration(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: ProcessInfo.processInfo.environment
        )
        try configuration.validate()
        let logger = BurnBarDaemonLogger(category: "process")
        let peerAuthenticator = makePeerAuthenticator(
            environment: ProcessInfo.processInfo.environment,
            logger: logger
        )

        // T-DMN-03: before binding the control socket, re-verify the daemon's own
        // on-disk image against the first-party designated requirement. Enforced
        // exactly when the peer-codesig gate is enforced (signed production
        // builds), so a same-uid attacker who swapped the user-writable installed
        // binary cannot bring up a foreign image that serves the full RPC/HID
        // surface. The install-location change (root-owned SMAppService) lives in
        // the app/installer and is tracked Deferred.
        #if canImport(Darwin)
        let selfVerifier = DaemonSelfCodeSignatureVerifier(enforced: peerAuthenticator.isEnforced, logger: logger)
        do {
            try selfVerifier.verify()
        } catch {
            logger.error(
                "daemon_self_verification_failed_refusing_start",
                metadata: ["error": "\(error)"]
            )
            throw error
        }
        #endif

        // T-DMN-04: production daemons independently re-verify high-risk Computer
        // Use local-auth proofs against the daemon-owned pinned phone-key store.
        // Enforcement is bound to the same production code-signature gate as
        // socket peer authentication: signed builds fail closed, while unsigned
        // developer builds keep the compatibility no-op.
        let localAuthProofSetup = DaemonLocalAuthProofVerifier.production(
            enforced: peerAuthenticator.isEnforced,
            logger: BurnBarDaemonLogger(category: "local-auth-proof")
        )
        #if os(Linux)
        let linuxCloudCredentialAuthority = LinuxDaemonCloudCredentialAuthority.production(
            environment: ProcessInfo.processInfo.environment
        )
        let linuxCredentialProvider: LinuxIrohControllerCredentialProvider = {
            try await linuxCloudCredentialAuthority.credentialContext()
        }
        let linuxCloudSyncRuntime = LinuxCloudSyncRuntimeFactory.makeProduction(
            configuration: configuration,
            credentialAuthority: linuxCloudCredentialAuthority,
            environment: ProcessInfo.processInfo.environment,
            logger: BurnBarDaemonLogger(category: "cloud-sync")
        )
        #else
        let linuxCloudCredentialAuthority: LinuxDaemonCloudCredentialAuthority? = nil
        let linuxCredentialProvider: LinuxIrohControllerCredentialProvider? = nil
        let linuxCloudSyncRuntime: LinuxCloudSyncRuntime? = nil
        #endif
        let server = BurnBarDaemonServer(
            configuration: configuration,
            logger: logger,
            peerAuthenticator: peerAuthenticator,
            localAuthProofVerifier: localAuthProofSetup.verifier,
            phoneControlPinStore: localAuthProofSetup.pinStore,
            linuxIrohControllerCredentialProvider: linuxCredentialProvider,
            linuxCloudCredentialAuthority: linuxCloudCredentialAuthority,
            linuxCloudSyncRuntime: linuxCloudSyncRuntime
        )
        #if os(Linux)
        await linuxCloudCredentialAuthority.setLifecycleHandler { event in
            await server.handleLinuxCloudAuthSessionEvent(event)
        }
        await linuxCloudCredentialAuthority.setTeardownHandler { credentials in
            await server.handleLinuxCloudAuthTeardown(credentials: credentials)
        }
        #endif
        let pensieveWatcher = makePensieveKnowledgeWatcher(
            environment: ProcessInfo.processInfo.environment,
            logger: logger
        )
        pensieveWatcher?.start()

        try await server.start()

        logger.notice(
            "process_ready",
            metadata: [
                "socket_path": configuration.socketPath,
                "daemon_version": configuration.daemonVersion
            ]
        )

        let signal = await BurnBarSignalMonitor(signals: [SIGINT, SIGTERM]).waitForSignal()
        logger.notice("shutdown_signal_received", metadata: ["signal": "\(signal)"])
        pensieveWatcher?.stop()
        await server.stop()
    }
}

/// RR-3 / T-DMN-05: build the control-socket peer authenticator for this process.
///
/// Enforcement of the first-party code-signature gate is ON by default — a
/// production daemon refuses any accepted peer that does not satisfy the
/// canonical designated requirement.
///
/// T-DMN-05: the `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1` escape hatch (used
/// by unsigned developer builds where no binary can carry the first-party
/// identity) is compiled out of release/distribution builds behind `#if DEBUG`.
/// An attacker who controls the daemon's launch environment can no longer strip
/// the gate by exporting the variable: in a release build the env value is never
/// read, so the authenticator is unconditionally `enforced: true`. In DEBUG the
/// opt-out remains and is logged loudly so a misconfiguration is never silent.
private func makePeerAuthenticator(
    environment: [String: String],
    logger: BurnBarDaemonLogger
) -> BurnBarDaemonPeerAuthenticator {
    let enforced = BurnBarDaemonPeerAuthenticator.resolveEnforcementForCurrentBuild(
        environment: environment
    )
    if !enforced {
        // Only reachable in a DEBUG build where the opt-out is compiled in; log
        // loudly so a misconfiguration is never silent. In release builds
        // `resolveEnforcementForCurrentBuild` always returns `true`, so a hostile
        // launch environment cannot strip the first-party code-signature gate.
        logger.warning(
            "rpc_peer_code_signature_enforcement_disabled",
            metadata: ["reason": "OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1 (DEBUG-only opt-out)"]
        )
        return .disabled
    }
    return BurnBarDaemonPeerAuthenticator(enforced: true, logger: logger)
}

private func makePensieveKnowledgeWatcher(
    environment: [String: String],
    logger: BurnBarDaemonLogger
) -> PensieveKnowledgeWatcher? {
    let repoDocsURL = environment["OPENBURNBAR_PENSIEVE_REPO_DOCS_PATH"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let notesURL = environment["OPENBURNBAR_PENSIEVE_NOTES_PATH"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let roots = PensieveKnowledgeWatcher.standardRoots(
        repoDocsURL: repoDocsURL,
        notesURL: notesURL
    )
    guard roots.isEmpty == false else { return nil }

    let uid = environment["OPENBURNBAR_PENSIEVE_VAULT_UID"] ?? environment["OPENBURNBAR_USER_ID"]
    let trimmedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
    logger.notice(
        "pensieve_watcher_configured",
        metadata: [
            "root_count": "\(roots.count)",
            "vault_uid_present": "\(trimmedUID?.isEmpty == false)"
        ]
    )
    #if canImport(Darwin)
    let keyStore = CloudVaultKeyStore(service: "com.openburnbar.cloud-vault")
    return PensieveKnowledgeWatcher(roots: roots) {
        guard let trimmedUID, trimmedUID.isEmpty == false else { return nil }
        return try? keyStore.loadKey(uid: trimmedUID)
    }
    #else
    return PensieveKnowledgeWatcher(roots: roots, vaultKeyProvider: { nil })
    #endif
}

private enum BurnBarDaemonCommandLine {
    static func makeConfiguration(
        arguments: [String],
        environment: [String: String]
    ) throws -> BurnBarDaemonConfiguration {
        var socketPath = environment["OPENBURNBAR_DAEMON_SOCKET_PATH"]
            ?? environment["BURNBAR_DAEMON_SOCKET_PATH"]
            ?? BurnBarDaemonPaths.defaultSocketPath
        var daemonVersion = environment["OPENBURNBAR_DAEMON_VERSION"]
            ?? environment["BURNBAR_DAEMON_VERSION"]
            ?? BurnBarDaemonVersion.current
        var indexDatabasePath = environment["OPENBURNBAR_INDEX_DATABASE_PATH"]
            ?? environment["BURNBAR_INDEX_DATABASE_PATH"]
        var gatewayEnabled = environment["OPENBURNBAR_GATEWAY_ENABLED"] == "1"
            || environment["BURNBAR_GATEWAY_ENABLED"] == "1"
        var gatewayHost = environment["OPENBURNBAR_GATEWAY_HOST"]
            ?? environment["BURNBAR_GATEWAY_HOST"]
            ?? "127.0.0.1"
        var gatewayPort = Int(environment["OPENBURNBAR_GATEWAY_PORT"]
            ?? environment["BURNBAR_GATEWAY_PORT"]
            ?? "8317") ?? 8317
        var gatewayAuthToken = environment["OPENBURNBAR_GATEWAY_AUTH_TOKEN"]
            ?? environment["BURNBAR_GATEWAY_AUTH_TOKEN"]
        #if DEBUG
        var gatewayAllowUnauthenticatedLoopback = environment["OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK"] == "1"
            || environment["BURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK"] == "1"
        #else
        let gatewayAllowUnauthenticatedLoopback = false
        #endif
        var socketAuthToken = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
            ?? environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--socket-path":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                socketPath = arguments[index]
            case "--index-database-path":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                indexDatabasePath = arguments[index]
            case "--version":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                daemonVersion = arguments[index]
            case "--gateway-enable":
                gatewayEnabled = true
            case "--gateway-host":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                gatewayHost = arguments[index]
            case "--gateway-port":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                gatewayPort = Int(arguments[index]) ?? 8317
            case "--gateway-auth-token":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                gatewayAuthToken = arguments[index]
            case "--gateway-auth-token-file":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                gatewayAuthToken = try readTokenFile(arguments[index], argument: argument)
            case "--gateway-allow-unauthenticated-loopback":
                #if DEBUG
                gatewayAllowUnauthenticatedLoopback = true
                #else
                throw BurnBarDaemonCommandLineError.debugOnlyArgument(argument)
                #endif
            case "--socket-auth-token":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                socketAuthToken = arguments[index]
            case "--socket-auth-token-file":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarDaemonCommandLineError.missingValue(argument)
                }
                socketAuthToken = try readTokenFile(arguments[index], argument: argument)
            case "--help", "-h":
                print(Self.helpText)
                exit(EXIT_SUCCESS)
            default:
                throw BurnBarDaemonCommandLineError.unknownArgument(argument)
            }
            index += 1
        }

        let trimmedIndexPath = indexDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateway = BurnBarGatewayConfiguration(
            isEnabled: gatewayEnabled,
            host: gatewayHost,
            port: gatewayPort,
            authToken: gatewayAuthToken,
            allowUnauthenticatedLoopback: gatewayAllowUnauthenticatedLoopback
        )
        return BurnBarDaemonConfiguration(
            socketPath: socketPath,
            socketAuthToken: socketAuthToken,
            daemonVersion: daemonVersion,
            indexDatabasePath: (trimmedIndexPath?.isEmpty == false) ? trimmedIndexPath : nil,
            gateway: gateway
        )
    }

    private static var helpText: String {
        #if DEBUG
        let debugOptions = """
          --gateway-allow-unauthenticated-loopback
                                       Opt out of gateway auth on a loopback bind (unsafe)
        """
        let debugEnvironment = """
          OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK=1
        """
        #else
        let debugOptions = ""
        let debugEnvironment = ""
        #endif
        return """
        Usage: OpenBurnBarDaemon [OPTIONS]

        Options:
          --socket-path PATH          Unix socket path for RPC
          --index-database-path PATH  SQLite database path for search
          --version VERSION            Daemon version string
          --gateway-enable             Enable the HTTP gateway
          --gateway-host HOST          Gateway bind host (default 127.0.0.1)
          --gateway-port PORT          Gateway port (default 8317)
          --gateway-auth-token TOKEN   Bearer token for gateway auth
          --gateway-auth-token-file PATH
                                       Read gateway auth token from file (avoids ps exposure)
        \(debugOptions)
          --socket-auth-token TOKEN    (Required) Auth token for daemon socket RPC
          --socket-auth-token-file PATH
                                       Read socket auth token from file (avoids ps exposure)

        Environment overrides:
          OPENBURNBAR_DAEMON_SOCKET_PATH
          OPENBURNBAR_DAEMON_VERSION
          OPENBURNBAR_INDEX_DATABASE_PATH
          OPENBURNBAR_GATEWAY_ENABLED=1
          OPENBURNBAR_GATEWAY_HOST
          OPENBURNBAR_GATEWAY_PORT
          OPENBURNBAR_GATEWAY_AUTH_TOKEN
        \(debugEnvironment)
          OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN
        """
    }
}

private enum BurnBarDaemonCommandLineError: Error, LocalizedError {
    case missingValue(String)
    case unknownArgument(String)
    case debugOnlyArgument(String)
    case tokenFileReadFailed(argument: String, path: String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let argument):
            return "Missing value for command-line option \(argument)."
        case .unknownArgument(let argument):
            return "Unknown OpenBurnBarDaemon argument \(argument)."
        case .debugOnlyArgument(let argument):
            return "OpenBurnBarDaemon argument \(argument) is only available in debug builds."
        case .tokenFileReadFailed(let argument, let path):
            return "Could not read token file for \(argument) at path '\(path)': file missing or unreadable."
        }
    }
}

/// Reads an auth token from a file via the shared `readTokenFile` utility in
/// `OpenBurnBarDaemon`. Wraps errors in `BurnBarDaemonCommandLineError` so the
/// CLI surface reports the flag name that triggered the read.
private func readTokenFile(_ path: String, argument: String) throws -> String {
    do {
        return try OpenBurnBarDaemon.readTokenFile(path)
    } catch let BurnBarTokenFileError.fileNotFound(filepath) {
        throw BurnBarDaemonCommandLineError.tokenFileReadFailed(argument: argument, path: filepath)
    } catch let BurnBarTokenFileError.unreadable(filepath, _) {
        throw BurnBarDaemonCommandLineError.tokenFileReadFailed(argument: argument, path: filepath)
    } catch let BurnBarTokenFileError.emptyOrWhitespace(filepath) {
        throw BurnBarDaemonCommandLineError.tokenFileReadFailed(argument: argument, path: filepath)
    }
}

#if canImport(Sentry)
/// remediation(Sentry B2): crash reporting must not fail OPEN silently. When the
/// `OPENBURNBAR_SENTRY_DSN` is missing the daemon runs with NO crash reporting —
/// previously a release daemon could ship that way without any signal. We now
/// mirror the fail-closed-in-prod / quiet-in-dev posture of
/// `functions/src/config.ts`'s App Check handling:
///
///   * Release builds (production posture) emit a loud WARNING that crash
///     reporting is DARK. If the operator has set the strict-observability flag
///     (`OPENBURNBAR_STRICT_OBSERVABILITY=1`), the daemon refuses to start —
///     fail-closed, matching App Check's `throw` in production.
///   * DEBUG builds (developer posture) emit a single clear log line and keep
///     running, so local development is never blocked by a missing DSN.
///
/// The prod-vs-dev decision comes from the existing `#if DEBUG` build signal
/// already used in this function; no new configuration channel is introduced
/// beyond the explicit strict opt-in.
private func configureSentryIfAvailable(environment: [String: String]) throws {
    let logger = BurnBarDaemonLogger(category: "observability")
    let dsn = (environment["OPENBURNBAR_SENTRY_DSN"] ?? environment["BURNBAR_SENTRY_DSN"])?
        .trimmingCharacters(in: .whitespaces)

    guard let dsn, !dsn.isEmpty else {
        #if DEBUG
        // Developer build: a single clear line, never fatal.
        logger.notice(
            "sentry_disabled_no_dsn_dev",
            metadata: ["reason": "OPENBURNBAR_SENTRY_DSN is empty; crash reporting is DARK (dev build)"]
        )
        #else
        let strictObservability = environment["OPENBURNBAR_STRICT_OBSERVABILITY"] == "1"
            || environment["BURNBAR_STRICT_OBSERVABILITY"] == "1"
        if strictObservability {
            // Production posture + strict opt-in: fail closed, refuse to start.
            logger.error(
                "sentry_disabled_no_dsn_strict",
                metadata: ["reason": "OPENBURNBAR_SENTRY_DSN is empty and OPENBURNBAR_STRICT_OBSERVABILITY=1"]
            )
            throw BurnBarObservabilityError.crashReportingDark
        }
        // Production posture, no strict opt-in: loud WARNING, keep running so a
        // user's daemon is not crashed, but the dark state is never silent.
        logger.warning(
            "sentry_disabled_no_dsn",
            metadata: [
                "reason": "OPENBURNBAR_SENTRY_DSN is empty; crash reporting is DARK for this release daemon. "
                    + "Set OPENBURNBAR_SENTRY_DSN to enable, or OPENBURNBAR_STRICT_OBSERVABILITY=1 to refuse "
                    + "to start without it."
            ]
        )
        #endif
        return
    }

    SentrySDK.start { options in
        options.dsn = dsn
        options.environment = "daemon"
        options.releaseName = "openburnbar-daemon@\(BurnBarDaemonVersion.current)"
        options.tracesSampleRate = 0.0
        options.sendDefaultPii = false
        options.beforeSend = { event in
            BurnBarDaemonSentryScrubber.scrub(event)
        }
        options.beforeBreadcrumb = { breadcrumb in
            BurnBarDaemonSentryScrubber.scrub(breadcrumb)
        }
        #if DEBUG
        options.debug = false
        #endif
    }
}

/// Mirrors the app Sentry privacy posture for daemon events: keep crash signal,
/// strip identity, request metadata, user text, paths, and credentials.
private enum BurnBarDaemonSentryScrubber {
    static func scrub(_ event: Event) -> Event? {
        event.user = nil
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: ClientTelemetrySanitizer.sanitizeString(message, key: nil))
        }
        if let extra = event.extra {
            event.extra = ClientTelemetrySanitizer.sanitizeJSONDictionary(extra)
        }
        event.request = nil
        if let crumbs = event.breadcrumbs {
            event.breadcrumbs = crumbs.compactMap { scrub($0) }
        }
        return event
    }

    static func scrub(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        if let message = breadcrumb.message {
            breadcrumb.message = ClientTelemetrySanitizer.sanitizeString(message, key: nil)
        }
        if let data = breadcrumb.data {
            breadcrumb.data = ClientTelemetrySanitizer.sanitizeJSONDictionary(data)
        }
        return breadcrumb
    }
}

/// remediation(Sentry B2): fail-closed error used when strict observability is
/// requested but crash reporting cannot be armed.
private enum BurnBarObservabilityError: Error, LocalizedError {
    case crashReportingDark

    var errorDescription: String? {
        switch self {
        case .crashReportingDark:
            return "Crash reporting is DARK: OPENBURNBAR_SENTRY_DSN is empty while OPENBURNBAR_STRICT_OBSERVABILITY=1. "
                + "Provide a Sentry DSN or clear the strict-observability flag."
        }
    }
}
#endif

// All stored properties are let; DispatchSourceSignal sources are immutable after init.
// Formally Sendable because no mutable state exists post-init; Dispatch types are
// simply not Sendable-annotated in the SDK. sendable-allowlist: foundation-sdk-shim
private final class BurnBarSignalMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let continuation: AsyncStream<Int32>.Continuation
    private let stream: AsyncStream<Int32>
    private let sources: [DispatchSourceSignal]

    init(signals: [Int32]) {
        let queue = DispatchQueue(label: "com.openburnbar.daemon.signal-monitor")
        var storedContinuation: AsyncStream<Int32>.Continuation?
        self.stream = AsyncStream { continuation in
            storedContinuation = continuation
        }
        self.continuation = storedContinuation!
        self.queue = queue
        let continuation = self.continuation

        self.sources = signals.map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [continuation] in
                continuation.yield(signalNumber)
            }
            source.resume()
            return source
        }
    }

    func waitForSignal() async -> Int32 {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? SIGTERM
    }
}
