#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenBurnBarCore

/// Mac-side producer of Smart Zoom focus context. Samples the AX tree,
/// the focused window, and the cursor at ≤ 4 Hz and emits a
/// `HermesRealtimeRelayFocusContext` for the phone's local Smart Zoom
/// reducer to consume. The provider never crops the Mac capture and
/// never sends a new frame type — it piggybacks on the existing
/// `media.stream.frame` envelope that already carries focus context.
///
/// Lives behind `#if canImport(AppKit) && !DISTRIBUTION_MAS` because
/// Path C (Mac App Store) cannot drive Accessibility, mirroring
/// `MacAccessibilityInspector` / `AgentFocusFollowController`.

/// Display rectangle expressed in the same top-left-origin event-tap
/// pixel coordinate system `MacInputCore.denormalize` consumes. Kept
/// minimal so tests do not need to import AppKit.
public struct SmartZoomDisplayBounds: Sendable, Equatable {
    public let displayId: String
    public let originX: CGFloat
    public let originY: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(displayId: String, originX: CGFloat, originY: CGFloat, width: CGFloat, height: CGFloat) {
        self.displayId = displayId
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    public var maxX: CGFloat { originX + width }
    public var maxY: CGFloat { originY + height }
}

/// AX-derived focused element snapshot in event-tap pixel coordinates.
public struct SmartZoomElementSnapshot: Sendable, Equatable {
    public let role: String?
    public let subrole: String?
    public let frame: CGRect

    public init(role: String?, subrole: String?, frame: CGRect) {
        self.role = role
        self.subrole = subrole
        self.frame = frame
    }
}

/// Snapshot of the focused application window in event-tap pixel
/// coordinates.
public struct SmartZoomWindowSnapshot: Sendable, Equatable {
    public let appName: String
    public let bundleId: String
    public let windowTitle: String?
    public let windowId: UInt32?
    public let frame: CGRect

    public init(
        appName: String,
        bundleId: String,
        windowTitle: String? = nil,
        windowId: UInt32? = nil,
        frame: CGRect
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.windowId = windowId
        self.frame = frame
    }
}

/// Inputs to `SmartZoomContextResolver.resolve`. Every field is
/// optional so the resolver can build context from whatever the AX/
/// cursor pipeline managed to fetch — degraded modes (Accessibility
/// denied, no focused element) still emit cursor and window context.
public struct SmartZoomSampleInputs: Sendable, Equatable {
    public let focusedElement: SmartZoomElementSnapshot?
    public let focusedWindow: SmartZoomWindowSnapshot?
    public let cursor: CGPoint?
    public let displays: [SmartZoomDisplayBounds]
    public let isUserSessionLocked: Bool
    public let isAccessibilityTrusted: Bool
    public let sampledAt: Date

    public init(
        focusedElement: SmartZoomElementSnapshot? = nil,
        focusedWindow: SmartZoomWindowSnapshot? = nil,
        cursor: CGPoint? = nil,
        displays: [SmartZoomDisplayBounds] = [],
        isUserSessionLocked: Bool = false,
        isAccessibilityTrusted: Bool = true,
        sampledAt: Date = Date()
    ) {
        self.focusedElement = focusedElement
        self.focusedWindow = focusedWindow
        self.cursor = cursor
        self.displays = displays
        self.isUserSessionLocked = isUserSessionLocked
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.sampledAt = sampledAt
    }
}

/// Pure transform from `SmartZoomSampleInputs` to a relay focus
/// context. All math is platform-neutral so tests can exercise the
/// padding/normalization/role-filtering rules without AppKit.
public enum SmartZoomContextResolver {
    /// Roles AX returns for editable text-like surfaces. Includes
    /// terminal-style editable areas (`AXTextArea`) and combo-box
    /// editors, per the plan.
    public static let textLikeRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox"
    ]

    /// Short axis padding ratio applied to the rect's smaller
    /// dimension on each side before normalization (plan: 12%).
    public static let textPaddingShortRatio: Double = 0.12
    /// Long axis padding ratio applied to the rect's larger
    /// dimension on each side before normalization (plan: 8%).
    public static let textPaddingLongRatio: Double = 0.08
    /// Window target padding applied symmetrically (plan: 4%).
    public static let windowPaddingRatio: Double = 0.04

