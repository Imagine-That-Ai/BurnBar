import SwiftUI
import OpenBurnBarCore

struct SwitcherOnboardingWelcomeStep: View {
    @ObservedObject var discoveryService: SwitcherDiscoveryService
    @Binding var providerOrder: [OnboardingProvider]

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

                    Text("Connect providers the fast way, keep multiple accounts on deck, and let BurnBar stay ready when one account hits its limit.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                }

                // Provider reorder section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Setup Order")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Spacer()

                        Text("Drag to reorder")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.xs)

                    GlassCard {
                        VStack(spacing: 0) {
                            ForEach(providerOrder) { provider in
                                providerRow(provider)
                                if provider.id != providerOrder.last?.id {
                                    Divider()
                                        .background(DesignSystem.Colors.borderSubtle)
                                        .padding(.horizontal, DesignSystem.Spacing.md)
                                }
                            }
                        }
                        .padding(.vertical, DesignSystem.Spacing.xs)
                    }
                }

                // Feature highlights
                VStack(spacing: DesignSystem.Spacing.sm) {
                    featureRow(icon: "link.badge.plus", text: "Launch provider login flows directly from BurnBar")
                    featureRow(icon: "person.2.fill", text: "Keep multiple accounts per provider ready for same-provider handoff")
                    featureRow(icon: "lock.shield", text: "No raw credentials stored in BurnBar — only safe account references")
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

    // MARK: - Provider Row

    private func providerRow(_ provider: OnboardingProvider) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 12)

            Group {
                if provider.hasBundledLogo {
                    Image(provider.bundledLogoName!)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: provider.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(provider.color)
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(provider.label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer()
        }
        .padding(.vertical, DesignSystem.Spacing.sm)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .contentShape(Rectangle())
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
