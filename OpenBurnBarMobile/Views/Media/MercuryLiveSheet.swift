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
    @State private var awaitingRequestID: String?
    @State private var lastError: String?
    @State private var isShowingFileImporter = false
    @State private var sendingFile = false
    @State private var pulseTrigger = false
    @State private var isShowingMirrorViewer = false
    @State private var mirrorTimeoutTask: Task<Void, Never>?
    @StateObject private var screenShareViewer = ScreenShareViewerCoordinator()
    @AppStorage("mercuryPinnedTileEnabled") private var mercuryPinnedTileEnabled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    private static let mercurySilver = Color(red: 0.78, green: 0.74, blue: 0.69)
    private static let mercuryGray = Color(red: 0.63, green: 0.67, blue: 0.73)

    var body: some View {
        VStack(spacing: 24) {
            header
            actionStack
            if let ack = lastAck {
                ackBanner(for: ack)
            }
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Divider()
            Toggle(isOn: $mercuryPinnedTileEnabled) {
                Text("Show My Mac on Hermes Square")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Show My Mac tile on Hermes Square pinned grid")
            Spacer(minLength: 0)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(borderGradient, lineWidth: 1)
                )
        )
        .padding(20)
        .onAppear {
            Self.debugTrace("mirror_sheet_appear connectionID=\(connectionID) peerOnline=\(peer.isOnline) phase=\(String(describing: controlStreamCoordinator.phase))")
            if !reduceMotion { pulseTrigger.toggle() }
            installAckHandler()
        }
        .onDisappear {
            // Don't permanently remove — `HermesSquareRoot` may have
            // installed a longer-lived handler. Only clear our pending
            // banner state.
            mirrorTimeoutTask?.cancel()
            mirrorTimeoutTask = nil
            awaitingRequestID = nil
            controlStreamCoordinator.mirrorFrameHandler = nil
        }
        .fullScreenCover(isPresented: $isShowingMirrorViewer) {
            MercuryMirrorViewerFullScreen(
                coordinator: screenShareViewer,
                onClose: { isShowingMirrorViewer = false }
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

    private var header: some View {
        VStack(spacing: 12) {
            avatar
            Text(peer.displayName)
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(peer.isOnline ? "Connected via iroh" : "Offline")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .strokeBorder(borderGradient, lineWidth: 1.5)
                .frame(width: 96, height: 96)
                .scaleEffect(pulseTrigger && !reduceMotion ? 1.06 : 1.0)
                .opacity(peer.isOnline ? 1.0 : 0.45)
                .animation(
                    reduceMotion
                        ? .none
                        : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                    value: pulseTrigger
                )
            Image(systemName: "macbook")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(borderGradient)
        }
        .accessibilityHidden(true)
    }

    private var actionStack: some View {
        VStack(spacing: 12) {
            Button {
                Task { await requestMirror() }
            } label: {
                Label(
                    awaitingRequestID == nil ? "Ask to Mirror" : "Waiting for Mac...",
                    systemImage: awaitingRequestID == nil ? "rectangle.on.rectangle.angled" : "hourglass"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Self.mercuryGray)
            .disabled(!canRequestMirror)
            .accessibilityLabel("Ask to mirror Mac screen")

            if awaitingRequestID != nil {
                Text("Request sent. Check your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let status = mercuryStatusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !peer.isOnline {
                Text("Mercury is still connecting. Ask will wait for the Mac and show the real error if it cannot connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await placeCall() }
            } label: {
                Label("Call Mac", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Self.mercuryGray)
            .disabled(peer.canPlaceCall == false)
            .accessibilityLabel("Call paired Mac")

            Button {
                isShowingFileImporter = true
            } label: {
                Label(sendingFile ? "Sending…" : "Send File…", systemImage: "paperclip")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Self.mercuryGray)
            .disabled(peer.canSendFile == false || sendingFile || fileTransferService == nil)
            .accessibilityLabel("Send file to paired Mac")
        }
    }

    @ViewBuilder
    private func ackBanner(for ack: HermesRealtimeRelayMirrorAck) -> some View {
        VStack(spacing: 4) {
            Text(bannerTitle(for: ack))
                .font(.subheadline.weight(.medium))
            if let detail = ack.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let cooldown = ack.cooldownSecondsRemaining, cooldown > 0 {
                Text("Cooling down · \(cooldown)s")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .accessibilityElement(children: .combine)
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
                if ack.requestId == self.awaitingRequestID {
                    self.mirrorTimeoutTask?.cancel()
                    self.mirrorTimeoutTask = nil
                    self.awaitingRequestID = nil
                }
                if ack.decision == .accepted {
                    self.isShowingMirrorViewer = true
                }
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
        lastError = nil
        lastAck = nil
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
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScreenShareViewerView(coordinator: coordinator)
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
