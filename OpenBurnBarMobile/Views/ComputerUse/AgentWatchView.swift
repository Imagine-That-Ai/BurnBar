#if canImport(SwiftUI) && canImport(UIKit)
import AVKit
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

/// Full-bleed iOS view that displays the Mac's mirrored surface and
/// overlays the planned-action chip, the pending-approval row, and the
/// trust-mode badge. Phase 8 ships the view; Phase 12 makes the
/// approval-row buttons functional via `PhoneControlSender`.
///
public struct AgentWatchView: View {
    @ObservedObject private var state: AgentWatchState
    @StateObject private var video = AgentWatchVideoCoordinator()
    private let downgradeTrustMode: (ComputerUseTrustMode) -> Void
    private let approveAction: (HermesRealtimeRelayApprovalRequest) -> Void
    private let rejectAction: (HermesRealtimeRelayApprovalRequest, Bool) -> Void
    private let panicHalt: () -> Void
    private let sendTapIntent: (Double, Double) -> Void
    private let sendScrollIntent: (Double, Double, Double, Double) -> Void
    private let sendTextIntent: (String) -> Void
    private let sendShortcutIntent: (String, [String]) -> Void
    @State private var showingTimeline = false
    @State private var showingOptions = false
    @State private var dragPreview: (start: CGPoint, end: CGPoint)?

