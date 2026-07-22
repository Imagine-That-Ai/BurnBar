import OpenBurnBarCore
import SwiftUI

// MARK: - Elder Wand Configurator
//
// The Elder Wand configurator: assemble an analysis panel + judge from the
// live advertised models, tune the tool-call budget, and save it as a named
// preset. This is the live configurator surface itself — NOT the entitlement
// gate. The integration layer wraps the *entry* (Settings row / chat-header
// button) with `.gatedFeature(.elderWand, …)`; this view assumes it is already
// reachable.
//
// Live model list comes from the BurnBar daemon gateway that executes Fusion. When no
// controller is in scope (for example, a preview or disconnected legacy
// surface), the view renders an empty state instead of a live picker.

struct ElderWandConfiguratorView: View {
    let controller: ChatSessionController?
    let settingsManager: SettingsManager

    /// The configurator owns its edit buffer (view-owned ⇒ `@State private`).
    @State private var editor = ElderWandConfiguratorModel()

    init(controller: ChatSessionController?, settingsManager: SettingsManager) {
        self.controller = controller
        self.settingsManager = settingsManager
    }

    var body: some View {
        SettingsDetailContainer(
            title: "Analysis Models",
            subtitle: "The Elder Wand answers hard prompts with a panel of models. They reason in parallel; a judge compares their answers; your chat model writes the final reply."
        ) {
            if let controller {
                ElderWandConfiguratorBody(
                    controller: controller,
                    settings: settingsManager.elderWand,
                    editor: editor
                )
            } else {
                ElderWandEmptyState()
            }
        }
        .task {
            await controller?.probeBurnBarGatewayAvailability()
        }
    }
}

// MARK: - Body (controller present)

/// The live configurator. Split out so the grouped model list is resolved once
/// per render with the controller in hand, and the sections receive prepared,
/// cached data (no inline `.filter` in any section body).
private struct ElderWandConfiguratorBody: View {
    let controller: ChatSessionController
    @Bindable var settings: ElderWandSettings
    @Bindable var editor: ElderWandConfiguratorModel

    @MainActor private var groupedModels: [ElderWandProviderGroup] {
        ElderWandModelGrouping.groups(from: controller)
    }

    var body: some View {
        let groups = groupedModels
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
            if groups.isEmpty {
                ElderWandNoModelsState()
            } else {
                GlassCard {
                    ElderWandAnalysisSection(model: editor, groups: groups)
                        .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    ElderWandJudgeSection(model: editor, groups: groups)
                        .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    ElderWandToolBudgetSection(model: editor)
                        .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    ElderWandPresetSection(settings: settings, editor: editor)
                        .padding(DesignSystem.Spacing.md)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty state (no advertised models)

private struct ElderWandNoModelsState: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.amber)

                VStack(alignment: .leading, spacing: 4) {
                    Text("No live models advertised")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text("Connect or enable a routed provider, then refresh the BurnBar gateway.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.xl)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No live models advertised. Connect or enable a routed provider, then refresh the BurnBar gateway.")
    }
}

// MARK: - Tool-call budget

/// The `max_tool_calls` control (OpenRouter Fusion parity: 1–16, default 8).
/// Each panel model and the judge may take this many web_search / web_fetch
/// steps.
private struct ElderWandToolBudgetSection: View {
    @Bindable var model: ElderWandConfiguratorModel

    private var range: ClosedRange<Double> {
        Double(ElderWandPreset.maxToolCallsRange.lowerBound)
            ... Double(ElderWandPreset.maxToolCallsRange.upperBound)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(model.maxToolCalls) },
            set: { model.maxToolCalls = Int($0.rounded()) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Research budget")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Max web search / fetch steps per model.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: DesignSystem.Spacing.sm)

                Text("\(model.maxToolCalls)")
                    .font(DesignSystem.Typography.title)
                    .monospacedDigit()
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.snappy, value: model.maxToolCalls)
            }

            Slider(
                value: sliderBinding,
                in: range,
                step: 1
            ) {
                Text("Research budget")
            } minimumValueLabel: {
                Text("\(ElderWandPreset.maxToolCallsRange.lowerBound)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } maximumValueLabel: {
                Text("\(ElderWandPreset.maxToolCallsRange.upperBound)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .tint(DesignSystem.Colors.amber)
            .accessibilityValue("\(model.maxToolCalls) tool calls")
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Empty state (no controller)

/// Shown when the configurator is opened without a `ChatSessionController`
/// (e.g. from the Settings tree). The live model catalog is only available
/// from a chat session, so the panel can't be assembled here.
private struct ElderWandEmptyState: View {
    var body: some View {
        GlassCard {
            VStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)

                Text("Open from a chat to pick live models")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("The Elder Wand panel is built from the models the BurnBar gateway is advertising right now. Start a chat, then open Analysis Models from the chat header.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(DesignSystem.Spacing.xl)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open from a chat to pick live models.")
    }
}

// MARK: - Model grouping

/// Groups the BurnBar daemon's live advertised models by provider,
/// de-duplicating by model ID. Pure transform so the view body stays free of
/// heavy compute.
enum ElderWandModelGrouping {
    @MainActor static func groups(from controller: ChatSessionController) -> [ElderWandProviderGroup] {
        groups(from: controller.burnBarGatewayModels)
    }

    static func groups(
        from advertisedModels: [OpenAICompatibleAdvertisedModel]
    ) -> [ElderWandProviderGroup] {
        var seen = Set<String>()
        var byProvider: [String: [ElderWandModelOption]] = [:]
        var providerOrder: [String] = []

        for advertised in advertisedModels {
            let modelID = advertised.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, !seen.contains(modelID) else { continue }
            seen.insert(modelID)

            let providerName = resolvedProviderName(for: advertised)
            if byProvider[providerName] == nil {
                byProvider[providerName] = []
                providerOrder.append(providerName)
            }
            byProvider[providerName]?.append(
                ElderWandModelOption(
                    id: modelID,
                    title: advertised.menuTitle,
                    isRouteEligible: advertised.routeEligible
                )
            )
        }

        return providerOrder.map { provider in
            ElderWandProviderGroup(
                providerName: provider,
                options: (byProvider[provider] ?? []).sorted { $0.title < $1.title }
            )
        }
    }

    private static func resolvedProviderName(for model: OpenAICompatibleAdvertisedModel) -> String {
        if let name = model.providerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let id = model.providerID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        return "Other"
    }
}
