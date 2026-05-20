import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Mercury Phase 8 — the beautiful entry sheet that opens when the
/// user taps "My Mac" in the Hermes Square pinned grid. Three actions
/// (Ask to Mirror / Call Mac / Send File) styled with the existing
/// Mercury vocabulary (silver→gray gradient hairline, `.thickMaterial`
/// background, `.borderedProminent` buttons, monospaced phase line).
///
/// The sheet doesn't own the iroh control stream — it pushes
/// `mediaMirrorRequest` frames through the existing
/// `MediaControlStreamCoordinator.send(_:)` API. Acks come back through
/// the coordinator's read-loop, which `HermesSquareRoot` wires into a
/// closure that updates the sheet's `lastAck` banner.
@MainActor
struct MercuryLiveSheet: View {
    private static let log = Logger(subsystem: "com.openburnbar.mobile", category: "Mercury")
    private static func debugTrace(_ message: String) {
        #if DEBUG
        NSLog("OpenBurnBarMercury \(message)")
        #endif
    }

    let connectionID: String
    let peer: MercuryPeer
    @ObservedObject var controlStreamCoordinator: MediaControlStreamCoordinator
    /// Optional — when present, "Send File…" is enabled. Looked up
    /// from `iOSFileTransferService.current` at presentation time.
    let fileTransferService: iOSFileTransferService?
    let uidProvider: @MainActor () -> String?

    @State private var lastAck: HermesRealtimeRelayMirrorAck?
    @State private var lastAckReceivedAt: Date?
    @State private var cooldownClock = Date()
    @State private var awaitingRequestID: String?
    @State private var activeMirrorRequestID: String?
    @State private var lastError: String?
    @State private var isShowingFileImporter = false
    @State private var sendingFile = false
    @State private var pulseTrigger = false
    @State private var isShowingMirrorViewer = false
    @State private var mirrorTimeoutTask: Task<Void, Never>?
    @State private var cooldownTickerTask: Task<Void, Never>?
    @StateObject private var screenShareViewer = ScreenShareViewerCoordinator()
    @AppStorage("mercuryPinnedTileEnabled") private var mercuryPinnedTileEnabled: Bool = true
    @AppStorage("mercuryMimicLoginBackground") private var mimicLoginBackground: Bool = true
    @State private var backgroundImage: UIImage? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    private static let mercurySilver = Color(red: 0.78, green: 0.74, blue: 0.69)
    private static let mercuryGray = Color(red: 0.63, green: 0.67, blue: 0.73)

