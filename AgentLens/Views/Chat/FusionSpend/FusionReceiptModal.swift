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

    @ViewBuilder
    private func loadedBody(_ session: FusionSessionSpend) -> some View {
        FusionReceiptHero(
            costShown: heroCostShown,
            isEstimated: !session.aggregateConfidence.isExact,
            isPartial: session.synthesisItem == nil,
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
    let valueSize: CGFloat

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(isPartial ? "Spent before the run stopped" : "This fusion cost")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Text(FusionSpendFormat.currency(costShown))
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: costShown)
                    .accessibilityLabel("Fusion total \(FusionSpendFormat.currency(costShown))")

                if isEstimated {
                    Label("Estimated — some sub-calls reported approximate usage", systemImage: "info.circle")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .accessibilityLabel("This total is estimated; some sub-calls reported approximate usage.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.sm)
        }
        .accessibilityElement(children: .combine)
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

// MARK: - Line items

private struct FusionReceiptLineItems: View {
    let session: FusionSessionSpend

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Itemized")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            LiquidGlassGroup(spacing: DesignSystem.Spacing.xs) {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(session.lineItems) { item in
                        FusionReceiptLineRow(item: item)
                    }
                }
            }

            FusionReceiptTotalsRow(session: session)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Itemized fusion sub-calls")
    }
}

private struct FusionReceiptLineRow: View {
    let item: FusionSubCallSpend

    private var modelColor: Color {
        DesignSystem.Colors.colorForModel(item.modelID)
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(modelColor)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.modelID)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(item.stage.displayRole)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(modelColor)
                    if !item.confidence.isExact {
                        Text("· est.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.warning)
                    }
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            VStack(alignment: .trailing, spacing: 1) {
                Text(FusionSpendFormat.currency(item.cost))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("\(FusionSpendFormat.tokens(item.inputTokens)) in · \(FusionSpendFormat.tokens(item.outputTokens)) out")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs + 2)
        .liquidGlassSurface(in: .rect(cornerRadius: DesignSystem.Radius.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let estimate = item.confidence.isExact ? "" : ", estimated"
        return "\(item.stage.displayRole), \(item.modelID), \(FusionSpendFormat.currency(item.cost)), "
            + "\(FusionSpendFormat.tokens(item.inputTokens)) input, "
            + "\(FusionSpendFormat.tokens(item.outputTokens)) output tokens\(estimate)"
    }
}

private struct FusionReceiptTotalsRow: View {
    let session: FusionSessionSpend

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("\(session.panelCount) panel · judge + final")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer()
            Text("\(FusionSpendFormat.tokens(session.totalTokens)) tokens")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(FusionSpendFormat.currency(session.totalCost))
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.top, DesignSystem.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Total \(FusionSpendFormat.currency(session.totalCost)), "
            + "\(FusionSpendFormat.tokens(session.totalTokens)) tokens across \(session.panelCount) panel models, judge, and final answer"
        )
    }
}

// MARK: - Cost of certainty

private struct FusionReceiptCertaintyLine: View {
    let multiplier: Double

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.whimsy)
            VStack(alignment: .leading, spacing: 1) {
                Text("Cost of certainty")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("≈ \(FusionSpendFormat.multiplier(multiplier)) a single-model answer")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            Text(FusionSpendFormat.multiplier(multiplier))
                .font(DesignSystem.Typography.mono)
                .foregroundStyle(DesignSystem.Colors.whimsy)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.whimsyGradient.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.whimsy.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cost of certainty: about \(FusionSpendFormat.multiplier(multiplier)) the price of a single-model answer")
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
                        FusionSearchesRingRow(bucket: bucket)
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
                            Text("These models used \(FusionSpendFormat.tokens(monthToDateModelTokens)) tokens this month")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Spacer()
                        }
                    }
                }
                .padding(DesignSystem.Spacing.sm)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct FusionSearchesRingRow: View {
    let bucket: ProviderQuotaBucket

    /// Remaining fraction (0…1) for the ring fill — what's LEFT, so a full ring
    /// reads "plenty remaining".
    private var remainingFraction: Double {
        max(0, min(1, 1 - bucket.progressFraction))
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            FusionRing(remainingFraction: remainingFraction)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Fusion searches")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(bucket.remainingText(displayMode: .absoluteValues))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                if let reset = bucket.resetsAtDisplay {
                    Text("Resets \(reset.relative)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(periodAccessibilityLabel)
    }

    private var periodAccessibilityLabel: String {
        let usage = bucket.remainingText(displayMode: .absoluteValues)
        let reset = bucket.resetsAtDisplay.map { ", resets \($0.relative)" } ?? ""
        return "Fusion searches, \(usage) remaining\(reset)"
    }
}

/// The remaining-allowance ring. Premium accent via the app's primary gradient —
/// macOS has no foil primitives, so the gradient stroke carries the flourish.
private struct FusionRing: View {
    let remainingFraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(DesignSystem.Colors.surfaceMuted, lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.001, remainingFraction)))
                .stroke(
                    DesignSystem.Colors.primaryGradient,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(DesignSystem.Animation.gentle, value: remainingFraction)
            Text("\(Int((remainingFraction * 100).rounded()))%")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
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
