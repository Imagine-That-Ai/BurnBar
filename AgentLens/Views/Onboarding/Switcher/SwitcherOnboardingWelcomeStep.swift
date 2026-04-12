import SwiftUI
import OpenBurnBarCore

struct SwitcherOnboardingWelcomeStep: View {
    @ObservedObject var discoveryService: SwitcherDiscoveryService

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: DesignSystem.Spacing.xl) {
                // Hero icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.amber.opacity(0.15),
                                    DesignSystem.Colors.ember.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 44, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                }

                VStack(spacing: DesignSystem.Spacing.sm) {
                    Text("Set Up Account Switching")
                        .font(DesignSystem.Typography.display)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Switch between browser profiles and CLI identities with one click. BurnBar discovers what\u{2019}s on your Mac and sets everything up automatically.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }

                // Feature highlights
                VStack(spacing: DesignSystem.Spacing.sm) {
                    featureRow(icon: "globe", text: "Launch Chrome or Safari with different accounts")
                    featureRow(icon: "terminal.fill", text: "Run Codex, Claude Code, or OpenCode with separate configs")
                    featureRow(icon: "lock.shield", text: "No credentials stored \u{2014} BurnBar only holds profile references")
                }
                .padding(.vertical, DesignSystem.Spacing.md)

                // Live scan progress
                if discoveryService.isScanning || !discoveryService.scanProgress.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                if discoveryService.isScanning {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 12, height: 12)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(DesignSystem.Colors.success)
                                }
                                Text(discoveryService.isScanning ? "Scanning your Mac..." : "Scan complete")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }

                            ForEach(discoveryService.scanProgress.suffix(5), id: \.self) { line in
                                HStack(spacing: DesignSystem.Spacing.xs) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8))
                                        .foregroundStyle(DesignSystem.Colors.success)
                                    Text(line)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                            }
                        }
                        .padding(DesignSystem.Spacing.md)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.lg)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.amber)
                .frame(width: 20)

            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }
}
