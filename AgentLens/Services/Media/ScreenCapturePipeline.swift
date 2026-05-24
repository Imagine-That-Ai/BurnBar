import Foundation
import AVFoundation
import AppKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
import OSLog
import OpenBurnBarCore
import OpenBurnBarMedia

/// Mac screen-capture pipeline driven by ScreenCaptureKit. Phase 3
/// (Mac → iOS one-way screen share) entry point. Captures the focused
/// window or display at 1920×1080@30 by default and surfaces
/// `CMSampleBuffer` frames to the encoder.
///
/// See `plans/2026-05-15-mercury-media-master-plan.md` § C.1.
@MainActor
final class ScreenCapturePipeline: NSObject {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")

    enum Failure: Error, LocalizedError {
        case screenRecordingPermissionDenied
        case noShareableContent
        case streamConfigurationFailed(String)

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermissionDenied:
                return "OpenBurnBar needs Screen Recording permission. Open System Settings → Privacy & Security → Screen Recording to enable."
            case .noShareableContent:
                return "No shareable display or window available."
            case .streamConfigurationFailed(let message):
                return "Screen capture stream failed: \(message)"
            }
        }
    }

    struct Configuration: Sendable, Equatable {
        var width: Int = 1920
        var height: Int = 1080
        var frameRate: Int = 30
        var captureFocusedWindowOnly: Bool = false
        var displayId: String? = nil
        var windowID: CGWindowID? = nil
    }

    struct WindowDescriptor: Sendable, Equatable {
        var windowID: CGWindowID
        var title: String?
        var appName: String
        var bundleIdentifier: String

        var focusContext: HermesRealtimeRelayFocusContext {
            HermesRealtimeRelayFocusContext(
                appName: appName,
                bundleId: bundleIdentifier,
                windowTitle: title,
                windowId: UInt32(windowID)
            )
        }
    }

    typealias FrameHandler = @MainActor @Sendable (CMSampleBuffer) async -> Void

    private let configuration: Configuration
    private let frameHandler: FrameHandler
    #if canImport(ScreenCaptureKit)
    private var stream: SCStream?
    #endif

    init(configuration: Configuration = Configuration(), frameHandler: @escaping FrameHandler) {
        self.configuration = configuration
        self.frameHandler = frameHandler
    }

    static func availableDisplays() -> [HermesRealtimeRelayDisplayDescriptor] {
        NSScreen.screens.enumerated().map { index, screen in
            let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { String($0.uint32Value) } ?? "display-\(index + 1)"
            return HermesRealtimeRelayDisplayDescriptor(
                id: displayId,
                name: index == 0 ? "Main Display" : "Display \(index + 1)",
                width: Int(screen.frame.width),
                height: Int(screen.frame.height),
                isPrimary: index == 0
            )
        }
    }

    static func availableWindows() async -> [WindowDescriptor] {
        #if canImport(ScreenCaptureKit)
        do {
            let content = try await currentShareableContent(requestPermissionIfNeeded: false)
            return content.windows.compactMap { window in
                guard let application = window.owningApplication,
                      application.applicationName.isEmpty == false,
                      application.bundleIdentifier.isEmpty == false
                else { return nil }
                return WindowDescriptor(
                    windowID: window.windowID,
                    title: window.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyForCapture,
                    appName: application.applicationName,
                    bundleIdentifier: application.bundleIdentifier
                )
            }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    func start() async throws {
        #if canImport(ScreenCaptureKit)
        let content: SCShareableContent
        do {
            content = try await Self.currentShareableContent(requestPermissionIfNeeded: true)
        } catch {
            if case Failure.screenRecordingPermissionDenied = error {
                throw error
            }
            throw Failure.streamConfigurationFailed(error.localizedDescription)
        }
        let filter: SCContentFilter
        if let windowID = configuration.windowID,
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            let display = configuration.displayId.flatMap { wanted in
                content.displays.first { String($0.displayID) == wanted }
            } ?? content.displays.first
            guard let display else {
                Self.log.error("screen_capture_shareable_content_empty displays=\(content.displays.count, privacy: .public) windows=\(content.windows.count, privacy: .public)")
                throw Failure.noShareableContent
            }
            let excludedApplications = Self.displayCaptureExcludedApplications(in: content)
            filter = SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: [])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = configuration.width
        cfg.height = configuration.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        cfg.queueDepth = 5
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true

        let newStream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await newStream.startCapture()
        self.stream = newStream
        #else
        throw Failure.streamConfigurationFailed("ScreenCaptureKit unavailable on this platform.")
        #endif
    }

    func stop() async {
        #if canImport(ScreenCaptureKit)
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        #endif
    }

    #if canImport(ScreenCaptureKit)
    static func shouldExcludeApplicationFromDisplayCapture(
        bundleIdentifier: String?,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        var excludedBundleIdentifiers: Set<String> = [
            "com.openburnbar.app",
            "com.openburnbar.AgentLens"
        ]
        if let ownBundleIdentifier, !ownBundleIdentifier.isEmpty {
            excludedBundleIdentifiers.insert(ownBundleIdentifier)
        }
        return excludedBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func displayCaptureExcludedApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter {
            shouldExcludeApplicationFromDisplayCapture(bundleIdentifier: $0.bundleIdentifier)
        }
    }

    private static func currentShareableContent(requestPermissionIfNeeded: Bool) async throws -> SCShareableContent {
        #if canImport(CoreGraphics)
        if !CGPreflightScreenCaptureAccess() {
            guard requestPermissionIfNeeded, CGRequestScreenCaptureAccess() else {
                log.error("screen_capture_permission_missing requestPermission=\(requestPermissionIfNeeded, privacy: .public)")
                throw Failure.screenRecordingPermissionDenied
            }
        }
        #endif

        let visibleContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        if !visibleContent.displays.isEmpty || !visibleContent.windows.isEmpty {
            return visibleContent
        }

        let fallback = try await SCShareableContent.current
        log.info("screen_capture_shareable_content_fallback visibleDisplays=0 visibleWindows=0 fallbackDisplays=\(fallback.displays.count, privacy: .public) fallbackWindows=\(fallback.windows.count, privacy: .public)")
        return fallback
    }
    #endif
}

#if canImport(ScreenCaptureKit)
private struct CapturedSampleBuffer: @unchecked Sendable {
    // ScreenCaptureKit delivers each sample buffer to this delegate callback
    // for one-way handoff into the main-actor encoder. Keep the unchecked
    // boundary local instead of declaring CMSampleBuffer globally Sendable.
    let sampleBuffer: CMSampleBuffer
}

extension ScreenCapturePipeline: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let frame = CapturedSampleBuffer(sampleBuffer: sampleBuffer)
        Task(priority: .userInitiated) { @MainActor [weak self, frame] in
            await self?.frameHandler(frame.sampleBuffer)
        }
    }
}

private extension String {
    var nilIfEmptyForCapture: String? {
        isEmpty ? nil : self
    }
}
#endif
