import SwiftUI
import OpenBurnBarKernel
import OpenBurnBarUI

// MARK: - Live agent fleet panel
//
// The upper half of the Home rail: which agents are working, which are blocked,
// and which we simply cannot see.
//
// Every state pairs a dot *style* with a *word*, so colour is never the only
// channel — the rule `AgentPresence.dotStyle`/`.glyph` already encodes.
//
// The copy vocabulary is deliberately narrow:
//
//   "Answering"  — a live turn in this app
//   "Thinking"   — a live turn in this app, pre-stream
//   "wrote 12s ago" / "quiet 6m" — observed writes
//   "Needs sign-in" / "Out of quota" / "Not installed" — blocked
//   "Not watched" — we cannot see it
//
// The word "idle" appears nowhere, at any width, in any mode. Absence of a
// write is not evidence of idleness.

struct LiveAgentFleetPanel: View {
    let model: LiveFleetModel
    let mode: DashboardHomeFleetMode
    let ink: BackdropInk
    let onOpenAgent: ((AgentProvider) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Rows shown before overflowing into a "+N" chip.
    ///
    /// The floor, not the answer. This was a flat `6`, which meant a rail panel
    /// dragged to 700pt showed six agents above 400pt of nothing while a 200pt
    /// one clipped — the panel's height was already known and simply not asked.
    /// `visibleRowLimit(forHeight:)` asks it.
    private static let minimumVisibleRows = 3
    /// One `FleetRowView` plus its gap.
    private static let rowUnit: CGFloat = 28
    /// Header, footer, and the panel's own gutters.
    private static let rowsChrome: CGFloat = 52

    /// How many agent rows this panel height can honestly hold.
    ///
    /// Pure and `static` so it can be pinned by a test without mounting a rail,
    /// the same contract every rule in `DashboardHomeRailMetrics` keeps.
    static func visibleRowLimit(forHeight height: CGFloat) -> Int {
        // The first layout pass can report zero before the rail has a frame;
        // answering 0 there would flash an empty panel on every launch.
        guard height > 0 else { return minimumVisibleRows }
        let usable = height - rowsChrome
        return max(minimumVisibleRows, Int(usable / rowUnit))
    }

    var body: some View {
        Group {
            switch mode {
            case .rows:     rowsMode
            case .strip:    stripMode
            case .timeline: FleetTimelineView(rows: model.rows, ink: ink)
            }
        }
        .accessibilityIdentifier(OBBAccessibilityID.dashboardHomeRailPanel("fleet"))
    }

    // MARK: - Rows

    private var rowsMode: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.rows.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    let limit = Self.visibleRowLimit(forHeight: geo.size.height)
                    let hidden = model.rows.count - limit
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            ForEach(model.rows.prefix(limit)) { row in
                                FleetRowView(row: row, ink: ink, onOpen: onOpenAgent)
                                    .transition(MotionTokens.flow(reduceMotion: reduceMotion))
                            }
                            if hidden > 0 {
                                Text("+\(hidden) more")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(ink.subtle)
                                    .padding(.horizontal, DesignSystem.Spacing.xs)
                                    .padding(.top, DesignSystem.Spacing.xxs)
                            }
                        }
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                    }
                    .animation(MotionTokens.settle(reduceMotion: reduceMotion), value: limit)
                }
            }
            footer
        }
    }

    // MARK: - Strip

    /// Marks and dots only. Says the least, so it cannot lie — and it is what
    /// the collapsed rail falls back to rather than showing nothing.
    private var stripMode: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            FlowLayout(horizontalSpacing: DesignSystem.Spacing.sm, verticalSpacing: DesignSystem.Spacing.sm) {
                ForEach(model.rows) { row in
                    Button { onOpenAgent?(row.provider) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            ProviderLogoView(provider: row.provider, size: 18, useFallbackColor: true)
                                .opacity(row.liveness.isActive ? 1 : 0.55)
                            FleetStatusDot(liveness: row.liveness, ink: ink, size: 6)
                                .offset(x: 2, y: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(row.provider.displayName) — \(FleetCopy.phrase(for: row.liveness))")
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.sm)
            footer
        }
    }

    // MARK: - Footer

    /// The honesty line.
    ///
    /// Non-negotiable: without it the panel is dishonest by omission even when
    /// every row is individually correct. It names the evidence floor the same
    /// way `docs/PROVIDERS.md` names exact/estimated/unavailable per provider.
    private var footer: some View {
        Text(FleetCopy.footer(
            hasRealTimeCoverage: model.hasRealTimeCoverage,
            sleepGapReason: model.sleepGapReason,
            lastScanAt: model.lastScanAt
        ))
        .font(DesignSystem.Typography.tiny)
        .foregroundStyle(ink.subtle)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(ink.icon)
            Text("No agents enabled")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.md)
    }
}

