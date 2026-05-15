import SwiftUI
import OpenBurnBarCore

// MARK: - Assistants Tab Root
//
// Renders the runtime currently selected in the assistants switcher. Today the
// switcher exposes up to five runtimes — Hermes, Pi, Codex, Claude, OpenClaw —
// filtered by the user's `ChatTilePreferences` (Settings → Chat tiles).
//
// Hermes and Pi have first-class mobile chat surfaces (`HermesConversationListView`
// / `PiConversationListView`). The remaining three (Codex / Claude / OpenClaw)
// today render an `AssistantTileBridgeView` that explains the runtime is
// driven from the macOS host and lets the user jump to the connection
// sheet.
//
// Toolbar layout (ChatGPT-app inspired):
//   • `.topBarLeading`  → `ConnectionStatusButton` (signal + status dot).
//   • `.principal`      → `AgentIdentityChip` (brand icon + name + sub-model + chevron).
//   • `.topBarTrailing` → owned by the inner conversation list (e.g. Hermes
//                         ellipsis menu, Pi settings). Untouched here.

struct AssistantsTabRoot: View {
    let hermesService: HermesService
    let dashboardSnapshot: DashboardStore?

    @State private var piService = PiService()
    @AppStorage("assistants.activeRuntime") private var rawRuntime: String = AssistantRuntimeID.hermes.rawValue
    @AppStorage(ChatTilePreferencesStorage.userDefaultsKey) private var tilePreferencesJSON: String = ""
    @State private var showConnectionSheet = false
    @State private var showAgentSwitcher = false

    private var preferences: ChatTilePreferences {
        ChatTilePreferences.from(jsonString: tilePreferencesJSON).sanitized()
    }

    private var visibleTiles: [AssistantRuntimeID] {
        // Hermes is always visible — same guarantee as the sanitize step.
        let ordered = preferences.orderedVisibleTiles
        return ordered.isEmpty ? [.hermes] : ordered
    }

    private var runtime: AssistantRuntimeID {
        let parsed = AssistantRuntimeID(rawValue: rawRuntime) ?? .hermes
        return visibleTiles.contains(parsed) ? parsed : (visibleTiles.first ?? .hermes)
    }

    private var runtimeBinding: Binding<AssistantRuntimeID> {
        Binding(
            get: { runtime },
            set: { newValue in
                rawRuntime = newValue.rawValue
                HapticBus.tabChange()
            }
        )
    }

    private var statusResolver: AssistantStatusResolver {
        AssistantStatusResolver(hermesService: hermesService, piService: piService)
    }

    private var modelSummary: HermesModelSummary? {
        guard runtime == .hermes else { return nil }
        return HermesModelSummary(service: hermesService)
    }

    var body: some View {
        Group {
            switch runtime {
            case .hermes:
                HermesConversationListView(service: hermesService, dashboardSnapshot: dashboardSnapshot)
            case .pi:
                PiConversationListView(service: piService)
            case .codex, .claude, .openClaw:
                if let cliRuntime = CLIAgentRuntime(assistant: runtime) {
                    CLIAgentConversationListView(runtime: cliRuntime)
                } else {
                    // Shouldn't happen — kept as a fallback so a future
                    // runtime added to AssistantRuntimeID without a
                    // matching CLI counterpart still has a sensible
                    // placeholder.
                    AssistantTileBridgeView(runtime: runtime) {
                        showConnectionSheet = true
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionStatusButton(
                    status: statusResolver.status(for: runtime),
                    endpointLabel: statusResolver.endpointLabel(for: runtime),
                    onTap: { showConnectionSheet = true }
                )
            }
            ToolbarItem(placement: .principal) {
                AgentIdentityChip(
                    runtime: runtime,
                    runtimeStatus: statusResolver.status(for: runtime),
                    modelSummary: modelSummary,
                    onTap: { showAgentSwitcher = true }
                )
            }
        }
        .sheet(isPresented: $showAgentSwitcher) {
            AgentSwitcherSheet(
                visibleRuntimes: visibleTiles,
                runtime: runtimeBinding,
                hermesService: hermesService,
                piService: piService,
                onManageConnections: {
                    showConnectionSheet = true
                }
            )
        }
        .sheet(isPresented: $showConnectionSheet) {
            AssistantConnectionSheet(
                hermesService: hermesService,
                piService: piService,
                focusedRuntime: runtime
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ShowAssistantsTab"))) { note in
            let runtimeRaw = note.userInfo?["runtime"] as? String
            let parsed = runtimeRaw.flatMap(AssistantRuntimeID.init(rawValue:)) ?? runtime
            rawRuntime = parsed.rawValue

            if let prompt = note.userInfo?["prompt"] as? String,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AssistantPendingPrompt.shared.stash(assistant: parsed, prompt: prompt)
            }
        }
    }
}

// MARK: - Tile Preferences Storage

/// Single source of truth for the `@AppStorage` key used to persist the
/// user's chat tile preferences. Mirrors the macOS `chatTilePreferencesJSON`
/// settings persistence key.
enum ChatTilePreferencesStorage {
    static let userDefaultsKey = "chat.tilePreferences.v1"
}

// MARK: - Bridge View for Non-Mobile-Native Runtimes

struct AssistantTileBridgeView: View {
    let runtime: AssistantRuntimeID
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.surface.opacity(0.6))
                    .frame(width: 88, height: 88)
                Text(runtime.glyph)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
            }
            VStack(spacing: 6) {
                Text(runtime.displayName)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(detailCopy)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button {
                onConnect()
            } label: {
                Text("Connect your Mac")
                    .font(MobileTheme.Typography.body.bold())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(MobileTheme.mercuryGradient))
                    .foregroundStyle(Color(hex: "151210"))
            }
            .buttonStyle(.plain)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EmberSurfaceBackground().ignoresSafeArea())
    }

    private var detailCopy: String {
        switch runtime {
        case .codex:
            return "Codex chat runs through OpenBurnBar on your Mac. Pair your Mac to start a session here."
        case .claude:
            return "Claude Code chat runs through OpenBurnBar on your Mac. Pair your Mac to start a session here."
        case .openClaw:
            return "OpenClaw uses your Mac's local agent runtime. Pair your Mac to chat with it from here."
        case .hermes, .pi:
            return ""
        }
    }
}
