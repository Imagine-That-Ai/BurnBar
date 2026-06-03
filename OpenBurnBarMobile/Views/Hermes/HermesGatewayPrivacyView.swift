import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Gateway Privacy UX
//
// The end-to-end privacy surface for the BurnBar Cloud gateway chat path. When a
// message travels phone → cloud → Mac it is sealed on this device and only the
// paired Mac can open it; the cloud only relays sealed bytes. This file makes
// that state legible and trustworthy without exposing any transport/crypto jargon:
//
//   • `HermesGatewayPrivacyState` — the single source of truth for "is this chat
//     private and verified, does it need a quick update, or does it look like a
//     new/reinstalled device that needs reconnecting." Derived purely from the
//     gateway store's real key/pin state.
//   • `HermesGatewayLockChip` — a quiet lock affordance for the chat runtime rail.
//   • `HermesGatewayPrivacySheet` — a calm, jargon-free explainer with a
//     human-comparable safety code and an explicit reconnect affordance.
//
// Copy policy: benefit-first + safety-forward, never "relay key / envelope / P-256
// / pin / MITM". The security trade-off (reconnecting trusts a new connection) is
// stated honestly but calmly, and reconnect always requires an explicit tap — it
// never silently accepts a changed connection.

// MARK: - State

/// What the privacy lock should communicate for the currently targeted gateway
/// client. Pure value type so it is trivial to reason about and screenshot.
enum HermesGatewayPrivacyState: Equatable {
    /// Sealed end-to-end and the connection matches what this device trusts.
    case privateVerified
    /// Paired, but the Mac hasn't published a way to read private messages yet
    /// (usually an out-of-date BurnBar on that Mac). Sending is held until ready.
    case updateNeeded
    /// The connection looks different from when it was set up — a changed
    /// connection (possible interception) or a reinstall / new phone. Requires an
    /// explicit reconnect; sending is held closed until the user confirms.
    case reconnectNeeded

    var glyph: String {
        switch self {
        case .privateVerified: return "lock.fill"
        case .updateNeeded: return "lock.trianglebadge.exclamationmark.fill"
        case .reconnectNeeded: return "lock.trianglebadge.exclamationmark.fill"
        }
    }

    /// Short chip label. Quiet and benefit-first.
    var chipLabel: String {
        switch self {
        case .privateVerified: return "Private"
        case .updateNeeded: return "Finish setup"
        case .reconnectNeeded: return "Reconnect"
        }
    }

    var tint: Color {
        switch self {
        case .privateVerified: return MobileTheme.success
        case .updateNeeded: return MobileTheme.warning
        case .reconnectNeeded: return MobileTheme.error
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .privateVerified:
            return "Messages are private. Only your devices can read them. Double tap to learn more."
        case .updateNeeded:
            return "Action needed to keep messages private. Double tap to learn more."
        case .reconnectNeeded:
            return "This connection looks different. Reconnect to keep messages private. Double tap to learn more."
        }
    }

    /// Sheet headline.
    var sheetTitle: String {
        switch self {
        case .privateVerified: return "Your messages are private"
        case .updateNeeded: return "One step to private messages"
        case .reconnectNeeded: return "Reconnect to stay private"
        }
    }

    /// The one-line summary under the sheet headline.
    var sheetSummary: String {
        switch self {
        case .privateVerified:
            return "Messages you send here are locked on this device and can only be read on your Mac. BurnBar Cloud carries them along but can't read them."
        case .updateNeeded:
            return "Your Mac needs a quick update before it can read private messages from here. Until then, messages stay safely on this device."
        case .reconnectNeeded:
            return "This Hermes connection looks different from when you first set it up. That can happen after reinstalling BurnBar or switching to a new device — but to be safe, nothing is sent until you reconnect."
        }
    }
}

extension HermesGatewayPrivacyState {
    /// Derive the live state for a client from the gateway store's real pin/key
    /// state. `keyChanged` comes from the store's TOFU comparison (the same signal
    /// the fail-closed seal guard uses), so this never claims "private" when the
    /// underlying connection can't actually be trusted.
    static func resolve(
        client: HermesGatewayClientRecord,
        keyChanged: Bool
    ) -> HermesGatewayPrivacyState {
        if keyChanged { return .reconnectNeeded }
        if client.canSealToAgent { return .privateVerified }
        return .updateNeeded
    }

    /// Every user-facing string this state surfaces, gathered for the jargon
    /// audit test so the copy policy is enforced in CI rather than by review.
    static var allUserFacingCopyForTests: [String] {
        allCases.flatMap { state in
            [state.chipLabel, state.accessibilityLabel, state.sheetTitle, state.sheetSummary]
        }
    }
}

extension HermesGatewayPrivacyState: CaseIterable {}

