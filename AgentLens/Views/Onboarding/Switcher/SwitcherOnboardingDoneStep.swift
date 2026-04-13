import SwiftUI
import OpenBurnBarCore

struct SwitcherOnboardingDoneStep: View {
    let addedCount: Int
    let verifiedCount: Int
    let identities: [DiscoveredIdentity]
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0

    private var providerSummaries: [(label: String, icon: String, count: Int, color: Color)] {
        var summaries: [(String, String, Int, Color)] = []
        let chromeCount = identities.filter { if case .chromeProfile = $0.source { return true }; return false }.count
        if chromeCount > 0 { summaries.append(("Chrome", "globe", chromeCount, Color(hex: "4285F4"))) }
        let safariCount = identities.filter { if case .safari = $0.source { return true }; return false }.count
        if safariCount > 0 { summaries.append(("Safari", "safari", safariCount, Color(hex: "0071E3"))) }
        let codexCount = identities.filter { if case .codex = $0.source { return true }; return false }.count
        if codexCount > 0 { summaries.append(("Codex", "terminal.fill", codexCount, Color(hex: "00A67E"))) }
        let claudeCount = identities.filter { if case .claudeCode = $0.source { return true }; return false }.count
        if claudeCount > 0 { summaries.append(("Claude Code", "terminal.fill", claudeCount, Color(hex: "CC785C"))) }
        let opencodeCount = identities.filter { if case .opencode = $0.source { return true }; return false }.count
        if opencodeCount > 0 { summaries.append(("OpenCode", "terminal.fill", opencodeCount, DesignSystem.Colors.whimsy)) }
        return summaries
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            // Animated success
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(DesignSystem.Colors.success)
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("You\u{2019}re switched in")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("\(addedCount) account\(addedCount == 1 ? "" : "s") ready across \(providerSummaries.count) provider\(providerSummaries.count == 1 ? "" : "s")")
                Text("\(addedCount) account\(addedCount == 1 ? "" : "s") ready across \(providerSummaries.count) provider\(providerSummaries.count == 1 ? "" : "s"). BurnBar can now keep provider reserves ready instead of making you reconnect from scratch.")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Provider-by-provider summary
            if !providerSummaries.isEmpty {
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(providerSummaries, id: \.label) { summary in
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Image(systemName: summary.icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(summary.color)
                                    .frame(width: 16)

                                Text(summary.label)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                                Spacer()

                                Text("\(summary.count) account\(summary.count == 1 ? "" : "s")")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }

            // Verification results
            if verifiedCount > 0 {
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(identities.filter { $0.isVerified }) { identity in
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.success)
                                Text(identity.displayTitle)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Spacer()
                                Text("Verified")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.success)
                            }
                        }
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }

            // Tips
            VStack(spacing: DesignSystem.Spacing.sm) {
                tipRow(text: "Use Settings to reorder primary and reserve accounts within each provider")
                tipRow(text: "Keep extra Codex or Claude accounts connected before you need them")
                tipRow(text: "Review or reconnect accounts anytime in Settings → Account Switcher")
            }
            .padding(.vertical, DesignSystem.Spacing.md)

            Spacer()

            VStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    onOpenSettings()
                } label: {
                    Text("Open Settings Review")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.amber)

                Button("Stay in menu bar") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.15)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
        }
    }

    private func tipRow(text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.success)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }
}
