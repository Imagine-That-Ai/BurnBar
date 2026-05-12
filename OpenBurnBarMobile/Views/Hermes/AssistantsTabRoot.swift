import SwiftUI
import OpenBurnBarCore

// MARK: - Assistants Tab Root
//
// Plan 2 — the iOS Assistants surface. Renders one of two child views based
// on the user-selected runtime:
//   • .hermes → existing `HermesConversationListView` (unchanged).
//   • .pi     → new `PiConversationListView`.
//
// A small runtime pill sits in the navigation toolbar above whichever child
// is active. Selection is persisted in `@AppStorage("assistants.activeRuntime")`
// so the surface remembers across launches.

struct AssistantsTabRoot: View {
    let hermesService: HermesService
    let dashboardSnapshot: DashboardStore?

    @State private var piService = PiService()
    @AppStorage("assistants.activeRuntime") private var rawRuntime: String = AssistantRuntimeID.hermes.rawValue
    @State private var showConnectionSheet = false

    private var runtime: AssistantRuntimeID {
        AssistantRuntimeID(rawValue: rawRuntime) ?? .hermes
    }

    var body: some View {
        Group {
            switch runtime {
            case .hermes:
                HermesConversationListView(service: hermesService, dashboardSnapshot: dashboardSnapshot)
            case .pi:
                PiConversationListView(service: piService)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                AssistantRuntimePill(
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

            // Forward an attached prompt (e.g. from the "Ask Hermes" /
            // "Ask Pi" widget chip AppIntent) into the pending-prompt
            // singleton. The child conversation list observes the slot
            // and auto-submits on appear.
            if let prompt = note.userInfo?["prompt"] as? String,
               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AssistantPendingPrompt.shared.stash(assistant: parsed, prompt: prompt)
            }
        }
    }
}

// MARK: - Assistant Runtime Pill

struct AssistantRuntimePill: View {
    @Binding var selection: AssistantRuntimeID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AssistantRuntimeID.allCases, id: \.self) { runtime in
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
        case .hermes: return AnyShapeStyle(MobileTheme.mercuryGradient)
        case .pi:     return AnyShapeStyle(MobileTheme.piGradient)
        }
    }

    private func activeForeground(_ runtime: AssistantRuntimeID) -> Color {
        switch runtime {
        case .hermes: return Color(hex: "151210")
        case .pi:     return .white
        }
    }
}
