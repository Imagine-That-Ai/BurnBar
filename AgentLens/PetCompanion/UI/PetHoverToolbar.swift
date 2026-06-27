import AppKit
import SwiftUI

// MARK: - PetHoverToolbar
//
// The Liquid Glass control bar that fades in above the founder on hover (PLAN C8
// follow-up). It exposes the three live-companion controls the desktop pet was
// missing — **Emote**, **Resize**, and **Change Avatar** — without a native gray
// context menu, so the whole surface reads as one stunning glass pill. It owns no
// state beyond a local "emote flyout open" toggle; every action is a closure the
// `PetCompanionController` wires to its existing seams (`drive(to:)`,
// `resizePet(by:)`, `PetFormPickerView` via `PetLibraryWindowPresenter`).

struct PetHoverToolbarView: View {
    /// One emote = a logical pose the founder can strike on demand.
    struct Emote: Identifiable {
        var emoji: String
        var label: String
        var state: PetLogicalState
        var id: String { state.rawValue }
    }

    /// The founder's name, used for the toolbar's accessibility label.
    var title: String
    var emotes: [Emote]
    var onEmote: (PetLogicalState) -> Void
    /// Multiplicative resize factor (>1 grows, <1 shrinks).
    var onResize: (CGFloat) -> Void
    var onResizeReset: () -> Void
    var onChangeAvatar: () -> Void

    @State private var showEmotes = false

    /// Glass-edge highlight shared by both pills.
    private static let sheen = LinearGradient(
        colors: [.white.opacity(0.42), .white.opacity(0.05), .white.opacity(0.16)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        LiquidGlassGroup(spacing: DesignSystem.Spacing.xs) {
            VStack(spacing: DesignSystem.Spacing.xs) {
                if showEmotes {
                    emoteFlyout
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
                mainBar
            }
        }
        .animation(DesignSystem.Animation.gentle, value: showEmotes)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) controls")
    }

    // MARK: Main bar

    private var mainBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            PetToolbarIconButton(
                systemName: "face.smiling",
                help: "Emote",
                isActive: showEmotes
            ) { withAnimation(DesignSystem.Animation.gentle) { showEmotes.toggle() } }

            divider

            PetToolbarIconButton(systemName: "minus", help: "Smaller") { onResize(0.85) }
            PetToolbarIconButton(systemName: "arrow.counterclockwise", help: "Reset size") { onResizeReset() }
            PetToolbarIconButton(systemName: "plus", help: "Bigger") { onResize(1.18) }

            divider

            PetToolbarIconButton(systemName: "theatermasks", help: "Change avatar") {
                showEmotes = false
                onChangeAvatar()
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .liquidGlassSurface(in: Capsule(), fallback: .regularMaterial)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(Self.sheen, lineWidth: 1) }
        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 5)
    }

    // MARK: Emote flyout

    private var emoteFlyout: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(emotes) { emote in
                Button {
                    onEmote(emote.state)
                    withAnimation(DesignSystem.Animation.gentle) { showEmotes = false }
                } label: {
                    Text(emote.emoji)
                        .font(.system(size: 18))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(PetToolbarEmoteButtonStyle())
                .help(emote.label)
                .accessibilityLabel(emote.label)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .liquidGlassSurface(in: Capsule(), fallback: .regularMaterial)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(Self.sheen, lineWidth: 1) }
        .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.5))
            .frame(width: 1, height: 16)
    }

    /// The curated emote set every founder can strike (poses fall back to the
    /// pet's default state when a definition lacks a clip, per `PetRenderer`).
    static let defaultEmotes: [Emote] = [
        .init(emoji: "✨", label: "React", state: .react),
        .init(emoji: "💬", label: "Speak", state: .speak),
        .init(emoji: "🤔", label: "Think", state: .think),
        .init(emoji: "🚶", label: "Wander", state: .wander),
        .init(emoji: "😴", label: "Sleep", state: .sleep)
    ]
}

// MARK: - Buttons

