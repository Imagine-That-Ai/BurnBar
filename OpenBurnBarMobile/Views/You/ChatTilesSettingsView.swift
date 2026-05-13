import SwiftUI
import OpenBurnBarCore

// MARK: - Chat Tiles Settings View
//
// Controls which top-level chat tiles appear in the Assistants pill and which
// Hermes sub-providers appear in the Hermes model picker. Persists a single
// JSON blob under `ChatTilePreferencesStorage.userDefaultsKey` so the on-disk
// shape matches the macOS and Android implementations.

struct ChatTilesSettingsView: View {
    @AppStorage(ChatTilePreferencesStorage.userDefaultsKey) private var tilePreferencesJSON: String = ""

    @State private var preferences: ChatTilePreferences = .default

    var body: some View {
        Form {
            Section {
                ForEach(AssistantRuntimeID.allCases, id: \.self) { runtime in
                    Toggle(isOn: tileBinding(for: runtime)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(runtime.displayName)
                                    .font(MobileTheme.Typography.body)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                Text(detailCopy(for: runtime))
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        } icon: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(tileTint(for: runtime))
                                    .frame(width: 26, height: 26)
                                Text(runtime.glyph)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            } header: {
                Text("Chat tiles")
            } footer: {
                Text("Choose which assistants appear in the Chat tab's runtime pill. Hermes always stays available.")
            }

            Section {
                ForEach(HermesSubProvider.allCases) { provider in
                    Toggle(isOn: subProviderBinding(for: provider)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(MobileTheme.Typography.body)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                Text("Routes Hermes traffic through \(provider.displayName).")
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        } icon: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(MobileTheme.Colors.surface.opacity(0.6))
                                    .frame(width: 26, height: 26)
                                Text(provider.glyph)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                            }
                        }
                    }
                }
            } header: {
                Text("Hermes models")
            } footer: {
                Text("Each toggle hides or shows a sub-provider in the Hermes model picker. Disabled providers stop appearing even when the live relay advertises them.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuroraBackdrop(density: .subtle).ignoresSafeArea())
        .navigationTitle("Chat tiles")
        .onAppear {
            preferences = ChatTilePreferences.from(jsonString: tilePreferencesJSON).sanitized()
        }
    }

    private func tileBinding(for runtime: AssistantRuntimeID) -> Binding<Bool> {
        Binding(
            get: { preferences.enabledTiles.contains(runtime) },
            set: { newValue in
                var next = preferences
                next.setTile(runtime, enabled: newValue)
                // Guardrail: keep at least one tile enabled. Hermes is the
                // implicit fallback if the user tries to disable everything.
                if next.enabledTiles.isEmpty {
                    next.enabledTiles = [.hermes]
                }
                preferences = next
                tilePreferencesJSON = next.jsonString()
            }
        )
    }

    private func subProviderBinding(for provider: HermesSubProvider) -> Binding<Bool> {
        Binding(
            get: { preferences.enabledHermesSubProviders.contains(provider) },
            set: { newValue in
                var next = preferences
                next.setHermesSubProvider(provider, enabled: newValue)
                preferences = next
                tilePreferencesJSON = next.jsonString()
            }
        )
    }

    private func tileTint(for runtime: AssistantRuntimeID) -> AnyShapeStyle {
        switch runtime {
        case .hermes:   return AnyShapeStyle(MobileTheme.mercuryGradient)
        case .pi:       return AnyShapeStyle(MobileTheme.piGradient)
        case .codex:    return AnyShapeStyle(LinearGradient(colors: [Color(hex: "1ABC9C"), Color(hex: "2ECC71")], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .claude:   return AnyShapeStyle(LinearGradient(colors: [Color(hex: "D58A4F"), Color(hex: "C76A2C")], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .openClaw: return AnyShapeStyle(LinearGradient(colors: [Color(hex: "6E56CF"), Color(hex: "4F44C6")], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func detailCopy(for runtime: AssistantRuntimeID) -> String {
        switch runtime {
        case .hermes:   return "Hosted AI assistant connected to your Mac."
        case .pi:       return "On-device Pi runtime, paired via gateway."
        case .codex:    return "Codex chat bridged from your Mac."
        case .claude:   return "Claude Code chat bridged from your Mac."
        case .openClaw: return "OpenClaw local agent bridged from your Mac."
        }
    }
}
