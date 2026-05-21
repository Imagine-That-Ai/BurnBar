import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
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
    @StateObject private var phoneControlCoordinator = AgentWatchOverlayCoordinator()
    @State private var phoneControlError: String?
    @State private var selectedMirrorDisplayId: String?
    @State private var backgroundImage: UIImage? = nil
    @ObservedObject private var personalizationStore = MercuryPersonalizationStore.shared
    @ObservedObject private var transferHistoryStore = MercuryTransferHistoryStore.shared
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
                        badges: personalization.normalizedBadges(),
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
            errorDismissTask?.cancel()
            errorDismissTask = nil
            ackDismissTask?.cancel()
            ackDismissTask = nil
            awaitingRequestID = nil
            controlStreamCoordinator.mirrorFrameHandler = nil
            controlStreamCoordinator.mirrorFrameV2Handler = nil
            screenShareViewer.longTermReferenceTokenHandler = nil
            Task { await phoneControlCoordinator.stop() }
        }
        .fullScreenCover(isPresented: $isShowingMirrorViewer) {
            MercuryMirrorViewerFullScreen(
                coordinator: screenShareViewer,
                resetToken: activeMirrorRequestID,
                controlStatus: mirrorControlStatus,
                streamPhase: controlStreamCoordinator.phase,
                displays: lastAck?.availableDisplays ?? [],
                selectedDisplayId: selectedMirrorDisplayId ?? lastAck?.selectedDisplayId,
                usePremiumSOTAUX: personalization.usePremiumSOTAUX ?? false,
                sendTapIntent: { x, y, mouseButton in
                    let displayId = selectedMirrorDisplayId ?? lastAck?.selectedDisplayId
                    Task { try? await phoneControlCoordinator.receiver?.tap(normalizedX: x, normalizedY: y, displayId: displayId, mouseButton: mouseButton) }
                },
                sendScrollIntent: { x1, y1, x2, y2, displayId in
                    Task {
                        try? await phoneControlCoordinator.receiver?.scrollDrag(
                            startNormalizedX: x1,
                            startNormalizedY: y1,
                            endNormalizedX: x2,
                            endNormalizedY: y2,
                            displayId: displayId ?? selectedMirrorDisplayId ?? lastAck?.selectedDisplayId
                        )
                    }
                },
                sendPointerMoveIntent: { dx, dy in
                    Task { try? await phoneControlCoordinator.receiver?.pointerMove(deltaX: dx, deltaY: dy) }
                },
                sendPointerClickIntent: { mouseButton in
                    Task { try? await phoneControlCoordinator.receiver?.pointerClick(mouseButton: mouseButton) }
                },
                sendTextIntent: { text in
                    Task { try? await phoneControlCoordinator.receiver?.type(text) }
                },
                sendShortcutIntent: { key, modifiers in
                    Task { try? await phoneControlCoordinator.receiver?.shortcut(key: key, modifiers: modifiers) }
                },
                onSelectDisplay: selectMirrorDisplay,
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
            WebsiteBackgroundView(accent: accent)
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
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
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
                let isActiveDisplaySelectionAck = ack.requestId == self.activeMirrorRequestID
                    && (ack.availableDisplays != nil || ack.selectedDisplayId != nil)

                if ack.decision == .accepted {
                    if isActiveDisplaySelectionAck {
                        self.selectedMirrorDisplayId = ack.selectedDisplayId ?? self.selectedMirrorDisplayId
                        self.lastError = nil
                        self.refreshCooldownTicker(for: ack)
                        return
                    }
                    self.activeMirrorRequestID = ack.requestId
                    self.selectedMirrorDisplayId = ack.selectedDisplayId ?? ack.availableDisplays?.first?.id ?? self.selectedMirrorDisplayId
                    self.isShowingMirrorViewer = true
                    Task { await self.startPhoneControlIfPossible() }
                } else if ack.requestId == self.activeMirrorRequestID {
                    if isActiveDisplaySelectionAck {
                        self.selectedMirrorDisplayId = ack.selectedDisplayId ?? self.selectedMirrorDisplayId
                        self.lastError = ack.detail ?? "Could not switch displays."
                        self.refreshCooldownTicker(for: ack)
                        return
                    }
                    self.activeMirrorRequestID = nil
                    self.selectedMirrorDisplayId = nil
                    self.isShowingMirrorViewer = false
                    Task { await self.phoneControlCoordinator.stop() }
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
        awaitingRequestID = requestID
        activeMirrorRequestID = nil
        selectedMirrorDisplayId = nil
        phoneControlError = nil
        lastError = nil
        lastAck = nil
        lastAckReceivedAt = nil
        await phoneControlCoordinator.stop()
        cooldownTickerTask?.cancel()
        cooldownTickerTask = nil
        let request = HermesRealtimeRelayMirrorRequest(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: deviceDisplayName(),
            streamClass: MediaStreamClass.screenVideo.rawValue,
            streamingCapabilities: MercuryVideoToolboxCapabilityProbe.snapshot(
                mediaFrameVersions: .v1Only
            ).wireValue
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
            selectedMirrorDisplayId = nil
            isShowingMirrorViewer = false
            await phoneControlCoordinator.stop()
            return
        }
        guard let requestID = activeMirrorRequestID else { return }
        activeMirrorRequestID = nil
        selectedMirrorDisplayId = nil
        isShowingMirrorViewer = false
        lastAck = nil
        lastAckReceivedAt = nil
        cooldownTickerTask?.cancel()
        cooldownTickerTask = nil
        await phoneControlCoordinator.stop()
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

    private func selectMirrorDisplay(_ displayId: String) {
        let previousDisplayId = selectedMirrorDisplayId
        selectedMirrorDisplayId = displayId
        guard let uid = uidProvider(), !uid.isEmpty,
              let requestID = activeMirrorRequestID else {
            selectedMirrorDisplayId = previousDisplayId
            return
        }
        lastError = nil
        let selection = HermesRealtimeRelayMirrorDisplaySelection(
            requestId: requestID,
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

    private var mirrorControlStatus: ScreenSharePhoneControlStatus {
        if let phoneControlError {
            return .unavailable(phoneControlError)
        }
        switch phoneControlCoordinator.phase {
        case .live:
            return .live
        case .dialing, .reconnecting:
            return .connecting
        case .failed(let reason):
            return .unavailable(reason)
        case .idle, .stopped:
            return activeMirrorRequestID == nil ? .unavailable("Mirror is read only.") : .connecting
        }
    }

    private func startPhoneControlIfPossible() async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            phoneControlError = "Sign in to control your Mac."
            return
        }
        do {
            let pairingPublicKey = try await FirestoreIrohPairingPublicKeyProvider.shared.fetchPublicKey(uid: uid)
            phoneControlCoordinator.start(
                uid: uid,
                connectionID: connectionID,
                relayPublicKey: pairingPublicKey
            )
            phoneControlError = nil
        } catch {
            phoneControlError = error.localizedDescription
        }
    }
}

private struct MercuryMirrorViewerFullScreen: View {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator
    let resetToken: String?
    let controlStatus: ScreenSharePhoneControlStatus
    let streamPhase: MediaControlStreamCoordinator.Phase
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let usePremiumSOTAUX: Bool
    let sendTapIntent: (Double, Double, Int) -> Void
    let sendScrollIntent: (Double, Double, Double, Double, String?) -> Void
    let sendPointerMoveIntent: (Double, Double) -> Void
    let sendPointerClickIntent: (Int) -> Void
    let sendTextIntent: (String) -> Void
    let sendShortcutIntent: (String, [String]) -> Void
    let onSelectDisplay: (String) -> Void
    let onForceReconnect: () -> Void
    let onRetryRequest: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScreenShareViewerView(
            coordinator: coordinator,
            resetToken: resetToken,
            controlStatus: controlStatus,
            displays: displays,
            selectedDisplayId: selectedDisplayId,
            streamPhase: streamPhase,
            usePremiumSOTAUX: usePremiumSOTAUX,
            onForceReconnect: onForceReconnect,
            onRetryRequest: onRetryRequest,
            sendTapIntent: sendTapIntent,
            sendScrollIntent: sendScrollIntent,
            sendPointerMoveIntent: sendPointerMoveIntent,
            sendPointerClickIntent: sendPointerClickIntent,
            sendTextIntent: sendTextIntent,
            sendShortcutIntent: sendShortcutIntent,
            onSelectDisplay: onSelectDisplay,
            onClose: onClose
        )
        .background(Color.black.ignoresSafeArea())
    }
}

