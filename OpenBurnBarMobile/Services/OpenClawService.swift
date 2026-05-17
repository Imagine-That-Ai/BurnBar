import Foundation
import Observation
import OpenBurnBarCore

enum OpenClawServiceError: LocalizedError {
    case selectedModelUnavailable(String)
    case selectedModelCatalogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .selectedModelUnavailable(let modelID):
            return "Selected OpenClaw model '\(modelID)' is not available on this Mac OpenClaw harness. Pick another model or refresh/restart the Mac OpenClaw gateway."
        case .selectedModelCatalogUnavailable(let modelID):
            return "Selected OpenClaw model '\(modelID)' has not been verified against this Mac OpenClaw harness catalog yet. Refresh the Mac OpenClaw gateway before sending, so the selected model is not silently rerouted."
        }
    }
}

// MARK: - OpenClaw Service
//
// Minimal mobile-side discovery client for the OpenClaw harness running on
// the user's Mac (default gateway `http://127.0.0.1:18789`). OpenClaw is
// already wired as a chat harness via the macOS daemon; we don't host the
// chat surface from mobile yet. What we *do* need is the live model list
// so the assistant model picker can show what the user can actually route
// to via OpenClaw (Ollama-installed local models plus any cloud routes the
// daemon advertises).
//
// Mirrors `PiService`'s reachability + model-discovery shape so the
// `AssistantModelMerger` can plug it into the picker without runtime-
// specific branching beyond the `runtime` switch.

@Observable
@MainActor
final class OpenClawService {
    /// Process-wide shared instance. Long-lived views can construct their
    /// own if they need an isolated state machine.
    static let shared = OpenClawService()

    var modelOptions: [HermesRuntimeModelOption] = []
    var selectedModelID: String?
    var favoriteModelIDs: [String] = []
    var isReachable = false
    var isLoadingRuntime = false
    var runtimeErrorText: String?

    /// Endpoint the daemon serves `/v1/models` on. Defaults to the
    /// canonical OpenClaw gateway declared in `AssistantRuntimeID`. Users
    /// can override via UserDefaults to point at a remote daemon.
    var baseURL: URL {
        if let raw = defaults.string(forKey: baseURLDefaultsKey),
           let url = URL(string: raw) {
            return url
        }
        return AssistantRuntimeID.openClaw.defaultGatewayURL
    }

    var bearerToken: String? {
        defaults.string(forKey: bearerDefaultsKey)
    }

    private let urlSession: URLSession
    private let defaults: UserDefaults

    private let baseURLDefaultsKey = "openClaw.gatewayBaseURL"
    private let bearerDefaultsKey = "openClaw.bearerToken"
    private let selectedModelDefaultsKey = "openClaw.selectedModelID"
    private let favoriteModelsDefaultsKey = "openClaw.favoriteModelIDs"
    private var selectedModelWasExplicit = false

    init(urlSession: URLSession = .shared,
         defaults: UserDefaults = .standard) {
        self.urlSession = urlSession
        self.defaults = defaults
        self.selectedModelID = Self.restoredModelID(
            defaults.string(forKey: selectedModelDefaultsKey),
            defaults: defaults,
            key: selectedModelDefaultsKey
        )
        self.selectedModelWasExplicit = self.selectedModelID?.nonEmpty != nil
        self.favoriteModelIDs = Self.decodeStringArray(
            defaults.string(forKey: favoriteModelsDefaultsKey)
        )
    }

    // MARK: - Public surface

    func refreshRuntime() async {
        isLoadingRuntime = true
        runtimeErrorText = nil
        defer { isLoadingRuntime = false }
        await probeReachability()
        if isReachable {
            await loadModels()
        }
    }

    var favoriteModelOptions: [HermesRuntimeModelOption] {
        modelOptions.filter { favoriteModelIDs.contains($0.modelID) }
    }

    func selectModel(_ option: HermesRuntimeModelOption) {
        let requested = AssistantModelIDCanonicalizer.canonicalized(option.modelID)
        let resolved = !modelOptions.isEmpty
            ? AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(requested, in: modelOptions)
            : requested
        let modelID = resolved ?? requested
        selectedModelID = modelID
        selectedModelWasExplicit = true
        defaults.set(modelID, forKey: selectedModelDefaultsKey)
    }

    func clearSelectedModel() {
        selectedModelID = nil
        selectedModelWasExplicit = false
        defaults.removeObject(forKey: selectedModelDefaultsKey)
    }

