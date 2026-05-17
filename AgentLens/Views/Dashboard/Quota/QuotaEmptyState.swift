import SwiftUI

// MARK: - QuotaEmptyState

struct QuotaEmptyState: View {
    var onOpenConnections: () -> Void

    @State private var glow = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.18),
                                DesignSystem.Colors.amber.opacity(0.10),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 168, height: 168)
                    .blur(radius: 18)
                    .scaleEffect(glow ? 1.06 : 0.94)
                    .opacity(glow ? 1 : 0.7)

                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    glow = true
                }
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("No active subscriptions yet")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Connect a provider in Settings → Connections to watch its quota land here in real time.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onOpenConnections) {
                HStack(spacing: 8) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Open Connections")
                        .font(DesignSystem.Typography.body)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.md)
                .background(
                    Capsule(style: .continuous)
                        .fill(DesignSystem.Colors.primaryGradient)
                )
                .shadow(color: DesignSystem.Colors.ember.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xxl)
    }
}

// MARK: - Setup suggestions strip

struct QuotaSetupSuggestionsStrip: View {
    let slots: [SubscriptionSetupSlot]
    var onOpenConnections: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                Text("READY TO ADD · \(slots.count) PROVIDER\(slots.count == 1 ? "" : "S")")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.0)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                Button(action: onOpenConnections) {
                    HStack(spacing: 4) {
                        Text("Open Connections")
                            .font(DesignSystem.Typography.tiny)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(DesignSystem.Colors.ember)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(slots) { slot in
                        slotChip(slot)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(DesignSystem.Spacing.lg)
    }

    private func slotChip(_ slot: SubscriptionSetupSlot) -> some View {
        let theme = ProviderTheme.theme(for: slot.provider)
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProviderQuotaIdentityOrb(provider: slot.provider, isActive: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slot.provider.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(slot.hasConnectedAccount ? "Connected, awaiting signal" : "Not connected")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(
                            slot.hasConnectedAccount
                                ? DesignSystem.Colors.amber
                                : DesignSystem.Colors.textMuted
                        )
                }
            }

            Text(slot.statusMessage)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 200, alignment: .leading)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.20), lineWidth: 0.75)
        )
        .frame(width: 232)
    }
}

#if DEBUG
#Preview("Quota empty state") {
    QuotaEmptyState(onOpenConnections: {})
        .frame(minWidth: 640, minHeight: 480)
}
#endif
