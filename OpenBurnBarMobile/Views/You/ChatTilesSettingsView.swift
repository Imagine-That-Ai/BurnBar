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
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(detailCopy(for: runtime))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            UnifiedProviderLogoView(provider: runtime.agentProvider, size: 29)
                        }
                    }
                    .tint(MobileTheme.ember)
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
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("Routes Hermes traffic through \(provider.displayName).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            UnifiedProviderLogoView(provider: provider.agentProvider, size: 29)
                        }
                    }
                    .tint(MobileTheme.ember)
                }
            } header: {
                Text("Hermes models")
            } footer: {
                Text("Each toggle hides or shows a sub-provider in the Hermes model picker. Disabled providers stop appearing even when the live relay advertises them.")
            }
        }
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

    private func detailCopy(for runtime: AssistantRuntimeID) -> String {
        switch runtime {
        case .hermes:   return "Hosted AI assistant connected to your Mac."
        case .pi:       return "On-device Pi runtime, paired via gateway."
        case .codex:    return "Codex chat bridged from your Mac."
        case .claude:   return "Claude Code chat bridged from your Mac."
        case .openClaw: return "OpenClaw local agent bridged from your Mac."
        case .droid:    return "Droid chat bridged from your Mac."
        case .forge:    return "Forge chat bridged from your Mac."
        case .antigravity: return "Antigravity chat bridged from your Mac."
        case .grok: return "Grok Build chat bridged from your Mac."
        case .cursorAgent: return "Cursor Agent chat bridged from your Mac."
        }
    }
}
