import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import LocalAuthentication
import OSLog
import Security
#if canImport(UIKit)
import UIKit
#endif

// Background, aurora, HUD, and mirror-ack rendering helpers.
// Extracted from MercuryLiveSheet.swift (god-type decomposition) — same module, same isolation, verbatim.

extension MercuryLiveSheet {

    @ViewBuilder
    var backgroundView: some View {
        switch personalization.background {
        case .wallpaper:
            if let backgroundImage, personalization.mimicLoginBackground {
                Image(uiImage: backgroundImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 30, opaque: true)
                    .overlay(Color.black.opacity(0.3))
            } else {
                auroraBackground
            }
        case .aurora:
            auroraBackground
        case .solid:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.07, blue: 0.09),
                        Color(red: 0.03, green: 0.03, blue: 0.04)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [accent.opacity(0.18), Color.clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 500
                )
            }
        case .website:
            WebsiteBackgroundView(
                accent: accent,
                colorDriver: dashboardStore.swarmColorDriver,
                visibility: backgroundVisibility
            )
        case .constellation:
            ConstellationBackgroundView(
                accent: accent,
                visibility: backgroundVisibility
            )
        }
    }

    @ViewBuilder
    var auroraBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.12, blue: 0.14),
                Color(red: 0.05, green: 0.05, blue: 0.06)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            ZStack {
                RadialGradient(
                    colors: [accent.opacity(0.18), Color.clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 300
                )
                RadialGradient(
                    colors: [Color.purple.opacity(0.12), Color.clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 400
                )
            }
        )
    }

    func decodeWallpaper(_ base64: String?) {
        guard let base64,
              let data = Data(base64Encoded: base64),
              let image = UIImage(data: data) else {
            self.backgroundImage = nil
            return
        }
        self.backgroundImage = image
    }

    /// Shared plate behind the floating error/ack HUD banners. The banners
    /// are HUD controls (tap ✕ to dismiss, drag up to dismiss), so on iOS 26
    /// they render as interactive Liquid Glass with the status wash riding
    /// directly on the glass shape — no material underneath, the glass must
    /// sample the live sheet background. iOS 17–25 keeps the original
    /// `.ultraThinMaterial` + wash stack unchanged.
    @ViewBuilder
    func hudGlassBackground(wash: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26, *) {
            shape
                .fill(wash)
                .liquidGlassEffect(.regular.interactive(), in: shape)
        } else {
            ZStack {
                shape
                    .fill(.ultraThinMaterial)

                shape
                    .fill(wash)
            }
        }
    }

    @ViewBuilder
    func floatingErrorHUD(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .font(.system(size: 20, weight: .bold))
                .symbolEffect(.pulse, options: .repeating)
                .shadow(color: .red.opacity(0.3), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("Error Alert")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    lastError = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(hudGlassBackground(wash: Color.red.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.23, blue: 0.19).opacity(0.65),
                            Color(red: 1.0, green: 0.62, blue: 0.04).opacity(0.20),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.red, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * errorProgress)
            }
            .frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.red.opacity(0.18), radius: 22, x: 0, y: 12)
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
        .offset(y: errorDragOffset)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    if gesture.translation.height < 0 {
                        errorDragOffset = gesture.translation.height
                    } else {
                        errorDragOffset = pow(gesture.translation.height, 0.7)
                    }
                }
                .onEnded { gesture in
                    if gesture.translation.height < -15 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            lastError = nil
                            errorDragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            errorDragOffset = 0
                        }
                    }
                }
        )
    }

    @ViewBuilder
    func floatingAckHUD(for ack: HermesRealtimeRelayMirrorAck) -> some View {
        let progress: CGFloat = {
            if ack.decision == .coolingDown,
               let original = ack.cooldownSecondsRemaining,
               let remaining = cooldownSecondsRemaining(for: ack),
               original > 0 {
                return CGFloat(remaining) / CGFloat(original)
            }
            return ackProgress
        }()

        HStack(spacing: 12) {
            Image(systemName: ackIcon(for: ack))
                .foregroundStyle(ackColor(for: ack))
                .font(.system(size: 20, weight: .bold))
                .symbolEffect(.bounce, value: ackAnimateTrigger)
                .shadow(color: ackColor(for: ack).opacity(0.3), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle(for: ack))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if let detail = ack.detail {
                    Text(detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.leading)
                }

                if let cooldown = cooldownSecondsRemaining(for: ack), cooldown > 0 {
                    Text("Cooling down · \(cooldown)s")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    lastAck = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(hudGlassBackground(wash: ackColor(for: ack).opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ackGradient(for: ack), lineWidth: 1.5)
        )
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(ackProgressGradient(for: ack))
                    .frame(width: geo.size.width * progress)
            }
            .frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: ackColor(for: ack).opacity(0.18), radius: 22, x: 0, y: 12)
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
        .offset(y: ackDragOffset)
        .gesture(
            DragGesture()
                .onChanged { gesture in
                    if gesture.translation.height < 0 {
                        ackDragOffset = gesture.translation.height
                    } else {
                        ackDragOffset = pow(gesture.translation.height, 0.7)
                    }
                }
                .onEnded { gesture in
                    if gesture.translation.height < -15 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            lastAck = nil
                            ackDragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            ackDragOffset = 0
                        }
                    }
                }
        )
        .onAppear {
            ackAnimateTrigger.toggle()
        }
    }

    @ViewBuilder
    func floatingCallAckHUD(for ack: HermesRealtimeRelayCallAck) -> some View {
        HStack(spacing: 12) {
            Image(systemName: callAckIcon(for: ack))
                .foregroundStyle(callAckColor(for: ack))
                .font(.system(size: 20, weight: .bold))
                .symbolEffect(.bounce, value: ackAnimateTrigger)
                .shadow(color: callAckColor(for: ack).opacity(0.3), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(callBannerTitle(for: ack))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if let detail = ack.detail {
                    Text(detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    lastCallAck = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(hudGlassBackground(wash: callAckColor(for: ack).opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(callAckGradient(for: ack), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: callAckColor(for: ack).opacity(0.18), radius: 22, x: 0, y: 12)
        .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 8)
        .onAppear {
            ackAnimateTrigger.toggle()
        }
    }

    func ackGradient(for ack: HermesRealtimeRelayMirrorAck) -> LinearGradient {
        let colors: [Color]
        switch ack.decision {
        case .accepted:
            colors = [Color.green.opacity(0.65), Color.green.opacity(0.20), Color.white.opacity(0.08)]
        case .denied:
            colors = [Color.red.opacity(0.65), Color.orange.opacity(0.20), Color.white.opacity(0.08)]
        case .coolingDown, .busy:
            colors = [Color.orange.opacity(0.65), Color.yellow.opacity(0.20), Color.white.opacity(0.08)]
        case .unsupported:
            colors = [Color.gray.opacity(0.65), Color.white.opacity(0.12), Color.white.opacity(0.08)]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func ackProgressGradient(for ack: HermesRealtimeRelayMirrorAck) -> LinearGradient {
        let colors: [Color]
        switch ack.decision {
        case .accepted:
            colors = [.green, .mint]
        case .denied:
            colors = [.red, .orange]
        case .coolingDown, .busy:
            colors = [.orange, .yellow]
        case .unsupported:
            colors = [.gray, .white.opacity(0.5)]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    func ackIcon(for ack: HermesRealtimeRelayMirrorAck) -> String {
        switch ack.decision {
        case .accepted:    return "checkmark.circle.fill"
        case .denied:      return "xmark.circle.fill"
        case .coolingDown: return "timer"
        case .busy:        return "minus.circle.fill"
        case .unsupported: return "slash.circle.fill"
        }
    }

    func callAckIcon(for ack: HermesRealtimeRelayCallAck) -> String {
        switch ack.decision {
        case .accepted: return "phone.connection.fill"
        case .denied: return "phone.down.fill"
        case .busy: return "minus.circle.fill"
        case .unsupported: return "slash.circle.fill"
        }
    }

    func ackColor(for ack: HermesRealtimeRelayMirrorAck) -> Color {
        switch ack.decision {
        case .accepted:    return .green
        case .denied:      return .red
        case .coolingDown: return .orange
        case .busy:        return .orange
        case .unsupported: return .gray
        }
    }

    func callAckColor(for ack: HermesRealtimeRelayCallAck) -> Color {
        switch ack.decision {
        case .accepted: return .green
        case .denied: return .red
        case .busy: return .orange
        case .unsupported: return .gray
        }
    }

    func bannerTitle(for ack: HermesRealtimeRelayMirrorAck) -> String {
        switch ack.decision {
        case .accepted:    return "Accepted — opening viewer…"
        case .denied:      return "Mac declined the request."
        case .coolingDown: return "Mac is cooling down."
        case .busy:        return "Mac is busy."
        case .unsupported: return "Mac can't mirror right now."
        }
    }

    func callBannerTitle(for ack: HermesRealtimeRelayCallAck) -> String {
        switch ack.decision {
        case .accepted: return "Mac accepted the call."
        case .denied: return "Mac declined the call."
        case .busy: return "Mac is busy."
        case .unsupported: return "Mac can't call right now."
        }
    }

    func callAckGradient(for ack: HermesRealtimeRelayCallAck) -> LinearGradient {
        let colors: [Color]
        switch ack.decision {
        case .accepted:
            colors = [Color.green.opacity(0.65), Color.green.opacity(0.20), Color.white.opacity(0.08)]
        case .denied:
            colors = [Color.red.opacity(0.65), Color.orange.opacity(0.20), Color.white.opacity(0.08)]
        case .busy:
            colors = [Color.orange.opacity(0.65), Color.yellow.opacity(0.20), Color.white.opacity(0.08)]
        case .unsupported:
            colors = [Color.gray.opacity(0.65), Color.white.opacity(0.12), Color.white.opacity(0.08)]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var canRequestMirror: Bool {
        awaitingRequestID == nil
            && peer.capabilities.contains(.mirrorHost)
    }

    var canPlaceCall: Bool {
        Self.canStartCall(
            pendingCallRequestID: pendingCallRequestID,
            peerCanPlaceCall: peer.canPlaceCall,
            controlStreamPhase: controlStreamCoordinator.phase
        )
    }

    static func canStartCall(
        pendingCallRequestID: String?,
        peerCanPlaceCall: Bool,
        controlStreamPhase: MediaControlStreamCoordinator.Phase
    ) -> Bool {
        pendingCallRequestID == nil
            && peerCanPlaceCall
            && controlStreamPhase == .live
    }

    static func shouldDetachCallAckHandlerOnDisappear(pendingCallRequestID: String?) -> Bool {
        pendingCallRequestID == nil
    }

    var mirrorAutoAccept: Bool {
        peer.capabilities.contains(.mirrorAutoAccept)
    }

    var mercuryStatusMessage: String? {
        if !peer.capabilities.contains(.mirrorHost) {
            return "This Mac is not advertising screen mirroring yet."
        }
        switch controlStreamCoordinator.phase {
        case .live:
            return nil
        case .idle, .dialing:
            return "Mercury is connecting to your Mac..."
        case .reconnecting:
            return "Mercury lost the Mac connection and is reconnecting..."
        case .failed(let reason):
            return "Mercury unavailable: \(reason)"
        case .stopped:
            return "Mercury is stopped. Reopen BurnBar on the Mac, then try again."
        }
    }

    var callStatusMessage: String? {
        if pendingCallRequestID != nil {
            return "Calling Mac. Waiting for a response..."
        }
        if !peer.canPlaceCall {
            return "This Mac is not advertising calls yet."
        }
        switch controlStreamCoordinator.phase {
        case .live:
            return nil
        case .idle, .dialing:
            return "Mercury is connecting to your Mac before calling..."
        case .reconnecting:
            return "Mercury lost the Mac connection and is reconnecting..."
        case .failed(let reason):
            return "Mercury unavailable: \(reason)"
        case .stopped:
            return "Mercury is stopped. Reopen BurnBar on the Mac, then try again."
        }
    }
}
