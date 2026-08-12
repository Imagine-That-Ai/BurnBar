import AppKit
import Combine
import CoreGraphics
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
    /// Observes the pet panel's move/resize notifications so the chat bubble
    /// follows the pet as it is dragged around the screen.
    private var panelFrameObserver: NSObjectProtocol?

    // MARK: Chat bubble wiring (C5/C7)

    /// The conversational controller, present once the host injects the shared
    /// ``ChatSessionController`` via ``attachChat(_:)``. `nil` until then, so the
    /// pet runs ambient-only (e.g. before the app's chat stack is built).
    private(set) var chat: PetChatController?
    /// The separate floating panel that hosts the frosted chat bubble above the
    /// pet. Kept independent of the pet panel so the bubble can size/position
    /// freely without resizing the creature.
    private var bubblePanel: PetBubblePanel?
    /// The Liquid Glass hover toolbar (emote / resize / change avatar) that fades
    /// in above the founder. A sibling float like the bubble.
    private var toolbarPanel: PetToolbarPanel?
    /// Pointer-hover bookkeeping for the toolbar: it stays up while the pointer is
    /// over the founder OR the toolbar itself, with a short hide debounce so the
    /// gap between them never flickers it away.
    private var hoverOverPet = false
    private var hoverOverToolbar = false
    private var toolbarHideTask: Task<Void, Never>?
    /// Click monitor installed on the pet panel to open/toggle the bubble.
    private var clickGesture: NSClickGestureRecognizer?
    /// NSObject shim that carries the gesture's `@objc` action into this
    /// (non-NSObject) controller.
    private var clickTarget: PetClickTarget?
    /// Gesture gate that keeps empty renderer pixels click-through.
    private var clickGestureGate: PetClickGestureGate?
    /// File drag-and-drop delegate installed on the current renderer view so a
    /// drop anywhere on the desktop pet stages the file as a chat attachment on
    /// the shared ``ChatSessionController`` (and opens the bubble to show it).
    /// Re-installed on every renderer view swap alongside the click gesture so a
    /// 2D↔3D form swap keeps the drop target live.
    ///
    /// The controller is the sole owner of the delegate; the renderer views hold
    /// it weakly, so this strong reference is what keeps the drop target alive.
    /// reason: a weak ref here would deallocate the sole-owned delegate at once.
    private var attachmentDropDelegate: PetAttachmentDropDelegate? // swiftlint:disable:this weak_delegate
    /// Observes the pet panel's frame so sibling panels (chat bubble, toolbar)
    /// stay attached while the renderer drags/resizes the pet window directly.
    private var panelFrameObservers: [NSObjectProtocol] = []

    /// Ambient tick that feeds time-driven triggers (`cooldownElapsed`,
    /// `idleElapsed`) into the interpreter. Paused alongside the renderer.
    private var ambientTimer: Timer?
    private var lastInteractionAt = Date()
    private var lastTypingAt: Date?
    private var isAgentBusy = false
    private var appFocused = NSApp.isActive
    private var osIdle = false
    private var lastIntent: PetMessageIntent?
    private var lastIntentAt: Date?
    private var repeatedIntentCount = 0
    private var lastOutcome: PetTaskOutcome?
    private var lastOutcomeAt: Date?
    private var lastAmbientReactionAt = Date.distantPast

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
        observePanelFrame(panel)

        renderer?.unmount()
        renderer = nil
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
        resetReactionState()
        renderer.play(state: currentState)

        isRunning = true
        startAmbientLoop()
    }

    /// Stop the loop, unmount the renderer, and hide the panel. The panel stays
    /// cached for a fast `start()` again.
    func stop() {
        stopAmbientLoop()
        stopObservingPanelFrame()
        renderer?.unmount()
        renderer = nil
        interpreter = nil
        isRunning = false
        removePanelFrameObservers()
        hide()
    }

    // MARK: Visibility

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Restore a user-positioned/resized frame if one was saved for this pet,
        // clamped on-screen; otherwise park it in the default corner.
        if let id = definition?.id, let frame = PetWindowState.storedFrame(for: id) {
            panel.setFrame(frame, display: false)
            panel.clamp(to: panel.bestScreen)
        } else {
            panel.moveToDefaultCorner(on: panel.bestScreen)
        }
        panel.orderFrontRegardless()
        isVisible = true
        setPaused(false)
        startObservingPanelFrame()
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        setPaused(true)
        hoverOverPet = false
        hoverOverToolbar = false
        toolbarHideTask?.cancel()
        toolbarHideTask = nil
        dismissToolbar()
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
        let previousForm = form
        self.form = newForm
        if let renderer, previousForm?.isAtlas == newForm.isAtlas {
            renderer.setForm(newForm)
        } else if let content = panel?.contentView {
            renderer?.unmount()
            let r = rendererFactory(definition, newForm)
            renderer = r
            r.mount(in: content)
            r.play(state: currentState)
            r.setPaused(!isVisible || !isRunning)
            installClickGesture(on: r.view)
        }
    }

    /// Swap to a different pet definition and renderer while keeping the panel
    /// alive. Used by the dynamic picker when the selected id changes.
    func setPet(_ newDefinition: PetDefinition, form requestedForm: PetForm? = nil) {
        definition = newDefinition
        guard let resolvedForm = requestedForm ?? newDefinition.defaultForm else { return }
        form = resolvedForm

        if let graph = newDefinition.behavior {
            interpreter = BehaviorInterpreter(graph: graph, seed: Self.seed())
            currentState = interpreter?.current ?? PetLogicalState.idle.rawValue
        } else {
            interpreter = nil
            currentState = newDefinition.atlas2d?.defaultState ?? PetLogicalState.idle.rawValue
        }
        resetReactionState()

        renderer?.unmount()
        renderer = nil
        guard let content = panel?.contentView else { return }
        let nextRenderer = rendererFactory(newDefinition, resolvedForm)
        renderer = nextRenderer
        nextRenderer.mount(in: content)
        installClickGesture(on: nextRenderer.view)
        nextRenderer.play(state: currentState)
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
        drive(to: state.rawValue)
    }

    /// Drive to any semantic clip/state name produced by the reaction brain.
    func drive(to state: String, force: Bool = false) {
        guard force || state != currentState else { return }
        currentState = state
        renderer?.play(state: state)
    }

    @discardableResult
    func recordUserMessage(_ text: String) -> PetMessageIntent {
        let now = Date()
        let intent = PetReactionBrain.classifyMessage(text)
        if intent == lastIntent, let lastIntentAt, now.timeIntervalSince(lastIntentAt) < 30 {
            repeatedIntentCount += 1
        } else {
            repeatedIntentCount = 1
        }
        lastIntent = intent
        lastIntentAt = now
        lastInteractionAt = now
        lastOutcome = nil
        lastOutcomeAt = nil
        isAgentBusy = true
        resolveReaction(force: true)
        return intent
    }

    func recordUserTyping() {
        let now = Date()
        lastTypingAt = now
        lastInteractionAt = now
        resolveReaction(force: false)
    }

    func noteAgentBusy(_ busy: Bool) {
        isAgentBusy = busy
        resolveReaction(force: busy)
    }

    func recordTaskOutcome(_ outcome: PetTaskOutcome) {
        lastOutcome = outcome
        lastOutcomeAt = Date()
        isAgentBusy = false
        resolveReaction(force: true)
    }

    func setAppFocused(_ focused: Bool) {
        appFocused = focused
        resolveReaction(force: true)
    }

    func setSystemIdle(_ idle: Bool) {
        osIdle = idle
        resolveReaction(force: true)
    }

    // MARK: Energy gating (PLAN §4, C9)

    /// Pause/resume the renderer and the ambient loop together. Called by the
    /// system observers on occlusion / display sleep / screen lock.
    func setPaused(_ paused: Bool) {
        let shouldPause = paused || !isRunning || !isVisible
        renderer?.setPaused(shouldPause)
        if shouldPause {
            stopAmbientLoop()
        } else {
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

    /// Whether the pet persona voice override is enabled (per-app UserDefaults,
    /// default ON). The chat controller gates both the cloud persona override AND
    /// the local fallback voice-lines behind this so a user can turn the in-
    /// character voice off without changing pets.
    var personaVoiceEnabled: Bool {
        PetCompanionFeature.personaVoiceEnabled
    }

    /// Toggle the persona voice override on/off and persist it.
    func setPersonaVoiceEnabled(_ enabled: Bool) {
        PetCompanionFeature.setPersonaVoiceEnabled(enabled)
    }

    /// The active pet's chat voice (`agent.persona`), or `nil` when the loaded
    /// definition carries none OR when the persona voice override is toggled off.
    /// The bubble's ``PetChatController`` reads this at send time and overrides
    /// the shared controller's trusted persona block so answers land in this
    /// pet's voice; a `nil` keeps the default prompt.
    var activeChatPersona: String? {
        guard personaVoiceEnabled else { return nil }
        return definition?.agent?.persona
    }

    /// The chosen pet's human name (e.g. "Sam Altman"), for chat chrome that should
    /// address the pet by name rather than "the pet". Falls back to the id, then a
    /// gentle default when no pet is mounted.
    var displayName: String {
        definition?.displayName ?? definition?.name ?? "your companion"
    }

    /// The pet's BurnBar persona voice-lines (enter/work/cheer/exit), decoded from
    /// the petdef `agent.voiceLines` JSON string. The local chat floor uses these
    /// to answer IN CHARACTER (and on BurnBar's domain) when no AI provider replies.
    /// Returns `nil` when the persona voice override is toggled off so the local
    /// floor falls back to the generic guide voice.
    var voiceLines: [String: [String]]? {
        guard personaVoiceEnabled else { return nil }
        guard let raw = definition?.agent?.voiceLines,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data),
              !decoded.isEmpty
        else { return nil }
        return decoded
    }

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
        // The bubble owns the space above the founder while chatting, so fold the
        // hover toolbar away (it returns on the next hover once the bubble closes).
        dismissToolbar()
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
        lastInteractionAt = Date()
        guard let chat else { drive(to: .react); return }
        if chat.isOpen {
            closeBubble()
        } else {
            openBubble()
        }
    }

    // MARK: Right-click context menu

    /// Build the elegant pet context menu (emotes / chat / size / persona / reset).
    /// Uses a native `NSMenu` so it reads as AppKit chrome, not a SwiftUI popover.
    private func buildPetContextMenu(at point: CGPoint, in view: NSView) -> NSMenu {
        let menu = NSMenu(title: "Pet")
        menu.autoenablesItems = false

        // Emote submenu — pick from the pet's available reaction clips.
        if let emotes = availableEmotes(), !emotes.isEmpty {
            let emoteItem = menu.addItem(withTitle: "Emote", action: nil, keyEquivalent: "")
            emoteItem.submenu = emoteMenu(emotes)
        } else {
            let wave = menu.addItem(withTitle: "Wave", action: #selector(petMenuWave), keyEquivalent: "")
            wave.target = self
        }

        menu.addItem(.separator())

        let chatItem = menu.addItem(
            withTitle: (chat?.isOpen ?? false) ? "Close Chat" : "Open Chat",
            action: #selector(petMenuToggleChat),
            keyEquivalent: ""
        )
        chatItem.target = self

        menu.addItem(.separator())

        let grow = menu.addItem(withTitle: "Grow Pet", action: #selector(petMenuGrowPet), keyEquivalent: "+")
        grow.target = self
        let shrink = menu.addItem(withTitle: "Shrink Pet", action: #selector(petMenuShrinkPet), keyEquivalent: "-")
        shrink.target = self

        let growChat = menu.addItem(withTitle: "Grow Chat", action: #selector(petMenuGrowChat), keyEquivalent: "=")
        growChat.target = self
        let shrinkChat = menu.addItem(withTitle: "Shrink Chat", action: #selector(petMenuShrinkChat), keyEquivalent: "_")
        shrinkChat.target = self

        menu.addItem(.separator())

        let personaTitle = personaVoiceEnabled ? "Pet Voice: On" : "Pet Voice: Off"
        let persona = menu.addItem(
            withTitle: personaTitle,
            action: #selector(petMenuTogglePersona),
            keyEquivalent: ""
        )
        persona.target = self

        let reset = menu.addItem(withTitle: "Reset View", action: #selector(petMenuReset), keyEquivalent: "")
        reset.target = self

        return menu
    }

    /// The pet's available emote/reaction clip names (semantic-first, fallback to
    /// raw clip names). Used to populate the Emote submenu.
    private func availableEmotes() -> [String]? {
        let names = availableReactionNames()
        let emoteOrder = ["wave", "cheer", "clap", "dance", "jump", "nod", "think", "surprised", "shrug", "sleep"]
        let ordered = emoteOrder.filter { names.contains($0) }
        if ordered.isEmpty { return nil }
        return ordered
    }

    private func emoteMenu(_ emotes: [String]) -> NSMenu {
        let sub = NSMenu(title: "Emote")
        sub.autoenablesItems = false
        for name in emotes {
            let item = sub.addItem(withTitle: name.capitalized, action: #selector(petMenuEmote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
        }
        return sub
    }

    // MARK: Context menu actions

    @objc private func petMenuWave() {
        drive(to: "greeting")
    }

    @objc private func petMenuEmote(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        drive(to: name, force: true)
    }

    @objc private func petMenuToggleChat() {
        guard let chat else { drive(to: .react); return }
        if chat.isOpen { closeBubble() } else { openBubble() }
    }

    @objc private func petMenuGrowPet() {
        resizePetPanel(by: 1.12)
    }

    @objc private func petMenuShrinkPet() {
        resizePetPanel(by: 1 / 1.12)
    }

    @objc private func petMenuGrowChat() {
        resizeChatBubble(by: 1.12)
    }

    @objc private func petMenuShrinkChat() {
        resizeChatBubble(by: 1 / 1.12)
    }

    @objc private func petMenuTogglePersona() {
        let next = !personaVoiceEnabled
        setPersonaVoiceEnabled(next)
    }

    @objc private func petMenuReset() {
        resetPetView()
    }

    /// Resize the floating pet panel by `factor` (works for both 2D and 3D
    /// forms — it scales the host window, which the renderer view fills).
    func resizePetPanel(by factor: CGFloat) {
        guard factor.isFinite, factor > 0, let panel else { return }
        let frame = panel.frame
        let aspect = frame.height / max(frame.width, 1)
        let minW: CGFloat = 110, maxW: CGFloat = 560
        let newWidth = min(maxW, max(minW, frame.width * factor))
        let newHeight = newWidth * aspect
        let origin = NSPoint(x: frame.midX - newWidth / 2, y: frame.minY)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: newWidth, height: newHeight)), display: true)
        panel.clamp(to: panel.bestScreen)
        if let id = definition?.id {
            PetWindowState.store(panel.frame, for: id)
        }
        // Re-anchor the bubble so it tracks the resized pet.
        reanchorBubble()
    }

    /// Resize the chat bubble by `factor` (scales the bubble panel width/height,
    /// clamped, re-anchored above the pet).
    func resizeChatBubble(by factor: CGFloat) {
        guard factor.isFinite, factor > 0, let chat, let bubble = bubblePanel else { return }
        chat.resizeBubbleWidth(by: factor)
        bubble.resizeToContent()
        reanchorBubble()
    }

    /// Reset the pet's view transform (yaw/scale for 3D; no-op for 2D).
    func resetPetView() {
        if let scn = renderer as? SceneKitPetRenderer {
            scn.resetModelView()
        }
        // 2D SpriteKit pets have no user view transform to reset.
        reanchorBubble()
    }

    /// Re-anchor the bubble to the (possibly moved/resized) pet. No-op if closed.
    func reanchorBubble() {
        guard let bubble = bubblePanel, bubble.isVisible, chat?.isOpen == true else { return }
        anchorBubble(bubble)
    }

    /// Observe the pet panel's move + resize notifications so the chat bubble
    /// tracks the pet as it is dragged around the screen (and re-anchors after a
    /// resize). Throttled via `DispatchQueue.main.async` so a rapid drag doesn't
    /// re-anchor on every single frame event.
    private func startObservingPanelFrame() {
        guard let panel, panelFrameObserver == nil else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reanchorBubble()
            }
        }
        let move = center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main, using: update)
        let resize = center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main, using: update)
        panelFrameObserver = TokenBox(tokens: [move, resize])
    }

    private func stopObservingPanelFrame() {
        guard let box = panelFrameObserver as? TokenBox else { return }
        let center = NotificationCenter.default
        box.tokens.forEach { center.removeObserver($0) }
        panelFrameObserver = nil
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

        // Wire file drag-and-drop onto the same view so a drop anywhere on the
        // desktop pet stages the file as a chat attachment on the shared
        // ChatSessionController (and opens the bubble to show it). Only views
        // that conform to PetDropHostingView (the SceneKit/SpriteKit renderer
        // subclasses) accept drops; a plain NSView (the placeholder) is skipped.
        installDropTarget(on: view)
        // Wire the elegant right-click context menu (emote / open-close chat /
        // resize pet +/- / resize chat / persona toggle / reset) on the same
        // view. Only renderer views that adopt PetDropHostingView get it.
        installRightClickMenu(on: view)
    }

    /// Install the right-click handler that builds the pet context menu. No-op
    /// for renderer views that do not adopt ``PetDropHostingView`` (the
    /// placeholder), so an ambient-only pet still right-clicks through.
    private func installRightClickMenu(on view: NSView) {
        guard let host = view as? PetDropHostingView else { return }
        host.rightClickHandler = { [weak self] clickedView, event in
            guard let self else { return }
            // Only show the menu when the right-click hits visible pet content,
            // so empty panel padding stays click-through.
            let point = clickedView.convert(event.locationInWindow, from: nil)
            if let renderer = self.renderer, renderer.view === clickedView,
               !renderer.containsVisibleContent(at: point) {
                return
            }
            let menu = self.buildPetContextMenu(at: point, in: clickedView)
            if let window = clickedView.window {
                let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
                menu.popUp(positioning: nil, at: screenPoint, in: nil)
            } else {
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
        }
    }

    /// Install (or re-install) the file drop delegate on the renderer view. The
    /// gate reuses the click gesture's visible-content test so a drop only
    /// "sticks" on pet pixels — empty panel padding stays drop-through. No-op for
    /// renderer views that do not adopt ``PetDropHostingView`` (the placeholder).
    private func installDropTarget(on view: NSView) {
        guard let host = view as? PetDropHostingView else { return }
        // Build one delegate per mount; closures reach back into this controller.
        let gate: (CGPoint, NSView) -> Bool = { [weak self] point, view in
            guard let self, let renderer = self.renderer, renderer.view === view else { return true }
            return renderer.containsVisibleContent(at: point)
        }
        let delegate = PetAttachmentDropDelegate(
            onDropFile: { [weak self] url in self?.handleDroppedFile(url) },
            onDropImage: { [weak self] image, name in self?.handleDroppedImage(image, suggestedName: name) },
            visibleContentGate: gate
        )
        attachmentDropDelegate = delegate
        host.dropDelegate = delegate
        host.registerPetDropTypes()
    }

    // MARK: File drag-and-drop

    /// Stage a dropped file URL onto the shared chat controller, then play a
    /// celebratory `react` beat and open the bubble so the attachment tray is
    /// visible at the pet (Option C feedback). Falls back to `react` only when
    /// no chat is attached (ambient-only pet), matching the click fallback — a
    /// drop is never inert.
    func handleDroppedFile(_ url: URL) {
        lastInteractionAt = Date()
        guard let chat else {
            fire(.resultLanded)
            drive(to: .react)
            return
        }
        chat.stageAttachment(from: url)
        fire(.resultLanded)
        openBubble()       // drives to .listen via chat.open()
        drive(to: .react)  // override: the drop celebration wins over the listen pose
    }

    /// Stage a dropped in-memory image onto the shared chat controller, then
    /// react + open the bubble (see ``handleDroppedFile(_:)``).
    func handleDroppedImage(_ image: NSImage, suggestedName: String?) {
        lastInteractionAt = Date()
        guard let chat else {
            fire(.resultLanded)
            drive(to: .react)
            return
        }
        chat.stageAttachment(image: image, suggestedName: suggestedName)
        fire(.resultLanded)
        openBubble()       // drives to .listen via chat.open()
        drive(to: .react)  // override: the drop celebration wins over the listen pose
    }

    /// Build/show the bubble panel and anchor it to the pet's contact socket.
    private func presentBubble(for chat: PetChatController) {
        let bubble = bubblePanel ?? PetBubblePanel()
        bubblePanel = bubble
        let anchor = bubbleTailAnchor()
        bubble.host(chat: chat, tailAnchorX: anchor) { [weak self, weak bubble] in
            guard let self, let bubble else { return }
            self.anchorBubble(bubble)
        }
        anchorBubble(bubble)
        bubble.makeKeyAndOrderFront(nil)
        // The pet's projected top-of-head moves once the one-shot presentation
        // framing lands (it can fire a moment after open). Re-anchor shortly
        // after so the bubble tracks the framed head instead of sitting on it.
        Task { @MainActor [weak self, weak bubble] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, let bubble, self.chat?.isOpen == true else { return }
            self.anchorBubble(bubble)
        }
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

    /// The tail's horizontal anchor (0…1 across the bubble width) so it points
    /// at the pet's contact socket x rather than the bubble centre. Re-evaluated
    /// on each anchor so the tail tracks the pet as it moves.
    private func bubbleTailAnchor() -> CGFloat {
        guard let panel, let renderer else { return 0.5 }
        let viewPoint = renderer.socketPoint("contact") ?? CGPoint(x: renderer.view.bounds.midX, y: 0)
        let windowPoint = renderer.view.convert(viewPoint, to: nil)
        let screenX = panel.convertPoint(toScreen: windowPoint).x
        // The bubble is centered over the anchor in `anchorBubble`, so the tail
        // points at the bubble centre → 0.5. When the bubble is clamped off-centre
        // by the screen edge, re-derive the anchor against the live bubble frame.
        if let bubble = bubblePanel, bubble.frame.width > 0 {
            let frac = (screenX - bubble.frame.minX) / bubble.frame.width
            return min(0.85, max(0.15, frac))
        }
        return 0.5
    }

    /// Position the bubble panel just above the pet's contact socket.
    private func anchorBubble(_ bubble: PetBubblePanel) {
        guard let anchor = bubbleAnchorPoint() else { return }
        bubble.resizeToContent()
        let size = bubble.frame.size
        // Center the bubble horizontally over the anchor, sit it above with a
        // generous gap so the tail clears the pet's head (was 12px → overlapped
        // the skull; the anchor now points at the projected top-of-head, so the
        // gap is pure breathing room above the head).
        let gap: CGFloat = 28
        let origin = CGPoint(
            x: anchor.x - size.width / 2,
            y: anchor.y + gap
        )
        bubble.setFrameOrigin(origin)
        bubble.clamp(to: panel?.bestScreen)
        // Re-point the tail at the (possibly clamped) anchor so the bubble's tail
        // tracks the pet even when the bubble itself was nudged on-screen.
        let anchor2 = bubbleTailAnchor()
        if let chat { bubble.host(chat: chat, tailAnchorX: anchor2) }
    }

    private func observePanelFrame(_ panel: PetPanel) {
        removePanelFrameObservers()
        let center = NotificationCenter.default
        panelFrameObservers = [
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.petPanelFrameDidChange()
                }
            },
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.petPanelFrameDidChange()
                }
            }
        ]
    }

    private func removePanelFrameObservers() {
        for observer in panelFrameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        panelFrameObservers.removeAll()
    }

    private func petPanelFrameDidChange() {
        if let bubblePanel, chat?.isOpen == true {
            anchorBubble(bubblePanel)
        }
        if toolbarPanel?.isVisible == true {
            repositionToolbar()
        }
    }

    // MARK: Hover toolbar (emote / resize / change avatar)

    enum HoverSource { case pet, toolbar }

    /// Resize clamps mirror the renderer's interaction defaults so 2D and 3D
    /// founders grow/shrink within the same bounds (the renderer view fills the
    /// panel, so resizing the panel scales the creature in either form).
    private static let minPanelWidth: CGFloat = 110
    private static let maxPanelWidth: CGFloat = 560
    private static let panelAspect: CGFloat = PetPanel.defaultSize.height / PetPanel.defaultSize.width

    /// Pointer entered/left the founder or the toolbar. The toolbar shows while
    /// either is hovered and hides (after a short debounce) when neither is — so
    /// reaching up from the pet to the bar never drops it.
    func setHover(_ over: Bool, source: HoverSource) {
        switch source {
        case .pet: hoverOverPet = over
        case .toolbar: hoverOverToolbar = over
        }
        if hoverOverPet || hoverOverToolbar {
            toolbarHideTask?.cancel()
            toolbarHideTask = nil
            presentToolbar()
        } else {
            scheduleToolbarHide()
        }
    }

    private func scheduleToolbarHide() {
        toolbarHideTask?.cancel()
        toolbarHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self, !Task.isCancelled else { return }
            if !self.hoverOverPet, !self.hoverOverToolbar {
                self.dismissToolbar()
            }
            self.toolbarHideTask = nil
        }
    }

    /// Show (or re-anchor) the hover toolbar above the founder. Suppressed while
    /// the chat bubble is open (it owns the space then) or the pet is hidden.
    func presentToolbar() {
        guard isVisible, isRunning, chat?.isOpen != true else { return }
        let toolbar = toolbarPanel ?? makeToolbarPanel()
        toolbarPanel = toolbar
        repositionToolbar()
        toolbar.orderFront(nil)
    }

    func dismissToolbar() {
        toolbarPanel?.orderOut(nil)
    }

    private func makeToolbarPanel() -> PetToolbarPanel {
        let panel = PetToolbarPanel(onHoverChange: { [weak self] over in
            self?.setHover(over, source: .toolbar)
        })
        panel.host(
            PetHoverToolbarView(
                title: displayName,
                emotes: PetHoverToolbarView.defaultEmotes,
                onEmote: { [weak self] in self?.playEmote($0) },
                onResize: { [weak self] in self?.resizePet(by: $0) },
                onResizeReset: { [weak self] in self?.resetPetSize() },
                onChangeAvatar: { [weak self] in self?.presentLibrary() }
            )
        )
        return panel
    }

    /// Position the toolbar centered just above the founder, overlapping the
    /// crown a touch so the pointer never crosses empty space between them.
    private func repositionToolbar() {
        guard let toolbarPanel, let panel else { return }
        toolbarPanel.resizeToContent()
        let size = toolbarPanel.frame.size
        let petFrame = panel.frame
        let origin = CGPoint(
            x: petFrame.midX - size.width / 2,
            y: petFrame.maxY - 12
        )
        toolbarPanel.setFrameOrigin(origin)
        toolbarPanel.clamp(to: panel.bestScreen)
    }

    /// Strike an emote pose on demand, then settle back so it reads as a beat.
    func playEmote(_ state: PetLogicalState) {
        lastInteractionAt = Date()
        drive(to: state.rawValue, force: true)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, !self.isAgentBusy, self.isVisible else { return }
            self.drive(to: .idle)
        }
    }

    /// Grow/shrink the founder by `factor` (panel resize, aspect-locked, clamped),
    /// anchored at the bottom centre so it scales from where it sits. Persisted so
    /// the size survives relaunch (the same store the drag/scroll path uses).
    func resizePet(by factor: CGFloat) {
        guard let panel, factor.isFinite, factor > 0 else { return }
        let frame = panel.frame
        let newWidth = min(Self.maxPanelWidth, max(Self.minPanelWidth, frame.width * factor))
        let newHeight = newWidth * Self.panelAspect
        let origin = NSPoint(x: frame.midX - newWidth / 2, y: frame.minY)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: newWidth, height: newHeight)), display: true)
        panel.clamp(to: panel.bestScreen)
        persistPetFrame()
        repositionToolbar()
    }

    /// Reset the founder to its default size, bottom-centre anchored.
    func resetPetSize() {
        guard let panel else { return }
        let frame = panel.frame
        let size = PetPanel.defaultSize
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size.width, height: size.height)), display: true)
        panel.clamp(to: panel.bestScreen)
        persistPetFrame()
        repositionToolbar()
    }

    /// Open the founder library (switch founder + 2D/3D form) in its own window.
    func presentLibrary() {
        PetLibraryWindowPresenter.open(selectedPetID: definition?.id ?? PetCompanionFeature.activePetID)
    }

    private func persistPetFrame() {
        guard let id = definition?.id, let panel else { return }
        PetWindowState.store(panel.frame, for: id)
    }

    // MARK: Private

    private func makePanel() -> PetPanel {
        let panel = PetPanel()
        // A hover-tracking content view so the controller can fade the Liquid
        // Glass toolbar in/out as the pointer enters/leaves the founder. The
        // renderer still mounts into this view and clicks still reach its gesture.
        let content = PetPanelHoverView(frame: NSRect(origin: .zero, size: PetPanel.defaultSize))
        content.onHoverChange = { [weak self] over in self?.setHover(over, source: .pet) }
        panel.contentView = content
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
        if resolveReaction(force: false) { return }
        settleControllerStateIfNeeded()

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

    private func resetReactionState() {
        let now = Date()
        lastInteractionAt = now
        lastTypingAt = nil
        isAgentBusy = false
        appFocused = NSApp.isActive
        osIdle = false
        lastIntent = nil
        lastIntentAt = nil
        repeatedIntentCount = 0
        lastOutcome = nil
        lastOutcomeAt = nil
        lastAmbientReactionAt = .distantPast
    }

    @discardableResult
    private func resolveReaction(force: Bool) -> Bool {
        guard let target = PetReactionBrain.pickReaction(makeReactionSenses()) else {
            return false
        }
        if target == currentState && !force {
            return true
        }
        if target != currentState || force {
            drive(to: target, force: force)
            if isAmbientState(target) {
                lastAmbientReactionAt = Date()
            }
            return true
        }
        return false
    }

    private func makeReactionSenses() -> PetReactionSenses {
        let now = Date()
        let osUserIdle = userIdleSeconds() >= 120
        return PetReactionSenses(
            availableClips: availableReactionNames(),
            sinceInteraction: now.timeIntervalSince(lastInteractionAt),
            userTyping: lastTypingAt.map { now.timeIntervalSince($0) <= 2.5 } ?? false,
            agentBusy: isAgentBusy,
            appFocused: appFocused,
            osIdle: osIdle || osUserIdle,
            pointerNear: pointerNearPet(),
            lastIntent: lastIntent,
            lastIntentAge: lastIntentAt.map { now.timeIntervalSince($0) },
            repeatedIntentCount: repeatedIntentCount,
            lastOutcome: lastOutcome,
            lastOutcomeAge: lastOutcomeAt.map { now.timeIntervalSince($0) },
            timeOfDayHour: Calendar.current.component(.hour, from: now),
            wasSleeping: ["sleep", "doze"].contains(currentState),
            ambientPulse: now.timeIntervalSince(lastAmbientReactionAt) >= 15
        )
    }

    private func availableReactionNames() -> Set<String> {
        if let model = definition?.model3d {
            let semantic = model.availableSemanticClips
            if !semantic.isEmpty { return semantic }
            guard let clips = model.clips else { return [] }
            return Set(clips.keys)
        }
        if let atlas = definition?.atlas2d {
            return Set(atlas.states.keys).union(PetLogicalState.allCases.map(\.rawValue))
        }
        return Set(PetLogicalState.allCases.map(\.rawValue))
    }

    private func pointerNearPet() -> Bool {
        guard isVisible, let panel else { return false }
        return panel.frame.insetBy(dx: -64, dy: -64).contains(NSEvent.mouseLocation)
    }

    private func userIdleSeconds() -> TimeInterval {
        let state = CGEventSourceStateID.combinedSessionState
        let key = CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown)
        let move = CGEventSource.secondsSinceLastEventType(state, eventType: .mouseMoved)
        let click = CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseDown)
        let values = [key, move, click].filter { $0.isFinite && $0 >= 0 }
        return values.min() ?? 0
    }

    private func settleControllerStateIfNeeded() {
        guard !isHoldingState(currentState) else { return }
        drive(to: PetLogicalState.idle.rawValue)
    }

    private func isHoldingState(_ state: String) -> Bool {
        ["idle", "walk", "wander", "listen", "think", "sleep", "doze", "retreat"].contains(state)
    }

    private func isAmbientState(_ state: String) -> Bool {
        ["idleVar", "stretch", "lookAround", "sip", "vanity", "excited"].contains(state)
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

/// Holds an array of notification observer tokens so the controller can remove
/// them together when the panel tears down. A plain `NSObject` box keeps the
/// tokens (untyped `NSObjectProtocol`) alive without exposing them.
@MainActor
final class TokenBox: NSObject {
    let tokens: [NSObjectProtocol]
    init(tokens: [NSObjectProtocol]) { self.tokens = tokens }
}

@MainActor
private final class PetClickGestureGate: NSObject, NSGestureRecognizerDelegate {
    private let shouldAccept: (CGPoint, NSView) -> Bool

    init(_ shouldAccept: @escaping (CGPoint, NSView) -> Bool) {
        self.shouldAccept = shouldAccept
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let view = gestureRecognizer.view else { return false }
        return shouldAccept(gestureRecognizer.location(in: view), view)
    }
}
