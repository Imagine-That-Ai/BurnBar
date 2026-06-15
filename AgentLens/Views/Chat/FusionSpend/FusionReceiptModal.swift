import OpenBurnBarCore
import SwiftUI

// MARK: - Fusion Receipt Modal
//
// The macOS end-of-session receipt for one Elder Wand model-fusion run. It owns
// its own dismiss (`@Environment(\.dismiss)`) and reads everything from an
// injected `FusionReceiptModalModel` source object (loaded off-main from the
// daemon usage ledger). Sections, top to bottom:
//
//   • Hero — the session total, counting up via `contentTransition(.numericText())`,
//     with an honest "estimated" caption when the aggregate confidence is not exact.
//   • Itemized list — one row per sub-call (panel members, judge, final answer),
//     each colored by `DesignSystem.Colors.colorForModel`, in pipeline order.
//   • Cost of certainty — the `costMultiplier` line ("≈ N× a single answer"),
//     omitted when no positive baseline exists.
//   • Period ring — the `fusion_searches` quota bucket (used / limit / remaining)
//     plus a month-to-date model-token footnote.
//
// Duress / empty: when a run failed mid-flight (no synthesis sub-call recorded),
// the receipt shows what DID spend and says so, rather than pretending the run
// completed. When the ledger held no fusion rows at all, it shows a plain empty
// state. macOS has no foil primitives — the premium accent rides on
// `DesignSystem.Colors` gradients and `GlassCard`.

/// `Identifiable` wrapper around the controller's `String?` fusion token, so the
/// host can present the receipt with `.sheet(item:)` (which requires an
/// `Identifiable` item) and have dismiss clear the token automatically.
struct FusionReceiptToken: Identifiable, Hashable {
    let id: String
}

struct FusionReceiptModal: View {
    @Bindable var model: FusionReceiptModalModel

    @Environment(\.dismiss) private var dismiss

    /// Drives the hero count-up: starts at 0, animates to the real total once
    /// the session loads, so `contentTransition(.numericText())` rolls the digits.
    @State private var heroCostShown: Double = 0

    @ScaledMetric(relativeTo: .largeTitle) private var heroValueSize: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    content
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .frame(width: 460)
        .frame(minHeight: 420, maxHeight: 720)
        .background(DesignSystem.Colors.background)
        .task { await model.load() }
        .onChange(of: model.session) { _, newSession in
            // Count the hero up to the freshly loaded total. Guarded by the
            // value so the animation fires exactly once per resolved session.
            withAnimation(DesignSystem.Animation.gentle) {
                heroCostShown = newSession?.totalCost ?? 0
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.whimsy)

            Text("Fusion receipt")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .liquidGlassInteractive(in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close receipt")
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            FusionReceiptLoadingView()
        case .failed(let reason):
            FusionReceiptUnavailableView(
                title: "Couldn't load the receipt",
                detail: reason,
                glyph: "exclamationmark.triangle"
            )
        case .empty:
            emptyBody
        case .loaded:
            if let session = model.session {
                loadedBody(session)
            } else {
                emptyBody
            }
        }
    }

    /// No fusion run to itemize — but the period allowance ring is still useful
    /// (this is exactly the "how much of my quota is left" check), so show it
    /// whenever a quota snapshot loaded.
    @ViewBuilder
    private var emptyBody: some View {
        FusionReceiptUnavailableView(
            title: "No fusion spend to show",
            detail: "This run didn't record any Elder Wand sub-calls yet.",
            glyph: "wand.and.stars.inverse"
        )
        if model.quotaBucket != nil {
            FusionReceiptPeriodSection(
                bucket: model.quotaBucket,
                monthToDateModelTokens: model.monthToDateModelTokens
            )
        }
    }

