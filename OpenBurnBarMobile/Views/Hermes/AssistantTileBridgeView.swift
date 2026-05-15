import SwiftUI
import OpenBurnBarCore

// MARK: - Assistant Tile Bridge View
//
// Placeholder rendered when a runtime exists in `AssistantRuntimeID` but
// has no first-class mobile chat surface (or its CLI mirror isn't yet
// wired). Lives outside the legacy `AssistantsTabRoot` since Hermes
// Square is now the default — only the bridge view itself is still
// reachable, from `HermesSquareRoot` when routing to an unrecognised
// runtime.

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

// MARK: - Chat Tile Preferences Storage key
//
// Lifted out of the deleted `AssistantsTabRoot.swift` so the rest of the
// app (Hermes Square `tilePreferencesJSON` storage, screenshot mode,
// etc.) keeps reading from the same `@AppStorage` key.

enum ChatTilePreferencesStorage {
    static let userDefaultsKey = "chat.tilePreferences.v1"
}
