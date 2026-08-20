#if canImport(UIKit)
import SwiftUI
import OpenBurnBarComputerUseCore

/// Phase 14 — Mercury-stroked inline chip that appears directly below
/// the assistant tool-calls strip when a Hermes tool fails on a missing
/// macOS permission. Tapping it promotes to the full
/// `SystemPermissionGrantSheet`.
public struct SystemPermissionInlinePill: View {
    public let item: SystemPermissionItem
    public let onTap: () -> Void

    @State private var shimmerPhase: CGFloat = 0
    @State private var pulse: CGFloat = 0

    public init(item: SystemPermissionItem, onTap: @escaping () -> Void) {
        self.item = item
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.mercuryGradient)
                        .frame(width: 28, height: 28)
                        .opacity(0.22)
                    Image(systemName: item.kind.sfSymbolName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(MobileTheme.mercuryGradient)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(headlineText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(MobileTheme.textPrimary)
                    Text(subtitleText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(MobileTheme.textSecondary)
                }
                Spacer(minLength: 6)
                trailingAccessory
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MobileTheme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MobileTheme.mercuryGradient, lineWidth: 1)
                    .opacity(0.78)
            )
            .overlay(shimmerOverlay)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
        .onAppear { startAnimations() }
    }

    private var headlineText: String {
        switch item.status {
        case .needsAccess: return "Grant \(item.kind.displayTitle) on your Mac"
        case .requesting:  return "Granting \(item.kind.displayTitle)…"
        case .granted:     return "\(item.kind.displayTitle) is on"
        case .denied:      return "\(item.kind.displayTitle) was denied"
        case .timeout:     return "Grant \(item.kind.displayTitle) on your Mac"
        case .unknown:     return "Grant \(item.kind.displayTitle) on your Mac"
        }
    }

    private var subtitleText: String {
        switch item.status {
        case .needsAccess, .timeout, .unknown:
            return "Tap to send a one-tap request to your Mac."
        case .requesting:
            return "Watching for the system prompt…"
        case .granted:
            if let toolName = item.originatingToolName {
                return "Auto-retrying \(toolName)…"
            }
            return "Auto-retrying the blocked tool…"
        case .denied:
            return "Tap to retry or open System Settings."
        }
    }

    private var accessibilityText: String {
        "\(headlineText). \(subtitleText)"
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        switch item.status {
        case .needsAccess, .timeout, .unknown:
            Image(systemName: "arrow.up.right.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MobileTheme.mercuryGradient)
        case .requesting:
            ProgressView()
                .controlSize(.small)
                .tint(MobileTheme.hermesMercury)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MobileTheme.success)
        case .denied:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MobileTheme.warning)
        }
    }

    private var shimmerOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, shimmerPhase - 0.1)),
                        .init(color: Color.white.opacity(0.42), location: shimmerPhase),
                        .init(color: .clear, location: min(1, shimmerPhase + 0.1))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    private func startAnimations() {
        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
            shimmerPhase = 1
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse = 1
        }
    }
}
#endif