    /// A one-line provenance summary for the hero: how the answer was reached.
    private static func panelSummary(for session: FusionSessionSpend) -> String {
        let n = session.panelCount
        var parts = ["Panel of \(n) model\(n == 1 ? "" : "s")"]
        if session.judgeItem != nil { parts.append("judged") }
        if session.synthesisItem != nil { parts.append("synthesized") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func loadedBody(_ session: FusionSessionSpend) -> some View {
        FusionReceiptHero(
            costShown: heroCostShown,
            isEstimated: !session.aggregateConfidence.isExact,
            isPartial: session.synthesisItem == nil,
            panelSummary: Self.panelSummary(for: session),
            valueSize: heroValueSize
        )

        if session.synthesisItem == nil {
            FusionReceiptDuressNote()
        }

        FusionReceiptLineItems(session: session)

        if let multiplier = session.costMultiplier {
            FusionReceiptCertaintyLine(multiplier: multiplier)
        }

        FusionReceiptPeriodSection(
            bucket: model.quotaBucket,
            monthToDateModelTokens: model.monthToDateModelTokens
        )
    }
}

// MARK: - Hero

private struct FusionReceiptHero: View {
    let costShown: Double
    let isEstimated: Bool
    let isPartial: Bool
    let panelSummary: String?
    let valueSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var heroNumberGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: "FFF4D6"), Color(hex: "FFD56B"), Color(hex: "FF9E5C")],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ElderWandFoilBackdrop {
            VStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(ElderWandFoil.gradient)
                    .shadow(color: Color(hex: "FFB85C").opacity(0.6), radius: 12)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)
                    .accessibilityHidden(true)

                Text(isPartial ? "Spent before the run stopped" : "This fusion cost")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.72))

                Text(FusionSpendFormat.currency(costShown))
                    .font(.system(size: valueSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(heroNumberGradient)
                    .contentTransition(.numericText())
                    .shadow(color: Color(hex: "FF8A3D").opacity(0.35), radius: 14)
                    .animation(DesignSystem.Animation.gentle, value: costShown)
                    .accessibilityLabel("Fusion total \(FusionSpendFormat.currency(costShown))")

                if let panelSummary {
                    Text(panelSummary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .accessibilityLabel(panelSummary)
                }

                if isEstimated {
                    Label("Estimated", systemImage: "info.circle")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(Color(hex: "FFD56B"))
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .accessibilityLabel("This total is estimated; some sub-calls reported approximate usage.")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.xl)
            .padding(.horizontal, DesignSystem.Spacing.lg)
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6).delay(0.05)) {
                appeared = true
            }
        }
    }
}

// MARK: - Duress note

private struct FusionReceiptDuressNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.warning)
            Text("The run stopped before a final answer. You were only charged for the sub-calls below.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .liquidGlassSurface(in: .rect(cornerRadius: DesignSystem.Radius.md))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stage presentation
//
// Each pipeline stage earns a distinguishing SF Symbol and a one-word framing,
// so a glance down the column reads as a story: a panel convenes, a judge
// weighs in, a final answer is cast. Kept here (view layer) rather than on the
// `FusionStage` model so the spine stays storage-agnostic.

private extension FusionStage {
    /// A small, distinguishing glyph per stage.
    var glyph: String {
        switch self {
        case .panel: return "person.3.sequence.fill"
        case .judge: return "scale.3d"
        case .synthesis: return "wand.and.stars"
        case .unknown: return "circle.dotted"
        }
    }
}

// MARK: - Line items

private struct FusionReceiptLineItems: View {
    let session: FusionSessionSpend

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text("The council")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: DesignSystem.Spacing.sm)
                Text(Self.councilSummary(session))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            GlassCard {
                VStack(spacing: 0) {
                    ForEach(Array(session.lineItems.enumerated()), id: \.element.id) { index, item in
                        FusionReceiptLineRow(item: item)
                        if index < session.lineItems.count - 1 {
                            Divider()
                                .opacity(0.18)
                                .padding(.leading, Self.rowGlyphInset)
                        }
                    }

                    Divider()
                        .opacity(0.35)
                        .padding(.vertical, DesignSystem.Spacing.xxs)
                    FusionReceiptTotalsRow(session: session)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The council — itemized fusion sub-calls")
    }

    /// The inset (chip width + spacing) so dividers align under the text column,
    /// not under the leading stage chip — a small alignment detail that reads as
    /// "grouped", the way a polished receipt does.
    static let rowGlyphInset: CGFloat = 30 + DesignSystem.Spacing.sm

    private static func councilSummary(_ session: FusionSessionSpend) -> String {
        let n = session.panelCount
        return "\(n) panel · judge · final"
    }
}

private struct FusionReceiptLineRow: View {
    let item: FusionSubCallSpend

    @ScaledMetric(relativeTo: .caption) private var chipSize: CGFloat = 30

    private var modelColor: Color {
        DesignSystem.Colors.colorForModel(item.modelID)
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            stageChip

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(item.stage.displayRole)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    if !item.confidence.isExact {
                        estChip
                    }
                }
                Text(item.modelID)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            VStack(alignment: .trailing, spacing: 1) {
                Text(FusionSpendFormat.currency(item.cost))
                    .font(DesignSystem.Typography.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("\(FusionSpendFormat.tokens(item.totalTokens)) tok")
                    .font(DesignSystem.Typography.monoTiny)
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .layoutPriority(1)
        }
        .padding(.vertical, DesignSystem.Spacing.xs + 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A per-model color chip carrying the stage glyph — the row's identity at a
    /// glance: the model's color, the stage's symbol.
    private var stageChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(modelColor.opacity(0.16))
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(modelColor.opacity(0.35), lineWidth: 0.75)
            Image(systemName: item.stage.glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(modelColor)
        }
        .frame(width: chipSize, height: chipSize)
        .accessibilityHidden(true)
    }

    private var estChip: some View {
        Text("est.")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.warning)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.warning.opacity(0.14))
            )
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let estimate = item.confidence.isExact ? "" : ", estimated"
        return "\(item.stage.displayRole), \(item.modelID), \(FusionSpendFormat.currency(item.cost)), "
            + "\(FusionSpendFormat.tokens(item.totalTokens)) tokens\(estimate)"
    }
}

