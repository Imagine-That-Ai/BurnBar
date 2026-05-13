import SwiftUI
import OpenBurnBarCore

// MARK: - Assistants Tab Root
//
// Renders the runtime currently selected in the assistants pill. Today the
// pill exposes up to five runtimes — Hermes, Pi, Codex, Claude, OpenClaw —
// filtered by the user's `ChatTilePreferences` (Settings → Chat tiles).
//
// Hermes and Pi have first-class mobile chat surfaces (`HermesConversationListView`
// / `PiConversationListView`). The remaining three (Codex / Claude / OpenClaw)
// today render an `AssistantTileBridgeView` that explains the runtime is
// driven from the macOS host and lets the user jump to the connection
// sheet.

struct AssistantsTabRoot: View {
    let hermesService: HermesService
    let dashboardSnapshot: DashboardStore?

    @State private var piService = PiService()
    @AppStorage("assistants.activeRuntime") private var rawRuntime: String = AssistantRuntimeID.hermes.rawValue
    @AppStorage(ChatTilePreferencesStorage.userDefaultsKey) private var tilePreferencesJSON: String = ""
    @State private var showConnectionSheet = false

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

    var body: some View {
        Group {
            switch runtime {
            case .hermes:
                HermesConversationListView(service: hermesService, dashboardSnapshot: dashboardSnapshot)
            case .pi:
                PiConversationListView(service: piService)
            case .codex, .claude, .openClaw:
                AssistantTileBridgeView(runtime: runtime) {
                    showConnectionSheet = true
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                AssistantRuntimePill(
                    visible: visibleTiles,
                    selection: Binding(
                        get: { runtime },
                        set: { newValue in
                            rawRuntime = newValue.rawValue
                            HapticBus.tabChange()
                        }
                    )
                )
            }
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

// MARK: - Assistant Runtime Pill

struct AssistantRuntimePill: View {
    let visible: [AssistantRuntimeID]
    @Binding var selection: AssistantRuntimeID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visible, id: \.self) { runtime in
                segment(for: runtime)
            }
        }
        .padding(3)
        .background(MobileTheme.Colors.surface.opacity(0.55))
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Runtime selector")
    }

    @ViewBuilder
    private func segment(for runtime: AssistantRuntimeID) -> some View {
        let active = selection == runtime
        Button {
            selection = runtime
        } label: {
            HStack(spacing: 4) {
                Text(runtime.glyph)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(runtime.displayName)
                    .font(MobileTheme.Typography.caption.bold())
            }
            .foregroundStyle(active ? activeForeground(runtime) : MobileTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if active {
                    Capsule(style: .continuous).fill(gradient(for: runtime))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(runtime.displayName) runtime")
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    private func gradient(for runtime: AssistantRuntimeID) -> AnyShapeStyle {
        switch runtime {
        case .hermes:   return AnyShapeStyle(MobileTheme.mercuryGradient)
        case .pi:       return AnyShapeStyle(MobileTheme.piGradient)
        case .codex:    return AnyShapeStyle(LinearGradient(colors: [Color(hex: "1ABC9C"), Color(hex: "2ECC71")], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .claude:   return AnyShapeStyle(LinearGradient(colors: [Color(hex: "D58A4F"), Color(hex: "C76A2C")], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .openClaw: return AnyShapeStyle(LinearGradient(colors: [Color(hex: "6E56CF"), Color(hex: "4F44C6")], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func activeForeground(_ runtime: AssistantRuntimeID) -> Color {
        switch runtime {
        case .hermes: return Color(hex: "151210")
        case .pi, .codex, .claude, .openClaw: return .white
        }
    }
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
