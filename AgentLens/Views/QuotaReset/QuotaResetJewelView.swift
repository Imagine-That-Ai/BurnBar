import SwiftUI
import OpenBurnBarCore

struct QuotaResetJewelView: View {
    let performance: QuotaResetPerformance
    var onOpen: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 12) {
                if case .coalesced(let events) = performance {
                    coalescedBody(events)
                } else if let event = performance.lead {
                    QuotaResetSealView(event: event, compact: true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(width: 320)
            .background(jewelBackground)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens quota details")
    }

    private func coalescedBody(_ events: [QuotaResetEvent]) -> some View {
        let caption = QuotaResetCopy.coalescedCaption(providers: events.map(\.providerToken))
        return VStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach(events.prefix(4)) { event in
                    let provider = AgentProvider.fromPersistedToken(event.providerToken)
                        ?? AgentProvider.fromProviderID(event.providerID)
                        ?? .codex
                    ProviderLogoView(provider: provider, size: 28, useFallbackColor: false)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(DesignSystem.Colors.border, lineWidth: 0.6))
                }
            }
            VStack(spacing: 4) {
                Text(caption.eyebrow)
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.1)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(caption.headline)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var jewelBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(DesignSystem.Colors.surfaceElevated.opacity(colorScheme == .dark ? 0.92 : 0.96))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.7), lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(0.28), radius: 22, y: 10)
    }
}
