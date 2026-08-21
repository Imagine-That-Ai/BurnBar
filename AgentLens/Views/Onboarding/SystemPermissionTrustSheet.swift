#if canImport(AppKit) && !DISTRIBUTION_MAS
import SwiftUI
import OpenBurnBarComputerUseCore

/// BurnBar's own explanation, shown immediately before a macOS permission dialog.
///
/// Structure follows `CLIAssistantConsentSheet` (gradient icon, title, body, reassurance
/// rows, trailing button pair) so this reads as the same app rather than a new dialect.
/// The content is `SystemPermissionKind.safetyFrame` -- the five answers a frightened
/// person actually wants -- plus the existing `onboardingDenialExamples` behind a
/// disclosure, so "what you lose" is available without leading with it.
///
/// The primary button says **"Show the macOS prompt"**, never "Allow". Clicking it grants
/// nothing; macOS still asks. An "Allow" button followed immediately by a second dialog
/// asking the same question is the double-consent pattern that makes people suspect
/// they are being tricked into clicking twice.
struct SystemPermissionTrustSheet: View {
    let kind: SystemPermissionKind
    var bundleName: String?
    /// `true` to continue to macOS, `false` to back out.
    let onDecision: (Bool) -> Void

    @State private var showDenialExamples = false

    private var frame: SystemPermissionSafetyFrame { kind.safetyFrame }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            reassuranceRows
            denialDisclosure
            buttonRow
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 460)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.15), DesignSystem.Colors.border.opacity(0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
        }
        .liquidGlassSurface(
            in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous),
            fallback: .ultraThinMaterial
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.whimsy.opacity(0.35),
                                DesignSystem.Colors.ember.opacity(0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: kind.sfSymbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(titleText)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(frame.whoDrives)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleText: String {
        if kind == .automation, let bundleName {
            return "Let your agent operate \(bundleName)?"
        }
        return kind.displayTitle
    }

    private var reassuranceRows: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            row("eye", frame.whoWatches)
            row("arrow.up.forward.app", frame.whereItGoes)
            row("checkmark.circle", frame.ifYouDecline)
            row("gearshape", frame.howToRevoke)
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(DesignSystem.Colors.whimsy.opacity(0.9))
        }
    }

    private var denialDisclosure: some View {
        DisclosureGroup(isExpanded: $showDenialExamples) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(kind.onboardingDenialExamples, id: \.self) { example in
                    Text("\u{2022} \(example)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("What the agent can't do without this")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var buttonRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Button("Not now") { onDecision(false) }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

            // Not "Allow": this button does not grant anything.
            Button(primaryLabel) { onDecision(true) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.whimsy)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var primaryLabel: String {
        SystemPermissionPromptRunner.hasNativePrompt(for: kind)
            ? "Show the macOS prompt"
            : "Open System Settings"
    }
}
#endif
