import SwiftUI
@preconcurrency import AVKit
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

// remediation(media-decomposition): relocated verbatim from
// ScreenShareViewerView.swift (which remained >2500 lines after the
// screen-share stats throttle fix) to shrink that god-file. These are the
// self-contained stats/coordinator types and the display-layer host; no
// behavior changed. `DisplayLayerHost` was `private` in the original file and
// is referenced by `ScreenShareViewerView.body`, so it is now internal so it
// stays visible across the move within the module. `DisplayLayerView` and
// `StatsOverlay` are only used here, so they remain file-private.

struct ScreenShareViewerPerformanceStats: Equatable, Sendable {
    var resolution: String = ""
    var codec: String = ""
    var bitsPerSecond: Int = 0
    var roundTripMillis: Int = 0
}

struct ScreenShareViewerStatsMeter: Sendable {
    private var windowStartedAt: Date?
    private var bytesInWindow: Int = 0
    private var lastStats = ScreenShareViewerPerformanceStats()
    private let minimumSampleInterval: TimeInterval

    init(minimumSampleInterval: TimeInterval = 0.5) {
        self.minimumSampleInterval = minimumSampleInterval
    }

    mutating func recordFrame(
        byteCount: Int,
        now: Date = Date(),
        codec: String? = nil,
        resolution: String? = nil
    ) -> ScreenShareViewerPerformanceStats {
        if windowStartedAt == nil {
            windowStartedAt = now
        }
        bytesInWindow += max(byteCount, 0)

        var next = lastStats
        if let codec, !codec.isEmpty {
            next.codec = codec
        }
        if let resolution, !resolution.isEmpty {
            next.resolution = resolution
        }

        let elapsed = max(0, now.timeIntervalSince(windowStartedAt ?? now))
        if elapsed >= minimumSampleInterval {
            next.bitsPerSecond = Int((Double(bytesInWindow) * 8.0 / elapsed).rounded())
            windowStartedAt = now
            bytesInWindow = 0
        }

        lastStats = next
        return next
    }

    mutating func updateRoundTripMillis(_ roundTripMillis: Int) -> ScreenShareViewerPerformanceStats {
        lastStats.roundTripMillis = max(0, roundTripMillis)
        return lastStats
    }
}

@MainActor
final class ScreenShareViewerCoordinator: ObservableObject {
    typealias Stats = ScreenShareViewerPerformanceStats

    let displayLayer: AVSampleBufferDisplayLayer
    @Published var lastStats = Stats()
    @Published var displayAspectRatio: CGFloat?
    @Published var latestFocusContext: ScreenShareSmartZoomContext?
    var longTermReferenceTokenHandler: ((MercuryLTRToken) async -> Void)?
    private var pipeline: VideoReceivePipeline?
    private var statsMeter = ScreenShareViewerStatsMeter()
    // remediation(1080p-hardcode): real source dimensions reported by the mirror
    // handshake (the selected display descriptor). When known, they override the
    // decoder's raw-payload fallback so a missing `VideoDecoderConfigurationPayload`
    // no longer silently assumes 1080p. Persisted so it survives pipeline
    // recreation in `resetForNewMirror`.
    private var expectedSourceDimensions: (width: Int, height: Int)?
    // remediation(screen-share-throttle): the per-frame hot path computes fresh
    // stats at 30-60fps, but `lastStats` is `@Published` and is observed by the
    // main mirroring `body` (via `displayStats`). Publishing every frame forced
    // a full body re-evaluation at frame rate even when the stats overlay is
    // hidden. We mirror `HermesStreamingEngine`'s commit throttle (~344-347):
    // the running meter keeps accumulating every frame, but we only republish
    // when the Equatable value actually changed AND at most every
    // `statsPublishInterval`. Bitrate only moves ~every 0.5s, so a 3 Hz cap
    // keeps the overlay functionally identical while ending the per-frame churn.
    private static let statsPublishInterval: Duration = .milliseconds(333)
    private var lastStatsPublishedAt: ContinuousClock.Instant?

