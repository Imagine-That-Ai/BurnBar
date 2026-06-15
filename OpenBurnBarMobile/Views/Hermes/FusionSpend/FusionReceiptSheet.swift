import SwiftUI
import OpenBurnBarCore

// MARK: - Fusion Receipt Sheet (iOS)
//
// The end-of-session receipt for one Elder Wand fusion run — the premium
// moment. Presented the instant a fusion run finishes (the chat view observes
// `HermesService.fusionReceiptToken` and presents this sheet on a fresh token).
//
// The sheet draws from the membership "foil world": an `AuroraGlassCard` shell,
// a `HoloSheenSweep` sweeping the session total, a brief `HoloSparksOverlay` on
// appear, per-model color dots via `MobileTheme.Colors.colorForModel`, and a
// numeric count-up on the total. All motion self-gates on reduce-motion through
// the primitives' built-in gating.
//
// Two honest render modes (see `FusionReceiptSheetModel`):
//   • `.itemized`  — a real per-sub-call breakdown: hero total + count-up +
//     multiplier + itemized line items + the quota ring.
//   • `.quotaOnly` — no per-sub-call spend reached this device today: the
//     authoritative `fusion_searches` ring plus a "detailed token breakdown
//     shows on your Mac" note, and NO invented totals.

struct FusionReceiptSheet: View {

    @State private var model: FusionReceiptSheetModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the numeric count-up: starts at 0, animates to the real total
    /// once on appear.
    @State private var revealTotal = false

    /// Designated init for production: pass the itemized `session` when the
    /// relay forwards per-sub-call spend, or `nil` for today's quota-only path.
    init(session: FusionSessionSpend?) {
        _model = State(initialValue: FusionReceiptSheetModel(session: session))
    }

