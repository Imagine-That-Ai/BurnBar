import OpenBurnBarCore
import Foundation

extension BurnBarProviderRouter {
    public func markRouteFailure(
        _ route: BurnBarProviderRoute,
        error: Error
    ) async {
        guard let slotID = route.credentialSlotID else { return }
        let now = Date()
        let cooldown = Calendar.current.date(byAdding: .minute, value: 5, to: now)
        var status: BurnBarProviderCredentialSlotStatus?
        var cooldownUntil: Date?
        if let providerError = error as? BurnBarProviderExecutorError,
           let statusAndBody = providerError.upstreamStatusAndBody {
            let statusCode = statusAndBody.statusCode
            let body = statusAndBody.body
            if FactoryDroidProviderExecutor.isStrictStandardUsageExhaustion(error: error, route: route) {
                return
            }
            let lowerBody = body.lowercased()
            if BurnBarProviderExecutorError.isTransientCapacityFailure(statusCode: statusCode, body: body) {
                status = .coolingDown; cooldownUntil = Calendar.current.date(byAdding: .minute, value: 1, to: now)
            } else if statusCode == 401 || statusCode == 403 {
                status = .missingSecret
                cooldownUntil = nil
            } else if statusCode == 402
                || lowerBody.contains("quota")
                || lowerBody.contains("insufficient") || lowerBody.contains("exhaust") {
                status = .exhausted
                cooldownUntil = nil
            } else if statusCode == 429 || lowerBody.contains("rate limit") || lowerBody.contains("rate_limit") {
                if Self.shouldPreserveSlotAvailabilityForRateLimit(route) {
                    return
                }
                status = .coolingDown
                cooldownUntil = cooldown
            } else {
                return
            }
        } else {
            if FactoryDroidProviderExecutor.isStrictStandardUsageExhaustion(error: error, route: route) {
                return
            }
            let lowercasedDescription = error.localizedDescription.lowercased()
            if lowercasedDescription.contains("quota")
                || lowercasedDescription.contains("insufficient") || lowercasedDescription.contains("exhaust") {
                status = .exhausted
                cooldownUntil = nil
            } else if lowercasedDescription.contains("rate limit")
                || lowercasedDescription.contains("rate_limit")
                || lowercasedDescription.contains("429") {
                if Self.shouldPreserveSlotAvailabilityForRateLimit(route) {
                    return
                }
                status = .coolingDown
                cooldownUntil = cooldown
            } else if Self.isLocalOllamaConnectivityFailure(error, route: route) {
                status = .coolingDown
                cooldownUntil = cooldown
            } else if lowercasedDescription.contains("401")
                || lowercasedDescription.contains("403")
                || lowercasedDescription.contains("invalid api key") {
                status = .missingSecret
                cooldownUntil = nil
            } else {
                return
            }
        }

        guard let status else { return }
        do {
            try await configStore.updateCredentialSlotStatus(
                providerID: route.providerID,
                slotID: slotID,
                status: status,
                cooldownUntil: cooldownUntil,
                message: error.localizedDescription
            )
        } catch {
            logger.silentFailure("update_credential_slot_status_failure", error: error)
        }
    }

    private static func shouldPreserveSlotAvailabilityForRateLimit(_ route: BurnBarProviderRoute) -> Bool {
        guard route.providerID.caseInsensitiveCompare("anthropic") == .orderedSame,
              route.formatFamily == .anthropic else {
            return false
        }

        let normalizedKey = route.apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedKey.hasPrefix("sk-ant-oat")
    }

    private static func isLocalOllamaConnectivityFailure(_ error: Error, route: BurnBarProviderRoute) -> Bool {
        guard route.providerID.caseInsensitiveCompare("ollama-local") == .orderedSame else {
            return false
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut, .cannotLoadFromNetwork:
                return true
            default:
                break
            }
        }

        let lowercasedDescription = error.localizedDescription.lowercased()
        return lowercasedDescription.contains("cannot connect")
            || lowercasedDescription.contains("connection refused")
            || lowercasedDescription.contains("timed out")
    }

    public func markRouteSuccess(_ route: BurnBarProviderRoute) async {
        guard let slotID = route.credentialSlotID else { return }
        do {
            try await configStore.updateCredentialSlotStatus(
                providerID: route.providerID,
                slotID: slotID,
                status: .ready,
                cooldownUntil: nil,
                message: nil
            )
        } catch {
            logger.silentFailure("update_credential_slot_status_success", error: error)
        }
    }
}