    func ingest(focusContext: HermesRealtimeRelayFocusContext) {
        guard let context = ScreenShareSmartZoomContext.from(focusContext) else { return }
        latestFocusContext = context
    }

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer
        self.pipeline = makePipeline()
    }

    func resetForNewMirror() {
        displayLayer.flushAndRemoveImage()
        lastStats = Stats()
        displayAspectRatio = nil
        latestFocusContext = nil
        statsMeter = ScreenShareViewerStatsMeter()
        lastStatsPublishedAt = nil
        pipeline = makePipeline()
    }

    /// Records the real source dimensions (from the mirror handshake's selected
    /// display descriptor) so the decoder's raw-payload fallback uses them
    /// instead of the documented 1080p default. Safe to call repeatedly; ignores
    /// non-positive sizes.
    func setExpectedSourceDimensions(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        expectedSourceDimensions = (width, height)
        pipeline?.updateFallbackDimensions(width: width, height: height)
    }

    private func makePipeline() -> VideoReceivePipeline {
        let fallbackDimensions = expectedSourceDimensions.map {
            CMVideoDimensions(width: Int32(clamping: $0.width), height: Int32(clamping: $0.height))
        } ?? VideoReceivePipeline.defaultFallbackDimensions
        return VideoReceivePipeline(fallbackDimensions: fallbackDimensions) { [weak self] sampleBuffer in
            await MainActor.run {
                self?.enqueue(sampleBuffer: sampleBuffer)
            }
        } onLongTermReferenceTokenDecoded: { [weak self] token in
            await self?.longTermReferenceTokenHandler?(token)
        }
    }

    func enqueue(sampleBuffer: CMSampleBuffer) {
        var resolution: String?
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let width = CGFloat(dimensions.width)
            let height = CGFloat(dimensions.height)
            if width > 0, height > 0 {
                resolution = "\(Int(width))x\(Int(height))"
                let aspectRatio = width / height
                if displayAspectRatio.map({ abs($0 - aspectRatio) > 0.0001 }) ?? true {
                    displayAspectRatio = aspectRatio
                }
            }
        }
        if let resolution, lastStats.resolution != resolution {
            var stats = lastStats
            stats.resolution = resolution
            lastStats = stats
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func ingest(frame: MediaFrame) async {
        recordIncomingFrame(byteCount: Self.estimatedWireByteCount(for: frame), codec: "HEVC")
        do {
            try await pipeline?.ingest(frame: frame)
        } catch {
            displayLayer.flush()
        }
    }

    func ingest(frameV2: MediaFrameV2) async {
        recordIncomingFrame(
            byteCount: Self.estimatedWireByteCount(for: frameV2),
            codec: Self.codecLabel(for: frameV2)
        )
        do {
            try await pipeline?.ingest(frameV2: frameV2)
        } catch {
            displayLayer.flush()
        }
    }

    func update(stats: Stats) {
        lastStats = stats
    }

    func update(roundTripMillis: Int) {
        lastStats = statsMeter.updateRoundTripMillis(roundTripMillis)
    }

    private func recordIncomingFrame(byteCount: Int, codec: String?) {
        // remediation(screen-share-throttle): the meter accumulates every frame,
        // but we only commit to the `@Published` property through the throttle so
        // the observing `body` does not re-evaluate at frame rate.
        let next = statsMeter.recordFrame(
            byteCount: byteCount,
            codec: codec,
            resolution: lastStats.resolution
        )
        publishStatsIfNeeded(next)
    }

    /// Commits freshly metered stats to `lastStats` only when the value actually
    /// changed (Equatable) and at least `statsPublishInterval` has elapsed since
    /// the last commit. The infrequent resolution/RTT paths assign `lastStats`
    /// directly and are unaffected.
    private func publishStatsIfNeeded(_ next: Stats) {
        guard next != lastStats else { return }
        let now = ContinuousClock.now
        if let last = lastStatsPublishedAt, now - last < Self.statsPublishInterval {
            return
        }
        lastStatsPublishedAt = now
        lastStats = next
    }

    private static func estimatedWireByteCount(for frame: MediaFrame) -> Int {
        MediaFrame.headerByteCount
            + (frame.flags.contains(.hasCursorMetadata) ? MediaFrame.cursorMetadataByteCount : 0)
            + frame.payload.count
    }

    private static func estimatedWireByteCount(for frame: MediaFrameV2) -> Int {
        MediaFrameV2Codec.fixedHeaderByteCount + frame.metadata.count + frame.payload.count
    }

    private static func codecLabel(for frame: MediaFrameV2) -> String? {
        guard let metadata = try? MediaFrameV2Metadata.decode(frame.metadata),
              let codec = metadata.codec
        else { return nil }

        switch codec {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        case .av1: return "AV1"
        }
    }
}

struct DisplayLayerHost: UIViewRepresentable {
    @ObservedObject var coordinator: ScreenShareViewerCoordinator

    func makeUIView(context: Context) -> DisplayLayerView {
        let view = DisplayLayerView()
        view.attach(layer: coordinator.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DisplayLayerView, context: Context) {
        // Layer reattachment handled internally; nothing to do per update.
    }
}

// remediation(media-decomposition): raised from `private` to internal because
// `DisplayLayerHost` (now internal, see above) returns this type from the
// internal `UIViewRepresentable.makeUIView` requirement; an internal method may
// not expose a private result type. Still effectively used only within Media.
final class DisplayLayerView: UIView {
    private weak var hostedLayer: AVSampleBufferDisplayLayer?

    func attach(layer: AVSampleBufferDisplayLayer) {
        if let existing = hostedLayer {
            existing.removeFromSuperlayer()
        }
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

private struct StatsOverlay: View {
    let stats: ScreenShareViewerCoordinator.Stats

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(stats.resolution).font(.system(size: 13, weight: .medium, design: .monospaced))
            Text("\(stats.codec) · \(formattedBitrate)").font(.system(size: 13, weight: .medium, design: .monospaced))
            Text("RTT \(stats.roundTripMillis) ms").font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.primary.opacity(0.85))
    }

    private var formattedBitrate: String {
        let mbps = Double(stats.bitsPerSecond) / 1_000_000.0
        return String(format: "%.2f Mbps", mbps)
    }
}