    /// Test/preview init accepting a pre-built model (e.g. an injected
    /// repository or a seeded quota bucket).
    init(model: FusionReceiptSheetModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    FusionReceiptHeroCard(
                        model: model,
                        revealTotal: revealTotal
                    )

                    if model.mode == .itemized, !model.lineItems.isEmpty {
                        FusionReceiptLineItemsCard(items: model.lineItems)
                    }

                    FusionSearchQuotaRingCard(
                        state: model.quotaLoadState,
                        retry: { Task { await model.loadQuota() } }
                    )

                    if model.mode == .quotaOnly {
                        macBreakdownNote
                    }
                }
                .padding(MobileTheme.Spacing.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(MobileTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Fusion receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .task {
            await model.loadQuota()
        }
        .onAppear {
            guard !reduceMotion else {
                revealTotal = true
                return
            }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.15)) {
                revealTotal = true
            }
        }
    }

    // MARK: - Quota-only note

    private var macBreakdownNote: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.hermesAureate)
                .accessibilityHidden(true)
            Text("The detailed per-model token breakdown for this run shows on your Mac, where the Elder Wand ran the panel and judge.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.borderSubtle, lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hero Card (session total + foil sheen + sparks)

/// The premium hero: the session total under a sweeping `HoloSheenSweep`, a
/// brief `HoloSparksOverlay` on appear, a numeric count-up, and the multiplier
/// line. In quota-only mode it carries the run's framing without a fabricated
/// total.
private struct FusionReceiptHeroCard: View {
    let model: FusionReceiptSheetModel
    let revealTotal: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 44

    private var holoColors: [Color] {
        CloudTier.ultra.holoStops
    }

    var body: some View {
        AuroraGlassCard(variant: .hero, cornerRadius: MobileTheme.Radius.xl) {
            VStack(spacing: MobileTheme.Spacing.md) {
                crest
                titleBlock
                totalBlock
                if let multiplier = model.costMultiplier {
                    multiplierLine(multiplier)
                }
                if model.showsEstimateCaption {
                    estimateCaption
                }
            }
            .frame(maxWidth: .infinity)
        }
        .overlay(sparks)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var crest: some View {
        ZStack {
            Circle()
                .fill(CloudTier.ultra.holoGradient)
                .frame(width: 56, height: 56)
                .blur(radius: 14)
                .opacity(0.5)
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(CloudTier.ultra.holoGradient)
        }
        .frame(width: 60, height: 60)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text("The Elder Wand")
                .font(ProTheme.Typography.titleSerif)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(subtitle)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var totalBlock: some View {
        if let total = model.totalCost {
            VStack(spacing: 2) {
                Text("THIS RUN COST")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.0)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text(CostText.dollars(revealTotal ? total : 0))
                    .font(.system(size: totalSize, weight: .heavy, design: .serif))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .contentTransition(.numericText(value: revealTotal ? total : 0))
                    .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.82), value: revealTotal)
                    .monospacedDigit()
                    // The signature foil glint sweeps the session total.
                    .overlay(
                        HoloSheenSweep(
                            tint: CloudTier.ultra.holoStops.first ?? .white,
                            period: 5.4,
                            bandOpacity: 0.45
                        )
                        .mask(
                            Text(CostText.dollars(total))
                                .font(.system(size: totalSize, weight: .heavy, design: .serif))
                                .monospacedDigit()
                        )
                    )
            }
        }
    }

    /// The "cost of certainty" pill — the payoff beat. The multiplier rides the
    /// tier holo gradient (the same foil the hero crest uses) as a celebratory
    /// accent, with the rationale beside it. Glassless: a soft holo-tinted
    /// capsule, not a glass plate.
    private func multiplierLine(_ multiplier: Double) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CloudTier.ultra.holoGradient)
                .accessibilityHidden(true)
            Text("\(CostText.multiplier(multiplier)) the cost of one model")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("· the price of a second opinion")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(CloudTier.ultra.holoGradient.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(holoColors.first?.opacity(0.30) ?? .clear, lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(CostText.multiplier(multiplier)) the cost of one model, the price of a second opinion")
    }

    private var estimateCaption: some View {
        Text("≈ estimated — one or more sub-calls reported an estimated token count")
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sparks: some View {
        // Brief living dust around the crest on appear. Self-gates on
        // reduce-motion (renders nothing) via the primitive.
        HoloSparksOverlay(colors: holoColors, count: 12)
            .allowsHitTesting(false)
    }

    private var subtitle: String {
        switch model.mode {
        case .itemized:
            if let count = model.contributingModelCount {
                let word = count == 1 ? "model" : "models"
                return "\(count) \(word) weighed in to answer you"
            }
            return "A council of models weighed in to answer you"
        case .quotaOnly:
            return "A council of models weighed in to answer you"
        }
    }

    private var accessibilityLabel: String {
        var parts = ["The Elder Wand fusion receipt"]
        if let total = model.totalCost {
            parts.append("this run cost \(CostText.dollars(total))")
        }
        if let multiplier = model.costMultiplier {
            parts.append("\(CostText.multiplier(multiplier)) the cost of a single model")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Stage presentation
//
// Each pipeline stage earns a distinguishing SF Symbol — read top-to-bottom the
// column tells the story: a panel convenes, a judge weighs in, a final answer is
// cast. Kept in the view layer so the shared `FusionStage` spine stays
// storage-agnostic (and identical to the macOS receipt's mapping).

private extension FusionStage {
    var glyph: String {
        switch self {
        case .panel: return "person.3.sequence.fill"
        case .judge: return "scale.3d"
        case .synthesis: return "wand.and.stars"
        case .unknown: return "circle.dotted"
        }
    }
}

// MARK: - Line Items Card

/// The itemized sub-call list — one row per panel member, the judge, and the
/// final synthesis, in pipeline order (the spine sorts them). Each row pairs a
/// per-model color chip carrying the stage glyph with its role, token count, and
/// right-aligned monospaced cost.
private struct FusionReceiptLineItemsCard: View {
    let items: [FusionSubCallSpend]

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            sectionHeader
            VStack(spacing: 0) {
                ForEach(items) { item in
                    FusionReceiptLineRow(item: item)
                    if item.id != items.last?.id {
                        Divider()
                            .overlay(MobileTheme.Colors.borderSubtle.opacity(0.5))
                            .padding(.leading, Self.rowGlyphInset)
                    }
                }
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.borderSubtle, lineWidth: 0.75)
        )
        .accessibilityElement(children: .contain)
    }

    /// Chip width + spacing, so dividers align under the text column rather than
    /// under the leading stage chip — the grouped-receipt look.
    static let rowGlyphInset: CGFloat = 34 + MobileTheme.Spacing.md

    private var sectionHeader: some View {
        Text("THE COUNCIL")
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.bold)
            .tracking(2.0)
            .foregroundStyle(MobileTheme.Colors.textMuted)
    }
}

/// One sub-call row: stage chip · role + model · tokens · cost.
private struct FusionReceiptLineRow: View {
    let item: FusionSubCallSpend

    @ScaledMetric(relativeTo: .body) private var chipSize: CGFloat = 34

    private var modelColor: Color {
        MobileTheme.Colors.colorForModel(item.modelID)
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            stageChip

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.stage.displayRole)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    if !item.confidence.isExact {
                        estChip
                    }
                }
                Text(ModelText.short(item.modelID))
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: MobileTheme.Spacing.sm)

            VStack(alignment: .trailing, spacing: 1) {
                Text(CostText.dollars(item.cost))
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .monospacedDigit()
                Text("\(TokenText.compact(item.totalTokens)) tok")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .monospacedDigit()
            }
            .layoutPriority(1)
        }
        .padding(.vertical, MobileTheme.Spacing.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A per-model color chip carrying the stage glyph — the row's identity at a
    /// glance: the model's color, the stage's symbol.
    private var stageChip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(modelColor.opacity(0.16))
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .strokeBorder(modelColor.opacity(0.35), lineWidth: 0.75)
            Image(systemName: item.stage.glyph)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(modelColor)
        }
        .frame(width: chipSize, height: chipSize)
        .accessibilityHidden(true)
    }

    private var estChip: some View {
        Text("est.")
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.warning)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous).fill(MobileTheme.warning.opacity(0.14))
            )
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        let estimate = item.confidence.isExact ? "" : ", estimated"
        return "\(item.stage.displayRole), \(ModelText.short(item.modelID)), \(TokenText.spoken(item.totalTokens)) tokens, \(CostText.dollars(item.cost))\(estimate)"
    }
}

