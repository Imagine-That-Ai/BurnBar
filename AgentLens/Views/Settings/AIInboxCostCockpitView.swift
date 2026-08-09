import SwiftUI
import OpenBurnBarKernel

// MARK: - AI Inbox Cost Cockpit
//
// A beautiful, honest place to answer "what is this thing costing me?"
// and "what would it cost if I used my sub instead?"
//
// Design: instrument-panel / ledger. Warm ledger paper in light, cool
// charcoal ledger in dark. Ember glow for spend, whimsy for local,
// success (teal→green) for $0 / saved. Mono for every number, rounded
// for every label. Cards breathe on a 4px grid, spring-gentle motion.
//
// Three layers:
//   1. Hero — today + projection + skip efficiency + budget rail
//   2. Ledger — 7-day sparkline + per-tick breakdown + recent runs
//   3. Model Atelier — picker with live estimates, sub-plan $0 badges,
//      and a cost-comparison bar that makes the trade legible.

struct AIInboxCostCockpitView: View {
    @Bindable var model: AIInboxSettingsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
            hero
            ledger
            modelAtelier
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text("Inbox spend")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if model.config.dailyBudgetUSD > 0 {
                    Text("budget \(Self.currency(model.config.dailyBudgetUSD))/day")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(DesignSystem.Colors.surfaceElevated)
                        )
                        .overlay(
                            Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                        )
                }
            }

            // Big number + context row
            HStack(alignment: .bottom, spacing: DesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.currency(model.todaySpendUSD ?? 0))
                        .font(DesignSystem.Typography.monoLarge)
                        .foregroundStyle(
                            (model.todaySpendUSD ?? 0) == 0
                                ? DesignSystem.Colors.textPrimary
                                : DesignSystem.Colors.ember
                        )
                        .contentTransition(.numericText())
                    Text("today · \(Self.todayLabel)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.currency(Self.projectedMonthly(model.todaySpendUSD ?? 0)))
                        .font(DesignSystem.Typography.mono)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("projected / 30d")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.skipSummary.isEmpty ? "—" : Self.skipPercentLabel(model.skipSummary))
                        .font(DesignSystem.Typography.mono)
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("checks free")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            // Budget rail — ember fill, warning when close, frost when empty
            if model.config.dailyBudgetUSD > 0 {
                GeometryReader { geo in
                    let ratio = min(1, (model.todaySpendUSD ?? 0) / max(0.0001, model.config.dailyBudgetUSD))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DesignSystem.Colors.surfaceMuted)
                            .frame(height: 8)
                        Capsule()
                            .fill(
                                ratio >= 1 ? DesignSystem.Colors.warning :
                                ratio >= 0.75 ? DesignSystem.Colors.amber :
                                DesignSystem.Colors.ember
                            )
                            .frame(width: geo.size.width * ratio, height: 8)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: ratio)
                        // tick marks at 50%
                        Rectangle()
                            .fill(DesignSystem.Colors.borderSubtle)
                            .frame(width: 1, height: 8)
                            .offset(x: geo.size.width * 0.5)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("$\(String(format: "%.2f", model.todaySpendUSD ?? 0)) of $\(String(format: "%.2f", model.config.dailyBudgetUSD))")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    if let remaining = Self.remainingLabel(spend: model.todaySpendUSD ?? 0, budget: model.config.dailyBudgetUSD) {
                        Text(remaining)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(
                                (model.todaySpendUSD ?? 0) >= model.config.dailyBudgetUSD
                                    ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary
                            )
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("No cap — inbox will keep writing summaries regardless of spend.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            // Budget slider (preserved, but tighter)
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("Cap")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: model.binding(\.dailyBudgetUSD) { $0.with(dailyBudgetUSD: $1) },
                    in: 0...10, step: 0.25
                )
                .tint(DesignSystem.Colors.ember)
                Text(model.config.dailyBudgetUSD > 0 ? Self.currency(model.config.dailyBudgetUSD) : "∞")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .frame(width: 48, alignment: .trailing)
                    .monospacedDigit()
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06), radius: 12, y: 4)
    }

    // MARK: - Ledger

    private var ledger: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Label("Ledger", systemImage: "chart.bar.doc.horizontal")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text("\(model.runs.count) recent checks")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            if model.runs.isEmpty {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text("No checks yet — the first one runs within \(AIInboxSettingsView.cadenceLabel(model.config.tickSeconds)). Nothing to bill until then.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                        .fill(DesignSystem.Colors.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
                )
            } else {
                // Sparkline — 7-day / last N runs spend
                AIInboxSpendSparkline(runs: Array(model.runs.prefix(24)))
                    .frame(height: 56)
                    .padding(.horizontal, 2)

                Divider().overlay(DesignSystem.Colors.borderSubtle)

                // Per-tick table header
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text("When")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 64, alignment: .leading)
                    Text("Outcome")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    Text("Cost")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 72, alignment: .trailing)
                }

                ForEach(model.runs.prefix(8)) { run in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Circle()
                            .fill(AIInboxSettingsView.runTint(run))
                            .frame(width: 6, height: 6)
                        Text(run.startedAt, style: .time)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .frame(width: 56, alignment: .leading)
                        Text(AIInboxSettingsView.runLabel(run))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if run.costUSD > 0 {
                            Text(Self.currency(run.costUSD))
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .monospacedDigit()
                        } else {
                            Text("—")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                            .fill(run.costUSD > 0 ? DesignSystem.Colors.surfaceElevated : Color.clear)
                    )
                }

                Text(model.skipSummary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Analyze now + spend footnote
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        Task { await model.runNow() }
                    } label: {
                        Label(model.isRunningNow ? "Analyzing…" : "Analyze now", systemImage: "wand.and.stars")
                            .font(DesignSystem.Typography.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(DesignSystem.Colors.ember)
                    .disabled(model.isRunningNow)

                    Spacer()

                    if let spend = model.todaySpendUSD, spend > 0 {
                        Text("Today’s inbox ledger: \(Self.currency(spend)) across \(model.runs.filter { $0.costUSD > 0 }.count) billed checks.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    } else {
                        Text("Deterministic detectors are free — only composed summaries bill.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }

    // MARK: - Model Atelier

    private var modelAtelier: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Label("Model atelier", systemImage: "wand.and.stars.inverse")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Text("tap to switch — estimates live")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Text("Pick where your inbox thinks. Subscription routes cost $0 and count against the plan you already pay for. Direct API routes bill per token.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Current split + what-if bar
            AIInboxWhatIfBar(
                analyst: Self.analystOption(for: model.config),
                verifier: Self.verifierOption(for: model.config),
                runsPerDay: Self.runsPerDay(tickSeconds: model.config.tickSeconds)
            )
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.5)
            )

            // Analyst picker
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Analyst — writes the brief")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSystem.Spacing.sm) {
                    ForEach(Self.analystCatalog) { option in
                        AIInboxModelCard(
                            option: option,
                            isSelected: option.providerID == model.config.analystProviderID && option.modelID == model.config.analystModel,
                            isZeroCost: option.isZeroCost
                        ) {
                            model.update { $0.with(analystProviderID: option.providerID, analystModel: option.modelID) }
                        }
                    }
                }
            }

            // Verifier picker
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Verifier — adversarial check (different provider)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSystem.Spacing.sm) {
                    ForEach(Self.verifierCatalog) { option in
                        AIInboxModelCard(
                            option: option,
                            isSelected: option.providerID == model.config.verifierProviderID && option.modelID == model.config.verifierModel,
                            isZeroCost: option.isZeroCost
                        ) {
                            model.update { $0.with(verifierProviderID: option.providerID, verifierModel: option.modelID) }
                        }
                    }
                }
                if model.config.analystProviderID == model.config.verifierProviderID {
                    Label("Analyst and verifier share a provider — verification is stronger when they don’t.", systemImage: "exclamationmark.triangle")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Egress reminder when off
            if model.config.egressMode == .off {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Egress is off — no model is called, so the atelier is preview only. Switch egress to Cloud or Local to bill.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .fill(DesignSystem.Colors.success.opacity(0.08))
                )
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    static func currency(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    static var todayLabel: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: Date())
    }

    static func projectedMonthly(_ today: Double) -> Double { today * 30 }

    static func remainingLabel(spend: Double, budget: Double) -> String? {
        guard budget > 0 else { return nil }
        if spend >= budget { return "budget reached — summaries paused" }
        let remaining = budget - spend
        return "\(currency(remaining)) left today"
    }

    static func skipPercentLabel(_ summary: String) -> String {
        // summary is "XX% of the last N checks found nothing to do · $..."
        if let pct = summary.split(separator: "%").first?.split(separator: " ").last {
            return "\(pct)%"
        }
        return "—"
    }

    static func runsPerDay(tickSeconds: Int) -> Int {
        max(1, 86_400 / max(60, tickSeconds))
    }

    // MARK: - Catalog (curated for inbox)

    struct ModelOption: Identifiable, Hashable, Sendable {
        let id: String
        let providerID: String
        let modelID: String
        let displayName: String
        let subtitle: String
        let inputPerMTok: Double
        let outputPerMTok: Double
        let cacheReadPerMTok: Double
        let badge: String? // e.g. "sub · $0" or "cheapest"
        let isZeroCost: Bool

        var perActiveTick: Double {
            // 60k prompt + 4k completion for analyst; 8k+0.3k per verifier call
            // For analyst cards we show analyst-only; atelier bar joins them.
            let input = 60_000.0 * inputPerMTok / 1_000_000.0
            let output = 4_000.0 * outputPerMTok / 1_000_000.0
            let cache = 0.0 // conservative; cache-hit prefix saves but we show worst-case
            return input + output + cache
        }
    }

        static let analystCatalog: [ModelOption] = [
        ModelOption(id: "deepseek:deepseek-v4-flash",
            providerID: "deepseek",
            modelID: "deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash 0731",
            subtitle: "Default · cheapest cloud, 1M ctx, cache $0.0028/M",
            inputPerMTok: 0.14,
            outputPerMTok: 0.28,
            cacheReadPerMTok: 0.0028,
            badge: "cheapest",
            isZeroCost: false),
        ModelOption(id: "ollama:qwen3.6-27b", providerID: "ollama", modelID: "qwen3.6:27b-coding-nvfp4", displayName: "Qwen 3.6 27B (Ollama)", subtitle: "Local · $0 · stays on this Mac", inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0, badge: "local · $0", isZeroCost: true),
        ModelOption(id: "codex:codex-gpt-5.6-luna-family", providerID: "codex", modelID: "codex-gpt-5.6-luna-family", displayName: "GPT-5.6 Luna via Codex", subtitle: "Sub · $0 · uses your Codex sub", inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0, badge: "sub · $0", isZeroCost: true),
        ModelOption(id: "factory:factory-minimax-m2.7-family",
            providerID: "factory",
            modelID: "factory-minimax-m2.7-family",
            displayName: "MiniMax M2.7 via Factory",
            subtitle: "Sub · $0 · uses your Factory sub",
            inputPerMTok: 0,
            outputPerMTok: 0,
            cacheReadPerMTok: 0,
            badge: "sub · $0",
            isZeroCost: true),
        ModelOption(id: "zai:glm-5", providerID: "zai", modelID: "glm-5", displayName: "GLM-5", subtitle: "Z.ai · $0.07/M · 1M ctx", inputPerMTok: 0.07, outputPerMTok: 0.07, cacheReadPerMTok: 0.02, badge: nil, isZeroCost: false),
        ModelOption(id: "minimax:minimax-m2.7-family", providerID: "minimax", modelID: "minimax-m2.7-family", displayName: "MiniMax M2.7 (direct)", subtitle: "API · $0.69/M flat", inputPerMTok: 0.69, outputPerMTok: 0.69, cacheReadPerMTok: 0.07, badge: nil, isZeroCost: false)
    ]

    static let verifierCatalog: [ModelOption] = [
        ModelOption(id: "openai:gpt-5.6-luna", providerID: "openai", modelID: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", subtitle: "Default verifier · $0.20/$1.20 · cross-provider", inputPerMTok: 0.20, outputPerMTok: 1.20, cacheReadPerMTok: 0.02, badge: "cross-provider", isZeroCost: false),
        ModelOption(id: "openai:gpt-5.6-terra", providerID: "openai", modelID: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", subtitle: "Stronger verifier · $2.50/$15", inputPerMTok: 2.5, outputPerMTok: 15, cacheReadPerMTok: 0.25, badge: "strong", isZeroCost: false),
        ModelOption(id: "codex:codex-gpt-5.6-luna-family", providerID: "codex", modelID: "codex-gpt-5.6-luna-family", displayName: "Luna via Codex", subtitle: "Sub · $0 · same family but sub", inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0, badge: "sub · $0", isZeroCost: true),
        ModelOption(id: "ollama:ollama-deepseek", providerID: "ollama", modelID: "deepseek-v4-flash", displayName: "DeepSeek via Ollama", subtitle: "Local · $0 if you host it", inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0, badge: "local · $0", isZeroCost: true)
    ]

    static func analystOption(for config: BurnBarInboxConfig) -> ModelOption {
        analystCatalog.first { $0.providerID == config.analystProviderID && $0.modelID == config.analystModel }
            ?? analystCatalog[0]
    }
    static func verifierOption(for config: BurnBarInboxConfig) -> ModelOption {
        verifierCatalog.first { $0.providerID == config.verifierProviderID && $0.modelID == config.verifierModel }
            ?? verifierCatalog[0]
    }
}

// MARK: - Model card

private struct AIInboxModelCard: View {
    let option: AIInboxCostCockpitView.ModelOption
    let isSelected: Bool
    let isZeroCost: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(isSelected ? DesignSystem.Colors.ember : DesignSystem.Colors.borderSubtle)
                        .overlay(
                            Circle().stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                        )
                        .frame(width: 12, height: 12)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.displayName)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        Text(option.subtitle)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let badge = option.badge {
                        Text(badge)
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(
                                isZeroCost ? DesignSystem.Colors.success :
                                badge == "cheapest" ? DesignSystem.Colors.ember :
                                DesignSystem.Colors.textMuted
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(
                                    isZeroCost ? DesignSystem.Colors.success.opacity(0.10) :
                                    DesignSystem.Colors.surfaceMuted
                                )
                            )
                    }
                }

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("$\(String(format: "%.2f", option.inputPerMTok))/$\(String(format: "%.2f", option.outputPerMTok)) per M")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    Text("≈ \(AIInboxCostCockpitView.currency(option.perActiveTick)) / active tick")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(isZeroCost ? DesignSystem.Colors.success : DesignSystem.Colors.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .fill(
                        isSelected
                            ? (colorScheme == .dark ? DesignSystem.Colors.surfaceElevated : Color.white)
                            : DesignSystem.Colors.surfaceElevated.opacity(0.6)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                    .stroke(isSelected ? DesignSystem.Colors.ember.opacity(0.9) : DesignSystem.Colors.borderSubtle, lineWidth: isSelected ? 1.2 : 0.5)
            )
            .shadow(color: isSelected ? DesignSystem.Colors.ember.opacity(0.12) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - What-if bar

private struct AIInboxWhatIfBar: View {
    let analyst: AIInboxCostCockpitView.ModelOption
    let verifier: AIInboxCostCockpitView.ModelOption
    let runsPerDay: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("This pairing")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                Text("per day if every check were active")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Pill(text: analyst.displayName, tint: DesignSystem.Colors.ember)
                Text("+")
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Pill(text: verifier.displayName, tint: DesignSystem.Colors.whimsy)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(estimatedDailyWorst)
                        .font(DesignSystem.Typography.mono)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .monospacedDigit()
                    Text("realistic ≈ \(estimatedDailyRealistic)  (15% active)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            // Cost split bar — ember for analyst, whimsy for verifier(s)
            GeometryReader { geo in
                let a = max(0.0001, analyst.perActiveTick)
                let v = max(0.0001, verifierCostPerTick)
                let total = a + v
                let aFrac = total > 0 ? a / total : 0.5
                HStack(spacing: 2) {
                    Capsule()
                        .fill(DesignSystem.Colors.ember.opacity(0.85))
                        .frame(width: geo.size.width * aFrac, height: 6)
                    Capsule()
                        .fill(DesignSystem.Colors.whimsy.opacity(0.85))
                        .frame(width: geo.size.width * (1 - aFrac) - 2, height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                HStack(spacing: 4) {
                    Circle().fill(DesignSystem.Colors.ember).frame(width: 6, height: 6)
                    Text("Analyst \(AIInboxCostCockpitView.currency(analyst.perActiveTick))")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                HStack(spacing: 4) {
                    Circle().fill(DesignSystem.Colors.whimsy).frame(width: 6, height: 6)
                    Text("Verifier \(AIInboxCostCockpitView.currency(verifierCostPerTick)) (×up to 3)")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
                if analyst.isZeroCost && verifier.isZeroCost {
                    Label("$0 with your subs", systemImage: "checkmark.seal.fill")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.success)
                }
            }
        }
    }

    private var verifierCostPerTick: Double {
        // up to 3 verifier calls per active tick, 8k in + 0.3k out each
        let perCall = 8_000.0 * verifier.inputPerMTok / 1_000_000.0 + 300.0 * verifier.outputPerMTok / 1_000_000.0
        return perCall * 3
    }

    private var estimatedDailyWorst: String {
        let perTick = analyst.perActiveTick + verifierCostPerTick
        let perDay = perTick * Double(runsPerDay)
        return AIInboxCostCockpitView.currency(perDay)
    }
    private var estimatedDailyRealistic: String {
        let perTick = analyst.perActiveTick + verifierCostPerTick
        let perDay = perTick * Double(runsPerDay) * 0.15
        return AIInboxCostCockpitView.currency(perDay)
    }

    private struct Pill: View {
        let text: String
        let tint: Color
        var body: some View {
            Text(text)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.10)))
                .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.5))
                .lineLimit(1)
        }
    }
}

