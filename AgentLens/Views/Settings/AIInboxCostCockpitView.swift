import SwiftUI
import OpenBurnBarKernel

/// Cost ↔ performance selector for the AI Inbox analyst/verifier pair.
///
/// Presets are the primary control: Fast / Balanced / Thorough map onto the
/// DeepSeek Flash + Luna design from `docs/AI_INBOX.md`. Advanced disclosure
/// lets power users pin any catalog id the daemon router already understands.
struct AIInboxCostCockpitView: View {
    @Bindable var model: AIInboxSettingsModel
    @State private var showAdvanced = false

    private var selectedPreset: BurnBarInboxSynthesisPreset? {
        BurnBarInboxSynthesisPreset.matching(config: model.config)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Intelligence tradeoff")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Which models write and check inbox briefs. Detectors still run for free either way — this only gates narrative synthesis.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(BurnBarInboxSynthesisPreset.allCases, id: \.self) { preset in
                    presetRow(preset)
                }
            }

            if selectedPreset == nil {
                Text("Custom models selected below.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            DisclosureGroup("Advanced model IDs", isExpanded: $showAdvanced) {
                advancedPickers
                    .padding(.top, DesignSystem.Spacing.xs)
            }
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private func presetRow(_ preset: BurnBarInboxSynthesisPreset) -> some View {
        let isSelected = selectedPreset == preset
        return Button {
            model.update { preset.applied(to: $0) }
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                    .font(.system(size: 16))
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(preset.title)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Spacer(minLength: 0)
                        Text(String(format: "~$%.3f / tick", preset.estimatedCostPerActiveTickUSD))
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    Text(preset.subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(preset.analystModel) · \(preset.maxVerifierCallsPerTick == 0 ? "no verifier" : "\(preset.verifierModel) ×\(preset.maxVerifierCallsPerTick)")")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                    .fill(isSelected
                          ? DesignSystem.Colors.ember.opacity(0.10)
                          : DesignSystem.Colors.surfaceElevated.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.ember.opacity(0.45) : DesignSystem.Colors.borderSubtle,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(OBBAccessibilityID.settingsRow("ai-inbox-preset-\(preset.rawValue)"))
    }

    private var advancedPickers: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            labeledPicker(
                title: "Analyst",
                selection: Binding(
                    get: { "\(model.config.analystProviderID):\(model.config.analystModel)" },
                    set: { raw in
                        let parts = Self.splitProviderModel(raw)
                        model.update {
                            $0.with(
                                analystProviderID: parts.provider,
                                analystModel: parts.model
                            )
                        }
                    }
                ),
                options: Self.analystOptions
            )

            labeledPicker(
                title: "Verifier",
                selection: Binding(
                    get: { "\(model.config.verifierProviderID):\(model.config.verifierModel)" },
                    set: { raw in
                        let parts = Self.splitProviderModel(raw)
                        model.update {
                            $0.with(
                                maxVerifierCallsPerTick: model.config.maxVerifierCallsPerTick == 0 ? 3 : nil,
                                verifierProviderID: parts.provider,
                                verifierModel: parts.model
                            )
                        }
                    }
                ),
                options: Self.verifierOptions
            )

            HStack {
                Text("Verifier calls / tick")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                Stepper(
                    value: Binding(
                        get: { model.config.maxVerifierCallsPerTick },
                        set: { value in
                            model.update { $0.with(maxVerifierCallsPerTick: value) }
                        }
                    ),
                    in: 0...12
                ) {
                    Text("\(model.config.maxVerifierCallsPerTick)")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
            }
        }
    }

    private func labeledPicker(
        title: String,
        selection: Binding<String>,
        options: [(id: String, label: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Picker(title, selection: selection) {
                ForEach(options, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private static let analystOptions: [(id: String, label: String)] = [
        ("deepseek:deepseek-v4-flash", "DeepSeek V4 Flash"),
        ("deepseek:deepseek-v4-pro", "DeepSeek V4 Pro"),
        ("deepseek:deepseek-chat", "DeepSeek Chat"),
        ("openai:gpt-5.6-luna", "GPT-5.6 Luna"),
        ("anthropic:claude-sonnet-4-6", "Claude Sonnet 4.6"),
        ("ollama:qwen3.5:4b", "Ollama Qwen 3.5 4B (local)")
    ]

    private static let verifierOptions: [(id: String, label: String)] = [
        ("openai:gpt-5.6-luna", "GPT-5.6 Luna"),
        ("openai:gpt-5.4", "GPT-5.4"),
        ("anthropic:claude-sonnet-4-6", "Claude Sonnet 4.6"),
        ("deepseek:deepseek-v4-flash", "DeepSeek V4 Flash")
    ]

    static func splitProviderModel(_ raw: String) -> (provider: String, model: String) {
        guard let colon = raw.firstIndex(of: ":") else {
            return ("deepseek", raw)
        }
        let provider = String(raw[..<colon])
        let model = String(raw[raw.index(after: colon)...])
        return (provider, model.isEmpty ? "deepseek-v4-flash" : model)
    }
}
