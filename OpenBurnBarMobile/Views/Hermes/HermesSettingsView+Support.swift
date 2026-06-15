import OSLog
import SwiftUI
import UIKit
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

// Settings card, pairing-code formatter, wizard command/step enums, notice style, success splash.
// Extracted from HermesSettingsView.swift (god-file decomposition) — same module, verbatim.

/// A native inset-grouped-style card. Replaces `AuroraGlassCard` on the Hermes
/// settings surface so it reads like Apple's stock Settings — grouped cards on
/// `systemGroupedBackground` — instead of the Aurora glass treatment used
/// elsewhere in the app.
struct NativeSettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

enum HermesGatewayPairingCodeFormatter {
    static func displayString(for raw: String) -> String {
        let compact = compactCode(raw)
        guard compact.count > 4 else { return compact }
        let split = compact.index(compact.startIndex, offsetBy: 4)
        return "\(compact[..<split])-\(compact[split...])"
    }

    static func canonicalCode(from raw: String) -> String? {
        let compact = compactCode(raw)
        guard compact.count == 8 else { return nil }
        return displayString(for: compact)
    }

    static func compactCode(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
    }
}

enum HermesGatewayWizardCommand: Hashable {
    case setup
    case run
    case restart

    var text: String {
        switch self {
        case .setup:
            return "hermes gateway setup"
        case .run:
            return "hermes gateway run"
        case .restart:
            return "hermes gateway restart"
        }
    }

    var accessibilityName: String {
        switch self {
        case .setup:
            return "Hermes gateway setup command"
        case .run:
            return "Hermes gateway run command"
        case .restart:
            return "Hermes gateway restart command"
        }
    }
}

enum HermesGatewayWizardStepState {
    case complete
    case current
    case upcoming
}

enum HermesGatewayNoticeStyle {
    case info
    case success
    case warning
    case error
}