    public static func resolve(_ inputs: SmartZoomSampleInputs) -> HermesRealtimeRelayFocusContext? {
        if inputs.isUserSessionLocked { return nil }

        let cursorBounds = inputs.cursor.flatMap { point in
            inputs.displays.first(where: { containsPoint($0, point: point) }) ?? inputs.displays.first
        }

        if inputs.isAccessibilityTrusted,
           let element = inputs.focusedElement,
           isTextLike(role: element.role),
           let display = displayContaining(rect: element.frame, in: inputs.displays) ?? cursorBounds {
            let padded = expandRect(
                element.frame,
                shortAxisRatio: textPaddingShortRatio,
                longAxisRatio: textPaddingLongRatio
            )
            let rect = normalize(rect: padded, in: display)
            let window = inputs.focusedWindow
            return HermesRealtimeRelayFocusContext(
                appName: window?.appName ?? "Mac",
                bundleId: window?.bundleId ?? "unknown.bundle",
                windowTitle: window?.windowTitle,
                windowId: window?.windowId,
                targetKind: .focusedElement,
                displayId: display.displayId,
                normalizedRect: rect,
                normalizedPoint: nil,
                confidence: 0.95,
                updatedAt: inputs.sampledAt
            )
        }

        if let window = inputs.focusedWindow,
           let display = displayContaining(rect: window.frame, in: inputs.displays) ?? cursorBounds {
            let padded = expandRect(
                window.frame,
                shortAxisRatio: windowPaddingRatio,
                longAxisRatio: windowPaddingRatio
            )
            let rect = normalize(rect: padded, in: display)
            return HermesRealtimeRelayFocusContext(
                appName: window.appName,
                bundleId: window.bundleId,
                windowTitle: window.windowTitle,
                windowId: window.windowId,
                targetKind: .focusedWindow,
                displayId: display.displayId,
                normalizedRect: rect,
                normalizedPoint: nil,
                confidence: 0.7,
                updatedAt: inputs.sampledAt
            )
        }

        if let cursor = inputs.cursor,
           let display = cursorBounds {
            let point = normalize(point: cursor, in: display)
            let window = inputs.focusedWindow
            return HermesRealtimeRelayFocusContext(
                appName: window?.appName ?? "Mac",
                bundleId: window?.bundleId ?? "unknown.bundle",
                windowTitle: window?.windowTitle,
                windowId: window?.windowId,
                targetKind: .cursor,
                displayId: display.displayId,
                normalizedRect: nil,
                normalizedPoint: point,
                confidence: 0.4,
                updatedAt: inputs.sampledAt
            )
        }

        return nil
    }

    // MARK: - Geometry helpers

    public static func isTextLike(role: String?) -> Bool {
        guard let role else { return false }
        return textLikeRoles.contains(role)
    }

