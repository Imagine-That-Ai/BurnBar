#if canImport(UIKit)
import SwiftUI
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import UIKit

/// Phase 14 — Full mercury-themed bottom sheet that opens from the
/// `SystemPermissionInlinePill`. Shows a hero card with the kind, a
/// status row that flips in real time, three CTAs, and the numbered
/// footer Apple wants every TCC explainer to ship. Closes itself with
/// a confetti-free dismiss when the monitor flips the status to
/// granted; the failed tool is then re-run by `HermesService`'s retry
/// observer.
public struct SystemPermissionGrantSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let item: SystemPermissionItem
    public let sender: SystemPermissionGrantSender
    public var onGrantTapped: (() -> Void)?
    public var onRetryTapped: (() -> Void)?

    @State private var isSending = false
    @State private var errorMessage: String?

    public init(
        item: SystemPermissionItem,
        sender: SystemPermissionGrantSender,
        onGrantTapped: (() -> Void)? = nil,
        onRetryTapped: (() -> Void)? = nil
    ) {
        self.item = item
        self.sender = sender
        self.onGrantTapped = onGrantTapped
        self.onRetryTapped = onRetryTapped
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    statusCard
                    ctaStack
                    instructionsFooter
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(MobileTheme.error)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: item.status) { _, newValue in
            if newValue == .granted {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(MobileTheme.mercuryGradient)
                        .frame(width: 56, height: 56)
                        .opacity(0.18)
                    Image(systemName: item.kind.sfSymbolName)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(MobileTheme.mercuryGradient)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.kind.displayTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(MobileTheme.textPrimary)
                    Text(item.kind.displaySubtitle)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(MobileTheme.textSecondary)
                }
            }
            Text(item.kind.heroExplanation)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(MobileTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(MobileTheme.mercuryGradient)
                .frame(height: 1)
                .opacity(0.7)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(statusHeadline)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.textPrimary)
                Text(statusSubtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(MobileTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(statusBorderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .needsAccess, .timeout, .unknown:
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(MobileTheme.mercuryGradient)
        case .requesting:
            ProgressView()
                .controlSize(.regular)
                .tint(MobileTheme.hermesMercury)
        case .granted:
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(MobileTheme.success)
        case .denied:
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(MobileTheme.warning)
        }
    }

    private var statusHeadline: String {
        switch item.status {
        case .needsAccess: return "Ready to request on your Mac"
        case .requesting:  return "Asking macOS for permission…"
        case .granted:     return "Permission granted"
        case .denied:      return "macOS denied the request"
        case .timeout:     return "macOS did not respond in time"
        case .unknown:     return "Permission state unknown"
        }
    }

    private var statusSubtitle: String {
        switch item.status {
        case .needsAccess: return "OpenBurnBar on your Mac will surface the prompt and System Settings deep link."
        case .requesting:  return "Watch your Mac for the native dialog or System Settings pane."
        case .granted:     return "Auto-retrying the blocked tool so the agent can finish."
        case .denied:      return "Tap Retry once you've toggled OpenBurnBar on in System Settings."
        case .timeout:     return "Tap Retry to send the request again."
        case .unknown:     return "Tap Send to retry."
        }
    }

    private var statusBorderColor: Color {
        switch item.status {
        case .needsAccess, .timeout, .unknown: return MobileTheme.hermesMercury.opacity(0.6)
        case .requesting: return MobileTheme.hermesAureate.opacity(0.7)
        case .granted: return MobileTheme.success.opacity(0.6)
        case .denied: return MobileTheme.warning.opacity(0.6)
        }
    }

    private var ctaStack: some View {
        VStack(spacing: 10) {
            Button {
                Task { await dispatchGrant(action: item.kind.defaultAction) }
            } label: {
                ctaLabel(primaryTitle, systemImage: "checkmark.shield.fill", filled: true)
            }
            .disabled(!item.status.allowsRetap || isSending)
            .accessibilityLabel(primaryTitle)

            Button {
                Task { await dispatchGrant(action: .openSettings) }
            } label: {
                ctaLabel("Open System Settings", systemImage: "gearshape", filled: false)
            }
            .disabled(isSending)
            .accessibilityLabel("Open System Settings on your Mac")

            Button {
                onRetryTapped?()
                Task { await dispatchGrant(action: .retryFailedTool) }
            } label: {
                ctaLabel(
                    item.status == .granted ? "Retry now" : "Retry once granted",
                    systemImage: "arrow.clockwise",
                    filled: false
                )
            }
            .disabled(isSending)
            .accessibilityLabel("Retry the failed tool call")
        }
    }

    private func ctaLabel(_ title: String, systemImage: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .foregroundStyle(filled ? MobileTheme.background : MobileTheme.textPrimary)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? AnyShapeStyle(MobileTheme.mercuryGradient) : AnyShapeStyle(MobileTheme.surfaceElevated))
                if !filled {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(MobileTheme.mercuryGradient, lineWidth: 1)
                }
            }
        )
    }

    private var primaryTitle: String {
        switch item.status {
        case .granted: return "Already granted"
        case .requesting: return "Awaiting macOS…"
        default: return "Grant on this Mac"
        }
    }

    private var instructionsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On your Mac")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.textSecondary)
            ForEach(Array(item.kind.numberedInstructions(bundleName: item.bundleId).enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(MobileTheme.hermesMercury)
                    Text(step)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(MobileTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MobileTheme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MobileTheme.borderSubtle, lineWidth: 1)
        )
    }

    @MainActor
    private func dispatchGrant(action: HermesRealtimeRelaySystemPermissionAction) async {
        guard !isSending else { return }
        isSending = true
        errorMessage = nil
        onGrantTapped?()
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        do {
            _ = try await sender.sendGrant(item: item, action: action)
            haptic.notificationOccurred(.success)
        } catch SystemPermissionGrantSender.SendError.noActiveSender {
            errorMessage = "No active Computer Use session. Start one from the Mac, then try again."
            haptic.notificationOccurred(.error)
        } catch {
            errorMessage = error.localizedDescription
            haptic.notificationOccurred(.error)
        }
        isSending = false
    }
}
#endif
