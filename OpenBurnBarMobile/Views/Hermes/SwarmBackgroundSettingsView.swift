import SwiftUI
import OpenBurnBarCore

struct SwarmBackgroundSettingsView: View {
    @AppStorage(SwarmBackgroundPreferences.userDefaultsKey) private var prefsJSON: String = SwarmBackgroundPreferences.defaultJSON
    @Environment(\.dismiss) private var dismiss
    @State private var isProviderGlyphsExpanded = true

    private var prefs: SwarmBackgroundPreferences {
        SwarmBackgroundPreferences.from(jsonString: prefsJSON)
    }

    private var selectedGlyphSet: Set<AgentProvider> {
        Set(prefs.selectedGlyphs)
    }

    private func updatePrefs(_ mutation: (inout SwarmBackgroundPreferences) -> Void) {
        var current = prefs
        mutation(&current)
        withAnimation {
            prefsJSON = current.toJSONString()
        }
    }

    private func setProvider(_ provider: AgentProvider, isSelected: Bool) {
        updatePrefs { prefs in
            var selected = Set(prefs.selectedGlyphs)
            if isSelected {
                selected.insert(provider)
            } else {
                selected.remove(provider)
            }
            prefs.selectedGlyphs = AgentProvider.swarmGlyphProviders.filter { selected.contains($0) }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Show Swarms", selection: Binding(
                    get: { prefs.location },
                    set: { val in updatePrefs { $0.location = val } }
                )) {
                    ForEach(SwarmBackgroundLocation.allCases) { loc in
                        Text(loc.rawValue).tag(loc)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Where")
            } footer: {
                Text("Controls where the live background is rendered. 'Everywhere' applies to all tabs and surfaces where it is visually supported.")
            }

            if prefs.location != .disabled {
                Section {
                    Picker("Condition", selection: Binding(
                        get: { prefs.condition },
                        set: { val in updatePrefs { $0.condition = val } }
                    )) {
                        ForEach(SwarmBackgroundCondition.allCases) { cond in
                            Text(cond.rawValue).tag(cond)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("When")
                } footer: {
                    Text("Live backgrounds use system resources. Restricting them to Wi-Fi or Power Connected saves battery and data.")
                }

                Section {
                    Toggle("Show Central Avatar Logo", isOn: Binding(
                        get: { prefs.isAvatarEnabled },
                        set: { val in updatePrefs { $0.isAvatarEnabled = val } }
                    ))
                    Toggle("Show Bottom-Left Brand Text", isOn: Binding(
                        get: { prefs.isBrandTextEnabled },
                        set: { val in updatePrefs { $0.isBrandTextEnabled = val } }
                    ))
                    Toggle("Exclude Brand Shapes", isOn: Binding(
                        get: { prefs.excludeBrandShapes },
                        set: { val in updatePrefs { $0.excludeBrandShapes = val } }
                    ))
                } header: {
                    Text("Formation Style")
                } footer: {
                    Text("Choose whether the murmuration converges into the central brand icon, bottom-left brand text, or both. Exclude Brand Shapes skips Dollar, Code, BurnBar, Rings, and Router Flow formations, leaving only AI provider logos.")
                }

                Section {
                    DisclosureGroup(isExpanded: $isProviderGlyphsExpanded) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 10) {
                                Text(selectionCountText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                ProviderGlyphQuickActionButton(
                                    title: "All",
                                    isActive: prefs.selectedGlyphs.count == AgentProvider.swarmGlyphProviders.count
                                ) {
                                    updatePrefs { $0.selectedGlyphs = AgentProvider.swarmGlyphProviders }
                                }

                                ProviderGlyphQuickActionButton(
                                    title: "None",
                                    isActive: prefs.selectedGlyphs.isEmpty
                                ) {
                                    updatePrefs { $0.selectedGlyphs = [] }
                                }
                            }

                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 142), spacing: 10, alignment: .top)
                                ],
                                alignment: .leading,
                                spacing: 10
                            ) {
                                ForEach(AgentProvider.swarmGlyphProviders) { provider in
                                    ProviderGlyphSelectionCard(
                                        provider: provider,
                                        isSelected: selectedGlyphSet.contains(provider)
                                    ) {
                                        setProvider(provider, isSelected: !selectedGlyphSet.contains(provider))
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        SettingsLabel(
                            icon: "slider.horizontal.3",
                            color: MobileTheme.ember,
                            title: "Provider Glyphs"
                        )
                    }
                } header: {
                    Text("Provider glyphs")
                } footer: {
                    Text("Choose which agent symbols appear when the swarm periodically reconverges.")
                }
            }
        }
        .navigationTitle("Swarm Backgrounds")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if prefs.location != .disabled && prefs.selectedGlyphs.count != AgentProvider.swarmGlyphProviders.count {
                    Button("Reset All") {
                        updatePrefs { $0.selectedGlyphs = AgentProvider.swarmGlyphProviders }
                    }
                }
            }
        }
    }

    private var providerGlyphSummary: String {
        let count = prefs.selectedGlyphs.count
        let total = AgentProvider.swarmGlyphProviders.count
        if count == total { return "Customize Provider Glyphs: All providers" }
        if count == 0 { return "Customize Provider Glyphs: Provider logos hidden" }
        return "Customize Provider Glyphs: \(count)/\(total) providers"
    }

    private var selectionCountText: String {
        let count = prefs.selectedGlyphs.count
        let total = AgentProvider.swarmGlyphProviders.count
        if count == total { return "All providers selected" }
        if count == 0 { return "No provider glyphs selected" }
        return "\(count) of \(total) providers selected"
    }
}

private struct ProviderGlyphQuickActionButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MobileTheme.Typography.tiny.weight(.bold))
                .foregroundStyle(isActive ? .white : MobileTheme.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? MobileTheme.ember : MobileTheme.Colors.surfaceElevated)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isActive ? MobileTheme.ember.opacity(0.1) : MobileTheme.Colors.border.opacity(0.65),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ProviderGlyphSelectionCard: View {
    let provider: AgentProvider
    let isSelected: Bool
    let action: () -> Void

    private var providerColor: Color {
        DesignSystemColors.primary(for: provider)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(MobileTheme.Colors.border.opacity(0.7), lineWidth: 1)
                        )

                    UnifiedProviderLogoView(provider: provider, size: 30, useFallbackColor: false)

                    Circle()
                        .fill(providerColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: 2)
                }
                .frame(width: 42, height: 42)

                Text(provider.rawValue)
                    .font(MobileTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? providerColor : MobileTheme.Colors.textMuted.opacity(0.42))
            }
            .padding(10)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? providerColor.opacity(0.16) : MobileTheme.Colors.surface.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? providerColor.opacity(0.72) : MobileTheme.Colors.border.opacity(0.46), lineWidth: isSelected ? 1.4 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
