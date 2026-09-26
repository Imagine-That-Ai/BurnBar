import OpenBurnBarKernel

// MARK: - Header Copy

/// Popover header strings as pure functions so the exact copy stays
/// unit-testable.
enum PopoverHeaderCopy {
    /// "Burning 52.4M" while usage flows; falls back to the app name before
    /// the first scan so the header never reads "Burning 0".
    static func burnTitle(metric: String, hasUsage: Bool) -> String {
        hasUsage ? "Burning \(metric)" : "OpenBurnBar"
    }

    /// Units line under the burn title — "tokens per week" in token mode,
    /// "per week" in currency mode. Nil until there's usage to describe.
    static func burnSubtitle(hasUsage: Bool, mode: UsageDisplayMode) -> String? {
        guard hasUsage else { return nil }
        switch mode {
        case .tokens: return "tokens per week"
        case .currency: return "per week"
        }
    }
}
