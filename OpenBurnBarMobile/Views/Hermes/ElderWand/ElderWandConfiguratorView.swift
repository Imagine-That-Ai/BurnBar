import SwiftUI
import OpenBurnBarCore

// MARK: - Elder Wand Configurator (iOS)
//
// The iOS configurator for **The Elder Wand** model-fusion router (OpenRouter
// "Fusion"-compatible). Mirrors the macOS feature, built entirely from the iOS
// design bases:
//   • analysis panel — provider-grouped multi-select chip cloud
//     (`MercuryBadgeFlowLayout` style) over the live model roster
//   • judge picker  — single-select chip cloud over the same roster
//   • preset manager — name + save + set-default + delete, persisted through
//     `ElderWandSettings.shared`
//
// The configurator never talks to StoreKit or the send-path directly; it only
// reads the live model list and writes presets to the shared store. The chat
// send-path picks the active preset's `elderWandPluginsPayload()` up on its own.
//
// Live model source: the Hermes runtime's advertised model roster
// (`HermesService.modelOptions`). When `service == nil` (opened outside a chat
// context) it renders an empty state — there is no live roster to choose from.

// MARK: - Row model

/// One selectable model in the configurator, derived from a live advertised
/// model option. Stable `Identifiable` identity (the model id) so `ForEach`
/// never reorders on selection — the contract the SwiftUI rules require.
struct ElderWandModelRow: Identifiable, Hashable {
    let id: String           // canonical model ID (the wire id stored in presets)
    let displayName: String
    let providerName: String

    init(option: HermesRuntimeModelOption) {
        self.id = option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = FriendlyModelName.format(option.displayName)
        self.providerName = option.providerName
    }

    /// Fallback row for a model id that a saved preset references but the live
    /// roster no longer advertises, so the user still sees (and can drop) it.
    init(orphanedModelID id: String) {
        self.id = id
        self.displayName = FriendlyModelName.format(id)
        self.providerName = "Not advertised"
    }
}

/// A provider's grouped rows. Stable identity by provider name keeps the
/// section list from reshuffling as the roster refreshes.
struct ElderWandProviderGroup: Identifiable, Hashable {
    let id: String          // providerName
    let rows: [ElderWandModelRow]
    var providerName: String { id }
}

// MARK: - Configurator

struct ElderWandConfiguratorView: View {
    /// The live model source. `nil` ⇒ empty state (no chat context to pick from).
    let service: HermesService?

    @State private var model: ElderWandConfiguratorModel
    @Environment(\.dismiss) private var dismiss

    init(service: HermesService?, store: ElderWandSettings = .shared) {
        self.service = service
        _model = State(initialValue: ElderWandConfiguratorModel(store: store))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                content
            }
            .navigationTitle("The Elder Wand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if providerGroups.isEmpty {
            ElderWandConfiguratorEmptyState()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    ElderWandIntroCard()
                    ElderWandAnalysisSection(model: model, groups: providerGroups)
                    ElderWandJudgeSection(model: model, groups: providerGroups)
                    ElderWandToolBudgetSection(model: model)
                    ElderWandPresetSection(model: model)
                }
                .padding(MobileTheme.Spacing.lg)
                .padding(.bottom, MobileTheme.Spacing.xxl)
            }
        }
    }

    // MARK: Live roster (prefiltered + cached per body eval, never inline in a row)

    /// Provider-grouped rows from the live roster, plus any saved-but-orphaned
    /// model ids surfaced under a trailing "Not advertised" group so the user
    /// can still see and remove them. Computed once per `body`, never inside a
    /// `ForEach` row.
    private var providerGroups: [ElderWandProviderGroup] {
        let liveOptions = service?.modelOptions ?? []
        var orderedProviders: [String] = []
        var rowsByProvider: [String: [ElderWandModelRow]] = [:]
        var seenModelIDs = Set<String>()

        for option in liveOptions {
            let row = ElderWandModelRow(option: option)
            guard !row.id.isEmpty, !seenModelIDs.contains(row.id) else { continue }
            seenModelIDs.insert(row.id)
            if rowsByProvider[row.providerName] == nil {
                orderedProviders.append(row.providerName)
            }
            rowsByProvider[row.providerName, default: []].append(row)
        }

        var groups = orderedProviders.compactMap { name -> ElderWandProviderGroup? in
            guard let rows = rowsByProvider[name], !rows.isEmpty else { return nil }
            return ElderWandProviderGroup(id: name, rows: rows)
        }

        // Surface saved-preset ids the live roster no longer advertises so the
        // selection chips below still render (and can be deselected).
        let referenced = Set(model.selectedAnalysisModelIDs).union(
            model.judgeModelID.isEmpty ? [] : [model.judgeModelID]
        )
        let orphans = referenced.subtracting(seenModelIDs)
            .filter { !$0.isEmpty }
            .sorted()
        if !orphans.isEmpty {
            groups.append(
                ElderWandProviderGroup(
                    id: "Not advertised",
                    rows: orphans.map { ElderWandModelRow(orphanedModelID: $0) }
                )
            )
        }
        return groups
    }
}

// MARK: - Intro card

private struct ElderWandIntroCard: View {
    var body: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: MobileTheme.Radius.lg) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.hermesAureate)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A panel deliberates, a judge weighs in")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pick up to eight models to answer your prompt in parallel and one judge to compare them. Your own chat model writes the final answer from that deliberation.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty state

private struct ElderWandConfiguratorEmptyState: View {
    var body: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.hermesAureate)
            Text("Open from a chat to pick live models")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text("The Elder Wand builds its panel from the models your Hermes relay is advertising right now. Start a chat so the live roster is available, then open the configurator from the chat menu.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
    }
}
