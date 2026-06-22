import AppKit
import Combine
import Foundation

// MARK: - PetCompanionController

/// The coordinator that owns the floating ``PetPanel``, a ``PetRenderer``, and a
/// ``BehaviorInterpreter``, and drives the ambient state loop. It is the single
/// seam the app shell talks to (`start/stop/show/hide/setForm`), independent of
/// the three existing `NSWindow`s in `WindowManager` (separate cached panel), so
/// it cannot disturb dashboard/settings/onboarding.
///
/// `@MainActor`, owned by ``PetCompanionRuntime``. It uses legacy
/// `ObservableObject` for parity with `WindowManager` (the menubar toggle
/// observes `isVisible`).
@MainActor
final class PetCompanionController: ObservableObject {
    /// Whether the pet panel is currently on screen.
    @Published private(set) var isVisible = false
    /// Whether the ambient behavior loop is running.
    @Published private(set) var isRunning = false
    /// The current logical state being rendered (mirrors the interpreter).
    @Published private(set) var currentState: String = PetLogicalState.idle.rawValue

    /// Injectable factory so tests / future backends pick the renderer for a
    /// form. Defaults to the placeholder until C4/C5 register real backends.
    var rendererFactory: (PetDefinition, PetForm) -> PetRenderer = { def, form in
        PlaceholderPetRenderer(definition: def, form: form)
    }

    private var panel: PetPanel?
    private var renderer: PetRenderer?
    private var definition: PetDefinition?
    private var interpreter: BehaviorInterpreter?
    private var form: PetForm?

    // MARK: Chat bubble wiring (C5/C7)

    /// The conversational controller, present once the host injects the shared
    /// ``ChatSessionController`` via ``attachChat(_:)``. `nil` until then, so the
    /// pet runs ambient-only (e.g. before the app's chat stack is built).
    private(set) var chat: PetChatController?
    /// The separate floating panel that hosts the frosted chat bubble above the
    /// pet. Kept independent of the pet panel so the bubble can size/position
    /// freely without resizing the creature.
    private var bubblePanel: PetBubblePanel?
    /// Click monitor installed on the pet panel to open/toggle the bubble.
    private var clickGesture: NSClickGestureRecognizer?
    /// NSObject shim that carries the gesture's `@objc` action into this
    /// (non-NSObject) controller.
    private var clickTarget: PetClickTarget?
    /// Gesture gate that keeps empty renderer pixels click-through.
    private var clickGestureGate: PetClickGestureGate?

    /// Ambient tick that feeds time-driven triggers (`cooldownElapsed`,
    /// `idleElapsed`) into the interpreter. Paused alongside the renderer.
    private var ambientTimer: Timer?

    init() {}

    // MARK: Lifecycle

    /// Load `definition`, build the panel + renderer, and start the ambient loop.
    /// Safe to call repeatedly; re-uses the cached panel like `WindowManager`.
    func start(with definition: PetDefinition, form requestedForm: PetForm? = nil) {
        self.definition = definition
        let resolved = requestedForm ?? definition.defaultForm
        guard let resolvedForm = resolved else { return }
        self.form = resolvedForm

        let panel = panel ?? makePanel()
        self.panel = panel

        let renderer = rendererFactory(definition, resolvedForm)
        self.renderer = renderer
        if let content = panel.contentView {
            renderer.mount(in: content)
            installClickGesture(on: renderer.view)
        }

        if let graph = definition.behavior {
            interpreter = BehaviorInterpreter(graph: graph, seed: Self.seed())
            currentState = interpreter?.current ?? PetLogicalState.idle.rawValue
        } else {
            interpreter = nil
            currentState = definition.atlas2d?.defaultState ?? PetLogicalState.idle.rawValue
        }
        renderer.play(state: currentState)

        isRunning = true
        startAmbientLoop()
    }

    /// Stop the loop, unmount the renderer, and hide the panel. The panel stays
    /// cached for a fast `start()` again.
    func stop() {
        stopAmbientLoop()
        renderer?.unmount()
        renderer = nil
        interpreter = nil
        isRunning = false
        hide()
    }

    // MARK: Visibility

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.moveToDefaultCorner(on: panel.bestScreen)
        panel.orderFrontRegardless()
        isVisible = true
        setPaused(false)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        setPaused(true)
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: Form swap (C8)