// MARK: - Sparkline

private struct AIInboxSpendSparkline: View {
    let runs: [BurnBarInboxRunTelemetry]

    var body: some View {
        let values = runs.reversed().map(\.costUSD)
        let maxVal = max(0.0001, values.max() ?? 0.0001)
        GeometryReader { geo in
            let stepX = geo.size.width / CGFloat(max(1, values.count - 1))
            // Bars for cost, dots for free
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, val in
                    let h = CGFloat(val / maxVal) * geo.size.height
                    let isFree = val == 0
                    Capsule()
                        .fill(isFree ? DesignSystem.Colors.borderSubtle : DesignSystem.Colors.ember.opacity(0.9))
                        .frame(width: max(3, stepX * 0.55), height: isFree ? 2 : max(4, h))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .frame(width: stepX)
                }
            }
        }
    }
}

// MARK: - Config helpers

private extension BurnBarInboxConfig {
    func with(analystProviderID: String, analystModel: String) -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: enabled, egressMode: egressMode, tickSeconds: tickSeconds,
            remotePhaseEveryNTicks: remotePhaseEveryNTicks, dailyBudgetUSD: dailyBudgetUSD,
            maxVerifierCallsPerTick: maxVerifierCallsPerTick, perTickPromptTokenCap: perTickPromptTokenCap,
            analystProviderID: analystProviderID, analystModel: analystModel,
            verifierProviderID: verifierProviderID, verifierModel: verifierModel,
            githubEnabled: githubEnabled, notifyOnP1: notifyOnP1, lookbackMinutes: lookbackMinutes
        )
    }
    func with(verifierProviderID: String, verifierModel: String) -> BurnBarInboxConfig {
        BurnBarInboxConfig(
            enabled: enabled, egressMode: egressMode, tickSeconds: tickSeconds,
            remotePhaseEveryNTicks: remotePhaseEveryNTicks, dailyBudgetUSD: dailyBudgetUSD,
            maxVerifierCallsPerTick: maxVerifierCallsPerTick, perTickPromptTokenCap: perTickPromptTokenCap,
            analystProviderID: analystProviderID, analystModel: analystModel,
            verifierProviderID: verifierProviderID, verifierModel: verifierModel,
            githubEnabled: githubEnabled, notifyOnP1: notifyOnP1, lookbackMinutes: lookbackMinutes
        )
    }
}

#if DEBUG
#Preview {
    AIInboxCostCockpitView(
        model: {
            let m = AIInboxSettingsModel()
            return m
        }()
    )
    .padding()
    .frame(width: 560)
    .background(DesignSystem.Colors.background)
}
#endif
