import Foundation
import OpenBurnBarCore

/// Coordinator surface the model-selection policy needs from
/// `HermesService`: the persisted selection, the live catalog, favorites,
/// and the user-facing error slots the policy writes when a selection
/// can't be honored.
@MainActor
protocol HermesModelSelectionCoordinating: AnyObject {
    var selectedConnection: HermesConnectionRecord { get }
    var selectedModelID: String? { get set }
    var selectedModelWasExplicit: Bool { get set }
    var modelOptions: [HermesRuntimeModelOption] { get }
    var favoriteModelIDs: [String] { get set }
    var lastError: String? { get set }
    var runtimeErrorText: String? { get set }
    var defaults: UserDefaults { get }
}

/// Model-selection policy for the Hermes chat surface: explicit selection
/// + persistence, canonicalization, favorites, route-eligibility
/// validation, and the "which model id goes on the wire" resolution the
/// streaming path and mission dispatch share.
///
/// All bodies were moved verbatim from `HermesService`; the service keeps
/// thin pass-throughs so its existing API surface (`selectModel`,
/// `validatedModelIDForMissionDispatch`, `activeModelIDForRequest`, ...)
/// stays unchanged for views, tests, and the streaming/transport engines.
@MainActor
enum HermesModelSelectionEngine {
    static let localHermesSelectedMessage =
        "This iPhone/iPad is still using Local Hermes, so localhost points at this device, not your Mac. " +
        "Select the Mac Remote Relay or add a reachable LAN/VPN Hermes URL, then refresh."

    static func selectModel(_ option: HermesRuntimeModelOption, coordinator: HermesModelSelectionCoordinating) {
        let raw = option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(raw)
        let resolved = !coordinator.modelOptions.isEmpty
            ? AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(raw, in: coordinator.modelOptions)
            : requested
        if !coordinator.modelOptions.isEmpty, resolved == nil {
            let message = "Selected Hermes model '\(option.modelID)' is not advertised by this Mac relay. Pick a live model from the relay list or refresh/restart the Mac Hermes gateway."
            coordinator.lastError = message
            coordinator.runtimeErrorText = message
            return
        }
        let modelID = resolved ?? requested
        coordinator.selectedModelID = modelID
        coordinator.selectedModelWasExplicit = true
        coordinator.defaults.set(modelID, forKey: HermesRuntimeStore.selectedModelDefaultsKey)
        coordinator.runtimeErrorText = nil
        coordinator.lastError = nil
    }

    static func clearSelectedModel(coordinator: HermesModelSelectionCoordinating) {
        coordinator.selectedModelID = nil
        coordinator.selectedModelWasExplicit = false
        coordinator.defaults.removeObject(forKey: HermesRuntimeStore.selectedModelDefaultsKey)
    }

