import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth
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
    let connectionID: String
    let peer: MercuryPeer
    let controlStreamCoordinator: MediaControlStreamCoordinator
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
            if !reduceMotion { pulseTrigger.toggle() }
            installAckHandler()
        }
        .onDisappear {
            // Don't permanently remove — `HermesSquareRoot` may have
            // installed a longer-lived handler. Only clear our pending
            // banner state.
            awaitingRequestID = nil
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
                Label("Ask to Mirror", systemImage: "rectangle.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Self.mercuryGray)
            .disabled(peer.canRequestMirror == false || awaitingRequestID != nil)
            .accessibilityLabel("Ask to mirror Mac screen")

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
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
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

    // MARK: - Actions

    private func installAckHandler() {
        controlStreamCoordinator.mirrorAckHandler = { ack in
            await MainActor.run {
                self.lastAck = ack
                if ack.requestId == self.awaitingRequestID {
                    self.awaitingRequestID = nil
                }
            }
        }
    }

    private func requestMirror() async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            lastError = "Sign in to mirror your Mac."
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
            try await controlStreamCoordinator.send(frame: frame)
        } catch {
            lastError = error.localizedDescription
            awaitingRequestID = nil
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
