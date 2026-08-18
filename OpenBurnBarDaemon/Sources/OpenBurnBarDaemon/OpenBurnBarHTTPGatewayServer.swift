import OpenBurnBarEngine
import CryptoKit
import Dispatch
import Foundation
import Network

/// HTTP gateway server exposing OpenAI-compatible endpoints through the daemon
/// provider router. Built on `Network.framework`, not raw sockets.
public actor BurnBarHTTPGatewayServer {
    static let listenerQueueLabel = "com.openburnbar.daemon.http-gateway.listener"

    static let maxHeaderBytes = 16 * 1024

    static let maxBodyBytes = 64 * 1024 * 1024

    /// Provider discovery is expensive and changes infrequently. Cache only
    /// that discovery layer for ten minutes; quota, health, enablement, and
    /// route eligibility are reprojected from current config on every read.
    public static let defaultModelCatalogCacheTTL: TimeInterval = 10 * 60

    let configuration: BurnBarGatewayConfiguration

    let configStore: BurnBarConfigStore

    let usageRecorder: BurnBarUsageRecorder?

    let proxyRouteLogStore: BurnBarProxyRouteLogStore?

    let quotaSignalStore: BurnBarQuotaSignalStore?

    let providerExecutor: BurnBarOpenAICompatibleProviderExecutor

    let anthropicExecutor: BurnBarAnthropicProviderExecutor

    let factoryExecutor: FactoryDroidProviderExecutor

    /// Opt-in, off-by-default cross-vendor degrade safety net (Part B3). When
    /// enabled, an OpenAI-chat request whose requested model is unavailable can
    /// fall back to an allow-listed OpenAI-compatible vendor on the user's own
    /// key instead of hard-failing.
    let crossVendorDegradePolicy: BurnBarCrossVendorDegradePolicy

    let modelHealthStore: BurnBarGatewayModelHealthStore

    /// Shared across Elder Wand requests so panel members using one credential
    /// cannot trigger avoidable provider concurrency limits.
    let elderWandPanelExecutionGate = ElderWandPanelExecutionGate()

    /// Owns the expensive live model-catalog snapshot (+ optional TTL cache) and
    /// the advertisement-eligibility predicate, consumed by `/v1/models` and the
    /// routing path through one narrow interface. Replaces the inline catalog
    /// session / droid runner / cache-TTL / cached-snapshot fields.
    let catalogSource: GatewayModelCatalogSource

    let logger: any BurnBarDaemonLogging

    let rateLimiter: BurnBarRateLimiter?

    /// remediation(loopback-c): a dedicated, stricter rate limiter that bounds
    /// tokenless callers SPECIFICALLY while the unauthenticated-loopback escape
    /// hatch is live (no enforced auth token). It is consulted only when auth is
    /// off, so it can never tighten the limit for authenticated callers. Non-nil
    /// only when the escape hatch is live (see `effectiveUnauthenticatedLoopbackRateLimit`),
    /// which keeps the fail-closed bound on by default whenever the hatch is used
    /// — even in production, where no general gateway `rateLimiter` is wired.
    let unauthenticatedLoopbackRateLimiter: BurnBarRateLimiter?

    /// Listener readiness is launch-critical. A dedicated queue prevents an
    /// unrelated backlog on the process-wide utility pool from delaying the
    /// bind long enough for the daemon or release smoke to declare the gateway
    /// unavailable. Connection work immediately hops back into structured
    /// Swift tasks, so this queue stays idle when the gateway is idle.
    let listenerQueue: DispatchQueue

    var listener: NWListener?

    public init(
        configuration: BurnBarGatewayConfiguration,
        configStore: BurnBarConfigStore,
        usageRecorder: BurnBarUsageRecorder? = nil,
        proxyRouteLogStore: BurnBarProxyRouteLogStore? = nil,
        quotaSignalStore: BurnBarQuotaSignalStore? = nil,
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor(),
        factoryExecutor: FactoryDroidProviderExecutor = FactoryDroidProviderExecutor(),
        crossVendorDegradePolicy: BurnBarCrossVendorDegradePolicy = .fromEnvironment(),
        modelHealthStore: BurnBarGatewayModelHealthStore = BurnBarGatewayModelHealthStore(),
        modelCatalogSession: URLSession = .shared,
        modelCatalogDroidProcessRunner: any FactoryDroidProcessRunning = FactoryDroidSystemProcessRunner(),
        modelCatalogCacheTTL: TimeInterval = 0,
        logger: any BurnBarDaemonLogging = BurnBarDaemonLogger(category: "http-gateway"),
        rateLimiter: BurnBarRateLimiter? = nil,
        listenerQueue: DispatchQueue? = nil
    ) {
        self.configuration = configuration
        self.configStore = configStore
        self.usageRecorder = usageRecorder
        self.proxyRouteLogStore = proxyRouteLogStore
        self.quotaSignalStore = quotaSignalStore
        self.providerExecutor = providerExecutor
        self.anthropicExecutor = anthropicExecutor
        self.factoryExecutor = factoryExecutor
        self.crossVendorDegradePolicy = crossVendorDegradePolicy
        self.modelHealthStore = modelHealthStore
        self.catalogSource = GatewayModelCatalogSource(
            configStore: configStore,
            session: modelCatalogSession,
            droidProcessRunner: modelCatalogDroidProcessRunner,
            modelHealthStore: modelHealthStore,
            cacheTTL: modelCatalogCacheTTL,
            logger: logger
        )
        self.logger = logger
        self.listenerQueue = listenerQueue ?? DispatchQueue(
            label: Self.listenerQueueLabel,
            qos: .userInitiated
        )
        self.rateLimiter = rateLimiter ?? configuration.rateLimit.map {
            BurnBarRateLimiter(configuration: $0)
        }
        // Bound the tokenless-loopback escape hatch independently of the
        // optional general limiter.
        self.unauthenticatedLoopbackRateLimiter = configuration
            .effectiveUnauthenticatedLoopbackRateLimit
            .map { BurnBarRateLimiter(configuration: $0) }
    }

    public func start() throws {
        guard listener == nil else { return }
        guard configuration.isEnabled else {
            logger.debug("gateway_disabled", metadata: [:])
            return
        }
        if let error = configuration.validationError {
            logger.error("gateway_config_invalid", metadata: ["error": error])
            throw BurnBarHTTPGatewayError.invalidConfiguration(error)
        }

        let host = configuration.normalizedHost
        let port = UInt16(configuration.port)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: params)
        } catch {
            throw BurnBarHTTPGatewayError.listenerCreationFailed(error: error)
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }

        let boundPort = self.configuration.port
        nwListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                BurnBarDaemonMetricsCounters.recordGatewayListenerReady()
                // Match the request-path enforcement: a whitespace-only token is
                // treated as no token at all (see `handleRequest`), so auth is
                // only "on" when a non-empty token is present.
                let authEnforced = self.configuration.authToken?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil
                self.logger.notice("gateway_started", metadata: [
                    "host": host,
                    "port": "\(boundPort)",
                    "auth_required": "\(authEnforced)"
                ])
                // remediation(loopback hardening): when the gateway is reachable
                // with NO bearer check, any same-host process can drive the
                // credential-spending proxy. The bind is already constrained to
                // loopback (validationError rejects non-loopback + wildcard
                // binds without a token), but this state must never be silent —
                // emit a loud, explicit startup WARNING so an operator can see
                // that the unauthenticated escape hatch is live.
                if !authEnforced {
                    self.logger.warning("gateway_auth_disabled_loopback", metadata: [
                        "host": host,
                        "port": "\(boundPort)",
                        "is_loopback": "\(self.configuration.isLoopback)",
                        "allow_unauthenticated_loopback": "\(self.configuration.allowUnauthenticatedLoopback)",
                        "reason": "Gateway is serving the credential-spending proxy with NO auth token; any local "
                            + "process can spend the user's provider credits. Set an auth token to fail closed."
                    ])
                }
                if !self.configuration.isLoopback {
                    self.logger.warning("gateway_non_loopback_bind", metadata: [
                        "host": host,
                        "port": "\(boundPort)"
                    ])
                }
            case .failed(let error):
                let reason = Self.listenerFailureReason(error, host: host, port: boundPort)
                BurnBarDaemonMetricsCounters.recordGatewayListenerFailure(reason)
                self.logger.error("gateway_listener_failed", metadata: [
                    "host": host,
                    "port": "\(boundPort)",
                    "reason": reason,
                    "error": "\(error)"
                ])
                // Tear the failed listener down so it is not left as a silent
                // zombie (a non-nil `listener` makes future `start()` calls
                // no-op). Clearing it lets a daemon restart rebind cleanly once
                // the conflicting process releases the port.
                Task { await self.handleListenerFailure() }
            default:
                break
            }
        }

        self.listener = nwListener
        nwListener.start(queue: listenerQueue)
    }

    /// Tears down a listener that transitioned to `.failed` so the gateway does
    /// not sit bound-but-not-serving with a stale `listener` reference.
    func handleListenerFailure() {
        listener?.cancel()
        listener = nil
    }

    /// Builds an operator-facing reason string for a listener bind failure,
    /// special-casing address-in-use (the common "port 8317 already taken"
    /// case) so the remediation is obvious in logs and on `GET /metrics`.
    nonisolated static func listenerFailureReason(_ error: NWError, host: String, port: Int) -> String {
        if case let .posix(code) = error, code == .EADDRINUSE {
            return "gateway port \(port) on \(host) is already in use by another process — the gateway is not serving"
        }
        if case let .posix(code) = error, code == .EACCES {
            return "permission denied binding gateway port \(port) on \(host)"
        }
        return "gateway listener on \(host):\(port) failed: \(error.localizedDescription)"
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        logger.notice("gateway_stopped", metadata: [:])
    }
}

// remediation(gateway decomposition): `BurnBarHTTPGatewayError` moved verbatim
// to OpenBurnBarHTTPGatewayError.swift (same directory, auto-included by the
// XcodeGen/SwiftPM source glob). No behavior change.