// MARK: - Fusion Search Quota Ring Card

/// The authoritative `fusion_searches` ring, read from the Elder Wand fusion
/// quota snapshot. This is the one number the server is fully truthful about on
/// iOS, so it anchors the receipt in both render modes.
private struct FusionSearchQuotaRingCard: View {
    let state: FusionReceiptSheetModel.QuotaLoadState
    let retry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            header
            content
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.Colors.borderSubtle, lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        Text("HOSTED SEARCHES THIS MONTH")
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.bold)
            .tracking(2.0)
            .foregroundStyle(MobileTheme.Colors.textMuted)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loaded(let bucket):
            HStack(spacing: MobileTheme.Spacing.lg) {
                FusionSearchRing(fraction: remainingFraction(of: bucket))
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(usedOfLimit(bucket))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .monospacedDigit()
                    Text(resetLine(bucket))
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        case .loading:
            HStack(spacing: MobileTheme.Spacing.sm) {
                ProgressView()
                Text("Loading your search quota…")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        case .empty:
            Text("No hosted searches used yet this month.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        case .failed:
            failedContent
        }
    }

    /// Distinct read-error state — never "0 used". Names the failure plainly and
    /// offers Retry, matching the macOS modal's `.failed` honesty.
    private var failedContent: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MobileTheme.warning)
                    .accessibilityHidden(true)
                Text("Couldn't load your hosted-search allowance")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(MobileTheme.Typography.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(MobileTheme.ember)
            .accessibilityHint("Reloads your hosted-search allowance")
        }
    }

    private func remainingFraction(of bucket: ProviderQuotaBucket) -> Double {
        bucket.displayRemainingFraction ?? 1
    }

    private func usedOfLimit(_ bucket: ProviderQuotaBucket) -> String {
        let used = Int(bucket.used.rounded())
        let limit = Int(bucket.limit.rounded())
        if limit > 0 {
            return "\(used) / \(limit) used"
        }
        return "\(used) used"
    }

    private func resetLine(_ bucket: ProviderQuotaBucket) -> String {
        if let label = bucket.resetsAtCombinedLabel {
            return "Resets \(label)"
        }
        let remaining = Int(bucket.remaining.rounded())
        return "\(remaining) searches remaining"
    }

    private var accessibilityLabel: String {
        switch state {
        case .loaded(let bucket):
            let pct = Int((remainingFraction(of: bucket) * 100).rounded())
            return "Hosted searches this month, \(usedOfLimit(bucket)), \(pct) percent remaining. \(resetLine(bucket))"
        case .loading:
            return "Loading your hosted search quota"
        case .empty:
            return "No hosted searches used yet this month"
        case .failed:
            return "Couldn't load your hosted-search allowance. Retry available."
        }
    }
}

