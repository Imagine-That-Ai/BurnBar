import AppKit
import SwiftUI

// MARK: - PetBubblePanel

/// The floating host panel for the frosted chat bubble (PLAN C5). It is a sibling
/// of ``PetPanel`` — a separate, transparent, all-Spaces panel positioned just
/// above the pet's contact socket — so the bubble can size and reposition without
/// resizing the creature, and so it can become **key** for text input while the
/// pet panel stays a non-activating, focus-preserving float.
///
/// Mirrors the app's shell convention: AppKit only at the window boundary; the
/// content is an `NSHostingView` of ``PetChatBubbleView``. The bubble auto-sizes
/// to its SwiftUI content via `NSHostingView`'s fitting size, and the controller
/// re-anchors it whenever it is shown.
final class PetBubblePanel: NSPanel {

    /// The hosting view wrapping the SwiftUI bubble (rebuilt when chat is hosted).
    private var hosting: NSHostingView<AnyView>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        // Sit a hair above the pet so the bubble overlaps cleanly if they touch.
        level = .floating
        hidesOnDeactivate = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI bubble draws its own shadow
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    // The bubble carries a text field, so it must be able to take key focus —
    // unlike the pet panel, which never does. It still never becomes *main*, so
    // the user's frontmost app keeps its main-window status.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Hosting

    /// Install (or refresh) the SwiftUI bubble bound to `chat`, sizing the panel
    /// to the content's fitting size. `tailAnchorX` (0...1) points the speech-
    /// bubble tail at the pet's contact socket so the bubble's tail tracks the
    /// pet rather than always pointing at the bubble centre.
    func host(chat: PetChatController, tailAnchorX: CGFloat = 0.5, onContentSizeChange: @escaping () -> Void = {}) {
        let clamped = min(0.85, max(0.15, tailAnchorX))
        let root = AnyView(
            PetChatBubbleView(
                controller: chat,
                tailAnchorX: clamped,
                onContentSizeChange: { [weak self] in
                    self?.resizeToContent()
                    onContentSizeChange()
                }
            )
            .fixedSize(horizontal: false, vertical: true)
        )

        if let hosting {
            hosting.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.translatesAutoresizingMaskIntoConstraints = true
            contentView = view
            hosting = view
        }
        resizeToContent()
    }

    /// Resize the panel to the SwiftUI content's fitting size (called before the
    /// controller positions it).
    func resizeToContent() {
        guard let hosting else { return }
        let fitting = hosting.fittingSize
        let size = NSSize(
            width: fitting.width > 0 ? fitting.width : 300,
            height: fitting.height > 0 ? fitting.height : 160
        )
        setContentSize(size)
    }

    /// Clamp the bubble fully inside `screen`'s visible frame so it never spills
    /// off the top/edge when the pet is near a corner.
    func clamp(to screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width - 8 }
        if f.minX < visible.minX { f.origin.x = visible.minX + 8 }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height - 8 }
        if f.minY < visible.minY { f.origin.y = visible.minY + 8 }
        setFrame(f, display: true)
    }
}