    static func selectGatewayModelID(_ modelID: String, coordinator: HermesModelSelectionCoordinating) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let canonical = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(trimmed)
        coordinator.selectedModelID = canonical
        coordinator.selectedModelWasExplicit = true
        coordinator.defaults.set(canonical, forKey: HermesRuntimeStore.selectedModelDefaultsKey)
        coordinator.runtimeErrorText = nil
        coordinator.lastError = nil
    }

    static func canonicalizedSelectedModelID(_ modelID: String, coordinator: HermesModelSelectionCoordinating) -> String {
        let canonical = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(modelID)
        persistResolvedSelectedModelID(canonical, coordinator: coordinator)
        return canonical
    }

    static func persistResolvedSelectedModelID(_ modelID: String, coordinator: HermesModelSelectionCoordinating) {
        guard coordinator.selectedModelID != modelID else { return }
        coordinator.selectedModelID = modelID
        if coordinator.selectedModelWasExplicit {
            coordinator.defaults.set(modelID, forKey: HermesRuntimeStore.selectedModelDefaultsKey)
        }
    }

    #if DEBUG
    static func selectModelIDForAutomation(_ modelID: String, coordinator: HermesModelSelectionCoordinating) {
        guard let trimmed = modelID.nilIfBlank else { return }
        if trimmed.lowercased() == "auto" || trimmed.lowercased() == "default" {
            coordinator.selectedModelID = HermesTransportSelector.preferredRouteEligibleModelID(
                in: coordinator.modelOptions,
                favorites: favoriteModelOptions(coordinator: coordinator)
            )
            coordinator.selectedModelWasExplicit = coordinator.selectedModelID != nil
            if coordinator.selectedModelID == nil, !coordinator.modelOptions.isEmpty {
                coordinator.lastError = HermesServiceError.noRouteEligibleModel.localizedDescription
                coordinator.runtimeErrorText = coordinator.lastError
            }
            return
        }
        let canonical = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(trimmed)
        let resolved = !coordinator.modelOptions.isEmpty
            ? AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(trimmed, in: coordinator.modelOptions)
            : canonical
        guard coordinator.modelOptions.isEmpty || resolved != nil else {
            coordinator.lastError = "Selected Hermes model '\(trimmed)' is not available on this Mac relay. Pick another model or refresh/restart the Mac Hermes gateway."
            coordinator.runtimeErrorText = coordinator.lastError
            return
        }
        coordinator.selectedModelID = resolved ?? canonical
        coordinator.selectedModelWasExplicit = true
        if let selectedModelID = coordinator.selectedModelID {
            coordinator.defaults.set(selectedModelID, forKey: HermesRuntimeStore.selectedModelDefaultsKey)
        }
    }
    #endif

    static func isFavoriteModel(_ option: HermesRuntimeModelOption, coordinator: HermesModelSelectionCoordinating) -> Bool {
        coordinator.favoriteModelIDs.contains(option.modelID)
    }

    static func toggleFavoriteModel(_ option: HermesRuntimeModelOption, coordinator: HermesModelSelectionCoordinating) {
        if let index = coordinator.favoriteModelIDs.firstIndex(of: option.modelID) {
            coordinator.favoriteModelIDs.remove(at: index)
        } else {
            coordinator.favoriteModelIDs.append(option.modelID)
        }
        coordinator.defaults.set(
            encodeStringArray(coordinator.favoriteModelIDs),
            forKey: HermesRuntimeStore.favoriteModelsDefaultsKey
        )
    }

    static func favoriteModelOptions(coordinator: HermesModelSelectionCoordinating) -> [HermesRuntimeModelOption] {
        let optionsByID = coordinator.modelOptions.reduce(into: [String: HermesRuntimeModelOption]()) { partialResult, option in
            partialResult[option.modelID] = option
        }
        return coordinator.favoriteModelIDs.compactMap { optionsByID[$0] }
    }

    static func validatedModelIDForMissionDispatch(coordinator: HermesModelSelectionCoordinating) throws -> String? {
        guard let selectedModelID = coordinator.selectedModelID?.nilIfBlank else {
            guard !coordinator.modelOptions.isEmpty else { return nil }
            guard let routeEligibleModelID = HermesTransportSelector.preferredRouteEligibleModelID(
                in: coordinator.modelOptions,
                favorites: favoriteModelOptions(coordinator: coordinator)
            ) else {
                throw HermesServiceError.noRouteEligibleModel
            }
            return routeEligibleModelID
        }
        if coordinator.modelOptions.isEmpty {
            if coordinator.selectedConnection.mode == .relayLink {
                return canonicalizedSelectedModelID(selectedModelID, coordinator: coordinator)
            }
            if coordinator.selectedModelWasExplicit {
                if coordinator.selectedConnection.id == HermesConnectionRecord.localDefault.id {
                    throw HermesServiceError.relayUnavailable(Self.localHermesSelectedMessage)
                }
                throw HermesServiceError.selectedModelCatalogUnavailable(selectedModelID)
            }
        } else if let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: coordinator.modelOptions) {
            persistResolvedSelectedModelID(resolved, coordinator: coordinator)
            return resolved
        } else {
            throw HermesServiceError.selectedModelUnavailable(selectedModelID)
        }
        return canonicalizedSelectedModelID(selectedModelID, coordinator: coordinator)
    }

    static func activeModelName(coordinator: HermesModelSelectionCoordinating) -> String? {
        if let selectedModelID = coordinator.selectedModelID,
           let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: coordinator.modelOptions),
           let option = coordinator.modelOptions.first(where: { $0.modelID == resolved }) {
            return option.displayName.nilIfBlank ?? option.modelID.nilIfBlank
        }
        return coordinator.selectedModelID?.nilIfBlank.map(AssistantModelIDCanonicalizer.canonicalizedPersistedSelection)
            ?? coordinator.selectedConnection.advertisedModel?.nilIfBlank
    }

    /// Raw model id we send in the `"model"` field of the chat completion
    /// request. Stored on the message as `requestedModelID` so we can be
    /// honest about what we asked for, even if the server reports something
    /// else back.
    static func activeRequestedModelID(coordinator: HermesModelSelectionCoordinating) -> String? {
        coordinator.selectedModelID?.nilIfBlank.map { canonicalizedSelectedModelID($0, coordinator: coordinator) }
            ?? coordinator.selectedConnection.advertisedModel?.nilIfBlank
    }

    static func activeModelIDForRequest(coordinator: HermesModelSelectionCoordinating) throws -> String {
        if let selectedModelID = coordinator.selectedModelID?.nilIfBlank {
            if coordinator.modelOptions.isEmpty {
                if coordinator.selectedConnection.mode == .relayLink {
                    return canonicalizedSelectedModelID(selectedModelID, coordinator: coordinator)
                }
                if coordinator.selectedModelWasExplicit {
                    if coordinator.selectedConnection.id == HermesConnectionRecord.localDefault.id {
                        throw HermesServiceError.relayUnavailable(Self.localHermesSelectedMessage)
                    }
                    throw HermesServiceError.selectedModelCatalogUnavailable(selectedModelID)
                }
            } else if let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: coordinator.modelOptions) {
                persistResolvedSelectedModelID(resolved, coordinator: coordinator)
                return resolved
            } else {
                throw HermesServiceError.selectedModelUnavailable(selectedModelID)
            }
            return canonicalizedSelectedModelID(selectedModelID, coordinator: coordinator)
        }
        if !coordinator.modelOptions.isEmpty {
            guard let routeEligibleModelID = HermesTransportSelector.preferredRouteEligibleModelID(
                in: coordinator.modelOptions,
                favorites: favoriteModelOptions(coordinator: coordinator)
            ) else {
                throw HermesServiceError.noRouteEligibleModel
            }
            return routeEligibleModelID
        }
        return coordinator.selectedConnection.advertisedModel?.nilIfBlank ?? "hermes"
    }

    private static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