/// The fusion-search allowance gauge — a 270° dial (a real gauge, not a full
/// ring) trimmed to the REMAINING fraction so a full arc reads "plenty left".
/// The remaining percent sits big in the bowl with a "left" caption. Animates on
/// value change; static under reduce-motion via the gated `.animation(_:value:)`.
private struct FusionSearchRing: View {
    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0.75 of a full turn — a classic gauge dial with the gap at the bottom.
    private let span: CGFloat = 0.75

    private var clamped: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var percent: Int { Int((fraction * 100).rounded()) }

    private var accent: Color {
        if fraction < 0.15 { return MobileTheme.warning }
        if fraction < 0.4 { return MobileTheme.amber }
        return MobileTheme.success
    }

    var body: some View {
        ZStack {
            // The dial — rotated so the gap is centered at the bottom. Only the
            // arcs rotate; the center label stays upright.
            ZStack {
                Circle()
                    .trim(from: 0, to: span)
                    .stroke(
                        MobileTheme.Colors.border.opacity(0.35),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                Circle()
                    .trim(from: 0, to: max(0.0001, span * clamped))
                    .stroke(
                        AngularGradient(
                            colors: [accent, accent.opacity(0.85), MobileTheme.amber, accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .shadow(color: accent.opacity(0.4), radius: 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85), value: clamped)
            }
            .rotationEffect(.degrees(135))

            VStack(spacing: 0) {
                Text("\(percent)%")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .contentTransition(.numericText())
                Text("left")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Formatting helpers

/// Cost / multiplier formatting tuned for fusion spend, which lives in the
/// sub-cent to low-dollar range — so cents matter.
private enum CostText {
    static func dollars(_ value: Double) -> String {
        if value >= 100 { return String(format: "$%.0f", value) }
        if value >= 1 { return String(format: "$%.2f", value) }
        if value >= 0.01 { return String(format: "$%.3f", value) }
        if value <= 0 { return "$0.00" }
        return String(format: "$%.4f", value)
    }

    static func multiplier(_ value: Double) -> String {
        if value >= 10 { return String(format: "%.0f×", value) }
        return String(format: "%.1f×", value)
    }
}

private enum TokenText {
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(value)"
    }

    static func spoken(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

private enum ModelText {
    /// A short, human label for a bare model id like
    /// "anthropic/claude-sonnet-4" → "claude-sonnet-4".
    static func short(_ modelID: String) -> String {
        if let slash = modelID.lastIndex(of: "/") {
            return String(modelID[modelID.index(after: slash)...])
        }
        return modelID
    }
}

// MARK: - Preview

#Preview("Itemized") {
    let session = FusionSessionSpend(
        parentRequestID: "elderwand-PREVIEW",
        lineItems: [
            FusionSubCallSpend(id: "p0", stage: .panel(index: 0), modelID: "anthropic/claude-sonnet-4", inputTokens: 1820, outputTokens: 540, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0, cost: 0.0142, confidence: .exact),
            FusionSubCallSpend(id: "p1", stage: .panel(index: 1), modelID: "openai/gpt-5", inputTokens: 1810, outputTokens: 610, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 220, cost: 0.0188, confidence: .exact),
            FusionSubCallSpend(id: "j", stage: .judge, modelID: "google/gemini-2.5-pro", inputTokens: 3200, outputTokens: 410, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0, cost: 0.0096, confidence: .exact),
            FusionSubCallSpend(id: "s", stage: .synthesis, modelID: "anthropic/claude-sonnet-4", inputTokens: 2100, outputTokens: 880, cacheCreationTokens: 0, cacheReadTokens: 0, reasoningTokens: 0, cost: 0.0151, confidence: .exact)
        ],
        completedAt: Date()
    )
    return FusionReceiptSheet(session: session)
}

#Preview("Quota only") {
    FusionReceiptSheet(session: nil)
}