// MARK: - Lock Chip

/// A quiet lock affordance for the chat runtime rail. Matches the rail's other
/// capsule chips (`runtimeChip`) in shape, padding, and typography, but carries a
/// privacy tint and opens the explainer on tap.
struct HermesGatewayLockChip: View {
    let state: HermesGatewayPrivacyState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: state.glyph)
                    .font(.system(size: 12, weight: .bold))
                Text(state.chipLabel)
                    .lineLimit(1)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(state.tint.opacity(0.12)))
            .overlay(Capsule().stroke(state.tint.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Privacy Sheet

/// The lock explainer. Plain-language "what this means", a human-comparable
/// safety code for confirming the connection across devices, and — only when the
/// connection needs it — an explicit reconnect affordance.
struct HermesGatewayPrivacySheet: View {
    let state: HermesGatewayPrivacyState
    let clientDisplayName: String
    /// A grouped, human-comparable safety code for the trusted connection, or
    /// `nil` when there isn't a key to show yet.
    let safetyCode: String?
    /// Invoked when the user explicitly confirms reconnecting. `nil` hides the
    /// reconnect button (the connection is already verified).
    let onReconnect: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showReconnectConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    hero
                    howItWorks
                    if safetyCode != nil {
                        safetyCodeCard
                    }
                    if onReconnect != nil {
                        reconnectCard
                    }
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Private messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("Reconnect Hermes?", isPresented: $showReconnectConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reconnect") {
                onReconnect?()
                dismiss()
            }
        } message: {
            Text("This trusts \(clientDisplayName) as it is now. Do this only if you recently reinstalled BurnBar or set up a new device. If you weren't expecting a change, check your Mac before reconnecting.")
        }
    }

    // MARK: Hero

    private var hero: some View {
        AuroraGlassCard(variant: heroVariant, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(state.tint.opacity(0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: state.glyph)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(state.tint)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.sheetTitle)
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(clientDisplayName)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                Text(state.sheetSummary)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var heroVariant: AuroraGlassVariant {
        switch state {
        case .privateVerified: return .hermes
        case .updateNeeded: return .urgent
        case .reconnectNeeded: return .urgent
        }
    }

    // MARK: How it works

    private var howItWorks: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Text("How it stays private")
                    .font(MobileTheme.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                privacyPoint(
                    icon: "lock.fill",
                    title: "Locked on this device",
                    detail: "Each message is locked here before it leaves your phone."
                )
                privacyPoint(
                    icon: "cloud",
                    title: "Carried, never read",
                    detail: "BurnBar Cloud passes messages along but can't open them."
                )
                privacyPoint(
                    icon: "macbook.and.iphone",
                    title: "Opened only on your Mac",
                    detail: "Only the Mac you paired can unlock and reply to them."
                )
            }
        }
    }

    private func privacyPoint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(MobileTheme.hermesAureate)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(detail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    // MARK: Safety code

    private var safetyCodeCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Label("Safety code", systemImage: "checkmark.shield.fill")
                    .font(MobileTheme.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text("Want to be extra sure no one is in the middle? Open this same screen on your Mac. If the code below matches on both, your connection is genuinely private.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let safetyCode {
                    Text(safetyCode)
                        .font(MobileTheme.Typography.monoLarge)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, MobileTheme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                                .fill(MobileTheme.hermesAureate.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                                .stroke(MobileTheme.hermesAureate.opacity(0.28), lineWidth: 0.5)
                        )
                        .accessibilityLabel("Safety code: \(spelledOut(safetyCode))")
                }
            }
        }
    }

    // MARK: Reconnect

    private var reconnectCard: some View {
        AuroraGlassCard(variant: .urgent, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Label(reconnectTitle, systemImage: "arrow.triangle.2.circlepath")
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text(reconnectDetail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    HapticBus.threshold()
                    showReconnectConfirm = true
                } label: {
                    Text("Reconnect Hermes")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.aurora(.hermes, fullWidth: true))
                .accessibilityHint("Asks you to confirm before trusting this connection again.")
            }
        }
    }

    private var reconnectTitle: String {
        switch state {
        case .reconnectNeeded: return "Looks like a new or reinstalled device"
        default: return "Reconnect this device"
        }
    }

    private var reconnectDetail: String {
        "If you recently reinstalled BurnBar or switched devices, reconnecting restores private replies. We'll ask you to confirm first, so a changed connection is never trusted by accident."
    }

    /// Spell out a hex/space safety code for VoiceOver so it isn't read as one
    /// run-on word (e.g. "A1B2" → "A 1 B 2").
    private func spelledOut(_ code: String) -> String {
        code.map { character -> String in
            character == " " ? "," : String(character)
        }
        .joined(separator: " ")
    }
}
