import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Result of an OpenAI-compatible `/v1/models` probe. `available` and
/// `authRejected` are mutually exclusive: `available` means the catalog was
/// readable, while `authRejected` means a 401/403 answer proved a gateway is
/// up but rejected the presented key.
struct OpenAICompatibleModelProbeResult: Sendable {
    var available: Bool
    var authRejected: Bool = false
    var modelName: String?
    var hermesModels: [HermesAdvertisedModel] = []
    var models: [OpenAICompatibleAdvertisedModel] = []
}

enum OpenAICompatibleModelProbe {
    static func modelsURL(baseURL: URL) -> URL? {
        URL(string: "v1/models", relativeTo: baseURL)?.absoluteURL
    }

    static func modelsRequest(baseURL: URL, bearerToken: String?, timeout: TimeInterval = 2) -> URLRequest? {
        guard let url = modelsURL(baseURL: baseURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func probe(baseURL: URL, bearerToken: String?, timeout: TimeInterval = 2, session: URLSession = .shared) async -> Bool {
        await probeWithModel(baseURL: baseURL, bearerToken: bearerToken, timeout: timeout, session: session).available
    }

    /// `/health` endpoint for the gateway, derived by replacing the path (mirrors
    /// `ChatSessionController.hermesHealthReachable`). A gateway that just cold-
    /// started answers this immediately, even while its `/v1/models` catalog is
    /// still warming up from upstream providers.
    static func healthURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/health"
        components.query = nil
        return components.url
    }

    /// Lightweight liveness probe: GET `/health`. This is the truth source for
    /// "is the gateway up?" independent of whether its model catalog can be read
    /// yet — so a slow/transient `/v1/models` never makes a running gateway look
    /// offline.
    static func healthReachable(
        baseURL: URL,
        bearerToken: String?,
        timeout: TimeInterval = 3,
        session: URLSession = .shared
    ) async -> Bool {
        guard let url = healthURL(baseURL: baseURL) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    static func probeWithModel(
        baseURL: URL,
        bearerToken: String?,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> (available: Bool, modelName: String?) {
        let result = await probeWithModels(baseURL: baseURL, bearerToken: bearerToken, timeout: timeout, session: session)
        return (result.available, result.modelName)
    }

    /// `probeWithModel` plus the auth verdict, for callers that must distinguish
    /// "gateway down" from "gateway up but the key was rejected" (a 401/403
    /// proves a server is answering, so relaunching it would fork a duplicate).
    static func probeWithModelAuth(
        baseURL: URL,
        bearerToken: String?,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> (available: Bool, authRejected: Bool, modelName: String?) {
        let result = await probeWithModels(baseURL: baseURL, bearerToken: bearerToken, timeout: timeout, session: session)
        return (result.available, result.authRejected, result.modelName)
    }

    /// hermes-agent (≥0.17) answers 401 `invalid_api_key` when `API_SERVER_KEY`
    /// is required and the bearer is missing/stale; generic gateways use 403 too.
    static func isAuthRejectedStatus(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    static func probeWithModels(
        baseURL: URL,
        bearerToken: String?,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> OpenAICompatibleModelProbeResult {
        guard let request = modelsRequest(baseURL: baseURL, bearerToken: bearerToken, timeout: timeout) else {
            return OpenAICompatibleModelProbeResult(available: false)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return OpenAICompatibleModelProbeResult(available: false)
            }
            guard (200...299).contains(http.statusCode) else {
                return OpenAICompatibleModelProbeResult(
                    available: false,
                    authRejected: isAuthRejectedStatus(http.statusCode)
                )
            }
            return OpenAICompatibleModelProbeResult(
                available: true,
                modelName: OpenAICompatibleModelListParser.modelName(from: data),
                hermesModels: OpenAICompatibleModelListParser.hermesAdvertisedModels(from: data),
                models: OpenAICompatibleModelListParser.advertisedModels(from: data)
            )
        } catch {
            return OpenAICompatibleModelProbeResult(available: false)
        }
    }
}
