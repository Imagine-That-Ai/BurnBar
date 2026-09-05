import Foundation

// MARK: - Build Gates
//
// The single place the app asks "does this build ship that feature at all?".
//
// Before this type there were two independent answers: `SettingsTab.visibleTabs`
// filtered `.computerUse` / `.updates` behind its own `#if DISTRIBUTION_MAS`,
// and every other surface re-derived the same condition inline. The Control
// Deck adds a third surface with the same question, so the condition moves here
// once and both `SettingsTab.visibleTabs` and `ControlKind.visibleKinds` read
// it. `ControlDeckRegistryTests` asserts the two agree.
//
// Build-gated features are **absent, not greyed**: a Mac App Store build must
// not advertise a capability it cannot ship, and a disabled row is still an
// advertisement.

enum OpenBurnBarBuildGates {

    /// Agent Control (Computer Use). Absent on the Mac App Store build — the
    /// sandbox forbids the automation entitlements it needs.
    static var agentControlAvailable: Bool {
        #if DISTRIBUTION_MAS
        return false
        #else
        return true
        #endif
    }

    /// The direct-download updater. The App Store owns updates for MAS copies,
    /// so shipping our own updater there is both wrong and disallowed.
    static var updatesAvailable: Bool {
        #if DISTRIBUTION_MAS
        return false
        #else
        return true
        #endif
    }

    /// System-wide text expansion, which installs a passive global key monitor
    /// and therefore needs Accessibility. In-app expansion is always available.
    static var globalTextExpansionAvailable: Bool {
        #if DISTRIBUTION_MAS
        return false
        #else
        return true
        #endif
    }
}