// MARK: - Row

struct FleetRowView: View {
    let row: FleetAgentRow
    let ink: BackdropInk
    let onOpen: ((AgentProvider) -> Void)?

    var body: some View {
        Button { onOpen?(row.provider) } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                FleetStatusDot(liveness: row.liveness, ink: ink, size: 7)

                ProviderLogoView(provider: row.provider, size: 16, useFallbackColor: true)
                    .opacity(row.liveness.isActive ? 1 : 0.7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.provider.displayName)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)

                    Text(detailLine)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var detailLine: String {
        let phrase = FleetCopy.phrase(for: row.liveness)
        guard let context = row.context, context.isEmpty == false else { return phrase }
        return "\(context) · \(phrase)"
    }

    private var helpText: String {
        guard let source = row.liveness.source else { return FleetCopy.phrase(for: row.liveness) }
        return "\(FleetCopy.phrase(for: row.liveness)) — \(source.explanation)"
    }
}

// MARK: - Dot

/// Status dot for a fleet row.
///
/// Distinguishes `.unobservable` (dashed, muted) from `.notInstalled` (also
/// dashed) by pairing it with a different word — the dot alone was never going
/// to carry that, which is why every row prints a phrase.
struct FleetStatusDot: View {
    let liveness: FleetLiveness
    let ink: BackdropInk
    var size: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Group {
            switch style {
            case .filled: Circle().fill(color)
            case .hollow: Circle().strokeBorder(color, lineWidth: 1.25)
            case .dashed: Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
        .opacity(shouldPulse && pulsing ? MotionTokens.pulseFloor : MotionTokens.pulseCeiling)
        .animation(shouldPulse ? MotionTokens.pulse(reduceMotion: reduceMotion) : nil, value: pulsing)
        .onAppear { pulsing = shouldPulse }
        .onChange(of: shouldPulse) { _, active in pulsing = active }
        .accessibilityHidden(true)
    }

    private enum Style { case filled, hollow, dashed }

    private var style: Style {
        switch liveness {
        case .workingHere, .wroteRecently: return .filled
        case .quietSince, .standingBy: return .hollow
        case .blocked(let presence):
            switch presence {
            case .exhausted: return .filled
            case .notInstalled, .offline: return .dashed
            default: return .hollow
            }
        case .unobservable: return .dashed
        }
    }

    private var color: Color {
        switch liveness {
        case .workingHere: return DesignSystem.Colors.success
        case .wroteRecently: return DesignSystem.Colors.success
        case .quietSince, .standingBy: return ink.icon
        case .blocked(let presence):
            switch presence {
            case .exhausted: return DesignSystem.Colors.amber
            case .needsAuth: return DesignSystem.Colors.warning
            case .error: return DesignSystem.Colors.error
            default: return ink.icon
            }
        // Never `DesignSystem.Colors.textMuted`: over a live backdrop that is
        // an invisible dot, which reads as "no agent" rather than "not watched".
        case .unobservable: return ink.icon
        }
    }

    /// Only a very fresh write pulses. A panel left open all day should be
    /// still almost all of the time.
    private var shouldPulse: Bool {
        guard reduceMotion == false else { return false }
        switch liveness {
        case .workingHere(let presence, _):
            if case .thinking = presence { return true }
            return false
        case .wroteRecently(let at, _):
            return Date().timeIntervalSince(at) <= FleetWindow.pulse
        default:
            return false
        }
    }
}
