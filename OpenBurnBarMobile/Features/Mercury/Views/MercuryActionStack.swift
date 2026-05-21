import SwiftUI
import OpenBurnBarMedia

/// Vertical button stack — Ask to Mirror / Call Mac / Send File… The
/// order and visibility comes from
/// `MercuryDevicePersonalization.actionOrder`, so users can reorder via
/// the personalize panel and hidden actions simply don't render here.
struct MercuryActionStack: View {
    let order: [MercuryQuickAction]
    let peer: MercuryPeer
    let accent: Color
    let canRequestMirror: Bool
    let canPlaceCall: Bool
    let canSendFile: Bool
    let awaitingRequestID: String?
    let sendingFile: Bool
    let mercuryStatusMessage: String?
    let onRequestMirror: () -> Void
    let onPlaceCall: () -> Void
    let onSendFile: () -> Void
    var usePremiumSOTAUX: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            ForEach(order) { action in
                row(for: action)
                if action == .mirror {
                    statusRow
                }
            }
        }
    }

    @ViewBuilder
    private func row(for action: MercuryQuickAction) -> some View {
        switch action {
        case .mirror:
            Button(action: onRequestMirror) {
                HStack(spacing: 12) {
                    Image(systemName: awaitingRequestID == nil ? action.icon : "hourglass")
                        .font(.system(size: 16, weight: .bold))
                    Text(awaitingRequestID == nil ? action.displayName : "Waiting for Mac…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassButtonStyle(isEnabled: canRequestMirror, accent: accent, usePremiumSOTAUX: usePremiumSOTAUX))
            .disabled(!canRequestMirror)
            .accessibilityLabel(action.accessibilityLabel)

        case .call:
            Button(action: onPlaceCall) {
                HStack(spacing: 12) {
                    Image(systemName: action.icon)
                        .font(.system(size: 14))
                    Text(action.displayName)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassButtonStyle(isEnabled: canPlaceCall, accent: accent, usePremiumSOTAUX: usePremiumSOTAUX))
            .disabled(!canPlaceCall)
            .accessibilityLabel(action.accessibilityLabel)

        case .sendFile:
            Button(action: onSendFile) {
                HStack(spacing: 12) {
                    Image(systemName: action.icon)
                        .font(.system(size: 14))
                    Text(sendingFile ? "Sending…" : action.displayName)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassButtonStyle(isEnabled: canSendFile && !sendingFile, accent: accent, usePremiumSOTAUX: usePremiumSOTAUX))
            .disabled(!canSendFile || sendingFile)
            .accessibilityLabel(action.accessibilityLabel)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if order.contains(.mirror) {
            if awaitingRequestID != nil {
                statusText("Request sent. Check your Mac.")
            } else if let status = mercuryStatusMessage {
                statusText(status)
            } else if !peer.isOnline {
                statusText("Mercury is still connecting. Ask will wait for the Mac and show the real error if it cannot connect.")
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)
    }
}
