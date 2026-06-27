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
    static let log = Logger(subsystem: "com.openburnbar.mobile", category: "Mercury")

    static let remoteUnlockSessionRequiredDetail = "remote_unlock_session_required"

    static let remoteUnlockCredentialAckTimeoutNanoseconds: UInt64 = 45_000_000_000

    static func debugTrace(_ message: String) {
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
    var terminalRuntime: String?

    @State var lastAck: HermesRealtimeRelayMirrorAck?

    @State var lastAckReceivedAt: Date?

    @State var cooldownClock = Date()

    @State var awaitingRequestID: String?

    @State var activeMirrorRequestID: String?

    @State var lastError: String?

    @State var errorProgress: CGFloat = 1.0

    @State var ackProgress: CGFloat = 1.0

    @State var isShowingFileImporter = false

    @State var sendingFile = false

    @State var pulseTrigger = false

    @State var isShowingMirrorViewer = false

    @State var mirrorTimeoutTask: Task<Void, Never>?

    @State var cooldownTickerTask: Task<Void, Never>?

    @State var errorDismissTask: Task<Void, Never>?

    @State var ackDismissTask: Task<Void, Never>?

    @State var errorDragOffset: CGFloat = 0

    @State var ackDragOffset: CGFloat = 0

    @State var ackAnimateTrigger = false

    @State var isShowingCustomizeSheet = false

    @StateObject var screenShareViewer = ScreenShareViewerCoordinator()

    /// Mercury screen-share controls share the already-live
    /// `media.control` stream, matching Android. Agent Watch still owns
    /// its dedicated Computer Use stream, but the mirror tools must not
    /// depend on that separate lifecycle.
    @State var phoneControlSender: PhoneControlSender?

    @State var phoneControlConnectionID: String?

    @State var phoneControlStarting = false

    @State var phoneControlError: String?

    @State var authorityRefreshTask: Task<Void, Never>?

    @State var clipboardStatusMessage: String?

    @State var pendingClipboardRequests: [String: HermesRealtimeRelayClipboardAction] = [:]

    @State var remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?

    @State var lastLockedRemoteUnlockState: HermesRealtimeRelayRemoteUnlockState?

    @State var remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult?

    @State var remoteUnlockRefreshInFlight = false

    @State var remoteUnlockPasswordDraft = ""

    @State var remoteUnlockSavedCredentialAvailable = false

    @State var remoteUnlockDiagnosticMessage: String?

    @State var pendingRemoteUnlockCredentialRequestID: String?

    @State var remoteUnlockMirrorRequestIDs: Set<String> = []

    @State var remoteUnlockCredentialAckTimeoutTask: Task<Void, Never>?

    @State var selectedMirrorDisplayId: String?

    @State var activeMirrorSessionId: String?

    @State var activeMirrorViewerId: String?

    @State var activeMirrorViewerRole: String?

    @State var backgroundImage: UIImage?

    @ObservedObject var personalizationStore = MercuryPersonalizationStore.shared

    @ObservedObject var transferHistoryStore = MercuryTransferHistoryStore.shared

    @State var dashboardStore = DashboardStore()

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    @Environment(\.dismiss) var dismiss

    @Environment(\.scenePhase) var scenePhase

    var personalization: MercuryDevicePersonalization {
        personalizationStore.snapshot(for: connectionID)
    }

    var personalizationBinding: Binding<MercuryDevicePersonalization> {
        personalizationStore.binding(for: connectionID)
    }

    var accent: Color {
        personalizationStore.resolvedAccent(
            for: connectionID,
            wallpaperBase64: peer.blurredWallpaperBase64
        )
    }

    var sampledAuto: Color {
        WallpaperAccentSampler.dominantAccent(fromBase64: peer.blurredWallpaperBase64)
            ?? MercuryAccent.blue.staticColor
    }

    var effectiveNickname: String {
        personalizationStore.effectiveNickname(for: connectionID, fallback: peer.displayName)
    }

    var backgroundVisibility: MobileBackgroundVisibility {
        isShowingMirrorViewer || isShowingCustomizeSheet
            ? MobileBackgroundVisibility.obscured
            : MobileBackgroundVisibility.prominent
    }

    var canSendFiles: Bool {
        peer.canSendFile && (fileTransferService?.canSendFiles ?? false)
    }

    var unavailableFileTransferMessage: String {
        guard let fileTransferService else {
            return iOSFileTransferService.Failure.backendUnavailable.errorDescription ?? "File transfer not available."
        }
        if !fileTransferService.hasFileTransferBackend {
            return iOSFileTransferService.Failure.backendUnavailable.errorDescription ?? "File transfer not available."
        }
        if !fileTransferService.isFileTransferEnabledInSettings {
            return iOSFileTransferService.Failure.settingDisabled.errorDescription ?? "File transfer not available."
        }
        return "This Mac is not advertising file transfer."
    }

    func openFileImporterIfAvailable() {
        guard canSendFiles else {
            lastError = unavailableFileTransferMessage
            return
        }
        isShowingFileImporter = true
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
                            canSendFile: canSendFiles,
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
                            onSendFile: { openFileImporterIfAvailable() },
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
                        canSendFile: canSendFiles,
                        mirrorAutoAccept: mirrorAutoAccept,
                        awaitingRequestID: awaitingRequestID,
                        sendingFile: sendingFile,
                        mercuryStatusMessage: mercuryStatusMessage,
                        onRequestMirror: { Task { await requestMirror() } },
                        onPlaceCall: { Task { await placeCall() } },
                        onSendFile: { openFileImporterIfAvailable() },
                        usePremiumSOTAUX: personalization.usePremiumSOTAUX ?? false
                    )

                    MercuryRecentTransfersCard(
                        entries: transferHistoryStore.recent(for: connectionID, limit: 5),
                        totalCount: transferHistoryStore.totalCount(for: connectionID),
                        accent: accent,
                        canSendAnother: canSendFiles,
                        onRemove: { transferHistoryStore.remove(id: $0.id) },
                        onSendAnother: { openFileImporterIfAvailable() }
                    )

                    MercuryMoodCarousel(
                        personalization: personalizationBinding,
                        sampledAuto: sampledAuto,
                        onOpenCustomize: { isShowingCustomizeSheet = true }
                    )
                }
                .padding(24)
            }

            // Top-floating HUD Overlay Container. Both glass banners can be
            // visible at once, so they share one LiquidGlassGroup — on iOS 26
            // grouped glass shapes must sample a single region (glass cannot
            // sample other glass); on iOS 17–25 the group passes through.
            LiquidGlassGroup {
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
                sendTapIntent: handleSendTapIntent,
                sendScrollIntent: handleSendScrollIntent,
                sendPointerMoveIntent: handleSendPointerMoveIntent,
                sendPointerClickIntent: handleSendPointerClickIntent,
                sendTextIntent: handleSendTextIntent,
                sendShortcutIntent: handleSendShortcutIntent,
                sendAgentContextTargetIntent: handleSendAgentContextTargetIntent,
                pasteClipboardToMac: handlePasteClipboardToMac,
                grabClipboardFromMac: handleGrabClipboardFromMac,
                sendRemoteUnlockCredential: handleSendRemoteUnlockCredential,
                saveRemoteUnlockCredential: handleSaveRemoteUnlockCredential,
                sendSavedRemoteUnlockCredential: handleSendSavedRemoteUnlockCredential,
                deleteSavedRemoteUnlockCredential: handleDeleteSavedRemoteUnlockCredential,
                requestRemoteUnlockSetup: requestRemoteUnlockInputSetupFromOverlay,
                onSelectDisplay: selectMirrorDisplay,
                onTrustControlDevice: handleTrustControlDevice,
                onForceReconnect: handleForceReconnect,
                onRetryRequest: handleRetryRequest,
                onClose: handleClose
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

    static let emptyAuthorityEnvelope = HermesRealtimeRelayAuthorityEnvelope(
        peerNodeId: "",
        counter: 0,
        timestamp: Date(timeIntervalSince1970: 0),
        intentHashBlake3: "",
        signatureEd25519: ""
    )

}