    /// Swap the rendered form (2D ↔ 3D) without tearing down the panel, keeping
    /// the currently-playing logical state.
    func setForm(_ newForm: PetForm) {
        guard let definition else { return }
        self.form = newForm
        if let renderer {
            renderer.setForm(newForm)
        } else if let content = panel?.contentView {
            let r = rendererFactory(definition, newForm)
            renderer = r
            r.mount(in: content)
            r.play(state: currentState)
        }
    }

    // MARK: Behavior driving

    /// Feed an external trigger (cursor proximity, chat events) into the graph and
    /// reflect the resulting state in the renderer.
    func fire(_ trigger: PetBehaviorTrigger) {
        guard interpreter != nil else { return }
        if let next = interpreter?.fire(trigger) {
            currentState = next
            renderer?.play(state: next)
        }
    }

    /// Drive the pet to a logical state directly (e.g. chat pipeline mapping
    /// send→`think`, tokens→`speak`, fallback→`react`). Does not consult the
    /// graph; used when the host owns the transition.
    func drive(to state: PetLogicalState) {
        currentState = state.rawValue
        renderer?.play(state)
    }

    // MARK: Energy gating (PLAN §4, C9)

    /// Pause/resume the renderer and the ambient loop together. Called by the
    /// system observers on occlusion / display sleep / screen lock.
    func setPaused(_ paused: Bool) {
        renderer?.setPaused(paused)
        if paused {
            stopAmbientLoop()
        } else if isRunning, isVisible {
            startAmbientLoop()
        }
    }

    /// Re-clamp to the active screen after a display reconfigure (C9).
    func handleScreenParametersChanged() {
        panel?.clamp(to: panel?.bestScreen)
    }

    /// Re-assert the floating level on a Space change (C9).
    func handleActiveSpaceChanged() {
        guard isVisible else { return }
        panel?.reassertLevel()
    }

    func setReducedMotion(_ reduced: Bool) {
        renderer?.setReducedMotion(reduced)
    }

    // MARK: Chat bubble (C5/C7)

    /// Inject the app's **shared** ``ChatSessionController`` (Ground Truth #2 — do
    /// not duplicate the agent layer). Builds the ``PetChatController`` that the
    /// bubble binds to. Call once from the launch hook where the shared chat
    /// controller is live. Idempotent.
    func attachChat(_ session: ChatSessionController) {
        guard chat == nil else { return }
        chat = PetChatController(chat: session, pet: self) { [weak self] in
            self?.closeBubble()
        }
    }

    /// Open (or focus) the chat bubble: brings up the bubble panel anchored above
    /// the pet and tells the chat controller to listen. No-op without a chat.
    func openBubble() {
        guard let chat else { return }
        chat.open()
        presentBubble(for: chat)
    }

    /// Close the chat bubble and settle the pet.
    func closeBubble() {
        chat?.close()
        bubblePanel?.orderOut(nil)
    }

    /// Handle a pet click: toggle the bubble. Falls back to a celebratory `react`
    /// beat when chat isn't attached (so a click is never inert). Invoked by the
    /// ``PetClickTarget`` NSObject shim below (the gesture's `@objc` action must
    /// live on an NSObject; this controller is a plain `ObservableObject`).
    func handlePetClick() {
        guard let chat else { drive(to: .react); return }
        if chat.isOpen {
            closeBubble()
        } else {
            openBubble()
        }
    }

