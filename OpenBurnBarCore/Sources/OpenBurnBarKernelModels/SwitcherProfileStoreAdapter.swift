import Foundation

// MARK: - Switcher Profile Store Adapter (GRDB-free profile-store protocol)
//
// Core-decomposition P-18 (docs/CORE_DECOMPOSITION_PROGRAM.md): the storage-agnostic
// profile-store protocol (and its in-memory test conformer), extracted DOWN from
// `OpenBurnBarLaunchServices/SwitcherBrowserLaunchService.swift` into the
// cross-platform Kernel so the daemon repoint reaches it via Engine WITHOUT linking
// the Apple-only, AppKit-importing `OpenBurnBarLaunchServices` target. The daemon's
// `OpenBurnBarSwitcherShell` refines this protocol
// (`BurnBarSwitcherProfileStoreProviding: SwitcherProfileStoreAdapter`); AgentLens'
// CLIBridge conforms production/spy adapters to it. Both types use only Kernel
// symbols (`SwitcherProfileRecord`, `ProviderID`, `Locked`), so this is a wholesale
// relocation with zero behavior change.
//
// The origin file was wholly `#if os(macOS)`, so these types were macOS-only (never
// iOS, never off-Apple). The guard is preserved verbatim so the surface is
// byte-identical to before.
#if os(macOS)

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

#endif
