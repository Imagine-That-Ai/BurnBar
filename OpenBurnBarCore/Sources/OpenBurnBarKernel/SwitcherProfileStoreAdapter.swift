// SPDX-License-Identifier: AGPL-3.0-only
//
// Core-decomposition P-18 (S17): the pure `SwitcherProfileStoreAdapter` profile
// storage abstraction, extracted from the Apple-only, AppKit-importing
// `OpenBurnBarLaunchServices/SwitcherBrowserLaunchService.swift` into the
// cross-platform kernel.
//
// The daemon's supervised-CLI shell (`OpenBurnBarSwitcherShell`) refines this
// protocol (`BurnBarSwitcherProfileStoreProviding: SwitcherProfileStoreAdapter`)
// and therefore needs the symbol reachable through `OpenBurnBarEngine`. The
// protocol itself has NO UI dependency — it only uses `SwitcherProfileRecord`,
// `ProviderID`, and `Locked`, all of which already live in OpenBurnBarKernel. It
// was merely trapped inside a `#if os(macOS)` file that also happens to import
// AppKit for the browser-launch path. Extracting it here lets the daemon link the
// UI-free engine umbrella while the Mac app and LaunchServices keep seeing the
// type unchanged (both link Kernel; Core and LaunchServices depend on / re-export
// it).
import Foundation

// MARK: - Profile Store Adapter

/// Protocol for accessing profile data.
/// This abstracts the actual storage so we can test without GRDB dependencies.
public protocol SwitcherProfileStoreAdapter: Sendable {
    func fetchProfile(id: String) -> SwitcherProfileRecord?
    func fetchAllProfiles() -> [SwitcherProfileRecord]
    /// Returns the currently active profile ID, if any.
    func fetchActiveProfileID() -> String?
    /// Returns the active (drain-target) profile ID for a specific provider, if any.
    func fetchActiveProfileID(for providerID: ProviderID) -> String?
    /// Sets the active profile ID. Pass nil to clear.
    func setActiveProfileID(_ profileID: String?)
    /// Sets the active (drain-target) profile ID for a specific provider. Pass nil to clear.
    func setActiveProfileID(_ profileID: String?, for providerID: ProviderID)
    /// Persists an updated profile record.
    func updateProfile(_ profile: SwitcherProfileRecord)
}

public extension SwitcherProfileStoreAdapter {
    /// Back-compat default: conformers that predate per-provider drain targets
    /// resolve any provider's drain target to the single global active profile,
    /// preserving the original behavior exactly.
    func fetchActiveProfileID(for providerID: ProviderID) -> String? {
        fetchActiveProfileID()
    }

    /// Back-compat default: routes per-provider writes to the single global
    /// pointer for conformers that haven't adopted per-provider drain targets.
    func setActiveProfileID(_ profileID: String?, for providerID: ProviderID) {
        setActiveProfileID(profileID)
    }
}

// MARK: - In-Memory Adapter for Testing

/// In-memory adapter for testing without GRDB.
public final class InMemorySwitcherProfileStoreAdapter: SwitcherProfileStoreAdapter, Sendable {
    private struct State {
        var profiles: [String: SwitcherProfileRecord] = [:]
        var activeProfileID: String?
        var activeProfileIDByProvider: [String: String] = [:]
    }
    private let state = Locked(State())

    public init() {}

    public func addProfile(_ profile: SwitcherProfileRecord) {
        state.withLock { $0.profiles[profile.id] = profile }
    }

    public func fetchProfile(id: String) -> SwitcherProfileRecord? {
        state.withLock { $0.profiles[id] }
    }

    public func fetchAllProfiles() -> [SwitcherProfileRecord] {
        state.withLock { Array($0.profiles.values).sorted { $0.sortKey < $1.sortKey } }
    }

    public func fetchActiveProfileID() -> String? {
        state.withLock { $0.activeProfileID }
    }

    public func fetchActiveProfileID(for providerID: ProviderID) -> String? {
        state.withLock { $0.activeProfileIDByProvider[providerID.rawValue] }
    }

    public func setActiveProfileID(_ profileID: String?) {
        state.withLock { $0.activeProfileID = profileID }
    }

    public func setActiveProfileID(_ profileID: String?, for providerID: ProviderID) {
        state.withLock {
            if let profileID {
                $0.activeProfileIDByProvider[providerID.rawValue] = profileID
            } else {
                $0.activeProfileIDByProvider[providerID.rawValue] = nil
            }
        }
    }

    public func updateProfile(_ profile: SwitcherProfileRecord) {
        state.withLock { $0.profiles[profile.id] = profile }
    }
}