private struct FusionReceiptTotalsRow: View {
    let session: FusionSessionSpend

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Total")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Spacer(minLength: DesignSystem.Spacing.sm)
            Text("\(FusionSpendFormat.tokens(session.totalTokens)) tok")
                .font(DesignSystem.Typography.monoTiny)
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(FusionSpendFormat.currency(session.totalCost))
                .font(DesignSystem.Typography.mono)
                .monospacedDigit()
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Total \(FusionSpendFormat.currency(session.totalCost)), "
            + "\(FusionSpendFormat.tokens(session.totalTokens)) tokens across \(session.panelCount) panel models, judge, and final answer"
        )
    }
}

// MARK: - Cost of certainty
//
// The payoff line. Foil earns a celebratory accent here (the multiplier rendered
// in the Elder Wand ember gradient) — but stays glassless per the brand rule: a
// warm obsidian-tinted pill, not a glass plate. This is the "why the panel was
// worth it" beat, so it reads as desirable, not as a fee.

private struct FusionReceiptCertaintyLine: View {
    let multiplier: Double

    @ScaledMetric(relativeTo: .title) private var multiplierSize: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var glyphBadge: CGFloat = 30

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle().fill(.black.opacity(0.18))
                Circle().strokeBorder(Color(hex: "FF8A3D").opacity(0.35), lineWidth: 0.75)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ElderWandFoil.gradient)
            }
            .frame(width: glyphBadge, height: glyphBadge)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("The cost of a second opinion")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.92))
                Text("This run cost about \(FusionSpendFormat.multiplier(multiplier)) a single answer.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Text(FusionSpendFormat.multiplier(multiplier))
                .font(.system(size: multiplierSize, weight: .heavy, design: .rounded))
                .foregroundStyle(ElderWandFoil.gradient)
                .monospacedDigit()
                .shadow(color: Color(hex: "FF8A3D").opacity(0.3), radius: 8)
                .layoutPriority(1)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background {
            let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            ZStack {
                shape.fill(ElderWandFoil.obsidian)
                shape.fill(ElderWandFoil.gradient.opacity(0.10))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color(hex: "FF8A3D").opacity(0.20), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color(hex: "FF6A3D").opacity(0.16), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The cost of a second opinion: this run cost about \(FusionSpendFormat.multiplier(multiplier)) the price of a single-model answer")
    }
}

// MARK: - Period ring + month-to-date

private struct FusionReceiptPeriodSection: View {
    let bucket: ProviderQuotaBucket?
    let monthToDateModelTokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("This billing period")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            GlassCard {
                VStack(spacing: DesignSystem.Spacing.md) {
                    if let bucket {
                        FusionSearchesGaugeRow(bucket: bucket)
                    } else {
                        Text("Fusion search allowance unavailable right now.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if monthToDateModelTokens > 0 {
                        Divider().opacity(0.3)
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .accessibilityHidden(true)
                            Text("These models used ")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            + Text("\(FusionSpendFormat.tokens(monthToDateModelTokens)) tokens")
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            + Text(" this month")
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Spacer(minLength: 0)
                        }
                        .font(DesignSystem.Typography.tiny)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("These models used \(FusionSpendFormat.tokens(monthToDateModelTokens)) tokens this month")
                    }
                }
                .padding(DesignSystem.Spacing.md)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct FusionSearchesGaugeRow: View {
    let bucket: ProviderQuotaBucket

    @ScaledMetric(relativeTo: .title) private var gaugeSize: CGFloat = 76

    /// Remaining fraction (0…1) for the gauge fill — what's LEFT, so a full arc
    /// reads "plenty remaining".
    private var remainingFraction: Double {
        max(0, min(1, 1 - bucket.progressFraction))
    }

    private var usedText: String {
        bucket.remainingText(displayMode: .absoluteValues)
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            FusionArcGauge(remainingFraction: remainingFraction)
                .frame(width: gaugeSize, height: gaugeSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Fusion searches")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(usedText)
                    .font(DesignSystem.Typography.monoSmall)
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                if let reset = bucket.resetsAtDisplay {
                    HStack(spacing: DesignSystem.Spacing.xxs) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .accessibilityHidden(true)
                        Text("Resets \(reset.relative)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(periodAccessibilityLabel)
        .accessibilityValue(usedText)
    }

    private var periodAccessibilityLabel: String {
        let pct = Int((remainingFraction * 100).rounded())
        let reset = bucket.resetsAtDisplay.map { ", resets \($0.relative)" } ?? ""
        return "Fusion searches, \(usedText), \(pct) percent remaining\(reset)"
    }
}

/// The remaining-allowance arc gauge. A 270° dial (a real gauge, not a full
/// ring) with the Elder Wand ember gradient stroke carrying the flourish; the
/// remaining-percent sits big in the bowl with a small "left" caption beneath.
private struct FusionArcGauge: View {
    let remainingFraction: Double

    /// 0.75 of a full turn — a classic gauge dial with the gap at the bottom.
    private let span: CGFloat = 0.75

    private var clamped: CGFloat { CGFloat(max(0, min(1, remainingFraction))) }
    private var percent: Int { Int((remainingFraction * 100).rounded()) }

    var body: some View {
        ZStack {
            // The dial — rotated so the 270° span's gap is centered at the
            // bottom. Only the arcs rotate; the center label stays upright.
            ZStack {
                Circle()
                    .trim(from: 0, to: span)
                    .stroke(
                        DesignSystem.Colors.surfaceMuted,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                Circle()
                    .trim(from: 0, to: max(0.0001, span * clamped))
                    .stroke(
                        ElderWandFoil.gradient,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .shadow(color: Color(hex: "FF8A3D").opacity(0.35), radius: 5)
                    .animation(DesignSystem.Animation.gentle, value: clamped)
            }
            .rotationEffect(.degrees(135))

            VStack(spacing: 0) {
                Text("\(percent)%")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text("left")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }
}

// MARK: - States

private struct FusionReceiptLoadingView: View {
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text("Reading the usage ledger…")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xxl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading the fusion receipt")
    }
}

private struct FusionReceiptUnavailableView: View {
    let title: String
    let detail: String
    let glyph: String

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: glyph)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(title)
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

/// Small, self-contained formatters for the receipt. Currency mirrors the
/// `ProviderQuotaBucket` currency formatting (two-decimal USD); token counts use
/// the same K/M abbreviation the quota strip uses, so the receipt speaks the
/// same numeric language as the rest of the spend surfaces.
enum FusionSpendFormat {
    static func currency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = value < 0.1 ? 3 : 2
        formatter.maximumFractionDigits = value < 0.1 ? 4 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(value)"
    }

    static func multiplier(_ value: Double) -> String {
        value >= 10
            ? String(format: "%.0f×", value)
            : String(format: "%.1f×", value)
    }
}
