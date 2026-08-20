#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore

/// Editorial onboarding surface that replaces the dashed-rectangle placeholder
/// when the Computer Use mirror has nothing to show. It explains what
/// Computer Use is, surfaces the live blocker (signed-in / Mac relay /
/// session) inline, and offers one-tap CTAs so the user is never stuck on
/// a screen that just says "Waiting".
///
/// Mirrored by `ComputerUseAgentWatchScreen.kt` on Android so the two
/// platforms tell the same story.
struct AgentWatchEmptyStateView: View {
    let isSignedIn: Bool
    let selectedConnection: HermesConnectionRecord
    let suggestedRelay: HermesConnectionRecord?
    let sessionId: String?
    let connectionMessage: String?
    let phase: AgentWatchOverlayCoordinator.Phase
    let onOpenHermes: () -> Void
    let onUseSuggestedRelay: () -> Void
    let onOpenSettings: () -> Void

    private var hasRelaySelected: Bool {
        selectedConnection.mode == .relayLink &&
            selectedConnection.id != HermesConnectionRecord.localDefault.id
    }

    private var hasLiveSession: Bool {
        sessionId != nil || phase == .live
    }

    private var stepIndex: Int {
        if !isSignedIn { return 1 }
        if !hasRelaySelected { return 2 }
        return 3
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xl) {
                hero
                statusChecklist
                stepGuide
                capabilityStrip
                permissionsFooter
            }
            .padding(.horizontal, 20)
            .padding(.vertical, MobileTheme.Spacing.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .background(MobileTheme.background.ignoresSafeArea())
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MobileTheme.mercuryGradient)
                Text("COMPUTER USE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(MobileTheme.hermesMercury)
                Spacer()
                phaseBadge
            }

            Text("Let the agent drive your Mac")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Watch every click live. Tap the mirror to grab the wheel. Three-finger long-press halts everything.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(MobileTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(MobileTheme.mercuryGradient)
                .frame(height: 1)
                .opacity(0.55)
                .padding(.top, MobileTheme.Spacing.xs)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surfaceElevated.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .strokeBorder(MobileTheme.mercuryGradient, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
    }

    private var phaseBadge: some View {
        let (label, color): (String, Color) = {
            switch phase {
            case .idle, .stopped:       return ("STANDBY", MobileTheme.textMuted)
            case .dialing:              return ("DIALING", MobileTheme.warning)
            case .reconnecting:         return ("RECONNECTING", MobileTheme.warning)
            case .live:                 return ("LIVE", MobileTheme.success)
            case .failed:               return ("ERROR", MobileTheme.error)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(color.opacity(0.16))
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5)
            )
    }

    // MARK: - Status checklist

    private var statusChecklist: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            sectionHeader("SETUP CHECKLIST")

            statusRow(
                index: 1,
                title: "Signed in to OpenBurnBar",
                detail: isSignedIn
                    ? "Account ready."
                    : "Sign in on this device to share encrypted control with your Mac.",
                isDone: isSignedIn,
                actionLabel: isSignedIn ? nil : "Open Settings",
                action: onOpenSettings
            )

            statusRow(
                index: 2,
                title: "Hermes Remote Relay selected",
                detail: hasRelaySelected
                    ? "\(selectedConnection.displayName) is paired."
                    : suggestedRelay != nil
                        ? "Found \(suggestedRelay!.displayName) online — one tap to connect."
                        : (connectionMessage ?? "Open Hermes, sign in on the Mac, and enable Remote Relay."),
                isDone: hasRelaySelected,
                actionLabel: hasRelaySelected
                    ? nil
                    : (suggestedRelay != nil ? "Use \(suggestedRelay!.displayName)" : "Open Hermes"),
                action: { suggestedRelay != nil ? onUseSuggestedRelay() : onOpenHermes() }
            )

            statusRow(
                index: 3,
                title: "Live Computer Use session",
                detail: hasLiveSession
                    ? "Streaming — the mirror will appear above."
                    : "Ask the agent on your Mac to do something. The mirror auto-opens here.",
                isDone: hasLiveSession,
                actionLabel: nil,
                action: {}
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surface.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .strokeBorder(MobileTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func statusRow(
        index: Int,
        title: String,
        detail: String,
        isDone: Bool,
        actionLabel: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? MobileTheme.success.opacity(0.18) : MobileTheme.error.opacity(0.18))
                    .frame(width: 24, height: 24)
                Image(systemName: isDone ? "checkmark" : "circle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isDone ? MobileTheme.success : MobileTheme.error)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(MobileTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let actionLabel {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(MobileTheme.hermesAureate.opacity(0.18))
                        )
                        .overlay(
                            Capsule().strokeBorder(MobileTheme.hermesAureate.opacity(0.7), lineWidth: 0.5)
                        )
                        .foregroundStyle(MobileTheme.hermesAureate)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(actionLabel) for step \(index)")
            }
        }
    }