    func validatedModelIDForMissionDispatch() throws -> String? {
        guard let selectedModelID = selectedModelID?.nonEmpty else { return nil }
        if selectedModelWasExplicit {
            guard !modelOptions.isEmpty else {
                throw OpenClawServiceError.selectedModelCatalogUnavailable(selectedModelID)
            }
            guard let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: modelOptions) else {
                throw OpenClawServiceError.selectedModelUnavailable(selectedModelID)
            }
            persistResolvedSelectedModelID(resolved)
            return resolved
        }
        return canonicalizedSelectedModelID(selectedModelID)
    }

    func isFavoriteModel(_ option: HermesRuntimeModelOption) -> Bool {
        favoriteModelIDs.contains(option.modelID)
    }

    func toggleFavoriteModel(_ option: HermesRuntimeModelOption) {
        if let index = favoriteModelIDs.firstIndex(of: option.modelID) {
            favoriteModelIDs.remove(at: index)
        } else {
            favoriteModelIDs.append(option.modelID)
        }
        defaults.set(Self.encodeStringArray(favoriteModelIDs),
                     forKey: favoriteModelsDefaultsKey)
    }

    var selectedModelOption: HermesRuntimeModelOption? {
        guard let selectedModelID else { return nil }
        guard let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: modelOptions) else {
            return nil
        }
        return modelOptions.first { $0.modelID == resolved }
    }

    // MARK: - HTTP

    private func probeReachability() async {
        guard let endpoint = URL(string: "v1/models", relativeTo: baseURL) else {
            isReachable = false
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 3)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                isReachable = (200..<300).contains(http.statusCode)
                if !isReachable {
                    runtimeErrorText = "OpenClaw gateway returned HTTP \(http.statusCode)."
                }
            } else {
                isReachable = false
            }
        } catch {
            isReachable = false
            // Quiet failure — OpenClaw is opt-in; surfacing every poll
            // miss as an error would spam the runtime banner.
        }
    }

    private func loadModels() async {
        guard let endpoint = URL(string: "v1/models", relativeTo: baseURL) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 4)
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await urlSession.data(for: request)
            modelOptions = Self.parseModels(data: data)
            if let selectedModelID,
               let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: modelOptions) {
                persistResolvedSelectedModelID(resolved)
                runtimeErrorText = nil
            } else if let selectedModelID, !modelOptions.contains(where: { $0.modelID == selectedModelID && $0.isRouteEligible }) {
                if selectedModelWasExplicit {
                    runtimeErrorText = "Selected OpenClaw model '\(selectedModelID)' is not advertised by this Mac OpenClaw harness. Pick a listed model or refresh the Mac provider catalog."
                } else {
                    self.selectedModelID = favoriteModelOptions.first { $0.isRouteEligible }?.modelID
                        ?? modelOptions.first { $0.isRouteEligible }?.modelID
                        ?? modelOptions.first?.modelID
                    selectedModelWasExplicit = false
                }
            } else if selectedModelID == nil {
                selectedModelID = favoriteModelOptions.first { $0.isRouteEligible }?.modelID
                    ?? modelOptions.first { $0.isRouteEligible }?.modelID
                    ?? modelOptions.first?.modelID
                selectedModelWasExplicit = false
            }
        } catch {
            runtimeErrorText = "Failed to list OpenClaw models: \(error.localizedDescription)"
        }
    }

    private static func restoredModelID(_ stored: String?, defaults: UserDefaults, key: String) -> String? {
        guard let stored = stored?.nonEmpty else { return nil }
        let canonical = AssistantModelIDCanonicalizer.canonicalized(stored)
        if canonical != stored {
            defaults.set(canonical, forKey: key)
        }
        return canonical
    }

    private func canonicalizedSelectedModelID(_ modelID: String) -> String {
        let canonical = AssistantModelIDCanonicalizer.canonicalized(modelID)
        persistResolvedSelectedModelID(canonical)
        return canonical
    }

    private func persistResolvedSelectedModelID(_ modelID: String) {
        guard selectedModelID != modelID else { return }
        selectedModelID = modelID
        if selectedModelWasExplicit {
            defaults.set(modelID, forKey: selectedModelDefaultsKey)
        }
    }

    // MARK: - Parsing

    static func parseModels(data: Data) -> [HermesRuntimeModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let raw = (object["data"] as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let provider = (entry["provider_id"] as? String)
                ?? (entry["owned_by"] as? String)
                ?? "openclaw"
            let providerName = (entry["provider_name"] as? String)
                ?? provider.capitalized
            let displayName = (entry["display_name"] as? String) ?? id
            return HermesRuntimeModelOption(
                providerID: provider,
                providerName: providerName,
                modelID: id,
                displayName: displayName,
                accountID: entry["account_id"] as? String,
                accountLabel: entry["account_label"] as? String,
                sourceID: entry["source_id"] as? String,
                sourceKind: entry["source_kind"] as? String,
                capabilities: entry["capabilities"] as? [String] ?? [],
                quotaState: entry["quota_state"] as? String,
                routeEligible: entry["route_eligible"] as? Bool,
                lastError: entry["last_error"] as? String
            )
        }
    }

    // MARK: - Defaults helpers

    private static func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private static func encodeStringArray(_ arr: [String]) -> String {
        (try? JSONEncoder().encode(arr))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