    private func installClickGesture(on view: NSView) {
        // Replace any prior recognizer (renderer view may have been swapped).
        if let old = clickGesture { old.view?.removeGestureRecognizer(old) }
        let target = clickTarget ?? PetClickTarget { [weak self] in self?.handlePetClick() }
        clickTarget = target
        let gate = PetClickGestureGate { [weak self] point, view in
            guard let self, let renderer = self.renderer, renderer.view === view else { return true }
            return renderer.containsVisibleContent(at: point)
        }
        clickGestureGate = gate
        let gesture = NSClickGestureRecognizer(target: target, action: #selector(PetClickTarget.fire))
        gesture.numberOfClicksRequired = 1
        gesture.delegate = gate
        view.addGestureRecognizer(gesture)
        clickGesture = gesture
    }

    /// Build/show the bubble panel and anchor it to the pet's contact socket.
    private func presentBubble(for chat: PetChatController) {
        let bubble = bubblePanel ?? PetBubblePanel()
        bubblePanel = bubble
        bubble.host(chat: chat, anchorProvider: { [weak self] in self?.bubbleAnchorPoint() })
        anchorBubble(bubble)
        bubble.orderFront(nil)
    }

    /// The on-screen point (screen coords) the bubble tail should aim at: the pet
    /// renderer's `"contact"` socket projected up from the pet panel.
    private func bubbleAnchorPoint() -> CGPoint? {
        guard let panel, let renderer else { return nil }
        let viewPoint = renderer.socketPoint("contact")
            ?? CGPoint(x: renderer.view.bounds.midX, y: renderer.view.bounds.maxY)
        let windowPoint = renderer.view.convert(viewPoint, to: nil)
        return panel.convertPoint(toScreen: windowPoint)
    }

    /// Position the bubble panel just above the pet's contact socket.
    private func anchorBubble(_ bubble: PetBubblePanel) {
        guard let anchor = bubbleAnchorPoint() else { return }
        bubble.resizeToContent()
        let size = bubble.frame.size
        // Center the bubble horizontally over the anchor, sit it above with a gap.
        let origin = CGPoint(
            x: anchor.x - size.width / 2,
            y: anchor.y + 12
        )
        bubble.setFrameOrigin(origin)
        bubble.clamp(to: panel?.bestScreen)
    }

    // MARK: Private

    private func makePanel() -> PetPanel {
        let panel = PetPanel()
        if panel.contentView == nil {
            panel.contentView = NSView(frame: NSRect(origin: .zero, size: PetPanel.defaultSize))
        }
        if let atlas = definition?.atlas2d {
            panel.setContentSize(NSSize(width: atlas.cell.w, height: atlas.cell.h))
        }
        return panel
    }

    private func startAmbientLoop() {
        guard ambientTimer == nil, isVisible, isRunning else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ambientTick() }
        }
        timer.tolerance = 0.5 // energy-friendly coalescing
        ambientTimer = timer
    }

    private func stopAmbientLoop() {
        ambientTimer?.invalidate()
        ambientTimer = nil
    }

    /// One ambient step: offer the time-driven triggers the current node accepts.
    private func ambientTick() {
        guard let interpreter, let graph = definition?.behavior else { return }
        let timeDriven: [PetBehaviorTrigger] = [.cooldownElapsed, .idleElapsed]
        for trigger in graph.triggers(from: interpreter.current) where timeDriven.contains(trigger) {
            fire(trigger)
            break
        }
    }

    /// Deterministic-enough ambient seed (time-derived). Tests inject their own.
    private static func seed() -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970)) | 1
    }
}

// MARK: - PlaceholderPetRenderer

/// A no-op renderer used until the SpriteKit (C4) / SceneKit (C5) backends are
/// registered. It satisfies the protocol so the panel + behavior loop are
/// exercisable today; it draws nothing and burns no CPU.
@MainActor
final class PlaceholderPetRenderer: PetRenderer {
    let definition: PetDefinition
    private(set) var form: PetForm
    let view: NSView

    init(definition: PetDefinition, form: PetForm) {
        self.definition = definition
        self.form = form
        self.view = NSView(frame: NSRect(origin: .zero, size: PetPanel.defaultSize))
        self.view.wantsLayer = true
    }

    func mount(in container: NSView) {
        guard view.superview !== container else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    func unmount() { view.removeFromSuperview() }
    func play(state: String) {}
    func setForm(_ form: PetForm) { self.form = form }
    func setFacing(_ direction: CGFloat) {}
    func setPaused(_ paused: Bool) {}
    func setAmbientFrameRate(_ fps: Int) {}
}

// MARK: - PetClickTarget

/// A tiny `NSObject` shim so an `NSClickGestureRecognizer` (which needs an
/// `@objc` target/action) can drive ``PetCompanionController``, which is a plain
/// `ObservableObject` (not an `NSObject`). Holds a closure and exposes one
/// `@objc` method the recognizer calls.
@MainActor
final class PetClickTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

@MainActor
private final class PetClickGestureGate: NSObject, NSGestureRecognizerDelegate {
    private let shouldAccept: (CGPoint, NSView) -> Bool

    init(_ shouldAccept: @escaping (CGPoint, NSView) -> Bool) {
        self.shouldAccept = shouldAccept
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldReceive event: NSEvent) -> Bool {
        guard let view = gestureRecognizer.view else { return false }
        return shouldAccept(view.convert(event.locationInWindow, from: nil), view)
    }
}