    var body: some View {
        ZStack {
            // Full-bleed premium background
            backgroundView
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header

                    actionStack

                    if let ack = lastAck {
                        ackBanner(for: ack)
                    }

                    if let lastError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(lastError)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.15))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                        .multilineTextAlignment(.center)
                    }

                    preferencesCard
                }
                .padding(24)
            }
        }
        .onAppear {
            Self.debugTrace("mirror_sheet_appear connectionID=\(connectionID) peerOnline=\(peer.isOnline) phase=\(String(describing: controlStreamCoordinator.phase))")
            if !reduceMotion { pulseTrigger.toggle() }
            installAckHandler()
            decodeWallpaper(peer.blurredWallpaperBase64)
        }
        .onChange(of: peer.blurredWallpaperBase64) { _, newBase64 in
            decodeWallpaper(newBase64)
        }
        .onDisappear {
            // Don't permanently remove — `HermesSquareRoot` may have
            // installed a longer-lived handler. Only clear our pending
            // banner state.
            mirrorTimeoutTask?.cancel()
            mirrorTimeoutTask = nil
            cooldownTickerTask?.cancel()
            cooldownTickerTask = nil
            awaitingRequestID = nil
            controlStreamCoordinator.mirrorFrameHandler = nil
        }
        .fullScreenCover(isPresented: $isShowingMirrorViewer) {
            MercuryMirrorViewerFullScreen(
                coordinator: screenShareViewer,
                resetToken: activeMirrorRequestID,
                onClose: {
                    isShowingMirrorViewer = false
                    Task { await stopActiveMirror(reason: "viewer_closed") }
                }
            )
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleFilePick(result) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mercury Live for \(peer.displayName)")
    }

    // MARK: - Subviews

    private var backgroundView: some View {
        ZStack {
            if mimicLoginBackground, let backgroundImage = backgroundImage {
                Image(uiImage: backgroundImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 30, opaque: true)
                    .overlay(Color.black.opacity(0.3)) // Subtle dimming for premium legibility
            } else {
                // High-contrast, sophisticated dark charcoal-to-black back plate with ambient glows
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
                        // Top-left purple/blue ambient glow
                        RadialGradient(
                            colors: [Color.blue.opacity(0.15), Color.clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 300
                        )

                        // Bottom-right purple glow
                        RadialGradient(
                            colors: [Color.purple.opacity(0.12), Color.clear],
                            center: .bottomTrailing,
                            startRadius: 0,
                            endRadius: 400
                        )
                    }
                )
            }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            avatar

            VStack(spacing: 4) {
                Text(peer.displayName)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 6) {
                    Circle()
                        .fill(peer.isOnline ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulseTrigger && peer.isOnline && !reduceMotion ? 1.2 : 1.0)
                        .animation(
                            reduceMotion
                                ? .none
                                : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: pulseTrigger
                        )

                    Text(peer.isOnline ? "Active Session" : "Offline")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(peer.isOnline ? .green : .secondary)
                }
            }

            // Spec/telemetry pill view
            HStack(spacing: 12) {
                telemetryTag(text: "Apple Silicon", icon: "cpu")
                telemetryTag(text: "macOS Sequoia", icon: "macwindow")
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: Color.black.opacity(0.15), radius: 15, x: 0, y: 10)
    }

    private func telemetryTag(text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .foregroundStyle(Color.white.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    private var avatar: some View {
        ZStack {
            // Ambient outer glow
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [Color.blue.opacity(0.2), Color.clear]),
                        center: .center,
                        startRadius: 10,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .scaleEffect(pulseTrigger && !reduceMotion ? 1.15 : 0.95)
                .animation(
                    reduceMotion
                        ? .none
                        : .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                    value: pulseTrigger
                )

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.5),
                            Color.white.opacity(0.1),
                            Color.blue.opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 88, height: 88)
                .scaleEffect(pulseTrigger && !reduceMotion ? 1.04 : 1.0)
                .opacity(peer.isOnline ? 1.0 : 0.45)
                .animation(
                    reduceMotion
                        ? .none
                        : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: pulseTrigger
                )

            // Outer blurred glow ring
            Circle()
                .stroke(Color.blue.opacity(0.3), lineWidth: 3)
                .blur(radius: 4)
                .frame(width: 88, height: 88)
                .opacity(peer.isOnline ? 0.7 : 0)

            Image(systemName: "macbook")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .accessibilityHidden(true)
    }

    private var actionStack: some View {
        VStack(spacing: 14) {
            Button {
                Task { await requestMirror() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: awaitingRequestID == nil ? "rectangle.on.rectangle.angled" : "hourglass")
                        .font(.system(size: 16, weight: .bold))
                    Text(awaitingRequestID == nil ? "Ask to Mirror" : "Waiting for Mac...")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassButtonStyle(isEnabled: canRequestMirror))
            .disabled(!canRequestMirror)
            .accessibilityLabel("Ask to mirror Mac screen")

            if awaitingRequestID != nil {
                statusText("Request sent. Check your Mac.")
            } else if let status = mercuryStatusMessage {
                statusText(status)
            } else if !peer.isOnline {
                statusText("Mercury is still connecting. Ask will wait for the Mac and show the real error if it cannot connect.")
            }

            Button {
                Task { await placeCall() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14))
                    Text("Call Mac")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassButtonStyle(isEnabled: peer.canPlaceCall))
            .disabled(!peer.canPlaceCall)
            .accessibilityLabel("Call paired Mac")

            Button {
                isShowingFileImporter = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                    Text(sendingFile ? "Sending…" : "Send File…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassButtonStyle(isEnabled: peer.canSendFile && !sendingFile && fileTransferService != nil))
            .disabled(peer.canSendFile == false || sendingFile || fileTransferService == nil)
            .accessibilityLabel("Send file to paired Mac")
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)
    }

    private var preferencesCard: some View {
        VStack(spacing: 16) {
            Toggle(isOn: $mercuryPinnedTileEnabled) {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2.fill")
                        .foregroundStyle(Color.blue)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hermes Square Integration")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Show My Mac tile in the main grid")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .accessibilityLabel("Show My Mac tile on Hermes Square pinned grid")

            Divider()
                .background(Color.white.opacity(0.12))

            Toggle(isOn: $mimicLoginBackground) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.purple)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mimic Mac Wallpaper")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Sync blurred desktop backdrop")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .blue))
            .accessibilityLabel("Mimic Mac login/desktop wallpaper as sheet background")
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func decodeWallpaper(_ base64: String?) {
        guard let base64 = base64,
              let data = Data(base64Encoded: base64),
              let image = UIImage(data: data) else {
            self.backgroundImage = nil
            return
        }
        self.backgroundImage = image
    }

    @ViewBuilder
    private func ackBanner(for ack: HermesRealtimeRelayMirrorAck) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ackIcon(for: ack))
                    .foregroundStyle(ackColor(for: ack))
                    .font(.system(size: 15, weight: .bold))

                Text(bannerTitle(for: ack))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }

            if let detail = ack.detail {
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            if let cooldown = cooldownSecondsRemaining(for: ack), cooldown > 0 {
                Text("Cooling down · \(cooldown)s")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }

    private func ackIcon(for ack: HermesRealtimeRelayMirrorAck) -> String {
        switch ack.decision {
        case .accepted:    return "checkmark.circle.fill"
        case .denied:      return "xmark.circle.fill"
        case .coolingDown: return "timer"
        case .busy:        return "minus.circle.fill"
        case .unsupported: return "slash.circle.fill"
        }
    }

    private func ackColor(for ack: HermesRealtimeRelayMirrorAck) -> Color {
        switch ack.decision {
        case .accepted:    return .green
        case .denied:      return .red
        case .coolingDown: return .orange
        case .busy:        return .orange
        case .unsupported: return .gray
        }
    }

    private func bannerTitle(for ack: HermesRealtimeRelayMirrorAck) -> String {
        switch ack.decision {
        case .accepted:    return "Accepted — opening viewer…"
        case .denied:      return "Mac declined the request."
        case .coolingDown: return "Mac is cooling down."
        case .busy:        return "Mac is busy."
        case .unsupported: return "Mac can't mirror right now."
        }
    }

    private var canRequestMirror: Bool {
        awaitingRequestID == nil
            && peer.isOnline
            && peer.capabilities.contains(.mirrorHost)
            && controlStreamCoordinator.phase == .live
    }

    private var mercuryStatusMessage: String? {
        if !peer.capabilities.contains(.mirrorHost) {
            return "This Mac is not advertising screen mirroring yet."
        }
        switch controlStreamCoordinator.phase {
        case .live:
            return peer.isOnline ? nil : "Mercury is connected, but the Mac presence is still catching up."
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

    // MARK: - Actions

    private func installAckHandler() {
        controlStreamCoordinator.mirrorAckHandler = { ack in
            await MainActor.run {
                self.lastAck = ack
                self.lastAckReceivedAt = Date()
                self.cooldownClock = Date()
                if ack.requestId == self.awaitingRequestID {
                    self.mirrorTimeoutTask?.cancel()
                    self.mirrorTimeoutTask = nil
                    self.awaitingRequestID = nil
                }
                if ack.decision == .accepted {
                    self.activeMirrorRequestID = ack.requestId
                    self.isShowingMirrorViewer = true
                } else if ack.requestId == self.activeMirrorRequestID {
                    self.activeMirrorRequestID = nil
                    self.isShowingMirrorViewer = false
                }
                self.refreshCooldownTicker(for: ack)
            }
        }
        controlStreamCoordinator.mirrorFrameHandler = { frame in
            await screenShareViewer.ingest(frame: frame)
        }
    }

    private func requestMirror() async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            lastError = "Sign in to mirror your Mac."
            return
        }
        guard canRequestMirror else {
            lastError = mercuryStatusMessage ?? "Mercury is not ready yet."
            return
        }
        let requestID = UUID().uuidString
        awaitingRequestID = requestID
        activeMirrorRequestID = nil
        lastError = nil
        lastAck = nil
        lastAckReceivedAt = nil
        cooldownTickerTask?.cancel()
        cooldownTickerTask = nil
        let request = HermesRealtimeRelayMirrorRequest(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: deviceDisplayName(),
            streamClass: MediaStreamClass.screenVideo.rawValue
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: request)
        )
        do {
            Self.log.info("mirror_request_send requestID=\(requestID, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("mirror_request_send requestID=\(requestID) connectionID=\(connectionID)")
            try await controlStreamCoordinator.send(frame: frame)
            Self.log.info("mirror_request_sent requestID=\(requestID, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("mirror_request_sent requestID=\(requestID) connectionID=\(connectionID)")
            startMirrorAckTimeout(requestID: requestID)
        } catch {
            Self.log.error("mirror_request_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mirror_request_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
            lastError = error.localizedDescription
            awaitingRequestID = nil
        }
    }

    private func startMirrorAckTimeout(requestID: String) {
        mirrorTimeoutTask?.cancel()
        mirrorTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, awaitingRequestID == requestID else { return }
            awaitingRequestID = nil
            lastError = "No response from the Mac. Reopen BurnBar on the Mac, confirm Local Network is enabled, then try Ask to Mirror again."
        }
    }

    private func stopActiveMirror(reason: String) async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            activeMirrorRequestID = nil
            return
        }
        guard let requestID = activeMirrorRequestID else { return }
        activeMirrorRequestID = nil
        let stop = HermesRealtimeRelayMirrorStop(
            requestId: requestID,
            stoppedAt: Date(),
            reason: reason
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorStop,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorStop: stop)
        )
        do {
            try await controlStreamCoordinator.send(frame: frame, timeout: 2)
        } catch {
            Self.log.error("mirror_stop_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mirror_stop_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
        }
    }

    private func refreshCooldownTicker(for ack: HermesRealtimeRelayMirrorAck) {
        cooldownTickerTask?.cancel()
        guard ack.decision == .coolingDown,
              (ack.cooldownSecondsRemaining ?? 0) > 0 else {
            cooldownTickerTask = nil
            return
        }
        let requestID = ack.requestId
        cooldownTickerTask = Task { @MainActor in
            while !Task.isCancelled {
                cooldownClock = Date()
                guard lastAck?.requestId == requestID,
                      let remaining = cooldownSecondsRemaining(for: ack),
                      remaining > 0 else {
                    if lastAck?.requestId == requestID {
                        lastAck = nil
                    }
                    cooldownTickerTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func cooldownSecondsRemaining(for ack: HermesRealtimeRelayMirrorAck) -> Int? {
        guard let original = ack.cooldownSecondsRemaining else { return nil }
        guard ack.decision == .coolingDown else { return original }
        guard let receivedAt = lastAckReceivedAt else { return original }
        let elapsed = max(0, Int(cooldownClock.timeIntervalSince(receivedAt).rounded(.down)))
        return max(0, original - elapsed)
    }

    private func placeCall() async {
        // VoIP wake from iOS → Mac requires a separate Cloud Function
        // (sibling to `triggerVoIPCall`). v1 of this sheet wires the
        // affordance and surfaces an honest error. The iroh transport
        // alone can't ring a sleeping Mac.
        lastError = "Calling Mac from iPhone arrives in a follow-up. Use the Mac to call your iPhone for now."
    }

    private func handleFilePick(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let err):
            lastError = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard let service = fileTransferService else {
                lastError = "File transfer not available."
                return
            }
            guard let uid = uidProvider(), !uid.isEmpty else {
                lastError = "Sign in to send files."
                return
            }
            sendingFile = true
            defer { sendingFile = false }
            do {
                _ = try await service.sendFile(
                    at: url,
                    uid: uid,
                    connectionID: connectionID,
                    peerDeviceID: connectionID
                )
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func deviceDisplayName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iPhone"
        #endif
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [Self.mercurySilver, Self.mercuryGray],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct MercuryMirrorViewerFullScreen: View {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator
    let resetToken: String?
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScreenShareViewerView(coordinator: coordinator, resetToken: resetToken)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
                    .padding(18)
            }
            .accessibilityLabel("Close mirror viewer")
        }
        .background(Color.black.ignoresSafeArea())
    }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(isEnabled ? .white : Color.white.opacity(0.35))
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(
                ZStack {
                    if isEnabled {
                        // Ambient card blur
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(configuration.isPressed ? 0.7 : 0.9)

                        // Shimmer highlight border
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.25),
                                        Color.white.opacity(0.05),
                                        Color.clear,
                                        Color.white.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    } else {
                        // Dark disabled background
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.04))

                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    }
                }
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65, blendDuration: 0), value: configuration.isPressed)
    }
}