    public static func expandRect(
        _ rect: CGRect,
        shortAxisRatio: Double,
        longAxisRatio: Double
    ) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return rect }
        let isWide = rect.width >= rect.height
        let shortAxisLength = isWide ? rect.height : rect.width
        let longAxisLength = isWide ? rect.width : rect.height
        let shortPad = CGFloat(shortAxisRatio) * shortAxisLength
        let longPad = CGFloat(longAxisRatio) * longAxisLength
        let horizontalPad = isWide ? longPad : shortPad
        let verticalPad = isWide ? shortPad : longPad
        return CGRect(
            x: rect.origin.x - horizontalPad,
            y: rect.origin.y - verticalPad,
            width: rect.width + 2 * horizontalPad,
            height: rect.height + 2 * verticalPad
        )
    }

    public static func normalize(
        rect: CGRect,
        in display: SmartZoomDisplayBounds
    ) -> HermesRealtimeRelayNormalizedRect {
        guard display.width > 0, display.height > 0 else {
            return HermesRealtimeRelayNormalizedRect(x: 0, y: 0, width: 0, height: 0)
        }
        let x = clamp01(Double((rect.origin.x - display.originX) / display.width))
        let y = clamp01(Double((rect.origin.y - display.originY) / display.height))
        let maxX = clamp01(Double((rect.maxX - display.originX) / display.width))
        let maxY = clamp01(Double((rect.maxY - display.originY) / display.height))
        return HermesRealtimeRelayNormalizedRect(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, maxY - y)
        )
    }

    public static func normalize(
        point: CGPoint,
        in display: SmartZoomDisplayBounds
    ) -> HermesRealtimeRelayNormalizedPoint {
        guard display.width > 0, display.height > 0 else {
            return HermesRealtimeRelayNormalizedPoint(x: 0, y: 0)
        }
        return HermesRealtimeRelayNormalizedPoint(
            x: clamp01(Double((point.x - display.originX) / display.width)),
            y: clamp01(Double((point.y - display.originY) / display.height))
        )
    }

    public static func displayContaining(rect: CGRect, in displays: [SmartZoomDisplayBounds]) -> SmartZoomDisplayBounds? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = displays.first(where: { containsPoint($0, point: center) }) {
            return hit
        }
        return displays.first
    }

    public static func containsPoint(_ display: SmartZoomDisplayBounds, point: CGPoint) -> Bool {
        point.x >= display.originX
            && point.x < display.maxX
            && point.y >= display.originY
            && point.y < display.maxY
    }

    private static func clamp01(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Wall-clock abstraction so tests can drive the 4 Hz sampler without
/// `Task.sleep`. Mirrors `AgentFocusFollowClock` for consistency.
public protocol SmartZoomClock: Sendable {
    func sleep(for seconds: TimeInterval) async
}

public struct SystemSmartZoomClock: SmartZoomClock {
    public init() {}
    public func sleep(for seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// 4 Hz Mac-side sampler. Calls a caller-provided `inputsProvider`
/// once per tick, runs `SmartZoomContextResolver`, and emits the
/// resulting context via `sink`. The sampler de-dupes successive
/// emissions to keep wire chatter quiet when nothing changed.
@MainActor
public final class SmartZoomContextProvider {
    public typealias InputsProvider = @MainActor @Sendable () async -> SmartZoomSampleInputs
    public typealias ContextSink = @MainActor @Sendable (HermesRealtimeRelayFocusContext) async -> Void

    public static let defaultSampleIntervalSeconds: TimeInterval = 0.25

    private let inputsProvider: InputsProvider
    private let sink: ContextSink
    private let clock: any SmartZoomClock
    private let sampleIntervalSeconds: TimeInterval
    private var loopTask: Task<Void, Never>?
    private var lastEmittedContext: HermesRealtimeRelayFocusContext?
    private var isRunning = false

    public init(
        inputsProvider: @escaping InputsProvider,
        sink: @escaping ContextSink,
        clock: any SmartZoomClock = SystemSmartZoomClock(),
        sampleIntervalSeconds: TimeInterval = SmartZoomContextProvider.defaultSampleIntervalSeconds
    ) {
        self.inputsProvider = inputsProvider
        self.sink = sink
        self.clock = clock
        self.sampleIntervalSeconds = sampleIntervalSeconds
    }

    public var isActive: Bool { isRunning }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lastEmittedContext = nil
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        lastEmittedContext = nil
    }

    /// Drives a single sample-emit cycle. Exposed for deterministic
    /// tests that don't want to spin the periodic loop.
    public func emitOnce() async {
        let inputs = await inputsProvider()
        guard let context = SmartZoomContextResolver.resolve(inputs) else { return }
        guard contextDiffersFromLast(context) else { return }
        lastEmittedContext = context
        await sink(context)
    }

    private func runLoop() async {
        while isRunning, !Task.isCancelled {
            await emitOnce()
            await clock.sleep(for: sampleIntervalSeconds)
        }
    }

    /// Compares the relevant slice of two contexts so equal targets do
    /// not generate wire chatter. The `updatedAt` timestamp is
    /// intentionally excluded — otherwise every tick would diff.
    private func contextDiffersFromLast(_ next: HermesRealtimeRelayFocusContext) -> Bool {
        guard let previous = lastEmittedContext else { return true }
        return previous.targetKind != next.targetKind
            || previous.displayId != next.displayId
            || previous.normalizedRect != next.normalizedRect
            || previous.normalizedPoint != next.normalizedPoint
            || previous.bundleId != next.bundleId
            || previous.windowId != next.windowId
    }
}

// MARK: - System adapters

/// Pulls a `SmartZoomSampleInputs` from live macOS APIs. Used by the
/// default provider wiring; tests inject fakes instead.
@MainActor
public enum SmartZoomSystemSampler {
    public static func sample(
        accessibilityTrusted: Bool? = nil,
        clock: @Sendable () -> Date = Date.init,
        ignoredBundleIdentifiers: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent"]
    ) -> SmartZoomSampleInputs {
        let trusted = accessibilityTrusted ?? AXIsProcessTrusted()
        let displays = systemDisplays()
        let cursor = systemCursorPoint(in: displays)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleId = frontmost?.bundleIdentifier ?? ""
        let isAuthGateActive = ignoredBundleIdentifiers.contains(bundleId)
        if isAuthGateActive {
            return SmartZoomSampleInputs(
                focusedElement: nil,
                focusedWindow: nil,
                cursor: nil,
                displays: displays,
                isUserSessionLocked: true,
                isAccessibilityTrusted: trusted,
                sampledAt: clock()
            )
        }
        let focusedWindow = trusted ? systemFocusedWindow(for: frontmost, displays: displays) : nil
        let focusedElement = trusted ? systemFocusedElement(for: frontmost, displays: displays) : nil
        return SmartZoomSampleInputs(
            focusedElement: focusedElement,
            focusedWindow: focusedWindow,
            cursor: cursor,
            displays: displays,
            isUserSessionLocked: false,
            isAccessibilityTrusted: trusted,
            sampledAt: clock()
        )
    }

    public static func systemDisplays() -> [SmartZoomDisplayBounds] {
        let unionTopEdge = appKitUnionTopEdge()
        return NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame
            let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { String($0.uint32Value) } ?? "display-\(index + 1)"
            return SmartZoomDisplayBounds(
                displayId: displayId,
                originX: frame.origin.x,
                originY: unionTopEdge - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
    }

    public static func systemCursorPoint(in displays: [SmartZoomDisplayBounds]) -> CGPoint? {
        let unionTopEdge = appKitUnionTopEdge()
        let appKitLocation = NSEvent.mouseLocation
        let topLeft = CGPoint(x: appKitLocation.x, y: unionTopEdge - appKitLocation.y)
        if displays.isEmpty {
            return topLeft
        }
        return topLeft
    }

    /// Highest AppKit `maxY` across all screens — the y-coordinate of
    /// the top edge of the desktop union, which is the origin of the
    /// top-left-origin event-tap pixel space we project into.
    private static func appKitUnionTopEdge() -> CGFloat {
        NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
    }

    public static func systemFocusedWindow(
        for application: NSRunningApplication?,
        displays: [SmartZoomDisplayBounds]
    ) -> SmartZoomWindowSnapshot? {
        guard let application else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused)
        guard err == .success, let window = focused else { return nil }
        let frame = axRect(for: window as! AXUIElement, displays: displays) ?? .zero
        let title = axString(window as! AXUIElement, kAXTitleAttribute as CFString)
        let windowID: UInt32? = nil
        let appName = application.localizedName
            ?? application.bundleURL?.lastPathComponent
            ?? "Active App"
        let bundleId = application.bundleIdentifier ?? "unknown.bundle"
        return SmartZoomWindowSnapshot(
            appName: appName,
            bundleId: bundleId,
            windowTitle: title,
            windowId: windowID,
            frame: frame
        )
    }

    public static func systemFocusedElement(
        for application: NSRunningApplication?,
        displays: [SmartZoomDisplayBounds]
    ) -> SmartZoomElementSnapshot? {
        guard let application else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        let raw = element as! AXUIElement
        let role = axString(raw, kAXRoleAttribute as CFString)
        let subrole = axString(raw, kAXSubroleAttribute as CFString)
        let frame = axRect(for: raw, displays: displays)
        return SmartZoomElementSnapshot(
            role: role,
            subrole: subrole,
            frame: frame ?? .zero
        )
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard err == .success else { return nil }
        return raw as? String
    }

    private static func axRect(for element: AXUIElement, displays _: [SmartZoomDisplayBounds]) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeErr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard positionErr == .success, sizeErr == .success,
              let positionRaw = positionValue,
              let sizeRaw = sizeValue else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        if AXValueGetType(positionRaw as! AXValue) == .cgPoint {
            AXValueGetValue(positionRaw as! AXValue, .cgPoint, &origin)
        }
        if AXValueGetType(sizeRaw as! AXValue) == .cgSize {
            AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        // AX positions are already top-left-origin event-tap pixels.
        return CGRect(origin: origin, size: size)
    }
}

#endif