struct HermesGatewayConnectionSuccessSplash: View {
    let client: HermesGatewayClientRecord
    let onDone: () -> Void
    let onSendTest: () -> Void

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var cardIn = false
    @State var avatarsIn = false
    @State var connected = false
    @State var detailsIn = false
    @State var haloPulse = false
    @State var burst = false

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .full)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    MobileTheme.ember.opacity(0.22),
                    MobileTheme.hermesAureate.opacity(0.14),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: MobileTheme.Spacing.xl) {
                Spacer(minLength: 18)

                VStack(spacing: MobileTheme.Spacing.xl) {
                    logoHandshake

                    VStack(spacing: MobileTheme.Spacing.sm) {
                        Text("Hermes is connected")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("BurnBar Cloud can now send messages to Hermes and receive replies from your local gateway.")
                            .font(.body)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .opacity(connected ? 1 : 0)
                    .offset(y: connected ? 0 : 10)

                    VStack(spacing: MobileTheme.Spacing.sm) {
                        connectionPill(
                            icon: "checkmark.seal.fill",
                            label: client.displayName,
                            value: "Active"
                        )
                        .opacity(detailsIn ? 1 : 0)
                        .offset(y: detailsIn ? 0 : 14)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.04), value: detailsIn)

                        connectionPill(
                            icon: "key.horizontal.fill",
                            label: "Token",
                            value: client.tokenPreview
                        )
                        .opacity(detailsIn ? 1 : 0)
                        .offset(y: detailsIn ? 0 : 14)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.12), value: detailsIn)
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.xl)
                .padding(.vertical, MobileTheme.Spacing.xxxl)
                .background(cardBackground)
                .scaleEffect(cardIn ? 1 : 0.94)
                .opacity(cardIn ? 1 : 0)

                VStack(spacing: MobileTheme.Spacing.md) {
                    Button {
                        HapticBus.primaryAction()
                        onSendTest()
                    } label: {
                        Label("Send test message", systemImage: "paperplane.fill")
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MobileTheme.ember)

                    Button {
                        onDone()
                    } label: {
                        Text("Done")
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.bordered)
                    .tint(MobileTheme.hermesAureate)
                }
                .padding(.horizontal, MobileTheme.Spacing.xl)
                .opacity(detailsIn ? 1 : 0)
                .offset(y: detailsIn ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.2), value: detailsIn)

                Spacer(minLength: 28)
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
        .onAppear { runIntro() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes is connected to BurnBar Cloud")
    }

    var cardBackground: some View {
        RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous)
            .fill(MobileTheme.Colors.surface.opacity(0.82))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.xl, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                MobileTheme.hermesAureate.opacity(0.56),
                                MobileTheme.ember.opacity(0.34),
                                Color.white.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: MobileTheme.ember.opacity(0.20), radius: 34, x: 0, y: 18)
    }

    // MARK: - Handshake

    var logoHandshake: some View {
        HStack(spacing: 0) {
            avatar(assetName: "HermesLogo", label: "Hermes", color: MobileTheme.hermesAureate, fillsCircle: true)
                .offset(x: 10)
                .zIndex(1)

            connectorColumn
                .zIndex(2)

            avatar(assetName: "AppLogo", label: "BurnBar", color: MobileTheme.ember, fillsCircle: false)
                .offset(x: -10)
                .zIndex(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hermes connected to BurnBar")
    }

    var connectorColumn: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            ZStack {
                Capsule()
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(0.92))
                    .frame(width: 84, height: 42)
                    .overlay(Capsule().stroke(MobileTheme.Colors.border.opacity(0.8), lineWidth: 0.75))
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)

                if connected && !reduceMotion {
                    burstRing(delay: 0)
                    burstRing(delay: 0.12)
                }

                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(MobileTheme.success)
                    .scaleEffect(connected ? 1 : 0.2)
                    .opacity(connected ? 1 : 0)
            }
            .scaleEffect(avatarsIn ? 1 : 0.6)
            .opacity(avatarsIn ? 1 : 0)

            // Phantom label keeps the badge vertically centered on the avatar
            // circles (whose columns also carry a caption row below).
            Text(" ")
                .font(.caption)
                .opacity(0)
        }
        .accessibilityHidden(true)
    }

    func burstRing(delay: Double) -> some View {
        Circle()
            .stroke(MobileTheme.success.opacity(0.55), lineWidth: 2.5)
            .frame(width: 40, height: 40)
            .scaleEffect(burst ? 2.6 : 0.55)
            .opacity(burst ? 0 : 0.85)
            .animation(.easeOut(duration: 0.75).delay(delay), value: burst)
    }

    func avatar(assetName: String, label: String, color: Color, fillsCircle: Bool) -> some View {
        let size: CGFloat = 104
        return VStack(spacing: MobileTheme.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: size, height: size)
                    .blur(radius: 20)
                    .scaleEffect(haloPulse ? 1.12 : 0.94)
                    .opacity(haloPulse ? 0.95 : 0.55)

                Circle()
                    .fill(MobileTheme.Colors.surfaceElevated)
                    .frame(width: size, height: size)
                    .shadow(color: color.opacity(0.28), radius: 16, x: 0, y: 9)

                logoArtwork(assetName, fillsCircle: fillsCircle, size: size)

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [color.opacity(0.85), color.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: size, height: size)
            }
            .scaleEffect(avatarsIn ? 1 : 0.6)
            .opacity(avatarsIn ? 1 : 0)

            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .opacity(connected ? 1 : 0)
        }
    }

    @ViewBuilder
    func logoArtwork(_ name: String, fillsCircle: Bool, size: CGFloat) -> some View {
        if fillsCircle {
            // Portrait-style logo: fill the circle and crop the asset's baked
            // square frame so it reads as an elegant avatar, not a boxed image.
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .scaleEffect(1.2)
                .clipShape(Circle())
        } else {
            Image(name)
                .resizable()
                .scaledToFit()
                .padding(size * 0.22)
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }

    func connectionPill(icon: String, label: String, value: String) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.success)
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Spacer(minLength: MobileTheme.Spacing.sm)

            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.72))
        )
    }

    // MARK: - Intro choreography

    func runIntro() {
        Haptics.light()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            cardIn = true
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.66).delay(0.12)) {
            avatarsIn = true
        }
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                haloPulse = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
            HapticBus.milestone()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                connected = true
            }
            // Defer one runloop so the burst rings mount before they animate.
            DispatchQueue.main.async {
                withAnimation { burst = true }
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                detailsIn = true
            }
        }
    }
}
