import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import LocalAuthentication
import OSLog
#if canImport(UIKit)
import UIKit
#endif

enum PhoneControlSetupMessage {
    static let trustedDeviceRequired = "Trust this iPhone for Mac control. If it is already trusted, confirm Computer Use is enabled for this account."

    static func message(for error: Error) -> String {
        if let gatewayError = error as? CloudGatewayError {
            switch gatewayError.classification {
            case .notAuthenticated:
                return "Sign in to control your Mac."
            case .networkUnavailable:
                return "You appear to be offline. Reconnect, then try Mac control again."
            case .appCheckBlocked:
                return "App Check blocked Mac control on this iPhone."
            case .permissionDenied:
                return trustedDeviceRequired
            default:
                return gatewayError.classification.recoveryHint
            }
        }
        if isFirestorePermissionDenied(error) {
            return trustedDeviceRequired
        }
        return error.localizedDescription
    }

    static func isFirestorePermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == FirestoreErrorDomain,
           FirestoreErrorCode.Code(rawValue: ns.code) == .permissionDenied {
            return true
        }
        return ns.localizedDescription.localizedCaseInsensitiveContains("permission")
            || ns.localizedDescription.localizedCaseInsensitiveContains("insufficient")
    }
}

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
    @State private var errorProgress: CGFloat = 1.0
    @State private var ackProgress: CGFloat = 1.0
    @State private var isShowingFileImporter = false
    @State private var sendingFile = false
    @State private var pulseTrigger = false
    @State private var isShowingMirrorViewer = false
    @State private var mirrorTimeoutTask: Task<Void, Never>?
    @State private var cooldownTickerTask: Task<Void, Never>?
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var ackDismissTask: Task<Void, Never>?
    @State private var errorDragOffset: CGFloat = 0
    @State private var ackDragOffset: CGFloat = 0
    @State private var ackAnimateTrigger = false
    @State private var isShowingCustomizeSheet = false
    @StateObject private var screenShareViewer = ScreenShareViewerCoordinator()
    /// Mercury screen-share controls share the already-live
    /// `media.control` stream, matching Android. Agent Watch still owns
    /// its dedicated Computer Use stream, but the mirror tools must not
    /// depend on that separate lifecycle.
    @State private var phoneControlSender: PhoneControlSender?
    @State private var phoneControlConnectionID: String?
    @State private var phoneControlStarting = false
    @State private var phoneControlError: String?
    @State private var clipboardStatusMessage: String?
    @State private var pendingClipboardRequests: [String: HermesRealtimeRelayClipboardAction] = [:]
    @State private var remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    @State private var remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult?
    @State private var selectedMirrorDisplayId: String?
    @State private var activeMirrorSessionId: String?
    @State private var activeMirrorViewerId: String?
    @State private var activeMirrorViewerRole: String?
    @State private var backgroundImage: UIImage? = nil
    @ObservedObject private var personalizationStore = MercuryPersonalizationStore.shared
    @ObservedObject private var transferHistoryStore = MercuryTransferHistoryStore.shared
    @State private var dashboardStore = DashboardStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dismiss) private var dismiss

    private var personalization: MercuryDevicePersonalization {
        personalizationStore.snapshot(for: connectionID)
    }

    private var personalizationBinding: Binding<MercuryDevicePersonalization> {
        personalizationStore.binding(for: connectionID)
    }

    private var accent: Color {
        personalizationStore.resolvedAccent(
            for: connectionID,
            wallpaperBase64: peer.blurredWallpaperBase64
        )
    }

    private var sampledAuto: Color {
        WallpaperAccentSampler.dominantAccent(fromBase64: peer.blurredWallpaperBase64)
            ?? MercuryAccent.blue.staticColor
    }

    private var effectiveNickname: String {
        personalizationStore.effectiveNickname(for: connectionID, fallback: peer.displayName)
    }

    var body: some View {
        ZStack {
            backgroundView
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    MercuryHeaderCard(
                        peer: peer,
                        nickname: effectiveNickname,
                        accent: accent,
                        pulse: pulseTrigger,
                        avatarStyle: personalization.avatar,
                        reduceMotion: reduceMotion
                    ) {
                        MercuryLiveStatusStrip(
                            peer: peer,
                            phase: controlStreamCoordinator.phase,
                            accent: accent,
                            sampledAuto: sampledAuto,
                            recentTransfersCount: transferHistoryStore.totalCount(for: connectionID),
                            inFlightCount: fileTransferService?.inFlightCount ?? 0,
                            moodName: MercuryMoodPreset.matching(personalization)?.name,
                            canRequestMirror: canRequestMirror,
                            onReconnect: {
                                Task {
                                    await controlStreamCoordinator.stop()
                                    if let uid = uidProvider() {
                                        controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
                                    }
                                }
                            },
                            onMirror: { Task { await requestMirror() } },
                            onCall: { Task { await placeCall() } },
                            onSendFile: { isShowingFileImporter = true },
                            onShowActivity: {
                                // The Recent Transfers card is already
                                // visible — opening the customize sheet
                                // would surprise the user. For now this
                                // is a no-op tap target that just
                                // confirms with a haptic via the chip's
                                // selectionChanged feedback.
                            },
                            onOpenCustomize: { isShowingCustomizeSheet = true }
                        )
                    }

                    MercuryActionStack(
                        order: personalization.normalizedActionOrder(),
                        peer: peer,
                        accent: accent,
                        canRequestMirror: canRequestMirror,
                        canPlaceCall: peer.canPlaceCall,
                        canSendFile: peer.canSendFile && fileTransferService != nil,
                        mirrorAutoAccept: mirrorAutoAccept,
                        awaitingRequestID: awaitingRequestID,
                        sendingFile: sendingFile,
                        mercuryStatusMessage: mercuryStatusMessage,
                        onRequestMirror: { Task { await requestMirror() } },
                        onPlaceCall: { Task { await placeCall() } },
                        onSendFile: { isShowingFileImporter = true },
                        usePremiumSOTAUX: personalization.usePremiumSOTAUX ?? false
                    )

                    MercuryRecentTransfersCard(
                        entries: transferHistoryStore.recent(for: connectionID, limit: 5),
                        totalCount: transferHistoryStore.totalCount(for: connectionID),
                        accent: accent,
                        onRemove: { transferHistoryStore.remove(id: $0.id) },
                        onSendAnother: { isShowingFileImporter = true }
                    )

                    MercuryMoodCarousel(
                        personalization: personalizationBinding,
                        sampledAuto: sampledAuto,
                        onOpenCustomize: { isShowingCustomizeSheet = true }
                    )
                }
                .padding(24)
            }

            // Top-floating HUD Overlay Container
            VStack {
                if let lastError {
                    floatingErrorHUD(message: lastError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }

                if let ack = lastAck {
                    floatingAckHUD(for: ack)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .animation(.spring(response: 0.38, dampingFraction: 0.78, blendDuration: 0), value: lastError)
            .animation(.spring(response: 0.38, dampingFraction: 0.78, blendDuration: 0), value: lastAck)
        }
        .onAppear {
            Self.debugTrace("mirror_sheet_appear connectionID=\(connectionID) peerOnline=\(peer.isOnline) phase=\(String(describing: controlStreamCoordinator.phase))")
            if !reduceMotion { pulseTrigger.toggle() }
            installAckHandler()
            decodeWallpaper(peer.blurredWallpaperBase64)
            Task {
                await dashboardStore.load()
            }
        }
        .onChange(of: peer.blurredWallpaperBase64) { _, newBase64 in
            decodeWallpaper(newBase64)
        }
        .onDisappear {
            if activeMirrorRequestID != nil {
                Task { await stopActiveMirror(reason: "sheet_disappeared") }
            }
            // Don't permanently remove — `HermesSquareRoot` may have
            // installed a longer-lived handler. Only clear our pending
            // banner state.
            mirrorTimeoutTask?.cancel()
            mirrorTimeoutTask = nil
            cooldownTickerTask?.cancel()
            cooldownTickerTask = nil
            errorDismissTask?.cancel()
            errorDismissTask = nil
            ackDismissTask?.cancel()
            ackDismissTask = nil
            awaitingRequestID = nil
            activeMirrorSessionId = nil
            activeMirrorViewerId = nil
            activeMirrorViewerRole = nil
            pendingClipboardRequests.removeAll()
            controlStreamCoordinator.mirrorFrameHandler = nil
            controlStreamCoordinator.mirrorFrameV2Handler = nil
            controlStreamCoordinator.focusContextHandler = nil
            controlStreamCoordinator.controlDeniedHandler = nil
            controlStreamCoordinator.clipboardResponseHandler = nil
            controlStreamCoordinator.remoteUnlockStateHandler = nil
            controlStreamCoordinator.remoteUnlockResultHandler = nil
            screenShareViewer.longTermReferenceTokenHandler = nil
            // Do NOT stop the phone control coordinator here — it is the
            // app-scope singleton; tearing it down would close the
            // Computer Use bi-stream that the Agent Live Stage and the
            // You-tab Agent Watch surface also depend on.
        }
        .fullScreenCover(isPresented: $isShowingMirrorViewer) {
            MercuryMirrorViewerFullScreen(
                coordinator: screenShareViewer,
                resetToken: activeMirrorRequestID,
                controlStatus: mirrorControlStatus,
                controlInputEnabled: activeMirrorRequestID != nil && activeMirrorViewerRole == "controller",
                streamPhase: controlStreamCoordinator.phase,
                reconnectAttemptStartedAt: controlStreamCoordinator.reconnectAttemptStartedAt,
                lastFailureReason: controlStreamCoordinator.lastFailureReason,
                lastLiveAt: controlStreamCoordinator.lastLiveAt,
                controlRoundTripMillis: controlStreamCoordinator.lastRoundTripMillis,
                displays: lastAck?.availableDisplays ?? [],
                selectedDisplayId: selectedMirrorDisplayId ?? lastAck?.selectedDisplayId,
                remoteUnlockState: remoteUnlockState ?? lastAck?.remoteUnlockState,
                usePremiumSOTAUX: personalization.usePremiumSOTAUX ?? false,
                sendTapIntent: { x, y, mouseButton in
                    let displayId = selectedMirrorDisplayId ?? lastAck?.selectedDisplayId
                    Task { await sendPhoneControlIntent(kind: .tap, displayId: displayId, normalizedX: x, normalizedY: y, mouseButton: mouseButton) }
                },
                sendScrollIntent: { x1, y1, x2, y2, displayId in
                    Task {
                        await sendPhoneControlIntent(
                            kind: .scroll,
                            displayId: displayId ?? selectedMirrorDisplayId ?? lastAck?.selectedDisplayId,
                            normalizedX: x1,
                            normalizedY: y1,
                            normalizedX2: x2,
                            normalizedY2: y2
                        )
                    }
                },
                sendPointerMoveIntent: { dx, dy in
                    Task { await sendPhoneControlIntent(kind: .pointerMove, normalizedX2: dx, normalizedY2: dy) }
                },
                sendPointerClickIntent: { mouseButton in
                    Task { await sendPhoneControlIntent(kind: .pointerClick, mouseButton: mouseButton) }
                },
                sendTextIntent: { text in
                    Task { await sendPhoneControlIntent(kind: .type, text: text) }
                },
                sendShortcutIntent: { key, modifiers in
                    Task { await sendPhoneControlIntent(kind: .shortcut, key: key, modifiers: modifiers) }
                },
                sendAgentContextTargetIntent: { x, y, instruction, runtime, clientIntentId in
                    Task {
                        await sendPhoneControlContextTarget(
                            normalizedX: x,
                            normalizedY: y,
                            instruction: instruction,
                            runtime: runtime,
                            threadId: nil
                        )
                    }
                },
                pasteClipboardToMac: {
                    Task { await sendClipboardRequest(action: .pasteToMac) }
                },
                grabClipboardFromMac: {
                    Task { await sendClipboardRequest(action: .grabFromMac) }
                },
                sendRemoteUnlockCredential: { password in
                    Task { await sendRemoteUnlockCredential(password: password) }
                },
                onSelectDisplay: selectMirrorDisplay,
                onTrustControlDevice: {
                    Task { await trustThisIPhoneForControl() }
                },
                onForceReconnect: {
                    Task {
                        await controlStreamCoordinator.stop()
                        if let uid = uidProvider() {
                            controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
                        }
                    }
                },
                onRetryRequest: {
                    Task {
                        await requestMirror()
                    }
                },
                onClose: {
                    isShowingMirrorViewer = false
                    Task { await stopActiveMirror(reason: "viewer_closed") }
                }
            )
            .onDisappear {
                if activeMirrorRequestID != nil {
                    Task { await stopActiveMirror(reason: "viewer_disappeared") }
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleFilePick(result) }
        }
        .sheet(isPresented: $isShowingCustomizeSheet) {
            MercuryCustomizeSheet(
                peer: peer,
                personalization: personalizationBinding,
                sampledAuto: sampledAuto,
                nicknameSuggestions: personalizationStore.nicknameSuggestions(for: peer.displayName)
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mercury Live for \(effectiveNickname)")
        .onChange(of: lastError) { _, newValue in
            errorDismissTask?.cancel()
            errorProgress = 1.0
            if newValue != nil {
                withAnimation(.linear(duration: 6.0)) {
                    errorProgress = 0.0
                }
                errorDismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        lastError = nil
                    }
                }
            }
        }
        .onChange(of: lastAck) { _, newValue in
            ackDismissTask?.cancel()
            ackProgress = 1.0
            if let newValue {
                if newValue.decision != .accepted && newValue.decision != .coolingDown {
                    withAnimation(.linear(duration: 6.0)) {
                        ackProgress = 0.0
                    }
                    ackDismissTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            lastAck = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        switch personalization.background {
        case .wallpaper:
            if let backgroundImage = backgroundImage, personalization.mimicLoginBackground {
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
                colorDriver: dashboardStore.swarmColorDriver
            )
        }
    }

    @ViewBuilder
    private var auroraBackground: some View {
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
    private func floatingErrorHUD(message: String) -> some View {
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
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.red.opacity(0.04))
            }
        )
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
    private func floatingAckHUD(for ack: HermesRealtimeRelayMirrorAck) -> some View {
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
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ackColor(for: ack).opacity(0.04))
            }
        )
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

    private func ackGradient(for ack: HermesRealtimeRelayMirrorAck) -> LinearGradient {
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

    private func ackProgressGradient(for ack: HermesRealtimeRelayMirrorAck) -> LinearGradient {
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

    private var mirrorAutoAccept: Bool {
        peer.capabilities.contains(.mirrorAutoAccept)
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
                self.remoteUnlockState = ack.remoteUnlockState ?? self.remoteUnlockState
                self.cooldownClock = Date()
                if ack.requestId == self.awaitingRequestID {
                    self.mirrorTimeoutTask?.cancel()
                    self.mirrorTimeoutTask = nil
                    self.awaitingRequestID = nil
                }
                if ack.requestId == self.activeMirrorRequestID || ack.requestId == self.awaitingRequestID {
                    self.activeMirrorSessionId = ack.sessionId ?? self.activeMirrorSessionId
                    self.activeMirrorViewerId = ack.viewerId ?? self.activeMirrorViewerId
                    self.activeMirrorViewerRole = ack.viewerRole ?? self.activeMirrorViewerRole
                }
                let isActiveDisplaySelectionAck = ack.requestId == self.activeMirrorRequestID
                    && (ack.availableDisplays != nil || ack.selectedDisplayId != nil)

                if ack.decision == .accepted {
                    if isActiveDisplaySelectionAck {
                        self.selectedMirrorDisplayId = ack.selectedDisplayId ?? self.selectedMirrorDisplayId
                        self.activeMirrorSessionId = ack.sessionId ?? self.activeMirrorSessionId
                        self.activeMirrorViewerId = ack.viewerId ?? self.activeMirrorViewerId
                        self.activeMirrorViewerRole = ack.viewerRole ?? self.activeMirrorViewerRole
                        self.lastError = nil
                        self.refreshCooldownTicker(for: ack)
                        return
                    }
                    self.activeMirrorRequestID = ack.requestId
                    self.activeMirrorSessionId = ack.sessionId
                    self.activeMirrorViewerId = ack.viewerId
                    self.activeMirrorViewerRole = ack.viewerRole ?? "controller"
                    self.selectedMirrorDisplayId = ack.selectedDisplayId ?? ack.availableDisplays?.first?.id ?? self.selectedMirrorDisplayId
                    self.isShowingMirrorViewer = true
                    Task { await self.startPhoneControlIfPossible(surfaceError: false) }
                } else if ack.requestId == self.activeMirrorRequestID {
                    if isActiveDisplaySelectionAck {
                        self.selectedMirrorDisplayId = ack.selectedDisplayId ?? self.selectedMirrorDisplayId
                        self.lastError = ack.detail ?? "Could not switch displays."
                        self.refreshCooldownTicker(for: ack)
                        return
                    }
                    self.activeMirrorRequestID = nil
                    self.activeMirrorSessionId = nil
                    self.activeMirrorViewerId = nil
                    self.activeMirrorViewerRole = nil
                    self.selectedMirrorDisplayId = nil
                    self.isShowingMirrorViewer = false
                    // Mirror rejected — keep the singleton's Computer
                    // Use bi-stream alive; it is shared with other
                    // surfaces and will be reused on the next mirror.
                }
                self.refreshCooldownTicker(for: ack)
            }
        }
        controlStreamCoordinator.mirrorFrameHandler = { frame in
            await screenShareViewer.ingest(frame: frame)
        }
        controlStreamCoordinator.mirrorFrameV2Handler = { frame in
            await screenShareViewer.ingest(frameV2: frame)
        }
        controlStreamCoordinator.focusContextHandler = { context in
            await MainActor.run {
                screenShareViewer.ingest(focusContext: context)
            }
        }
        controlStreamCoordinator.controlDeniedHandler = { denied in
            await MainActor.run {
                self.phoneControlError = self.phoneControlDeniedMessage(for: denied)
                switch denied.reason {
                case .signatureFailure, .counterReplay, .staleTimestamp:
                    self.phoneControlSender = nil
                    self.phoneControlConnectionID = nil
                default:
                    break
                }
            }
        }
        controlStreamCoordinator.clipboardResponseHandler = { response in
            await MainActor.run {
                self.handleClipboardResponse(response)
            }
        }
        controlStreamCoordinator.remoteUnlockStateHandler = { state in
            await MainActor.run {
                self.remoteUnlockState = state
            }
        }
        controlStreamCoordinator.remoteUnlockResultHandler = { result in
            await MainActor.run {
                self.remoteUnlockResult = result
                switch result.status {
                case .unlocked:
                    self.remoteUnlockState = nil
                    self.phoneControlError = nil
                case .denied, .failed, .expired:
                    self.phoneControlError = result.detail ?? "Remote Unlock was denied."
                case .accepted, .disconnected:
                    break
                }
            }
        }
        screenShareViewer.longTermReferenceTokenHandler = { token in
            try? await controlStreamCoordinator.sendLongTermReferenceAcknowledgement(
                token: token,
                requestId: activeMirrorRequestID
            )
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
        personalization.haptics.play()
        let requestID = UUID().uuidString
        let viewerID = UUID().uuidString
        let signingKey = try? PhoneControlSigningKeyStore.shared.signingKey()
        let controlAuthorityPeerNodeId = signingKey.map {
            PhoneControlSigningKeyStore.shared.peerNodeId(for: $0)
        }
        let remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession?
        if peer.capabilities.contains(.remoteUnlockHost) {
            guard let signingKey, let controlAuthorityPeerNodeId else {
                lastError = "Trust this iPhone for Mac control before requesting a locked Mac mirror."
                return
            }
            do {
                try await confirmLocalAuthentication(reason: "Allow Remote Unlock for this Mac.")
                try await PhoneControlAuthorityPublisher.shared.publish(
                    uid: uid,
                    connectionId: connectionID,
                    deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
                    peerNodeId: controlAuthorityPeerNodeId,
                    publicKey: signingKey.privateKey.publicKey
                )
                let sessionSigner = PhoneControlSender(
                    peerNodeId: controlAuthorityPeerNodeId,
                    uid: uid,
                    connectionId: connectionID,
                    signingKeyProvider: { signingKey },
                    frameSink: { _ in }
                )
                let issuedAt = Date()
                let unsignedSession = HermesRealtimeRelayRemoteUnlockSession(
                    requestId: "remote-unlock-\(requestID)",
                    sessionId: UUID().uuidString,
                    intent: .request,
                    requesterDisplayName: deviceDisplayName(),
                    viewerDeviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
                    requestedAt: issuedAt,
                    expiresAt: issuedAt.addingTimeInterval(RemoteUnlockPolicy.default.sessionTTLSeconds),
                    localAuthenticationSatisfied: true,
                    requestedLockState: nil,
                    requestedBackend: .appleScreenSharingLoopback,
                    authority: Self.emptyAuthorityEnvelope
                )
                remoteUnlockSession = try sessionSigner.sign(remoteUnlockSession: unsignedSession)
            } catch {
                lastError = "Remote Unlock needs Face ID, Touch ID, or passcode confirmation."
                awaitingRequestID = nil
                return
            }
        } else {
            remoteUnlockSession = nil
        }
        awaitingRequestID = requestID
        activeMirrorRequestID = nil
        activeMirrorSessionId = nil
        activeMirrorViewerId = viewerID
        activeMirrorViewerRole = nil
        selectedMirrorDisplayId = nil
        phoneControlError = nil
        lastError = nil
        lastAck = nil
        lastAckReceivedAt = nil
        remoteUnlockState = nil
        remoteUnlockResult = nil
        do {
            try await controlStreamCoordinator.ensureResponsive(uid: uid, connectionID: connectionID)
        } catch {
            Self.log.error("mirror_request_probe_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mirror_request_probe_failed requestID=\(requestID) error=\(error.localizedDescription)")
            lastError = error.localizedDescription
            awaitingRequestID = nil
            return
        }
        // Don't tear down the app-scope phone control coordinator on
        // every mirror request — it stays warm and is reused for tap /
        // scroll input once the Mac approves the mirror.
        cooldownTickerTask?.cancel()
        cooldownTickerTask = nil
        let request = HermesRealtimeRelayMirrorRequest(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: deviceDisplayName(),
            streamClass: MediaStreamClass.screenVideo.rawValue,
            streamingCapabilities: MercuryVideoToolboxCapabilityProbe.snapshot(
                mediaFrameVersions: .v1AndV2
            ).wireValue,
            focusFollowMode: AgentFocusFollowMode.off.rawValue,
            viewerId: viewerID,
            viewerDeviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
            controlAuthorityPeerNodeId: controlAuthorityPeerNodeId,
            remoteUnlockSession: remoteUnlockSession
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
        guard uidProvider()?.isEmpty == false else {
            activeMirrorRequestID = nil
            activeMirrorSessionId = nil
            activeMirrorViewerId = nil
            activeMirrorViewerRole = nil
            selectedMirrorDisplayId = nil
            isShowingMirrorViewer = false
            // Phone control coordinator is app-scope; do not stop it.
            return
        }
        guard let requestID = activeMirrorRequestID else { return }
        let sessionID = activeMirrorSessionId
        activeMirrorRequestID = nil
        activeMirrorSessionId = nil
        activeMirrorViewerId = nil
        activeMirrorViewerRole = nil
        selectedMirrorDisplayId = nil
        isShowingMirrorViewer = false
        lastAck = nil
        lastAckReceivedAt = nil
        cooldownTickerTask?.cancel()
        cooldownTickerTask = nil
        // Phone control coordinator is app-scope; do not stop it.
        do {
            try await controlStreamCoordinator.sendMirrorStop(
                requestId: requestID,
                sessionId: sessionID,
                reason: reason,
                timeout: 2
            )
        } catch {
            Self.log.error("mirror_stop_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mirror_stop_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
        }
    }

    private func selectMirrorDisplay(_ displayId: String) {
        let previousDisplayId = selectedMirrorDisplayId
        selectedMirrorDisplayId = displayId
        guard let uid = uidProvider(), !uid.isEmpty,
              let requestID = activeMirrorRequestID,
              activeMirrorViewerRole == "controller" else {
            selectedMirrorDisplayId = previousDisplayId
            lastError = "Another device controls display switching."
            return
        }
        lastError = nil
        let selection = HermesRealtimeRelayMirrorDisplaySelection(
            requestId: requestID,
            sessionId: activeMirrorSessionId,
            displayId: displayId
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorDisplaySelect,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorDisplaySelection: selection)
        )
        Task {
            do {
                try await controlStreamCoordinator.send(frame: frame, timeout: 2)
            } catch {
                await MainActor.run {
                    selectedMirrorDisplayId = previousDisplayId
                    lastError = "Could not switch display: \(error.localizedDescription)"
                }
            }
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
                personalization.haptics.play()
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

    private static let emptyAuthorityEnvelope = HermesRealtimeRelayAuthorityEnvelope(
        peerNodeId: "",
        counter: 0,
        timestamp: Date(timeIntervalSince1970: 0),
        intentHashBlake3: "",
        signatureEd25519: ""
    )

    private func confirmLocalAuthentication(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.passcodeNotSet)
        }
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? LAError(.authenticationFailed))
                }
            }
        }
    }

    private var mirrorControlStatus: ScreenSharePhoneControlStatus {
        if activeMirrorRequestID != nil && activeMirrorViewerRole == "watcher" {
            return .unavailable("Watching only. Another device controls the Mac.")
        }
        if let phoneControlError {
            return .unavailable(phoneControlError)
        }
        if phoneControlSender != nil {
            if let clipboardStatusMessage {
                return .liveNotice(clipboardStatusMessage)
            }
            return .live
        }
        if phoneControlStarting {
            return .connecting
        }
        return activeMirrorRequestID == nil ? .unavailable("Mirror is read only.") : .connecting
    }

    private func startPhoneControlIfPossible(surfaceError: Bool = true, allowTrustRetry: Bool = true) async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            if surfaceError {
                phoneControlError = "Sign in to control your Mac."
            }
            return
        }
        if phoneControlSender != nil, phoneControlConnectionID == connectionID { return }
        phoneControlStarting = true
        defer { phoneControlStarting = false }
        do {
            await LiveDeviceTrustGateway().registerSelfIfNeeded()
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
            let signingKey = try PhoneControlSigningKeyStore.shared.signingKey()
            let peerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingKey)
            try await PhoneControlAuthorityPublisher.shared.publish(
                uid: uid,
                connectionId: connectionID,
                deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
                peerNodeId: peerNodeId,
                publicKey: signingKey.privateKey.publicKey
            )
            try await sendPhoneControlClassify(uid: uid, connectionID: connectionID, peerNodeId: peerNodeId)
            phoneControlSender = PhoneControlSender(
                peerNodeId: peerNodeId,
                uid: uid,
                connectionId: connectionID,
                signingKeyProvider: { signingKey },
                frameSink: { frame in
                    try await controlStreamCoordinator.send(frame: frame)
                }
            )
            phoneControlConnectionID = connectionID
            phoneControlError = nil
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            if allowTrustRetry, PhoneControlSetupMessage.isFirestorePermissionDenied(error) {
                do {
                    try await LiveDeviceTrustGateway().trustSelfForComputerUseControl()
                    Self.debugTrace("phone_control_auto_trusted_retry connectionID=\(connectionID) deviceID=\(MobileDeviceIdentity.loadOrCreateDeviceId())")
                    await startPhoneControlIfPossible(surfaceError: surfaceError, allowTrustRetry: false)
                    return
                } catch {
                    let message = PhoneControlSetupMessage.message(for: error)
                    Self.log.error("phone_control_auto_trust_failed connectionID=\(self.connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    Self.debugTrace("phone_control_auto_trust_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
                    if surfaceError || PhoneControlSetupMessage.isFirestorePermissionDenied(error) {
                        phoneControlError = message
                    }
                    return
                }
            }
            let message = PhoneControlSetupMessage.message(for: error)
            Self.log.error("phone_control_start_failed connectionID=\(self.connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("phone_control_start_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
            if surfaceError || PhoneControlSetupMessage.isFirestorePermissionDenied(error) {
                phoneControlError = message
            }
        }
    }

    private func trustThisIPhoneForControl() async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to control your Mac."
            return
        }
        phoneControlStarting = true
        defer { phoneControlStarting = false }
        do {
            try await LiveDeviceTrustGateway().trustSelfForComputerUseControl()
            phoneControlSender = nil
            phoneControlConnectionID = nil
            phoneControlError = nil
            Self.debugTrace("phone_control_device_trusted connectionID=\(connectionID) deviceID=\(MobileDeviceIdentity.loadOrCreateDeviceId())")
            await startPhoneControlIfPossible()
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            phoneControlError = PhoneControlSetupMessage.message(for: error)
            Self.log.error("phone_control_trust_failed connectionID=\(self.connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("phone_control_trust_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
        }
    }

    private func ensurePhoneControlStreamResponsive(uid: String, connectionID: String) async throws {
        try await controlStreamCoordinator.ensureResponsive(
            uid: uid,
            connectionID: connectionID,
            freshnessInterval: 2.0,
            probeTimeout: 0.85,
            restartTimeout: 3.0
        )
    }

    private func sendPhoneControlClassify(uid: String, connectionID: String, peerNodeId: String) async throws {
        try await controlStreamCoordinator.send(frame: HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                authorityPeerNodeId: peerNodeId
            )
        ))
    }

    private func phoneControlDeniedMessage(for denied: HermesRealtimeRelayControlDenied) -> String {
        if denied.reason == .unknown, denied.detail == ComputerUseDenyReason.accessibilityRevoked.rawValue {
            return "Allow OpenBurnBar in Mac System Settings > Privacy & Security > Accessibility, then reopen the mirror."
        }
        switch denied.reason {
        case .entitlement:
            return "Mac control is not enabled for this account."
        case .sessionLimit:
            return "Mac control session limit reached. Reopen the mirror to start a fresh session."
        case .dailyLimit:
            return "Mac control hit today's Computer Use action limit."
        case .softCap:
            return "Mac control is limited while Computer Use is in soft-cap mode."
        case .hardCap:
            return "Mac control is blocked by the Computer Use hard cap."
        case .scope:
            return "The Mac blocked that control action for this screen."
        case .denyRegion:
            return "The Mac blocked control in a protected area."
        case .killSwitch:
            return "Mac control is temporarily disabled."
        case .signatureFailure, .counterReplay, .staleTimestamp:
            return "Mac rejected the control signature. Try the action again."
        case .agentUnavailable:
            return denied.detail ?? "The Mac agent is not available for that control action."
        case .unknown:
            return denied.detail ?? "The Mac rejected that control action."
        }
    }

    private func sendClipboardRequest(action: HermesRealtimeRelayClipboardAction) async {
        guard activeMirrorViewerRole == "controller" else {
            setClipboardStatus("Watching only. Take control to use Mac clipboard.")
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            setClipboardStatus("Sign in to control your Mac.")
            return
        }
        let requestId = UUID().uuidString
        let maxBytes = 65_536
        let text: String?
        switch action {
        case .pasteToMac:
            #if canImport(UIKit)
            let phoneText = UIPasteboard.general.string
            #else
            let phoneText: String? = nil
            #endif
            guard let phoneText, !phoneText.isEmpty else {
                setClipboardStatus("Clipboard empty")
                return
            }
            let byteCount = phoneText.utf8.count
            guard byteCount <= maxBytes else {
                setClipboardStatus("Clipboard too large")
                return
            }
            text = phoneText
        case .grabFromMac:
            text = nil
        }

        do {
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            setClipboardStatus(error.localizedDescription)
            return
        }
        if phoneControlSender == nil {
            await startPhoneControlIfPossible()
        }
        guard let phoneControlSender else { return }
        do {
            try await sendPhoneControlClassify(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: phoneControlSender.peerNodeId
            )
            let placeholder = HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "",
                counter: 0,
                timestamp: Date(timeIntervalSince1970: 0),
                intentHashBlake3: "",
                signatureEd25519: ""
            )
            let request = HermesRealtimeRelayClipboardRequest(
                requestId: requestId,
                action: action,
                contentType: "text/plain",
                text: text,
                maxBytes: maxBytes,
                clientIntentId: UUID().uuidString,
                authority: placeholder
            )
            pendingClipboardRequests[requestId] = action
            _ = try await phoneControlSender.send(clipboardRequest: request)
        } catch {
            pendingClipboardRequests.removeValue(forKey: requestId)
            self.phoneControlSender = nil
            phoneControlConnectionID = nil
            setClipboardStatus(error.localizedDescription)
        }
    }

    private func handleClipboardResponse(_ response: HermesRealtimeRelayClipboardResponse) {
        guard let pendingAction = pendingClipboardRequests.removeValue(forKey: response.requestId),
              pendingAction == response.action else {
            return
        }
        switch response.status {
        case .accepted:
            switch response.action {
            case .pasteToMac:
                setClipboardStatus("Pasted to Mac")
            case .grabFromMac:
                guard response.contentType == "text/plain",
                      let text = response.text else {
                    setClipboardStatus("Mac denied clipboard")
                    return
                }
                #if canImport(UIKit)
                UIPasteboard.general.string = text
                #endif
                setClipboardStatus("Mac clipboard copied")
            }
        case .empty:
            setClipboardStatus("Clipboard empty")
        case .denied:
            setClipboardStatus("Mac denied clipboard")
        case .tooLarge:
            setClipboardStatus("Clipboard too large")
        case .unsupported, .error:
            setClipboardStatus(response.detail == "too_large" ? "Clipboard too large" : "Mac denied clipboard")
        }
    }

    private func setClipboardStatus(_ message: String) {
        clipboardStatusMessage = message
        phoneControlError = nil
    }

    private func sendRemoteUnlockCredential(password: String) async {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else {
            phoneControlError = "Enter your Mac password."
            return
        }
        guard activeMirrorViewerRole == "controller" else {
            phoneControlError = "Watching only. Take control from this device to unlock the Mac."
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to unlock your Mac."
            return
        }
        let state = remoteUnlockState ?? lastAck?.remoteUnlockState
        guard let state, state.lockState != .unlocked else {
            phoneControlError = "The Mac is already unlocked."
            return
        }
        let capabilities = state.capabilities
        guard capabilities.enabled,
              capabilities.certificationStatus == .certified,
              let sessionId = state.sessionId,
              let recipientKeyId = capabilities.credentialRecipientKeyId,
              let recipientPublicKey = capabilities.credentialRecipientPublicKeyBase64,
              let algorithm = capabilities.credentialEnvelopeAlgorithm else {
            phoneControlError = "Remote Unlock is not certified on this Mac."
            return
        }
        guard algorithm == RemoteUnlockCredentialEnvelopeCrypto.algorithm else {
            phoneControlError = "Remote Unlock needs an app update on this device."
            return
        }

        do {
            try await confirmLocalAuthentication(reason: "Send your Mac password to this locked Mac.")
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
        } catch {
            phoneControlError = "Remote Unlock needs Face ID, Touch ID, or passcode confirmation."
            return
        }
        if phoneControlSender == nil {
            await startPhoneControlIfPossible()
        }
        guard let phoneControlSender else { return }

        do {
            try await sendPhoneControlClassify(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: phoneControlSender.peerNodeId
            )

            let requestId = UUID().uuidString
            let clientIntentId = UUID().uuidString
            let requestedAt = Date()
            let expiresAt = requestedAt.addingTimeInterval(RemoteUnlockPolicy.default.credentialTTLSeconds)
            let sealed = try RemoteUnlockCredentialEnvelopeCrypto.seal(
                credential: trimmedPassword,
                requestId: requestId,
                sessionId: sessionId,
                clientIntentId: clientIntentId,
                credentialKind: .typedPassword,
                recipientKeyId: recipientKeyId,
                recipientPublicKeyBase64: recipientPublicKey,
                algorithm: algorithm
            )
            let envelope = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
                requestId: requestId,
                sessionId: sessionId,
                clientIntentId: clientIntentId,
                credentialKind: .typedPassword,
                recipientKeyId: recipientKeyId,
                algorithm: algorithm,
                ciphertextBase64: sealed.ciphertextBase64,
                aadBase64: sealed.aadBase64,
                redactedByteCount: sealed.redactedByteCount,
                requestedAt: requestedAt,
                expiresAt: expiresAt,
                authority: Self.emptyAuthorityEnvelope
            )
            _ = try await phoneControlSender.send(remoteUnlockCredential: envelope)
            phoneControlError = "Password sent to Mac login window."
        } catch {
            self.phoneControlSender = nil
            phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
        }
    }

    private func sendPhoneControlIntent(
        kind: HermesRealtimeRelayInputIntent.Kind,
        displayId: String? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        normalizedX2: Double? = nil,
        normalizedY2: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil,
        mouseButton: Int? = nil
    ) async {
        guard activeMirrorViewerRole == "controller" else {
            phoneControlError = "Watching only. Take control from this device to click or type."
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to control your Mac."
            return
        }
        do {
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
            Self.debugTrace("phone_control_stream_not_responsive kind=\(kind.rawValue) connectionID=\(connectionID) error=\(error.localizedDescription)")
            return
        }
        if phoneControlSender == nil {
            await startPhoneControlIfPossible()
        }
        guard let phoneControlSender else {
            Self.debugTrace("phone_control_no_sender_after_start kind=\(kind.rawValue) connectionID=\(connectionID)")
            return
        }
        do {
            try await sendPhoneControlClassify(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: phoneControlSender.peerNodeId
            )
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
            Self.debugTrace("phone_control_classify_failed kind=\(kind.rawValue) connectionID=\(connectionID) error=\(error.localizedDescription)")
            return
        }
        let emptyAuthority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: kind,
            displayId: displayId,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            normalizedX2: normalizedX2,
            normalizedY2: normalizedY2,
            text: text,
            key: key,
            modifiers: modifiers,
            mouseButton: mouseButton,
            authority: emptyAuthority
        )
        do {
            Self.debugTrace("phone_control_send kind=\(kind.rawValue) connectionID=\(connectionID)")
            _ = try await phoneControlSender.send(intent: intent)
            phoneControlError = nil
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
            Self.debugTrace("phone_control_send_failed kind=\(kind.rawValue) connectionID=\(connectionID) error=\(error.localizedDescription)")
        }
    }

    private func sendPhoneControlContextTarget(
        normalizedX: Double,
        normalizedY: Double,
        instruction: String,
        runtime: String,
        threadId: String?
    ) async {
        guard activeMirrorViewerRole == "controller" else {
            phoneControlError = "Watching only. Take control to hand this target to an agent."
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to control your Mac."
            return
        }
        do {
            try await ensurePhoneControlStreamResponsive(uid: uid, connectionID: connectionID)
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
            return
        }
        if phoneControlSender == nil {
            await startPhoneControlIfPossible()
        }
        guard let phoneControlSender else {
            return
        }
        do {
            try await sendPhoneControlClassify(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: phoneControlSender.peerNodeId
            )
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
            return
        }

        let emptyAuthority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )

        let displayId = selectedMirrorDisplayId ?? lastAck?.selectedDisplayId
        let target = HermesRealtimeRelayAgentContextTarget(
            requestId: UUID().uuidString,
            sessionId: nil,
            runtime: runtime,
            threadId: threadId,
            displayId: displayId,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            normalizedRect: nil,
            instruction: instruction,
            focusContext: nil,
            clientIntentId: UUID().uuidString,
            requestedAt: Date(),
            authority: emptyAuthority
        )

        do {
            _ = try await phoneControlSender.send(contextTarget: target)
            phoneControlError = nil
        } catch {
            self.phoneControlSender = nil
            self.phoneControlConnectionID = nil
            phoneControlError = error.localizedDescription
        }
    }
}

