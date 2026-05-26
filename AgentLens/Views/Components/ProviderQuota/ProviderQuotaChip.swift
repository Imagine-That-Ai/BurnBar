import SwiftUI
import OpenBurnBarCore

// MARK: - Provider Quota Chip

/// Tiny capsule chip that shows "% remaining" for a provider's primary
/// displayable bucket. Backed by `ProviderQuotaService.shared` so the chip
/// updates automatically as snapshots refresh.
///
/// Self-hides (renders `EmptyView`) when the provider does not expose a
/// quota signal, when no snapshot is available yet, or when the snapshot
/// has no displayable percent. Callers can therefore drop it into any row
/// or header without guarding around it themselves.
struct ProviderQuotaChip: View {
    enum Style {
        /// `"82%"` — for header/inline-row use.
        case full
        /// `"82"` — for very tight space (inside an 18×18 pt pill, etc.).
        case compact
    }

    let provider: AgentProvider
    var style: Style = .full
    /// Overrides the leading word of the tooltip — useful when the caller
    /// is a backend pill that wants "Droid — ..." even though the provider
    /// is `.factory`. Falls back to `provider.displayName`.
    var displayName: String? = nil

    @State private var quotaService = ProviderQuotaService.shared

    var body: some View {
        if let resolved = Self.resolve(provider: provider, style: style, displayName: displayName, service: quotaService) {
            QuotaMicroBadge(text: resolved.text, tint: resolved.tint)
                .help(resolved.tooltip)
                .accessibilityLabel(resolved.accessibilityLabel)
        }
    }
}

// MARK: - Backend convenience

extension ProviderQuotaChip {
    /// Returns nil when the backend has no `agentProvider` mapping —
    /// future-proofs against new chat backends that don't map to a known
    /// quota provider.
    init?(backend: ChatBackendID, style: Style = .full) {
        guard let provider = backend.agentProvider else { return nil }
        self.init(provider: provider, style: style, displayName: backend.displayName)
    }
}

// MARK: - Pure resolution (tested directly)

extension ProviderQuotaChip {
    struct Resolution: Equatable {
        let text: String
        let tint: Color
        let tooltip: String
        let accessibilityLabel: String
    }

    /// Decides whether to render and what to show. Hoisted so tests can
    /// drive the formatting and pressure thresholds without standing up a
    /// SwiftUI view hierarchy.
    @MainActor
    static func resolve(
        provider: AgentProvider,
        style: Style,
        displayName: String?,
        service: ProviderQuotaService
    ) -> Resolution? {
        let snapshot = service.cumulativeSnapshot(for: provider) ?? service.snapshot(for: provider)
        return resolve(provider: provider, style: style, displayName: displayName, snapshot: snapshot)
    }

    static func resolve(
        provider: AgentProvider,
        style: Style,
        displayName: String?,
        snapshot: ProviderQuotaSnapshot?
    ) -> Resolution? {
        guard provider.isQuotaSignalProvider else { return nil }
        guard let snapshot, snapshot.hasDisplayableQuotaSignal else { return nil }
        guard let bucket = snapshot.primaryDisplayableBucket,
              let percent = bucket.remainingPercent else { return nil }

        let intPct = Int(percent.rounded())
        let fraction = max(0, min(percent / 100, 1))
        let label = displayName ?? provider.displayName
        return Resolution(
            text: formatText(intPercent: intPct, style: style),
            tint: pressureTint(for: fraction),
            tooltip: "\(label) — \(snapshot.summaryText)",
            accessibilityLabel: "\(label) quota \(intPct) percent remaining"
        )
    }

    /// `82` → `"82%"` / `"82"` per style. Negative inputs clamp at 0.
    static func formatText(intPercent: Int, style: Style) -> String {
        let clamped = max(0, intPercent)
        switch style {
        case .full:    return "\(clamped)%"
        case .compact: return "\(clamped)"
        }
    }

    /// Three-band pressure tint aligned with the dashboard's
    /// `QuotaArcDial.pressureColor(for:)` semantics: ≥75% → success (matches
    /// the dial's "healthy" band), 25–75% → amber (covers the dial's "fading"
    /// and "caution" bands), <25% → warning (matches the dial's "danger" band).
    static func pressureTint(for fraction: Double) -> Color {
        switch fraction {
        case 0.75...:       return DesignSystem.Colors.success
        case 0.25..<0.75:   return DesignSystem.Colors.amber
        default:            return DesignSystem.Colors.warning
        }
    }
}