    public init(
        state: AgentWatchState,
        downgradeTrustMode: @escaping (ComputerUseTrustMode) -> Void,
        approveAction: @escaping (HermesRealtimeRelayApprovalRequest) -> Void,
        rejectAction: @escaping (HermesRealtimeRelayApprovalRequest, Bool) -> Void,
        panicHalt: @escaping () -> Void,
        sendTapIntent: @escaping (Double, Double) -> Void = { _, _ in },
        sendScrollIntent: @escaping (Double, Double, Double, Double) -> Void = { _, _, _, _ in },
        sendTextIntent: @escaping (String) -> Void = { _ in },
        sendShortcutIntent: @escaping (String, [String]) -> Void = { _, _ in }
    ) {
        self._state = ObservedObject(wrappedValue: state)
        self.downgradeTrustMode = downgradeTrustMode
        self.approveAction = approveAction
        self.rejectAction = rejectAction
        self.panicHalt = panicHalt
        self.sendTapIntent = sendTapIntent
        self.sendScrollIntent = sendScrollIntent
        self.sendTextIntent = sendTextIntent
        self.sendShortcutIntent = sendShortcutIntent
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AgentWatchSurfaceView(coordinator: video)
                .ignoresSafeArea()
                .opacity(state.currentFrame == nil ? 0 : 1)
            if state.currentFrame == nil {
                framePlaceholder
            }
            phoneInputSurface
            cursorOverlay
            dragPreviewOverlay
            VStack {
                topHairline
                Spacer()
                bottomStrip
            }
            ThreeFingerLongPressCapture(onRecognized: panicHalt)
                .ignoresSafeArea()
        }
        .onChange(of: state.currentFrame) { _, frame in
            guard let frame else { return }
            Task { await video.ingest(frame: frame) }
        }
        .sheet(isPresented: $showingTimeline) {
            AgentActionTimelineSheet(entries: state.actionTimeline)
        }
        .sheet(isPresented: $showingOptions) {
            PhoneControlOptionSheet(
                snapshot: state.snapshot,
                onTrustMode: downgradeTrustMode,
                onType: sendTextIntent,
                onShortcut: sendShortcutIntent,
                onPanic: panicHalt
            )
        }
    }

    private var framePlaceholder: some View {
        VStack {
            Image(systemName: "rectangle.dashed")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(.white.opacity(0.2))
            Text(state.sessionId == nil ? "Waiting for Mac session" : "Live control stream ready")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var phoneInputSurface: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let distance = hypot(value.translation.width, value.translation.height)
                            dragPreview = distance >= 10 ? (value.startLocation, value.location) : nil
                        }
                        .onEnded { value in
                            defer { dragPreview = nil }
                            let distance = hypot(value.translation.width, value.translation.height)
                            if distance < 10 {
                                let point = normalized(value.location, in: proxy.size)
                                sendTapIntent(point.x, point.y)
                            } else {
                                let start = normalized(value.startLocation, in: proxy.size)
                                let end = normalized(value.location, in: proxy.size)
                                sendScrollIntent(start.x, start.y, end.x, end.y)
                            }
                        }
                )
        }
        .ignoresSafeArea()
    }

    private var dragPreviewOverlay: some View {
        GeometryReader { _ in
            if let dragPreview {
                Path { path in
                    path.move(to: dragPreview.start)
                    path.addLine(to: dragPreview.end)
                }
                .stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5]))
                Circle()
                    .fill(.white.opacity(0.88))
                    .frame(width: 8, height: 8)
                    .position(dragPreview.start)
                Circle()
                    .stroke(.white.opacity(0.88), lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .position(dragPreview.end)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var cursorOverlay: some View {
        GeometryReader { proxy in
            if let cursor = state.currentCursor {
                Image(systemName: "cursorarrow")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                    .position(
                        x: cursorPosition(cursor, in: proxy.size).x,
                        y: cursorPosition(cursor, in: proxy.size).y
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private var topHairline: some View {
        HStack(spacing: 12) {
            Text("Watching · \(state.liveTrustMode.rawValue.capitalized) · \(timeAgo)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button {
                showingOptions = true
            } label: {
                ComputerUseTrustModeBadge(mode: state.liveTrustMode)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var bottomStrip: some View {
        VStack(spacing: 12) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.2), .white.opacity(0.0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            HStack(spacing: 16) {
                Text(String(format: "Spent  $%.2f", state.dailySpentUSD))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Text("\(state.actionsExecuted) actions")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            }
            if let next = state.actionTimeline.last {
                Button {
                    showingTimeline = true
                } label: {
                    HStack {
                    Image(systemName: "wand.and.rays")
                    Text("Next: \(next.summary)")
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
            if let pending = state.pendingApproval {
                HStack(spacing: 12) {
                    Button(action: { rejectAction(pending, true) }) {
                        Text("Reject + Halt")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button(action: { rejectAction(pending, false) }) {
                        Text("Reject")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: { approveAction(pending) }) {
                        Text("Approve")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }

    private var timeAgo: String {
        guard let started = state.sessionStartedAt else { return "—:—:—" }
        let elapsed = Int(Date().timeIntervalSince(started))
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func cursorPosition(_ cursor: MediaFrame.CursorMetadata, in size: CGSize) -> CGPoint {
        // `MediaFrame` intentionally carries only codec payload + cursor
        // metadata. Until the stream publishes source dimensions, normalize
        // against the common Mercury screen-share canvas so the cursor remains
        // visible and directionally correct instead of clipping off-screen.
        let frameWidth: CGFloat = 1920
        let frameHeight: CGFloat = 1080
        let x = min(max(CGFloat(cursor.x) / frameWidth, 0), 1) * size.width
        let y = min(max(CGFloat(cursor.y) / frameHeight, 0), 1) * size.height
        return CGPoint(x: x, y: y)
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        return (Double(x), Double(y))
    }
}

private struct ThreeFingerLongPressCapture: UIViewRepresentable {
    let onRecognized: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        recognizer.minimumPressDuration = 0.8
        recognizer.numberOfTouchesRequired = 3
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onRecognized = onRecognized
    }

    @MainActor
    final class Coordinator: NSObject {
        var onRecognized: () -> Void

        init(onRecognized: @escaping () -> Void) {
            self.onRecognized = onRecognized
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onRecognized()
        }
    }
}

@MainActor
private final class AgentWatchVideoCoordinator: ObservableObject {
    let displayLayer: AVSampleBufferDisplayLayer
    private var pipeline: VideoReceivePipeline?

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer
        self.pipeline = VideoReceivePipeline { [weak self] sampleBuffer in
            await MainActor.run {
                self?.enqueue(sampleBuffer: sampleBuffer)
            }
        }
    }

    func ingest(frame: MediaFrame) async {
        do {
            try await pipeline?.ingest(frame: frame)
        } catch {
            displayLayer.flush()
        }
    }

    private func enqueue(sampleBuffer: CMSampleBuffer) {
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }
}

private struct AgentWatchSurfaceView: UIViewRepresentable {
    @ObservedObject var coordinator: AgentWatchVideoCoordinator

    func makeUIView(context: Context) -> AgentWatchDisplayLayerView {
        let view = AgentWatchDisplayLayerView()
        view.attach(layer: coordinator.displayLayer)
        return view
    }

    func updateUIView(_ uiView: AgentWatchDisplayLayerView, context: Context) {}
}

private final class AgentWatchDisplayLayerView: UIView {
    private weak var hostedLayer: AVSampleBufferDisplayLayer?

    func attach(layer: AVSampleBufferDisplayLayer) {
        hostedLayer?.removeFromSuperlayer()
        layer.frame = bounds
        layer.videoGravity = .resizeAspect
        self.layer.addSublayer(layer)
        hostedLayer = layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedLayer?.frame = bounds
    }
}
#endif
