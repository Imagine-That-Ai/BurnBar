import Foundation
import OpenBurnBarEngine

/// Picks a live provider route for the inbox analyst / reply path.
///
/// The config pin is tried first — pinning is still load-bearing, because an
/// unpinned `route(modelName:)` will otherwise prefer a $0 local model with
/// the same name and silently change both behavior and accounting.
///
/// A dead pin must not take the whole inbox down with it. "Analyst could not
/// run" used to mean "DeepSeek is missing credentials" even when OpenAI, Z.ai,
/// Codex, or another live provider could have written the brief. After the pin
/// is skipped (no live row — do not score the catalog) we walk every enabled
/// provider that can actually route, including local CLI providers.
enum BurnBarAIInboxRouteResolver {
    struct Attempt: Hashable, Sendable {
        let providerID: String?
        let modelName: String
    }

    /// First route that exists and is allowed to leave this Mac.
    ///
    /// Throws `BurnBarAIInboxAnalystError.egressRefused` when at least one
    /// route resolved but every one of them violated egress — that is the
    /// privacy failure, and it must not be rewritten as "unsupported model".
    /// Throws the first routing error when nothing resolved at all.
    static func firstRoutable(
        router: BurnBarProviderRouter,
        config: BurnBarInboxConfig,
        logger: BurnBarDaemonLogger,
        role: String
    ) async throws -> BurnBarProviderRoute {
        let configurations = (try? await router.configStore.resolvedConfigurations()) ?? []
        var firstRoutingError: Error?
        var firstEgressError: BurnBarAIInboxAnalystError?
        var triedRoutes = Set<String>()

        for attempt in attempts(config: config, configurations: configurations) {
            if let skip = skipReason(for: attempt, configurations: configurations) {
                if firstRoutingError == nil { firstRoutingError = skip }
                continue
            }

            let route: BurnBarProviderRoute
            do {
                route = try await router.route(
                    modelName: attempt.modelName,
                    preferredProviderID: attempt.providerID
                )
            } catch {
                if firstRoutingError == nil { firstRoutingError = error }
                continue
            }

            let routeKey = "\(route.providerID)|\(route.resolvedModelID)|\(route.baseURL)"
            guard triedRoutes.insert(routeKey).inserted else { continue }

            let decision = BurnBarAIInboxEgressGuard.evaluate(
                baseURL: route.baseURL,
                mode: config.egressMode
            )
            if case .refused(let reason) = decision {
                logger.warning(
                    "ai_inbox_route_egress_refused",
                    metadata: ["reason": reason, "route": routeKey, "role": role]
                )
                if firstEgressError == nil {
                    firstEgressError = .egressRefused(reason)
                }
                continue
            }

            let pinned = "\(config.analystProviderID):\(config.analystModel)"
            let used = "\(route.providerID):\(route.resolvedModelID)"
            if used != pinned {
                logger.info(
                    "ai_inbox_route_fallback",
                    metadata: [
                        "pinned": pinned,
                        "used": used,
                        "role": role
                    ]
                )
            }
            return route
        }

        if let firstEgressError {
            throw firstEgressError
        }
        if let firstRoutingError {
            throw firstRoutingError
        }
        throw BurnBarProviderRouterError.unsupportedModel(config.analystModel)
    }

    static func attempts(
        config: BurnBarInboxConfig,
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> [Attempt] {
        var seen = Set<String>()
        var ordered: [Attempt] = []

        func add(_ providerID: String?, _ modelName: String) {
            let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard model.isEmpty == false else { return }
            let key = "\(providerID ?? "*")|\(model)"
            guard seen.insert(key).inserted else { return }
            ordered.append(Attempt(providerID: providerID, modelName: model))
        }

        add(config.analystProviderID, config.analystModel)
        add(config.verifierProviderID, config.verifierModel)

        for configuration in configurations where isRoutable(configuration) {
            for model in configuration.preferredModels {
                add(configuration.provider.id, model.id)
            }
            for modelID in configuration.settings.preferredModelIDs {
                add(configuration.provider.id, modelID)
            }
        }
        return ordered
    }

    /// Local CLI providers (Codex, Ollama) are routable without an API key.
    /// Cloud providers need a stored credential. Disabled rows never run.
    static func isRoutable(_ configuration: BurnBarResolvedProviderConfiguration) -> Bool {
        configuration.settings.isEnabled && (configuration.provider.local || configuration.hasCredential)
    }

    /// Do not ask the five-dimension scorer to hunt a provider that is not
    /// actually live. A dead DeepSeek pin used to spend ~90s ranking the
    /// whole catalog before the walk reached a working route.
    static func skipReason(
        for attempt: Attempt,
        configurations: [BurnBarResolvedProviderConfiguration]
    ) -> Error? {
        guard let providerID = attempt.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              providerID.isEmpty == false else {
            return BurnBarProviderRouterError.unsupportedModel(attempt.modelName)
        }
        guard let configuration = configurations.first(where: {
            $0.provider.id.caseInsensitiveCompare(providerID) == .orderedSame
        }) else {
            return BurnBarProviderRouterError.unsupportedProvider(providerID)
        }
        if configuration.settings.isEnabled == false {
            return BurnBarProviderRouterError.providerDisabled(providerID)
        }
        if isRoutable(configuration) == false {
            return BurnBarProviderRouterError.missingCredential(providerID)
        }
        return nil
    }
}
