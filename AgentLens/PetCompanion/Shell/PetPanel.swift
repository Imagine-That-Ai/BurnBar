import AppKit

// MARK: - PetPanel

/// The floating, borderless, transparent host window for the pet (PLAN C1).
///
/// An `NSPanel` (not `NSWindow`) so it can be a `.nonactivatingPanel` that floats
/// without stealing key focus from the user's frontmost app. It joins all Spaces
/// and floats over fullscreen apps via its collection behavior, and it is
/// click-through everywhere except the non-rectangular pet silhouette (the hosted
/// SwiftUI/AppKit content decides hit-testing per-pixel).
///
/// This mirrors the app's shell convention: AppKit only at the window boundary;
/// the content is an `NSHostingView` of SwiftUI, installed by the controller.
final class PetPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultSize.width, height: Self.defaultSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    /// Default content size = one atlas cell (192×208) with a little breathing
    /// room. The controller resizes to the active pet's cell on mount.
    static let defaultSize = CGSize(width: 192, height: 208)

    private func configure() {
        // Float over fullscreen, on every Space, and don't get cycled by the
        // window switcher. `.stationary` keeps it from sliding with Exposé.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false

        // Transparent backing — only the pet pixels are visible.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Never take key/main; never participate in the responder/focus chain so
        // the user's frontmost app keeps focus when the pet is summoned.
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false

        // Released-when-closed off so the controller can cache and reuse it,
        // matching the app's WindowManager convention.
        isReleasedWhenClosed = false
    }

    // The pet panel never carries text input (the chat bubble is a SEPARATE
    // panel, PetBubblePanel, which is the only one allowed to become key). The
    // pet idle must NEVER steal key focus from the user's frontmost app —
    // returning true here let a pet click grab the keyboard, intercepting
    // typing for legitimate OS/computer requests. Return false so the user's
    // real app keeps key focus even while clicking/interacting with the pet.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Placement

    /// Re-assert the floating level (call on Space change so the pet never sinks
    /// behind a newly-activated fullscreen Space — PLAN C9).
    func reassertLevel() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        orderFrontRegardless()
    }

    /// Clamp the panel's frame so it stays fully inside `screen`'s visible frame.
    /// On display reconfigure the panel can be stranded off-screen; this returns
    /// it to the nearest in-bounds position (PLAN C9 multi-display).
    func clamp(to screen: NSScreen?) {
        guard let visible = (screen ?? bestScreen)?.visibleFrame else { return }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        setFrame(f, display: true)
    }

    /// The screen the panel mostly lives on (most overlapping area), else the
    /// main screen.
    var bestScreen: NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        return screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        } ?? NSScreen.main
    }

    /// Park the pet at a sensible default: lower-trailing corner of the active
    /// screen, on the foot baseline, with a small inset.
    func moveToDefaultCorner(on screen: NSScreen? = nil) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let inset: CGFloat = 24
        let origin = CGPoint(
            x: visible.maxX - frame.width - inset,
            y: visible.minY + inset
        )
        setFrameOrigin(origin)
    }
}

// MARK: - Geometry helper

private extension CGRect {
    var area: CGFloat { width * height }
}