private struct MercuryMirrorViewerFullScreen: View {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator
    let resetToken: String?
    let controlStatus: ScreenSharePhoneControlStatus
    let controlInputEnabled: Bool
    let streamPhase: MediaControlStreamCoordinator.Phase
    let reconnectAttemptStartedAt: Date?
    let lastFailureReason: String?
    let lastLiveAt: Date?
    let controlRoundTripMillis: Int?
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    let usePremiumSOTAUX: Bool
    let sendTapIntent: (Double, Double, Int) -> Void
    let sendScrollIntent: (Double, Double, Double, Double, String?) -> Void
    let sendPointerMoveIntent: (Double, Double) -> Void
    let sendPointerClickIntent: (Int) -> Void
    let sendTextIntent: (String) -> Void
    let sendShortcutIntent: (String, [String]) -> Void
    let sendAgentContextTargetIntent: (Double, Double, String, String, String?) -> Void
    let pasteClipboardToMac: () -> Void
    let grabClipboardFromMac: () -> Void
    let sendRemoteUnlockCredential: (String) -> Void
    let onSelectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScreenShareViewerView(
            coordinator: coordinator,
            resetToken: resetToken,
            controlStatus: controlStatus,
            controlInputEnabled: controlInputEnabled,
            controlRoundTripMillis: controlRoundTripMillis,
            displays: displays,
            selectedDisplayId: selectedDisplayId,
            streamPhase: streamPhase,
            reconnectAttemptStartedAt: reconnectAttemptStartedAt,
            lastFailureReason: lastFailureReason,
            lastLiveAt: lastLiveAt,
            remoteUnlockState: remoteUnlockState,
            usePremiumSOTAUX: usePremiumSOTAUX,
            onForceReconnect: onForceReconnect,
            onRetryRequest: onRetryRequest,
            sendTapIntent: sendTapIntent,
            sendScrollIntent: sendScrollIntent,
            sendPointerMoveIntent: sendPointerMoveIntent,
            sendPointerClickIntent: sendPointerClickIntent,
            sendTextIntent: sendTextIntent,
            sendShortcutIntent: sendShortcutIntent,
            sendAgentContextTargetIntent: sendAgentContextTargetIntent,
            pasteClipboardToMac: pasteClipboardToMac,
            grabClipboardFromMac: grabClipboardFromMac,
            sendRemoteUnlockCredential: sendRemoteUnlockCredential,
            onSelectDisplay: onSelectDisplay,
            onTrustControlDevice: onTrustControlDevice,
            onClose: onClose
        )
        .background(Color.black.ignoresSafeArea())
    }
}