    // MARK: - Step guide

    private var stepGuide: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            sectionHeader("HOW IT WORKS")
            stepRow(
                ordinal: "01",
                title: "Pair a Mac in Hermes",
                detail: "Run OpenBurnBar on the Mac, sign in with the same account, and turn on Remote Relay.",
                isActive: stepIndex == 1
            )
            stepRow(
                ordinal: "02",
                title: "Pick the Mac's relay connection",
                detail: "Open the Hermes tab, tap the connection name, and choose your Mac.",
                isActive: stepIndex == 2
            )
            stepRow(
                ordinal: "03",
                title: "Start a Computer Use task",
                detail: "Ask the agent on your Mac to do something. The live mirror appears here automatically.",
                isActive: stepIndex == 3
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surface.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .strokeBorder(MobileTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func stepRow(ordinal: String, title: String, detail: String, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ordinal)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? MobileTheme.hermesAureate : MobileTheme.textMuted)
                Rectangle()
                    .fill(isActive ? MobileTheme.hermesAureate : MobileTheme.border)
                    .frame(width: 18, height: 2)
                    .opacity(isActive ? 0.9 : 0.45)
            }
            .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? MobileTheme.textPrimary : MobileTheme.textSecondary)
                Text(detail)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(MobileTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Capability strip

    private var capabilityStrip: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            sectionHeader("WHAT YOU'LL GET")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                capabilityCard(
                    icon: "rectangle.inset.filled.on.rectangle",
                    title: "Live mirror",
                    detail: "See what the agent sees."
                )
                capabilityCard(
                    icon: "hand.tap.fill",
                    title: "Tap to drive",
                    detail: "Take over with taps + drags."
                )
                capabilityCard(
                    icon: "list.bullet.clipboard",
                    title: "Full audit",
                    detail: "Every action is recorded."
                )
                capabilityCard(
                    icon: "exclamationmark.octagon.fill",
                    title: "Panic halt",
                    detail: "Three-finger long-press."
                )
            }
        }
    }

    private func capabilityCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(MobileTheme.mercuryGradient)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.textPrimary)
            Text(detail)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(MobileTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.surfaceElevated.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .strokeBorder(MobileTheme.hermesMercury.opacity(0.32), lineWidth: 0.5)
        )
    }

    // MARK: - Footer

    private var permissionsFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MobileTheme.hermesMercury)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac permissions live on the Mac")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.textPrimary)
                Text("Run \"Re-run Mac permissions setup\" from Settings → Computer Use on your Mac to walk the TCC wizard.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(MobileTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.surface.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .strokeBorder(MobileTheme.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(MobileTheme.textMuted)
    }
}

#if DEBUG
#Preview("AgentWatchEmptyStateView – signed out") {
    AgentWatchEmptyStateView(
        isSignedIn: false,
        selectedConnection: .localDefault,
        suggestedRelay: nil,
        sessionId: nil,
        connectionMessage: "Sign in to watch the Mac agent.",
        phase: .idle,
        onOpenHermes: {},
        onUseSuggestedRelay: {},
        onOpenSettings: {}
    )
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("AgentWatchEmptyStateView – relay available") {
    let suggested = HermesConnectionRecord(
        id: "mock-relay-id",
        displayName: "Alberto's MacBook",
        mode: .relayLink,
        status: .online
    )
    return AgentWatchEmptyStateView(
        isSignedIn: true,
        selectedConnection: .localDefault,
        suggestedRelay: suggested,
        sessionId: nil,
        connectionMessage: nil,
        phase: .idle,
        onOpenHermes: {},
        onUseSuggestedRelay: {},
        onOpenSettings: {}
    )
    .background(Color.black)
    .preferredColorScheme(.dark)
}
#endif
#endif
