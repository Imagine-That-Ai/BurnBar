import AppKit
import OpenBurnBarKernel
import SwiftUI

// MARK: - Switcher Data Loading Protocol

/// Protocol for injectable switcher data source.
/// Allows UI tests to provide deterministic mock data without requiring
/// a real DataStore or SwitcherProfileStore instance.
///
/// Production: Use `DataStoreSwitcherDataLoading` which wraps `DataStore.switcherStore`.
/// Tests: Use `MockSwitcherDataLoading` for deterministic test data.
protocol SwitcherDataLoading {
    /// Fetches all switcher profiles.
    func fetchAllProfiles() throws -> [SwitcherProfileRecord]

    /// Validates and recovers active profile state.
    func validateAndRecoverActiveProfile() throws -> SwitcherActiveProfileState

    /// Fetches active profile state without running recovery writes.
    func fetchActiveProfileStateSnapshot() throws -> SwitcherActiveProfileState

    /// Sets the active profile by ID.
    func setActiveProfile(_ profileID: String) throws

    /// All current per-provider drain targets keyed by providerID raw value.
    func fetchAllActiveDrainTargets() throws -> [String: String]

    /// Sets the drain target for a single provider, leaving siblings untouched.
    func setDrainTarget(_ profileID: String, for providerID: ProviderID) throws
}

extension SwitcherDataLoading {
    // Defaults keep older conformers (e.g. test mocks) source-compatible while
    // the drain-target feature rolls out.
    func fetchAllActiveDrainTargets() throws -> [String: String] { [:] }

    func fetchActiveProfileStateSnapshot() throws -> SwitcherActiveProfileState {
        try validateAndRecoverActiveProfile()
    }

    func setDrainTarget(_ profileID: String, for providerID: ProviderID) throws {
        try setActiveProfile(profileID)
    }
}

/// Resolves the persisted active profile only when the read-only snapshot points
/// at a profile that still exists in the currently loaded list.
func persistedActiveProfileID(
    from snapshot: SwitcherActiveProfileState,
    loadedProfiles: [SwitcherProfileRecord]
) -> String? {
    guard let activeProfileID = snapshot.activeProfileID,
          loadedProfiles.contains(where: { $0.id == activeProfileID }) else {
        return nil
    }
    return activeProfileID
}

/// Production implementation that wraps `DataStore.switcherStore`.
final class DataStoreSwitcherDataLoading: SwitcherDataLoading {
    private let store: SwitcherProfileStore

    init(store: SwitcherProfileStore) {
        self.store = store
    }

    func fetchAllProfiles() throws -> [SwitcherProfileRecord] {
        try store.fetchAllProfiles()
    }

    func validateAndRecoverActiveProfile() throws -> SwitcherActiveProfileState {
        try store.validateAndRecoverActiveProfile()
    }

    func fetchActiveProfileStateSnapshot() throws -> SwitcherActiveProfileState {
        try store.fetchActiveProfileStateSnapshot()
    }

    func setActiveProfile(_ profileID: String) throws {
        try store.setActiveProfile(profileID)
    }

    func fetchAllActiveDrainTargets() throws -> [String: String] {
        try store.fetchAllActiveDrainTargets()
    }

    func setDrainTarget(_ profileID: String, for providerID: ProviderID) throws {
        try store.setActiveProfile(profileID, for: providerID)
    }
}
