import Foundation
import OpenBurnBarCore

extension ProviderQuotaBucket {
    /// Where usage *should* be in this window if it's to last the full
    /// reset period. Returns nil for lifetime/custom windows or buckets
    /// without a `resetsAt`.
    ///
    /// Math lives in `OpenBurnBarCore.PacingMath` so every surface
    /// (Mac, iOS, Android) can adopt the same algorithm. The AgentLens
    /// bucket has its own `ProviderQuotaWindowKind` enum that mirrors
    /// the Core one case-for-case; we bridge through `rawValue`.
    func idealPace(now: Date = Date(), calendar: Calendar = .current) -> IdealPace? {
        guard let coreKind = OpenBurnBarCore.ProviderQuotaWindowKind(rawValue: windowKind.rawValue) else {
            return nil
        }
        return OpenBurnBarCore.PacingMath.pace(
            windowKind: coreKind,
            resetsAt: resetsAt,
            progressFraction: progressFraction,
            now: now,
            calendar: calendar
        )
    }
}