/// A monochrome glass-toolbar icon button (the new design renders toolbar icons
/// monochrome on the glass; a faint hover plate gives the press affordance).
private struct PetToolbarIconButton: View {
    let systemName: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                                          : AnyShapeStyle(DesignSystem.Colors.textPrimary))
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(DesignSystem.Colors.textPrimary.opacity(isHovering ? 0.12 : 0))
                        .overlay {
                            if isActive {
                                Circle().fill(DesignSystem.Colors.primaryGradient.opacity(0.16))
                            }
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Emote chip press style: a gentle pop on press so the emoji "fires".
private struct PetToolbarEmoteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - PetToolbarPanel

/// Floating host panel for the hover toolbar — a sibling of ``PetPanel`` and
/// ``PetBubblePanel`` (transparent, non-activating, all-Spaces) anchored just
/// above the founder. It never takes key focus: its controls are plain clicks.
final class PetToolbarPanel: NSPanel {
    private var hosting: NSHostingView<AnyView>?
    private let onHoverChange: (Bool) -> Void

    init(onHoverChange: @escaping (Bool) -> Void) {
        self.onHoverChange = onHoverChange
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI pills draw their own shadow
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func host<Content: View>(_ view: Content) {
        let root = AnyView(view.fixedSize())
        // A tracking container reports pointer hover on the toolbar itself (an
        // NSTrackingArea, not SwiftUI `.onHover`, so it fires reliably inside a
        // non-activating panel), keeping the bar alive while the user reaches up
        // from the founder to click it.
        let container: PetPanelHoverView
        if let existing = contentView as? PetPanelHoverView {
            container = existing
        } else {
            let tracking = PetPanelHoverView()
            tracking.onHoverChange = onHoverChange
            contentView = tracking
            container = tracking
        }
        if let hosting {
            hosting.rootView = root
        } else {
            let hostingView = NSHostingView(rootView: root)
            hostingView.translatesAutoresizingMaskIntoConstraints = true
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = container.bounds
            container.addSubview(hostingView)
            hosting = hostingView
        }
        resizeToContent()
    }

    func resizeToContent() {
        guard let hosting else { return }
        let fitting = hosting.fittingSize
        setContentSize(NSSize(
            width: fitting.width > 0 ? fitting.width : 240,
            height: fitting.height > 0 ? fitting.height : 64
        ))
        hosting.frame = contentView?.bounds ?? hosting.frame
    }

    func clamp(to screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width - 8 }
        if f.minX < visible.minX { f.origin.x = visible.minX + 8 }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height - 8 }
        if f.minY < visible.minY { f.origin.y = visible.minY + 8 }
        setFrameOrigin(f.origin)
    }
}

// MARK: - PetPanelHoverView

/// The founder panel's content view, instrumented with a tracking area so the
/// controller knows when the pointer enters/leaves the creature (to fade the
/// hover toolbar in and out). A plain `NSView` host: the renderer mounts into it
/// exactly as before, and clicks still reach the renderer's click gesture.
final class PetPanelHoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

// MARK: - PetLibraryWindowPresenter

/// Opens the founder library (the existing ``PetFormPickerView`` gallery) in a
/// standalone window for the hover toolbar's "Change Avatar" action — switching
/// founder and toggling 2D/3D form, reusing ``PetCompanionFeature/selectPet``.
@MainActor
enum PetLibraryWindowPresenter {
    private static var window: NSWindow?

    static func open(selectedPetID: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = PetLibraryView(
            initialSelection: selectedPetID,
            onClose: {
                window?.close()
                window = nil
            }
        )

        let libraryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        libraryWindow.title = "Change Avatar"
        libraryWindow.titleVisibility = .hidden
        libraryWindow.titlebarAppearsTransparent = true
        libraryWindow.backgroundColor = NSColor(DesignSystem.Colors.background)
        libraryWindow.contentView = NSHostingView(rootView: view)
        libraryWindow.center()
        libraryWindow.isReleasedWhenClosed = false
        libraryWindow.makeKeyAndOrderFront(nil)

        window = libraryWindow
    }
}

/// Window content for the founder library: the shared picker plus a header.
private struct PetLibraryView: View {
    @State private var selectedPetID: String
    var onClose: () -> Void

    init(initialSelection: String, onClose: @escaping () -> Void) {
        _selectedPetID = State(initialValue: initialSelection)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Change Avatar")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Pick a founder and its 2D or 3D form — your desktop companion swaps live.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }

            PetFormPickerView(
                definitions: PetCatalog.bundledDefinitions(),
                selectedPetID: $selectedPetID
            ) { id, form in
                PetCompanionFeature.selectPet(id: id, form: form)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(minWidth: 540, minHeight: 580)
        .background(DesignSystem.Colors.background)
    }
}
