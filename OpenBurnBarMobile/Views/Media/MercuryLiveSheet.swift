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

enum MercuryMirrorTeardownTrigger: Equatable {
    case explicitClose
    case signOut
    case sheetDisappear
    case viewerDisappear
    case sceneInactive

    var shouldSendMirrorStop: Bool {
        switch self {
        case .explicitClose, .signOut:
            return true
        case .sheetDisappear, .viewerDisappear, .sceneInactive:
            return false
        }
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
    private static let remoteUnlockSessionRequiredDetail = "remote_unlock_session_required"
    private static let remoteUnlockCredentialAckTimeoutNanoseconds: UInt64 = 45_000_000_000
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
    /// Phase 12 — when set, the mirror request asks the Mac to launch this
    /// runtime's CLI interactively in a Terminal and pin the stream to just
    /// that window (a focused native TUI) instead of mirroring the whole
    /// display. `nil` keeps the standard full-display Mercury Live mirror.
    var terminalRuntime: String? = nil

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
    @State private var authorityRefreshTask: Task<Void, Never>?
    @State private var clipboardStatusMessage: String?
    @State private var pendingClipboardRequests: [String: HermesRealtimeRelayClipboardAction] = [:]
    @State private var remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    @State private var lastLockedRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    @State private var remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult?
    @State private var remoteUnlockRefreshInFlight = false
    @State private var remoteUnlockPasswordDraft = ""
    @State private var remoteUnlockSavedCredentialAvailable = false
    @State private var remoteUnlockDiagnosticMessage: String?
    @State private var pendingRemoteUnlockCredentialRequestID: String?
    @State private var remoteUnlockMirrorRequestIDs: Set<String> = []
    @State private var remoteUnlockCredentialAckTimeoutTask: Task<Void, Never>?
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
    @Environment(\.scenePhase) private var scenePhase

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

    private var backgroundVisibility: MobileBackgroundVisibility {
        isShowingMirrorViewer || isShowingCustomizeSheet
            ? MobileBackgroundVisibility.obscured
            : MobileBackgroundVisibility.prominent
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
            refreshSavedCredentialAvailability()
            Task {
                await dashboardStore.load()
            }
        }
        .onChange(of: peer.blurredWallpaperBase64) { _, newBase64 in
            decodeWallpaper(newBase64)
        }
        .onDisappear {
            // SwiftUI can call `onDisappear` when the app backgrounds,
            // re-parents a sheet, or promotes the full-screen viewer. Those
            // transitions are not user intent to end the Mac mirror. Keep the
            // server-side session alive and only detach local view handlers.
            // Explicit close paths call `stopActiveMirror(reason:)`.
            mirrorTimeoutTask?.cancel()
            mirrorTimeoutTask = nil
            cooldownTickerTask?.cancel()
            cooldownTickerTask = nil
            errorDismissTask?.cancel()
            errorDismissTask = nil
            ackDismissTask?.cancel()
            ackDismissTask = nil
            awaitingRequestID = nil
            pendingRemoteUnlockCredentialRequestID = nil
            remoteUnlockCredentialAckTimeoutTask?.cancel()
            remoteUnlockCredentialAckTimeoutTask = nil
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            reinstallMirrorSurfaceAfterReturn()
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
                remoteUnlockState: remoteUnlockState ?? lastAck?.remoteUnlockState ?? lastLockedRemoteUnlockState,
                savedRemoteUnlockCredentialAvailable: remoteUnlockSavedCredentialAvailable,
                remoteUnlockDiagnosticMessage: remoteUnlockDiagnosticMessage,
                remoteUnlockPasswordDraft: $remoteUnlockPasswordDraft,
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
                saveRemoteUnlockCredential: { password in
                    Task { await saveRemoteUnlockCredential(password: password) }
                },
                sendSavedRemoteUnlockCredential: {
                    Task { await sendSavedRemoteUnlockCredential() }
                },
                deleteSavedRemoteUnlockCredential: {
                    deleteSavedRemoteUnlockCredential()
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
                        if remoteUnlockState != nil || lastLockedRemoteUnlockState != nil || lastAck?.remoteUnlockState != nil {
                            await requestMirror(forceRemoteUnlockSession: true)
                        } else {
                            await requestMirror()
                        }
                    }
                },
                onClose: {
                    isShowingMirrorViewer = false
                    Task { await stopActiveMirror(reason: "viewer_closed") }
                }
            )
            .onDisappear {
                // Disappearing is lifecycle noise on iOS: app switch, PiP,
                // sheet re-presentation, and transient hierarchy rebuilds can
                // all trigger it. Only the close button ends the mirror.
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
                colorDriver: dashboardStore.swarmColorDriver,
                visibility: backgroundVisibility
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
            && peer.capabilities.contains(.mirrorHost)
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

    // MARK: - Actions

    private func installAckHandler() {
        controlStreamCoordinator.mirrorAckHandler = { ack in
            await MainActor.run {
                let isRemoteUnlockMirrorRequest = self.remoteUnlockMirrorRequestIDs.remove(ack.requestId) != nil
                self.lastAck = ack
                self.lastAckReceivedAt = Date()
                if let state = ack.remoteUnlockState ?? self.synthesizedRemoteUnlockState(for: ack, isRemoteUnlockMirrorRequest: isRemoteUnlockMirrorRequest) {
                    self.setRemoteUnlockState(state)
                }
                self.refreshSavedCredentialAvailability()
                self.cooldownClock = Date()
                if ack.requestId == self.awaitingRequestID {
                    self.mirrorTimeoutTask?.cancel()
                    self.mirrorTimeoutTask = nil
                    self.awaitingRequestID = nil
                }
                if ack.decision == .unsupported,
                   ack.detail == Self.remoteUnlockSessionRequiredDetail {
                    self.lastAck = nil
                    self.lastError = nil
                    Task {
                        await self.requestMirror(forceRemoteUnlockSession: true)
                    }
                    return
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
                    if self.activeMirrorRequestID != ack.requestId {
                        self.screenShareViewer.resetForNewMirror()
                    }
                    self.activeMirrorRequestID = ack.requestId
                    self.activeMirrorSessionId = ack.sessionId
                    self.activeMirrorViewerId = ack.viewerId
                    self.activeMirrorViewerRole = ack.viewerRole ?? "controller"
                    self.selectedMirrorDisplayId = ack.selectedDisplayId ?? ack.availableDisplays?.first?.id ?? self.selectedMirrorDisplayId
                    self.isShowingMirrorViewer = true
                    if isRemoteUnlockMirrorRequest,
                       self.remoteUnlockState == nil,
                       let state = self.synthesizedRemoteUnlockState(for: ack, isRemoteUnlockMirrorRequest: true) {
                        self.setRemoteUnlockState(state)
                    }
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
                switch denied.reason {
                case .signatureFailure, .counterReplay, .staleTimestamp:
                    // Tear down the stale sender. The most common cause is
                    // the Mac losing the peer registration (restart) or the
                    // authority key doc expiring. Re-publishing the key and
                    // restarting phone control re-establishes a clean
                    // handshake so the next gesture works transparently.
                    self.phoneControlSender = nil
                    self.phoneControlConnectionID = nil
                    self.authorityRefreshTask?.cancel()
                    Self.debugTrace("phone_control_denied_auto_recover reason=\(denied.reason.rawValue) connectionID=\(self.connectionID)")
                    Task {
                        await self.startPhoneControlIfPossible(surfaceError: false)
                    }
                default:
                    self.phoneControlError = self.phoneControlDeniedMessage(for: denied)
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
                if state.lockState != .unlocked {
                    self.controlStreamCoordinator.suspendBackgroundTraffic(
                        for: RemoteUnlockPolicy.default.sessionTTLSeconds
                    )
                } else {
                    self.pendingRemoteUnlockCredentialRequestID = nil
                    self.remoteUnlockCredentialAckTimeoutTask?.cancel()
                    self.remoteUnlockCredentialAckTimeoutTask = nil
                    self.remoteUnlockPasswordDraft = ""
                    self.phoneControlError = nil
                    self.remoteUnlockResult = nil
                }
                self.setRemoteUnlockState(state)
                self.refreshSavedCredentialAvailability()
            }
        }
        controlStreamCoordinator.remoteUnlockResultHandler = { result in
            await MainActor.run {
                self.remoteUnlockResult = result
                if result.requestId == self.pendingRemoteUnlockCredentialRequestID ||
                    (self.pendingRemoteUnlockCredentialRequestID != nil && result.sessionId == self.activeMirrorSessionId) {
                    self.pendingRemoteUnlockCredentialRequestID = nil
                    self.remoteUnlockCredentialAckTimeoutTask?.cancel()
                    self.remoteUnlockCredentialAckTimeoutTask = nil
                }
                switch result.status {
                case .unlocked:
                    self.clearRemoteUnlockState()
                    self.phoneControlError = nil
                    self.remoteUnlockDiagnosticMessage = "credential result: unlocked"
                case .denied, .failed, .expired:
                    let detail = result.detail ?? "Remote Unlock was denied."
                    self.phoneControlError = self.remoteUnlockMessage(for: detail)
                    self.remoteUnlockDiagnosticMessage = "credential result: \(detail)"
                    if self.shouldRefreshRemoteUnlockSession(after: detail) {
                        self.phoneControlSender = nil
                        self.phoneControlConnectionID = nil
                        self.clearRemoteUnlockState()
                        self.lastAck = nil
                        Task {
                            await self.refreshRemoteUnlockSessionAfterCredentialRejection()
                        }
                    }
                case .accepted:
                    let detail = result.detail ?? "credential_submitted"
                    self.phoneControlError = self.remoteUnlockMessage(for: detail)
                    self.remoteUnlockDiagnosticMessage = "credential result: \(detail)"
                case .disconnected:
                    break
                }
                if result.status == .unlocked ||
                    (result.status == .accepted && result.detail != "credential_received") {
                    self.remoteUnlockPasswordDraft = ""
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

    private func reinstallMirrorSurfaceAfterReturn() {
        installAckHandler()
        guard let uid = uidProvider(), !uid.isEmpty else { return }
        guard activeMirrorRequestID != nil || isShowingMirrorViewer else { return }
        Task {
            do {
                try await controlStreamCoordinator.ensureResponsive(
                    uid: uid,
                    connectionID: connectionID,
                    freshnessInterval: 2.0,
                    probeTimeout: 1.0,
                    restartTimeout: 4.0
                )
                await startPhoneControlIfPossible(surfaceError: false)
            } catch {
                await MainActor.run {
                    phoneControlSender = nil
                    phoneControlConnectionID = nil
                    lastError = "Reconnected to the viewer; tap Retry if frames do not resume. \(error.localizedDescription)"
                }
            }
        }
    }

    private func requestMirror(
        forceRemoteUnlockSession: Bool = false,
        retryingAfterControlStreamRefresh: Bool = false
    ) async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            lastError = "Sign in to mirror your Mac."
            return
        }
        guard canRequestMirror else {
            lastError = mercuryStatusMessage ?? "Mercury is not ready yet."
            return
        }
        if controlStreamCoordinator.phase != .live {
            await controlStreamCoordinator.stop()
            controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
        }
        controlStreamCoordinator.suspendBackgroundTraffic(for: 30)
        if !retryingAfterControlStreamRefresh {
            personalization.haptics.play()
        }
        let requestID = UUID().uuidString
        let viewerID = UUID().uuidString
        let remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession?
        let controlAuthorityPeerNodeId: String?
        if forceRemoteUnlockSession {
            guard peer.capabilities.contains(.remoteUnlockHost)
                    || remoteUnlockState?.capabilities.enabled == true
                    || lastAck?.remoteUnlockCapabilities?.enabled == true else {
                lastError = "Remote Unlock is not ready on this Mac."
                return
            }
            do {
                let prepared = try await makeRemoteUnlockSession(uid: uid, requestID: requestID)
                remoteUnlockSession = prepared.session
                controlAuthorityPeerNodeId = prepared.peerNodeId
            } catch {
                lastError = "Remote Unlock needs Face ID, Touch ID, or passcode confirmation."
                awaitingRequestID = nil
                return
            }
            remoteUnlockMirrorRequestIDs.insert(requestID)
        } else {
            remoteUnlockSession = nil
            if let signingKey = try? PhoneControlSigningKeyStore.shared.signingKey() {
                controlAuthorityPeerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingKey)
            } else {
                controlAuthorityPeerNodeId = nil
            }
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
        if forceRemoteUnlockSession {
            remoteUnlockState = remoteUnlockState ?? lastLockedRemoteUnlockState
        } else {
            clearRemoteUnlockState()
        }
        remoteUnlockResult = nil
        screenShareViewer.resetForNewMirror()
        // Don't tear down the app-scope phone control coordinator on
        // every mirror request — it stays warm and is reused for tap /
        // scroll input once the Mac approves the mirror. Also do not
        // gate mirror requests behind a separate heartbeat proof: while
        // macOS is at loginwindow, the mirror request is the handshake
        // that asks the Mac for the Remote Unlock lane, and a preflight
        // heartbeat can wedge before the Mac ever sees that request.
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
            remoteUnlockSession: remoteUnlockSession,
            agentTerminal: terminalRuntime.map {
                HermesRealtimeRelayAgentTerminalRequest(runtimeId: $0, interactive: true)
            }
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
            startMirrorAckTimeout(
                requestID: requestID,
                forceRemoteUnlockSession: forceRemoteUnlockSession,
                retryingAfterControlStreamRefresh: retryingAfterControlStreamRefresh
            )
        } catch {
            Self.log.error("mirror_request_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mirror_request_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
            if !retryingAfterControlStreamRefresh,
               shouldRetryMirrorRequestAfterRefreshingControlStream(error) {
                Self.log.info("mirror_request_retry_after_control_stream_refresh requestID=\(requestID, privacy: .public) connectionID=\(connectionID, privacy: .public)")
                Self.debugTrace("mirror_request_retry_after_control_stream_refresh requestID=\(requestID) connectionID=\(connectionID)")
                awaitingRequestID = nil
                await controlStreamCoordinator.stop()
                controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await requestMirror(
                    forceRemoteUnlockSession: forceRemoteUnlockSession,
                    retryingAfterControlStreamRefresh: true
                )
                return
            }
            lastError = error.localizedDescription
            awaitingRequestID = nil
        }
    }

    private func startMirrorAckTimeout(
        requestID: String,
        forceRemoteUnlockSession: Bool,
        retryingAfterControlStreamRefresh: Bool
    ) {
        mirrorTimeoutTask?.cancel()
        mirrorTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, awaitingRequestID == requestID else { return }
            awaitingRequestID = nil
            if let uid = uidProvider(), !uid.isEmpty {
                await controlStreamCoordinator.stop()
                controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
            }
            guard !retryingAfterControlStreamRefresh else {
                lastError = "No response from the Mac. Mercury reconnected; try Mirror Mac again."
                return
            }
            lastError = "No response from the Mac. Mercury reconnected and retried the mirror request."
            try? await Task.sleep(nanoseconds: 250_000_000)
            await requestMirror(
                forceRemoteUnlockSession: forceRemoteUnlockSession,
                retryingAfterControlStreamRefresh: true
            )
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

    private func setRemoteUnlockState(_ state: HermesRealtimeRelayRemoteUnlockState) {
        remoteUnlockState = state
        if state.lockState == .unlocked {
            lastLockedRemoteUnlockState = nil
        } else {
            lastLockedRemoteUnlockState = state
        }
    }

    private func clearRemoteUnlockState() {
        remoteUnlockState = nil
        lastLockedRemoteUnlockState = nil
    }

    private func synthesizedRemoteUnlockState(
        for ack: HermesRealtimeRelayMirrorAck,
        isRemoteUnlockMirrorRequest: Bool
    ) -> HermesRealtimeRelayRemoteUnlockState? {
        guard isRemoteUnlockMirrorRequest else { return nil }
        if var state = lastLockedRemoteUnlockState ?? remoteUnlockState {
            state.sessionId = ack.sessionId ?? state.sessionId
            state.controlOwnerViewerId = ack.viewerId ?? state.controlOwnerViewerId
            state.observedAt = Date()
            return state
        }
        guard let capabilities = ack.remoteUnlockCapabilities,
              capabilities.enabled else { return nil }
        return HermesRealtimeRelayRemoteUnlockState(
            sessionId: ack.sessionId,
            lockState: .unknown,
            backend: capabilities.activeBackend,
            capabilities: capabilities,
            controlOwnerViewerId: ack.viewerId,
            observedAt: Date()
        )
    }

    private func makeRemoteUnlockSession(
        uid: String,
        requestID: String
    ) async throws -> (session: HermesRealtimeRelayRemoteUnlockSession, peerNodeId: String) {
        let signingKey = try PhoneControlSigningKeyStore.shared.signingKey()
        let peerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingKey)
        let trustGateway = LiveDeviceTrustGateway()
        await trustGateway.registerSelfIfNeeded()
        if try await !trustGateway.isSelfTrustedForComputerUseControl() {
            try await confirmLocalAuthentication(reason: "Trust this iPhone for Remote Unlock.")
            try await trustGateway.trustSelfForComputerUseControl()
        }
        try await publishPhoneControlAuthorityWithTrustRetry(
            uid: uid,
            peerNodeId: peerNodeId,
            signingKey: signingKey,
            trustGateway: trustGateway
        )
        let sessionSigner = PhoneControlSender(
            peerNodeId: peerNodeId,
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
            // Durable device trust is granted once and then reused for locked
            // mirrors. The Mac password is never stored and must be typed for
            // each unlock attempt.
            localAuthenticationSatisfied: true,
            requestedLockState: nil,
            requestedBackend: .appleScreenSharingLoopback,
            authority: Self.emptyAuthorityEnvelope
        )
        return (try sessionSigner.sign(remoteUnlockSession: unsignedSession), peerNodeId)
    }

    private func publishPhoneControlAuthorityWithTrustRetry(
        uid: String,
        peerNodeId: String,
        signingKey: Curve25519SigningKey,
        trustGateway: LiveDeviceTrustGateway = LiveDeviceTrustGateway()
    ) async throws {
        do {
            try await publishPhoneControlAuthority(
                uid: uid,
                peerNodeId: peerNodeId,
                signingKey: signingKey
            )
        } catch {
            guard PhoneControlSetupMessage.isFirestorePermissionDenied(error) else { throw error }
            try await trustGateway.trustSelfForComputerUseControl()
            try await publishPhoneControlAuthority(
                uid: uid,
                peerNodeId: peerNodeId,
                signingKey: signingKey
            )
        }
    }

    private func publishPhoneControlAuthority(
        uid: String,
        peerNodeId: String,
        signingKey: Curve25519SigningKey
    ) async throws {
        try await PhoneControlAuthorityPublisher.shared.publish(
            uid: uid,
            connectionId: connectionID,
            deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
            peerNodeId: peerNodeId,
            publicKey: signingKey.privateKey.publicKey
        )
    }

    private func makeRemoteUnlockCredentialSender(uid: String) async throws -> PhoneControlSender {
        let signingKey = try PhoneControlSigningKeyStore.shared.signingKey()
        let peerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingKey)
        let trustGateway = LiveDeviceTrustGateway()
        await trustGateway.registerSelfIfNeeded()
        try await publishPhoneControlAuthorityWithTrustRetry(
            uid: uid,
            peerNodeId: peerNodeId,
            signingKey: signingKey,
            trustGateway: trustGateway
        )
        return PhoneControlSender(
            peerNodeId: peerNodeId,
            uid: uid,
            connectionId: connectionID,
            signingKeyProvider: { signingKey },
            frameSink: { frame in
                try await controlStreamCoordinator.send(frame: frame, timeout: 6)
            }
        )
    }

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
            // Keep the authority key doc fresh for long-lived sessions.
            // The Mac's 10-minute TTL on publishedAtMillis would otherwise
            // cause re-fetch failures if the Mac needed to re-register the
            // peer (e.g., after a Mac restart). Refreshing every 8 minutes
            // ensures the doc stays valid.
            startAuthorityRefreshTimer(
                uid: uid,
                peerNodeId: peerNodeId,
                signingKey: signingKey
            )
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

    /// Periodically re-publishes the authority key doc so its
    /// `publishedAtMillis` stays within the Mac's 10-minute TTL.
    /// Cancelled automatically when the phone control sender is torn
    /// down or the view disappears.
    private func startAuthorityRefreshTimer(
        uid: String,
        peerNodeId: String,
        signingKey: Curve25519SigningKey
    ) {
        authorityRefreshTask?.cancel()
        authorityRefreshTask = Task { @MainActor in
            // 8 minutes — comfortably under the 10-minute maximumAge.
            let interval: TimeInterval = 8 * 60
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, self.phoneControlSender != nil else { break }
                do {
                    try await PhoneControlAuthorityPublisher.shared.publish(
                        uid: uid,
                        connectionId: self.connectionID,
                        deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
                        peerNodeId: peerNodeId,
                        publicKey: signingKey.privateKey.publicKey
                    )
                    Self.debugTrace("phone_control_authority_refreshed connectionID=\(self.connectionID)")
                } catch {
                    Self.debugTrace("phone_control_authority_refresh_failed connectionID=\(self.connectionID) error=\(error.localizedDescription)")
                }
            }
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
            // The control.classify handshake already ran during
            // startPhoneControlIfPossible(). See sendPhoneControlIntent
            // for the full rationale.
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

    private func shouldRefreshRemoteUnlockSession(after detail: String) -> Bool {
        switch detail {
        case "session_mismatch",
             "session_expired",
             "signature_failure",
             "counter_replay",
             "stale_timestamp":
            return true
        default:
            return false
        }
    }

    private func shouldRetryMirrorRequestAfterRefreshingControlStream(_ error: Error) -> Bool {
        guard let controlError = error as? MediaControlStreamCoordinator.ControlStreamError else {
            return false
        }
        switch controlError {
        case .timedOutWaitingForLiveStream,
             .timedOutSendingFrame,
             .macDidNotRespond:
            return true
        case .notLive:
            return false
        }
    }

    private func remoteUnlockMessage(for detail: String) -> String {
        switch detail {
        case "session_mismatch", "session_expired":
            return "Unlock session refreshed. Enter your Mac password again."
        case "signature_failure", "counter_replay", "stale_timestamp":
            return "Secure unlock lane refreshed. Enter your Mac password again."
        case "credential_submitted":
            return "Password sent to Mac login window."
        case "credential_received":
            return "Mac received the password. Entering it at the login window..."
        case "credential_saved":
            return "One-tap Remote Unlock is ready on this device."
        case "saved_credential_deleted":
            return "Saved Remote Unlock credential removed from this device."
        case "untrusted_controller":
            return "Take control from this device, then try unlocking again."
        case "control_owned_by_other_viewer":
            return "Another device has control of this mirror."
        case "remote_access_daemon_unavailable", "remote_access_daemon_socket_unavailable":
            return "Remote Unlock helper is not reachable on the Mac."
        case "remote_access_daemon_rejected":
            return "Remote Unlock helper rejected the password request."
        case "login_session_worker_failed", "login_session_worker_launch_failed", "login_session_worker_input_failed":
            return "Remote Unlock could not reach the Mac login session."
        case "login_session_worker_timed_out":
            return "The Mac login window took too long to respond. Tap One-tap unlock again."
        default:
            return detail
        }
    }

    private func refreshRemoteUnlockSessionAfterCredentialRejection() async {
        guard !remoteUnlockRefreshInFlight else { return }
        remoteUnlockRefreshInFlight = true
        defer { remoteUnlockRefreshInFlight = false }
        await requestMirror(forceRemoteUnlockSession: true)
        if phoneControlError == nil {
            phoneControlError = "Unlock session refreshed. Enter your Mac password again."
        }
    }

    private func saveRemoteUnlockCredential(password: String) async {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else {
            phoneControlError = "Enter your Mac password before saving it for one-tap unlock."
            return
        }
        let capabilities = (remoteUnlockState ?? lastAck?.remoteUnlockState)?.capabilities
        guard capabilities?.enabled == true,
              capabilities?.allowsSavedCredentialUnlock == true else {
            phoneControlError = "One-tap Remote Unlock is not ready on this Mac."
            return
        }
        do {
            try await confirmLocalAuthentication(reason: "Save this Mac password for one-tap Remote Unlock on this device.")
            guard let storeKey = remoteUnlockCredentialStoreKey() else {
                phoneControlError = "Remote Unlock is not ready on this Mac."
                return
            }
            try RemoteUnlockSavedCredentialStore.shared.save(trimmedPassword, storeKey: storeKey)
            refreshSavedCredentialAvailability()
            phoneControlError = remoteUnlockMessage(for: "credential_saved")
        } catch {
            phoneControlError = "Saved Remote Unlock setup was cancelled."
        }
    }

    private func sendSavedRemoteUnlockCredential() async {
        phoneControlError = "Loading saved Remote Unlock credential..."
        Self.log.info("remote_unlock_saved_credential_load_start connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("remote_unlock_saved_credential_load_start connectionID=\(connectionID)")
        remoteUnlockDiagnosticMessage = "one-tap: loading saved credential"
        let capabilities = (remoteUnlockState ?? lastAck?.remoteUnlockState)?.capabilities
        guard capabilities?.enabled == true,
              capabilities?.allowsSavedCredentialUnlock == true else {
            phoneControlError = "One-tap Remote Unlock is not ready on this Mac."
            remoteUnlockDiagnosticMessage = "one-tap blocked: capability not ready"
            Self.log.error("remote_unlock_saved_credential_load_blocked reason=capability_not_ready connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_saved_credential_load_blocked reason=capability_not_ready connectionID=\(connectionID)")
            return
        }
        do {
            guard let storeKey = remoteUnlockCredentialStoreKey() else {
                phoneControlError = "One-tap Remote Unlock is not ready on this Mac."
                remoteUnlockDiagnosticMessage = "one-tap blocked: missing store key"
                Self.log.error("remote_unlock_saved_credential_load_blocked reason=missing_store_key connectionID=\(connectionID, privacy: .public)")
                Self.debugTrace("remote_unlock_saved_credential_load_blocked reason=missing_store_key connectionID=\(connectionID)")
                return
            }
            let password = try RemoteUnlockSavedCredentialStore.shared.load(
                storeKey: storeKey,
                reason: "Unlock your Mac with the saved Remote Unlock credential."
            )
            Self.log.info("remote_unlock_saved_credential_loaded storeKey=\(storeKey, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_saved_credential_loaded storeKey=\(storeKey) connectionID=\(connectionID)")
            await sendRemoteUnlockCredential(password: password, credentialKind: .savedPassword)
        } catch {
            refreshSavedCredentialAvailability()
            phoneControlError = "Saved Remote Unlock credential is unavailable. Type your Mac password instead."
            remoteUnlockDiagnosticMessage = "one-tap failed: saved credential unavailable"
            Self.log.error("remote_unlock_saved_credential_load_failed connectionID=\(connectionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            Self.debugTrace("remote_unlock_saved_credential_load_failed connectionID=\(connectionID) error=\(String(describing: error))")
        }
    }

    private func deleteSavedRemoteUnlockCredential() {
        guard let storeKey = remoteUnlockCredentialStoreKey() else {
            remoteUnlockSavedCredentialAvailable = false
            return
        }
        RemoteUnlockSavedCredentialStore.shared.delete(storeKey: storeKey)
        refreshSavedCredentialAvailability()
        phoneControlError = remoteUnlockMessage(for: "saved_credential_deleted")
    }

    private func refreshSavedCredentialAvailability() {
        guard let storeKey = remoteUnlockCredentialStoreKey() else {
            remoteUnlockSavedCredentialAvailable = false
            return
        }
        remoteUnlockSavedCredentialAvailable = RemoteUnlockSavedCredentialStore.shared.hasCredential(storeKey: storeKey)
    }

    private func remoteUnlockCredentialStoreKey() -> String? {
        RemoteUnlockCredentialStoreKey.make(
            state: remoteUnlockState ?? lastAck?.remoteUnlockState,
            phoneControlConnectionID: phoneControlConnectionID,
            mirrorConnectionID: connectionID,
            mirrorRequestID: activeMirrorRequestID
        )
    }

    private func sendRemoteUnlockCredential(
        password: String,
        credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind = .typedPassword
    ) async {
        Self.log.info("remote_unlock_credential_prepare_start kind=\(credentialKind.rawValue, privacy: .public) connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("remote_unlock_credential_prepare_start kind=\(credentialKind.rawValue) connectionID=\(connectionID)")
        remoteUnlockDiagnosticMessage = "credential: preparing"
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else {
            phoneControlError = "Enter your Mac password."
            remoteUnlockDiagnosticMessage = "credential blocked: empty password"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=empty_password connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=empty_password connectionID=\(connectionID)")
            return
        }
        controlStreamCoordinator.suspendBackgroundTraffic(for: 45)
        guard activeMirrorViewerRole == "controller" else {
            phoneControlError = "Watching only. Take control from this device to unlock the Mac."
            remoteUnlockDiagnosticMessage = "credential blocked: viewer is not controller"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=not_controller role=\(activeMirrorViewerRole ?? "nil", privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=not_controller role=\(activeMirrorViewerRole ?? "nil") connectionID=\(connectionID)")
            return
        }
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to unlock your Mac."
            remoteUnlockDiagnosticMessage = "credential blocked: missing user"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=missing_uid connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=missing_uid connectionID=\(connectionID)")
            return
        }
        let state = remoteUnlockState ?? lastAck?.remoteUnlockState
        guard let state, state.lockState != .unlocked else {
            phoneControlError = "The Mac is already unlocked."
            remoteUnlockDiagnosticMessage = "credential blocked: Mac already unlocked"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=already_unlocked connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=already_unlocked connectionID=\(connectionID)")
            return
        }
        let capabilities = state.capabilities
        guard capabilities.enabled,
              capabilities.allowsCredentialPaste,
              let sessionId = state.sessionId,
              let recipientKeyId = capabilities.credentialRecipientKeyId,
              let recipientPublicKey = capabilities.credentialRecipientPublicKeyBase64,
              let algorithm = capabilities.credentialEnvelopeAlgorithm else {
            phoneControlError = "Remote Unlock is not ready on this Mac."
            remoteUnlockDiagnosticMessage = "credential blocked: Mac capability incomplete"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=capability_incomplete connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=capability_incomplete connectionID=\(connectionID)")
            return
        }
        guard algorithm == RemoteUnlockCredentialEnvelopeCrypto.algorithm else {
            phoneControlError = "Remote Unlock needs an app update on this device."
            remoteUnlockDiagnosticMessage = "credential blocked: encryption mismatch"
            Self.log.error("remote_unlock_credential_prepare_blocked reason=algorithm_mismatch algorithm=\(algorithm, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_prepare_blocked reason=algorithm_mismatch algorithm=\(algorithm) connectionID=\(connectionID)")
            return
        }

        let credentialSender: PhoneControlSender
        do {
            if RemoteUnlockCredentialSenderReusePolicy.shouldReuseExistingSender(
                phoneControlConnectionID: phoneControlConnectionID,
                currentConnectionID: connectionID
            ),
               let existingSender = phoneControlSender {
                credentialSender = existingSender
            } else {
                let sender = try await makeRemoteUnlockCredentialSender(uid: uid)
                phoneControlSender = sender
                phoneControlConnectionID = connectionID
                credentialSender = sender
                Self.debugTrace("remote_unlock_credential_sender_rebuilt connectionID=\(connectionID)")
            }
        } catch {
            phoneControlSender = nil
            phoneControlConnectionID = nil
            phoneControlError = PhoneControlSetupMessage.message(for: error)
            remoteUnlockDiagnosticMessage = "credential blocked: sender setup failed"
            Self.log.error("remote_unlock_credential_sender_setup_failed connectionID=\(connectionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            Self.debugTrace("remote_unlock_credential_sender_setup_failed connectionID=\(connectionID) error=\(String(describing: error))")
            return
        }

        do {
            do {
                try await controlStreamCoordinator.ensureResponsive(
                    uid: uid,
                    connectionID: connectionID,
                    freshnessInterval: 2,
                    probeTimeout: 2.5,
                    restartTimeout: 6
                )
            } catch {
                phoneControlSender = nil
                phoneControlConnectionID = nil
                phoneControlError = "Mac control stream is not responding. Reopen Mercury and try again."
                remoteUnlockDiagnosticMessage = "credential blocked: control stream probe failed"
                Self.log.error("remote_unlock_credential_stream_probe_failed connectionID=\(connectionID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                Self.debugTrace("remote_unlock_credential_stream_probe_failed connectionID=\(connectionID) error=\(String(describing: error))")
                return
            }

            let requestId = UUID().uuidString
            let clientIntentId = UUID().uuidString
            let requestedAt = Date()
            let expiresAt = requestedAt.addingTimeInterval(RemoteUnlockPolicy.default.credentialTTLSeconds)
            let sealed = try RemoteUnlockCredentialEnvelopeCrypto.seal(
                credential: trimmedPassword,
                requestId: requestId,
                sessionId: sessionId,
                clientIntentId: clientIntentId,
                credentialKind: credentialKind,
                recipientKeyId: recipientKeyId,
                recipientPublicKeyBase64: recipientPublicKey,
                algorithm: algorithm
            )
            let envelope = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
                requestId: requestId,
                sessionId: sessionId,
                clientIntentId: clientIntentId,
                credentialKind: credentialKind,
                recipientKeyId: recipientKeyId,
                algorithm: algorithm,
                ciphertextBase64: sealed.ciphertextBase64,
                aadBase64: sealed.aadBase64,
                redactedByteCount: sealed.redactedByteCount,
                requestedAt: requestedAt,
                expiresAt: expiresAt,
                authority: Self.emptyAuthorityEnvelope
            )
            pendingRemoteUnlockCredentialRequestID = requestId
            remoteUnlockCredentialAckTimeoutTask?.cancel()
            phoneControlError = "Sending password to Mac..."
            remoteUnlockDiagnosticMessage = "credential: writing frame"
            Self.log.info("remote_unlock_credential_send_start requestID=\(requestId, privacy: .public) sessionID=\(sessionId, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_send_start requestID=\(requestId) sessionID=\(sessionId) connectionID=\(connectionID)")
            _ = try await credentialSender.send(remoteUnlockCredential: envelope)
            Self.log.info("remote_unlock_credential_frame_written requestID=\(requestId, privacy: .public) sessionID=\(sessionId, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("remote_unlock_credential_frame_written requestID=\(requestId) sessionID=\(sessionId) connectionID=\(connectionID)")
            phoneControlError = "Password sent. Waiting for Mac..."
            remoteUnlockDiagnosticMessage = "credential: frame written; waiting for Mac result"
            remoteUnlockCredentialAckTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.remoteUnlockCredentialAckTimeoutNanoseconds)
                guard pendingRemoteUnlockCredentialRequestID == requestId else { return }
                pendingRemoteUnlockCredentialRequestID = nil
                phoneControlError = "Still waiting for the Mac. If the login screen did not react, tap One-tap unlock again."
                remoteUnlockDiagnosticMessage = "credential timeout: Mac result not received"
                Self.log.error("remote_unlock_credential_ack_timeout requestID=\(requestId, privacy: .public) sessionID=\(sessionId, privacy: .public) connectionID=\(connectionID, privacy: .public)")
                Self.debugTrace("remote_unlock_credential_ack_timeout requestID=\(requestId) sessionID=\(sessionId) connectionID=\(connectionID)")
            }
        } catch {
            self.phoneControlSender = nil
            phoneControlConnectionID = nil
            if let pendingRemoteUnlockCredentialRequestID {
                Self.log.error("remote_unlock_credential_send_failed requestID=\(pendingRemoteUnlockCredentialRequestID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                Self.debugTrace("remote_unlock_credential_send_failed requestID=\(pendingRemoteUnlockCredentialRequestID) error=\(String(describing: error))")
            }
            pendingRemoteUnlockCredentialRequestID = nil
            remoteUnlockCredentialAckTimeoutTask?.cancel()
            remoteUnlockCredentialAckTimeoutTask = nil
            phoneControlError = error.localizedDescription
            remoteUnlockDiagnosticMessage = "credential failed: \(error.localizedDescription)"
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
        // The control.classify handshake already ran during
        // startPhoneControlIfPossible(). Re-sending it on every intent
        // caused the Mac to re-fetch the authority key from Firestore each
        // time. After the key doc's 10-minute publishedAtMillis TTL
        // expired, every re-fetch failed with `expired`, surfacing as
        // "Mac rejected the control signature."
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
        // The control.classify handshake already ran during
        // startPhoneControlIfPossible(). See sendPhoneControlIntent
        // for the full rationale.

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

enum RemoteUnlockCredentialStoreKey {
    static func make(
        state: HermesRealtimeRelayRemoteUnlockState?,
        phoneControlConnectionID: String?,
        mirrorConnectionID: String,
        mirrorRequestID: String?
    ) -> String? {
        if let recipientKey = nonEmpty(state?.capabilities.credentialRecipientKeyId) {
            return recipientKey
        }
        if let phoneConnectionID = nonEmpty(phoneControlConnectionID) {
            return phoneConnectionID
        }
        if let connectionID = nonEmpty(mirrorConnectionID) {
            return connectionID
        }
        return nonEmpty(mirrorRequestID)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RemoteUnlockCredentialSenderReusePolicy {
    static func shouldReuseExistingSender(
        phoneControlConnectionID: String?,
        currentConnectionID: String
    ) -> Bool {
        // Remote Unlock runs while the mirror is intentionally unstable: the Mac
        // may stop video, the viewer may reconnect, and moving the viewer can
        // churn the control stream. Rebuilding the signed sender is cheap and
        // prevents a stale point-and-click sender from reporting "sent" while
        // the credential frame never reaches the Mac.
        false
    }
}

private final class RemoteUnlockSavedCredentialStore: @unchecked Sendable {
    static let shared = RemoteUnlockSavedCredentialStore()

    private let service = "com.openburnbar.remote-unlock.saved-credential"
    private let defaultsPrefix = "remote_unlock.saved_credential_available."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasCredential(storeKey: String) -> Bool {
        defaults.bool(forKey: defaultsKey(storeKey: storeKey))
    }

    func save(_ password: String, storeKey: String) throws {
        guard let data = password.data(using: .utf8), !data.isEmpty else {
            throw StoreError.invalidCredential
        }
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            throw StoreError.accessControlUnavailable
        }
        let query = baseQuery(storeKey: storeKey)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychainStatus(status) }
        defaults.set(true, forKey: defaultsKey(storeKey: storeKey))
    }

    func load(storeKey: String, reason: String) throws -> String {
        let context = LAContext()
        context.localizedReason = reason
        var query = baseQuery(storeKey: storeKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            defaults.set(false, forKey: defaultsKey(storeKey: storeKey))
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw StoreError.keychainStatus(status)
        }
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            throw StoreError.invalidCredential
        }
        return password
    }

    func delete(storeKey: String) {
        SecItemDelete(baseQuery(storeKey: storeKey) as CFDictionary)
        defaults.set(false, forKey: defaultsKey(storeKey: storeKey))
    }

    private func baseQuery(storeKey: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(storeKey: storeKey)
        ]
    }

    private func account(storeKey: String) -> String {
        let trimmed = storeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown-mac" : trimmed
    }

    private func defaultsKey(storeKey: String) -> String {
        defaultsPrefix + account(storeKey: storeKey)
    }

    enum StoreError: Error {
        case accessControlUnavailable
        case invalidCredential
        case keychainStatus(OSStatus)
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
    let savedRemoteUnlockCredentialAvailable: Bool
    let remoteUnlockDiagnosticMessage: String?
    @Binding var remoteUnlockPasswordDraft: String
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
    let saveRemoteUnlockCredential: (String) -> Void
    let sendSavedRemoteUnlockCredential: () -> Void
    let deleteSavedRemoteUnlockCredential: () -> Void
    let onSelectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let onClose: () -> Void
    init(
        coordinator: ScreenShareViewerCoordinator,
        resetToken: String?,
        controlStatus: ScreenSharePhoneControlStatus,
        controlInputEnabled: Bool,
        streamPhase: MediaControlStreamCoordinator.Phase,
        reconnectAttemptStartedAt: Date?,
        lastFailureReason: String?,
        lastLiveAt: Date?,
        controlRoundTripMillis: Int?,
        displays: [HermesRealtimeRelayDisplayDescriptor],
        selectedDisplayId: String?,
        remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?,
        savedRemoteUnlockCredentialAvailable: Bool,
        remoteUnlockDiagnosticMessage: String?,
        remoteUnlockPasswordDraft: Binding<String>,
        usePremiumSOTAUX: Bool,
        sendTapIntent: @escaping (Double, Double, Int) -> Void,
        sendScrollIntent: @escaping (Double, Double, Double, Double, String?) -> Void,
        sendPointerMoveIntent: @escaping (Double, Double) -> Void,
        sendPointerClickIntent: @escaping (Int) -> Void,
        sendTextIntent: @escaping (String) -> Void,
        sendShortcutIntent: @escaping (String, [String]) -> Void,
        sendAgentContextTargetIntent: @escaping (Double, Double, String, String, String?) -> Void,
        pasteClipboardToMac: @escaping () -> Void,
        grabClipboardFromMac: @escaping () -> Void,
        sendRemoteUnlockCredential: @escaping (String) -> Void,
        saveRemoteUnlockCredential: @escaping (String) -> Void,
        sendSavedRemoteUnlockCredential: @escaping () -> Void,
        deleteSavedRemoteUnlockCredential: @escaping () -> Void,
        onSelectDisplay: @escaping (String) -> Void,
        onTrustControlDevice: @escaping () -> Void,
        onForceReconnect: @escaping () -> Void,
        onRetryRequest: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.resetToken = resetToken
        self.controlStatus = controlStatus
        self.controlInputEnabled = controlInputEnabled
        self.streamPhase = streamPhase
        self.reconnectAttemptStartedAt = reconnectAttemptStartedAt
        self.lastFailureReason = lastFailureReason
        self.lastLiveAt = lastLiveAt
        self.controlRoundTripMillis = controlRoundTripMillis
        self.displays = displays
        self.selectedDisplayId = selectedDisplayId
        self.remoteUnlockState = remoteUnlockState
        self.savedRemoteUnlockCredentialAvailable = savedRemoteUnlockCredentialAvailable
        self.remoteUnlockDiagnosticMessage = remoteUnlockDiagnosticMessage
        self._remoteUnlockPasswordDraft = remoteUnlockPasswordDraft
        self.usePremiumSOTAUX = usePremiumSOTAUX
        self.sendTapIntent = sendTapIntent
        self.sendScrollIntent = sendScrollIntent
        self.sendPointerMoveIntent = sendPointerMoveIntent
        self.sendPointerClickIntent = sendPointerClickIntent
        self.sendTextIntent = sendTextIntent
        self.sendShortcutIntent = sendShortcutIntent
        self.sendAgentContextTargetIntent = sendAgentContextTargetIntent
        self.pasteClipboardToMac = pasteClipboardToMac
        self.grabClipboardFromMac = grabClipboardFromMac
        self.sendRemoteUnlockCredential = sendRemoteUnlockCredential
        self.saveRemoteUnlockCredential = saveRemoteUnlockCredential
        self.sendSavedRemoteUnlockCredential = sendSavedRemoteUnlockCredential
        self.deleteSavedRemoteUnlockCredential = deleteSavedRemoteUnlockCredential
        self.onSelectDisplay = onSelectDisplay
        self.onTrustControlDevice = onTrustControlDevice
        self.onForceReconnect = onForceReconnect
        self.onRetryRequest = onRetryRequest
        self.onClose = onClose
    }

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
            savedRemoteUnlockCredentialAvailable: savedRemoteUnlockCredentialAvailable,
            remoteUnlockDiagnosticMessage: remoteUnlockDiagnosticMessage,
            remoteUnlockPasswordDraft: $remoteUnlockPasswordDraft,
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
            saveRemoteUnlockCredential: saveRemoteUnlockCredential,
            sendSavedRemoteUnlockCredential: sendSavedRemoteUnlockCredential,
            deleteSavedRemoteUnlockCredential: deleteSavedRemoteUnlockCredential,
            onSelectDisplay: onSelectDisplay,
            onTrustControlDevice: onTrustControlDevice,
            onClose: onClose
        )
        .background(Color.black.ignoresSafeArea())
    }
}
