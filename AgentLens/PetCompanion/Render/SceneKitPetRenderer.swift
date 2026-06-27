import AppKit
import CoreGraphics
import Foundation
import GLTFKit2
import SceneKit
import simd

// MARK: - PetModel3DInteractionState

/// User-controlled 3D view transform for model pets.
struct PetModel3DInteractionState: Equatable, Sendable {
    var yawRadians: CGFloat
    var scale: CGFloat
}

/// Debug/test-only framing metrics for a mounted 3D pet.
struct PetModel3DFrameMetrics: Equatable, Sendable {
    var sourceMaxExtent: CGFloat
    var normalizedMaxExtent: CGFloat
    var baseScale: CGFloat
}

// MARK: - GLBSceneLoading

/// The seam that turns a bundled `.glb` master into an `SCNScene`.
///
/// **Why a seam, not a direct call.** SceneKit/ModelIO on macOS 14 do **not**
/// natively decode binary glTF (`.glb`): `MDLAsset.canImportFileExtension("glb")`
/// is `false`, and `SCNScene(url:)` only reads SceneKit/USD/COLLADA. The pet
/// models in this feature are `.glb`, so a real build links **GLTFKit2**
/// (`import GLTFKit2`) and routes through `GLTFSCNSceneSource` →
/// `scene.defaultScene`, which also surfaces each glTF animation as an
/// `SCNAnimationPlayer` keyed by clip name.
///
/// Keeping that behind ``GLBSceneLoading`` lets tests inject a fake loader while
/// production routes through the bundled GLTFKit2 binary package.
@MainActor
protocol GLBSceneLoading: AnyObject {
    /// Load the scene graph for `url`. `clipNames` are the glTF animation names
    /// the petdef references (so a loader can pre-bind `SCNAnimationPlayer`s).
    /// Returns `nil` when the asset can't be decoded (caller draws a placeholder).
    func loadScene(at url: URL, clipNames: [String]) -> SCNScene?
}

/// Production loader.
///
/// Order of attempts, most-capable first:
/// 1. **GLTFKit2** — the canonical `.glb` path.
/// 2. **SceneKit native** (`SCNScene(url:)`) — succeeds for `.usdz`/`.scn`
///    siblings and any `.glb` once a GLTF importer is registered system-wide.
///
/// On total failure the caller falls back to ``SceneKitPetRenderer`` primitive
/// so the panel still shows a creature rather than a blank rect.
@MainActor
final class DefaultGLBSceneLoader: GLBSceneLoading {
    private static var didRegisterDracoDecompressor = false

    func loadScene(at url: URL, clipNames: [String]) -> SCNScene? {
        if let scene = loadViaGLTFKit2(url: url) { return scene }
        // Native SceneKit: handles USDZ/SCN and GLB-with-registered-importer.
        if let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) {
            return scene
        }
        return nil
    }

    private func loadViaGLTFKit2(url: URL) -> SCNScene? {
        Self.registerDracoDecompressorIfNeeded()
        guard let asset = try? GLTFAsset(url: url, options: [
            GLTFAssetLoadingOption.createNormalsIfAbsentKey: true
        ]) else {
            return nil
        }
        let source = GLTFSCNSceneSource(asset: asset)
        guard let scene = source.defaultScene else { return nil }
        // GLTFKit2 builds an `SCNAnimationPlayer` per glTF clip into
        // `source.animations` but never attaches them to the scene graph, so the
        // renderer would never find them and the pet would stay frozen. Attach
        // each to the scene root keyed by its clip name (the channels target nodes
        // by name, so the attach point is irrelevant) and leave them paused — the
        // renderer drives playback via `play(state:)`.
        for animation in source.animations {
            let player = animation.animationPlayer
            scene.rootNode.addAnimationPlayer(player, forKey: animation.name)
            player.stop()
        }
        return scene
    }

    private static func registerDracoDecompressorIfNeeded() {
        guard !didRegisterDracoDecompressor else { return }
        GLTFAsset.dracoDecompressorClassName = "OpenBurnBarDracoDecompressor"
        didRegisterDracoDecompressor = true
    }
}

// MARK: - SceneKitPetRenderer

/// The 3D model backend (PLAN C5). Conforms to ``PetRenderer``: it brings an
/// `SCNView` up **on demand** in ``mount(in:)``, loads the pet's GLB master via
/// ``GLBSceneLoading``, resolves named clips from ``PetDefinition/Model3D/clips``,
/// and tears the view + scene graph **down** in ``unmount()`` to return toward
/// baseline memory (PLAN §4 — the 3D form is the heavy one).
///
/// Energy gating maps onto SceneKit's own play switch: ``setPaused(_:)`` toggles
/// `SCNView.isPlaying`, so an occluded/asleep pet stops its render loop at ~0%
/// CPU and resumes instantly. Static models (no clips, e.g. `go-gopher`) get a
/// gentle host-driven idle bob so the panel never looks frozen.
@MainActor
final class SceneKitPetRenderer: NSObject, PetRenderer, SCNSceneRendererDelegate {
    private enum InteractionDefaults {
        static let yawPrefix = "pet.model3d.yaw."
        static let scalePrefix = "pet.model3d.scale."
        static let minimumScale: CGFloat = 0.55
        static let maximumScale: CGFloat = 2.4
        static let rotationSensitivity: CGFloat = 0.012
        static let scrollScaleSensitivity: CGFloat = 0.012
        // Desktop-pet panel resize (the camera fills the view, so resizing the
        // window resizes the visible pet). Aspect is locked to the default cell
        // (PetPanel.defaultSize = 192x208).
        static let panelAspect: CGFloat = 208.0 / 192.0
        static let minPanelWidth: CGFloat = 110
        static let maxPanelWidth: CGFloat = 560
    }

    private struct ModelFraming {
        var baseScale: CGFloat
        var centerX: CGFloat
        var centerZ: CGFloat
        var minY: CGFloat
    }

    // MARK: PetRenderer surface

    let definition: PetDefinition
    private(set) var form: PetForm
    var view: NSView { scnView }

    // MARK: SceneKit state

    private let scnView: InteractivePetSceneView
    private let loader: GLBSceneLoading

    /// The mounted scene graph for the current form; `nil` until mounted /
    /// after unmount, so memory returns to baseline when the pet is hidden.
    private var scene: SCNScene?
    /// The node we yaw for facing and bob for the static-idle fallback.
    private weak var contentRoot: SCNNode?
    /// Pre-resolved `clipName → SCNAnimationPlayer` from the loaded scene.
    private var clipPlayers: [String: SCNAnimationPlayer] = [:]
    /// Props grafted onto skeleton sockets (e.g. a broom in the right hand). Each
    /// node is a child of its bone, so it rides the bone's animated transform; we
    /// keep the pairing to toggle visibility per logical state.
    private var attachedProps: [(prop: PetDefinition.PetProp, node: SCNNode)] = []
    /// The clip key currently playing (for restore after pause / form swap).
    private var activeClipKey: String?
    /// Increments on every playback change so delayed settle tasks cannot race
    /// an interrupted reaction.
    private var playbackGeneration = 0

    private var currentStateKey: String
    private var facing: CGFloat = 1
    private var reducedMotion = false
    private var ambientFrameRate = 15
    private var paused = false
    private var userYawRadians: CGFloat
    private var userScale: CGFloat
    private var modelFraming: ModelFraming?
    /// Set when a freshly-loaded scene still needs the camera re-fit to its
    /// post-skinning presentation bounds on the next render (see install).
    private var needsPresentationFraming = false
    /// Window origin + mouse location captured at the start of a drag-to-move,
    /// so the panel tracks the cursor in absolute screen coordinates.
    private var dragStartWindowOrigin: NSPoint?
    private var dragStartMouse: NSPoint?

    private static let idleBobActionKey = "pet.idleBob"
    private static let targetModelHeight: CGFloat = 2.0

    var interactionState: PetModel3DInteractionState {
        PetModel3DInteractionState(yawRadians: userYawRadians, scale: userScale)
    }

    var frameMetricsForTesting: PetModel3DFrameMetrics? {
        guard let contentRoot,
              let framing = modelFraming,
              let bounds = subtreeBoundingBox(for: contentRoot) else { return nil }
        let (minB, maxB) = bounds
        let maxExtent = Self.maxExtent(min: minB, max: maxB)
        guard maxExtent > 0 else { return nil }
        let scale = framing.baseScale * userScale
        return PetModel3DFrameMetrics(
            sourceMaxExtent: maxExtent,
            normalizedMaxExtent: maxExtent * scale,
            baseScale: framing.baseScale
        )
    }

    /// Test hook: whether the mounted model stands upright. Measured in the
    /// content root's space so the verdict reflects the rendered orientation, not
    /// only the raw mesh metadata.
    ///
    /// The regression these rigs hit is the rendered body lying toward the camera:
    /// the head-to-toe axis ends up along SceneKit's Z (depth) with only the body's
    /// thickness along Y. So "upright" is precisely: the **vertical extent is at
    /// least the depth extent** (`height >= depth`). Width (X) is deliberately not
    /// compared — a standing rig's bind pose can splay its arms wider than it is
    /// tall, which is upright, not supine. `false` when no model is mounted.
    var isUprightForTesting: Bool {
        guard let contentRoot, let bounds = subtreeBoundingBox(for: contentRoot) else { return false }
        let (minB, maxB) = bounds
        let height = CGFloat(maxB.y - minB.y)
        let depth = CGFloat(maxB.z - minB.z)
        guard height.isFinite, depth.isFinite, height > 0 else { return false }
        return height >= depth
    }

    // MARK: Init

    init(
        definition: PetDefinition,
        form: PetForm,
        loader: GLBSceneLoading = DefaultGLBSceneLoader()
    ) {
        self.definition = definition
        self.form = form
        self.loader = loader

        let frame = CGRect(origin: .zero, size: PetPanel.defaultSize)
        let view = InteractivePetSceneView(frame: frame)
        view.backgroundColor = .clear
        // Transparent so the panel stays click-through where the model isn't.
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling2X
        view.isPlaying = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 15
        self.scnView = view

        self.currentStateKey = PetLogicalState.idle.rawValue
        self.userYawRadians = Self.storedYaw(for: definition.id)
        self.userScale = Self.storedScale(for: definition.id)

        super.init()

        installInteractionRecognizers()
    }

    // MARK: Mount / unmount (on-demand bring-up, teardown to baseline)

    func mount(in container: NSView) {
        scnView.frame = container.bounds
        scnView.autoresizingMask = [.width, .height]
        if scnView.superview !== container {
            container.addSubview(scnView)
        }
        if scene == nil {
            loadScene(for: form)
        }
        setPaused(false)
        play(state: currentStateKey)
    }

    func unmount() {
        // Stop the render loop, drop the scene graph + animation players, and
        // detach the view so GPU/scene memory returns toward baseline (C5).
        scnView.isPlaying = false
        scnView.rendersContinuously = false
        contentRoot?.removeAllActions()
        scnView.scene = nil
        scene = nil
        contentRoot = nil
        clipPlayers.removeAll(keepingCapacity: false)
        attachedProps.removeAll()
        activeClipKey = nil
        playbackGeneration += 1
        scnView.removeFromSuperview()
    }

    // MARK: Form swap (C8)

    func setForm(_ form: PetForm) {
        guard form != self.form else { return }
        self.form = form
        contentRoot?.removeAllActions()
        scnView.scene = nil
        scene = nil
        contentRoot = nil
        modelFraming = nil
        clipPlayers.removeAll(keepingCapacity: true)
        attachedProps.removeAll()
        activeClipKey = nil
        playbackGeneration += 1
        loadScene(for: form)
        play(state: currentStateKey)
    }

    // MARK: Playback

    func play(state: String) {
        currentStateKey = state
        updatePropVisibility(for: state)

        // Do NOT re-frame the camera on a pose change. The camera is framed ONCE —
        // upright and face-on, after the skinner settles (see `install` +
        // `frameCameraToPresentation`) — and then stays put until the user drags it.
        // Re-fitting on every pose change re-ran presentation framing against an
        // *unsettled* skinned pose; a skinned rig's bounding sphere is momentarily
        // degenerate mid-blend, and aiming `look(at:)` at that snapped the camera
        // for a frame and read as a top-of-head / bird's-eye view the instant chat
        // drove the pet `idle → listen`. Every clip keeps the rig upright (the Hips
        // bone never tips past a lean), so one fixed frame holds every pose.

        guard let model = definition.model3d else { return }

        // Resolve the logical state → glTF clip name via the petdef clip map
        // (with the same logical aliases the 2D backend uses), then fall back to
        // any available clip.
        let clipName = resolveClipName(for: state, in: model)

        // Stop whatever was playing.
        if let prevKey = activeClipKey, let prev = clipPlayers[prevKey] {
            prev.stop(withBlendOutDuration: 0.15)
        }

        guard let clipName, let player = clipPlayers[clipName] else {
            // Static model (no clips) or unknown state: settle and run the
            // gentle host-driven idle bob so the panel isn't frozen.
            activeClipKey = nil
            playbackGeneration += 1
            applyIdleBob()
            return
        }

        contentRoot?.removeAction(forKey: Self.idleBobActionKey)
        let shouldLoop = !reducedMotion && Self.shouldLoop(logical: state, clipName: clipName)
        configurePlayer(player, loop: shouldLoop)
        playbackGeneration += 1
        let generation = playbackGeneration
        player.animation.blendInDuration = 0.15
        player.play()
        activeClipKey = clipName
        if !shouldLoop {
            settleToIdle(after: player.animation.duration, generation: generation)
        }
    }

    func setFacing(_ direction: CGFloat) {
        let sign: CGFloat = direction < 0 ? -1 : 1
        guard sign != (facing < 0 ? -1 : 1) else { facing = sign; return }
        facing = sign
        applyModelTransform()
    }

    // MARK: Energy gating (PLAN §4)

    func setPaused(_ paused: Bool) {
        self.paused = paused
        // SceneKit's own play switch: stops the render loop at ~0% CPU.
        scnView.isPlaying = !paused
        scnView.rendersContinuously = !paused
        if paused {
            clipPlayers[activeClipKey ?? ""]?.paused = true
        } else {
            clipPlayers[activeClipKey ?? ""]?.paused = false
            // Re-assert in case a non-looping clip stranded while paused.
            play(state: currentStateKey)
        }
    }

    func setAmbientFrameRate(_ fps: Int) {
        ambientFrameRate = max(fps, 1)
        scnView.preferredFramesPerSecond = ambientFrameRate
    }

    func rotateModel(by deltaRadians: CGFloat, persist: Bool = true) {
        guard deltaRadians.isFinite else { return }
        userYawRadians = Self.normalizedAngle(userYawRadians + deltaRadians)
        applyModelTransform()
        if persist { Self.storeYaw(userYawRadians, for: definition.id) }
    }

    func resizeModel(by factor: CGFloat, persist: Bool = true) {
        guard factor.isFinite, factor > 0 else { return }
        userScale = Self.clampedScale(userScale * factor)
        applyModelTransform()
        if persist { Self.storeScale(userScale, for: definition.id) }
    }

    func resetModelView(persist: Bool = true) {
        userYawRadians = 0
        userScale = 1
        applyModelTransform()
        if persist {
            Self.storeYaw(userYawRadians, for: definition.id)
            Self.storeScale(userScale, for: definition.id)
        }
    }

    func setReducedMotion(_ reduced: Bool) {
        guard reduced != reducedMotion else { return }
        reducedMotion = reduced
        if reduced {
            // Freeze ambient motion to a settled pose: stop the loop and the bob.
            clipPlayers[activeClipKey ?? ""]?.paused = true
            contentRoot?.removeAction(forKey: Self.idleBobActionKey)
        } else {
            play(state: currentStateKey)
        }
    }

    /// 3D socket projection: project the named atlas socket (if the pet also
    /// carries a 2D atlas) onto the view, else center-top of the view as a
    /// reasonable bubble anchor for a model-only pet.
    func socketPoint(_ name: String) -> CGPoint? {
        if let atlas = definition.atlas2d, let p = atlas.socketPoint(name) {
            let size = scnView.bounds.size == .zero ? PetPanel.defaultSize : scnView.bounds.size
            guard atlas.cell.w > 0, atlas.cell.h > 0 else { return nil }
            return CGPoint(x: p.x / atlas.cell.w * size.width,
                           y: (atlas.cell.h - p.y) / atlas.cell.h * size.height)
        }
        let size = scnView.bounds.size == .zero ? PetPanel.defaultSize : scnView.bounds.size
        // "contact" → just above the model's head; default → center.
        if name == "contact" || name == "bubble" {
            return CGPoint(x: size.width / 2, y: size.height * 0.9)
        }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func containsVisibleContent(at point: CGPoint) -> Bool {
        guard scnView.bounds.contains(point), scnView.scene != nil else { return false }
        return scnView.hitTest(point, options: [
            .ignoreHiddenNodes: true,
            .boundingBoxOnly: false
        ]).contains { result in
            result.node.geometry != nil
        }
    }

    // MARK: Scene loading

    /// Resolve the GLB master to an `SCNScene`, normalise it into the panel,
    /// pre-bind animation players, and prime lights/camera. Falls back to a
    /// primitive placeholder if the loader can't decode the asset.
    private func loadScene(for form: PetForm) {
        let glbName: String
        switch form {
        case .model3d(let name): glbName = name
        case .atlas2d:
            // A 2D form on the 3D backend: nothing to load; the controller
            // should have routed this to the SpriteKit backend. Draw a
            // placeholder so we never crash.
            installPlaceholderScene()
            return
        }

        let clipNames = Array((definition.model3d?.clips ?? [:]).values)
        let url = PetModelResourceLocator.url(for: glbName, petID: definition.id)

        if let url, let loaded = loader.loadScene(at: url, clipNames: clipNames) {
            install(scene: loaded)
        } else {
            installPlaceholderScene()
        }
    }

    private func install(scene loaded: SCNScene) {
        self.scene = loaded
        scnView.scene = loaded

        // Wrap the imported root so we can yaw/bob without disturbing clips.
        // `root` owns the yaw/bob (applied in applyModelTransform). The synced
        // GLBs are already authored Y-up; adding a blanket pitch correction turns
        // founder bodies horizontal, which reads as a top-of-head view. Keep the
        // imported rig orientation intact and let framing/camera handle scale.
        let root = SCNNode()
        for child in loaded.rootNode.childNodes {
            root.addChildNode(child)
        }
        loaded.rootNode.addChildNode(root)
        contentRoot = root

        normalizeFraming(root: root, in: loaded)
        harvestClipPlayers(from: loaded.rootNode)
        ensureCameraAndLights(in: loaded)
        attachProps(under: root)

        // Skinned rigs (the founders) deform far beyond their bind-pose bounding
        // sphere once the skinner runs at first render, so the bind-pose camera
        // framing above misses them entirely. Re-fit the camera to the actual
        // PRESENTATION bounds after the first render lands. This is the SOLE camera
        // framing pass — one-shot per mount/form-swap, never re-armed on a pose
        // change — so the view holds still while the pet animates (see `play`).
        needsPresentationFraming = true
        scnView.delegate = self
    }

    /// Graft each declared prop onto its skeleton socket: resolve socket → bone
    /// node, load the static prop GLB, offset it in bone-local space, and add it as
    /// a child of the bone so it rides the bone's animated transform — the same
    /// contract the web three.js `attachProps` honors (the petdef `props[]` is the
    /// shared wire format). A prop whose socket or GLB can't be resolved is skipped;
    /// a missing prop never breaks the pet.
    private func attachProps(under root: SCNNode) {
        attachedProps.removeAll()
        guard let props = definition.model3d?.props, !props.isEmpty else { return }

        var boneNames = Set<String>()
        root.enumerateHierarchy { node, _ in
            if let name = node.name { boneNames.insert(name) }
        }

        for prop in props {
            let parent: SCNNode?
            if let boneName = PetDefinition.PetProp.resolveSocketBone(prop.socket, available: boneNames) {
                parent = root.childNode(withName: boneName, recursively: true)
            } else if prop.socket == "root" {
                parent = root
            } else {
                parent = nil
            }
            guard let parent,
                  let url = PetModelResourceLocator.propURL(for: prop.glb),
                  let propScene = loader.loadScene(at: url, clipNames: []) else { continue }

            let node = SCNNode()
            node.name = "prop:\(prop.id)"
            for child in propScene.rootNode.childNodes { node.addChildNode(child) }
            applyPropTransform(node, prop.transform)
            parent.addChildNode(node)
            attachedProps.append((prop, node))
        }
        updatePropVisibility(for: currentStateKey)
    }

    /// Apply a bone-local offset to a prop node (identity for absent fields).
    private func applyPropTransform(_ node: SCNNode, _ transform: PetDefinition.PetPropTransform?) {
        guard let transform else { return }
        if let p = transform.position, p.count == 3 {
            node.position = SCNVector3(Float(p[0]), Float(p[1]), Float(p[2]))
        }
        if let r = transform.rotationEuler, r.count == 3 {
            node.eulerAngles = SCNVector3(Float(r[0]), Float(r[1]), Float(r[2]))
        }
        if let s = transform.scale, s.count == 3 {
            node.scale = SCNVector3(Float(s[0]), Float(s[1]), Float(s[2]))
        }
    }

    /// Show/hide attached props for the pet's current logical state.
    private func updatePropVisibility(for state: String?) {
        guard !attachedProps.isEmpty else { return }
        let key = state ?? definition.model3d?.clips?.keys.first ?? "idle"
        for (prop, node) in attachedProps {
            node.isHidden = !prop.isVisible(in: key)
        }
    }

    /// Re-fit the camera to the model's PRESENTATION (post-skinning) bounds. The
    /// presentation node reflects the actual rendered pose; for skinned founder
    /// rigs that is ~100x larger and offset high on +Y versus the static
    /// bind-pose bounds used at install time. Unskinned models (presentation ==
    /// bind pose, e.g. go-gopher) are unaffected.
    /// Returns `true` only when a finite, sane presentation sphere was available and
    /// the camera was actually re-aimed; `false` asks the caller to retry on a later
    /// render. A skinned rig's first post-mount frame can momentarily report a
    /// degenerate / NaN bounding-sphere centre while the skinner blends in — aiming
    /// `look(at:)` at a NaN centre is the one way this otherwise-level camera tilts,
    /// flashing a bird's-eye view — so never apply a non-finite frame.
    @discardableResult
    private func frameCameraToPresentation() -> Bool {
        guard let scene = scnView.scene,
              let cameraNode = scene.rootNode.childNode(withName: "pet.camera", recursively: true) else { return false }
        let sphere = scene.rootNode.presentation.boundingSphere
        let center = sphere.center
        let radius = CGFloat(sphere.radius)
        guard radius.isFinite, radius > 0,
              CGFloat(center.x).isFinite, CGFloat(center.y).isFinite, CGFloat(center.z).isFinite else { return false }
        let camera = cameraNode.camera ?? SCNCamera()
        cameraNode.camera = camera
        camera.usesOrthographicProjection = false
        camera.fieldOfView = 60
        let distance = radius * 3
        camera.zNear = Double(max(0.01, distance - radius * 2))
        camera.zFar = Double(distance + radius * 10)
        cameraNode.position = SCNVector3(center.x, center.y, center.z + distance)
        cameraNode.look(at: center)
        scnView.pointOfView = cameraNode
        // Paused previews (the Settings picker cells) won't re-render on their own
        // after the camera moves, so request one redraw to show the reframed pet.
        scnView.needsDisplay = true
        return true
    }

    nonisolated func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        Task { @MainActor [weak self] in
            guard let self, self.needsPresentationFraming else { return }
            // Consume the one-shot ONLY once a sane sphere was actually applied, so a
            // degenerate first frame retries on the next render instead of leaving a
            // bad (or bird's-eye) framing latched in.
            if self.frameCameraToPresentation() {
                self.needsPresentationFraming = false
            }
        }
    }

    /// Build a minimal placeholder scene (a capsule) so a model-only pet whose
    /// GLB failed to decode still shows a creature silhouette.
    private func installPlaceholderScene() {
        let scene = SCNScene()
        let geometry = SCNCapsule(capRadius: 0.4, height: 1.6)
        geometry.firstMaterial?.diffuse.contents = NSColor.systemTeal
        let node = SCNNode(geometry: geometry)
        let root = SCNNode()
        root.addChildNode(node)
        scene.rootNode.addChildNode(root)
        self.scene = scene
        scnView.scene = scene
        contentRoot = root
        modelFraming = nil
        ensureCameraAndLights(in: scene)
        applyIdleBob()
    }

    /// Center the model and scale it to fill the panel cell, feet near the
    /// bottom (matches the 2D baseline convention).
    private func normalizeFraming(root: SCNNode, in scene: SCNScene) {
        // `SCNVector3` components are `CGFloat` on macOS; keep all math in
        // `CGFloat` so this typechecks against the AppKit SceneKit overlay.
        guard let bounds = subtreeBoundingBox(for: root) else { return }
        let (minB, maxB) = bounds
        let maxExtent = Self.maxExtent(min: minB, max: maxB)
        guard maxExtent > 0 else { return }
        modelFraming = ModelFraming(
            baseScale: Self.targetModelHeight / maxExtent,
            centerX: (CGFloat(minB.x) + CGFloat(maxB.x)) / 2,
            centerZ: (CGFloat(minB.z) + CGFloat(maxB.z)) / 2,
            minY: CGFloat(minB.y)
        )
        applyModelTransform()
    }

    private func subtreeBoundingBox(for root: SCNNode) -> (SCNVector3, SCNVector3)? {
        var minPoint: SCNVector3?
        var maxPoint: SCNVector3?

        func include(_ point: SCNVector3) {
            guard CGFloat(point.x).isFinite,
                  CGFloat(point.y).isFinite,
                  CGFloat(point.z).isFinite else { return }

            if let current = minPoint {
                minPoint = SCNVector3(
                    Swift.min(current.x, point.x),
                    Swift.min(current.y, point.y),
                    Swift.min(current.z, point.z)
                )
            } else {
                minPoint = point
            }

            if let current = maxPoint {
                maxPoint = SCNVector3(
                    Swift.max(current.x, point.x),
                    Swift.max(current.y, point.y),
                    Swift.max(current.z, point.z)
                )
            } else {
                maxPoint = point
            }
        }

        func includeBounds(of node: SCNNode) {
            let (minB, maxB) = node.boundingBox
            guard Self.hasFinitePositiveExtent(min: minB, max: maxB) else { return }
            for corner in Self.boundingBoxCorners(min: minB, max: maxB) {
                include(root.convertPosition(corner, from: node))
            }
        }

        includeBounds(of: root)
        root.enumerateChildNodes { node, _ in
            includeBounds(of: node)
        }

        guard let minPoint,
              let maxPoint,
              Self.hasFinitePositiveExtent(min: minPoint, max: maxPoint) else { return nil }
        return (minPoint, maxPoint)
    }

    private static func boundingBoxCorners(min minB: SCNVector3, max maxB: SCNVector3) -> [SCNVector3] {
        [
            SCNVector3(minB.x, minB.y, minB.z),
            SCNVector3(minB.x, minB.y, maxB.z),
            SCNVector3(minB.x, maxB.y, minB.z),
            SCNVector3(minB.x, maxB.y, maxB.z),
            SCNVector3(maxB.x, minB.y, minB.z),
            SCNVector3(maxB.x, minB.y, maxB.z),
            SCNVector3(maxB.x, maxB.y, minB.z),
            SCNVector3(maxB.x, maxB.y, maxB.z)
        ]
    }

    private static func hasFinitePositiveExtent(min minB: SCNVector3, max maxB: SCNVector3) -> Bool {
        let extents = [
            CGFloat(maxB.x - minB.x),
            CGFloat(maxB.y - minB.y),
            CGFloat(maxB.z - minB.z)
        ]
        return extents.allSatisfy { $0.isFinite } && extents.contains { $0 > 0 }
    }

    private static func maxExtent(min minB: SCNVector3, max maxB: SCNVector3) -> CGFloat {
        let extentX = CGFloat(maxB.x - minB.x)
        let extentY = CGFloat(maxB.y - minB.y)
        let extentZ = CGFloat(maxB.z - minB.z)
        return max(extentX, max(extentY, extentZ))
    }

    private func applyModelTransform() {
        guard let node = contentRoot, let framing = modelFraming else { return }
        let scale = framing.baseScale * userScale
        node.scale = SCNVector3(scale, scale, scale)
        node.position = SCNVector3(
            -framing.centerX * scale,
            -framing.minY * scale - Self.targetModelHeight / 2,
            -framing.centerZ * scale
        )
        let facingYaw: CGFloat = facing < 0 ? .pi : 0
        node.eulerAngles = SCNVector3(0, facingYaw + userYawRadians, 0)
    }

    /// Walk the graph and collect every `SCNAnimationPlayer`, keyed by its
    /// animation key. GLTFKit2 sets the key to the glTF clip name; native
    /// SceneKit imports key by their own ids, so we index by both the node's
    /// keys and the clip names the petdef expects.
    private func harvestClipPlayers(from root: SCNNode) {
        for key in root.animationKeys {
            if let player = root.animationPlayer(forKey: key) {
                clipPlayers[key] = player
            }
        }

        root.enumerateChildNodes { node, _ in
            for key in node.animationKeys {
                if let player = node.animationPlayer(forKey: key) {
                    clipPlayers[key] = player
                }
            }
        }
    }

    private func configurePlayer(_ player: SCNAnimationPlayer, loop: Bool) {
        player.animation.repeatCount = loop ? .greatestFiniteMagnitude : 1
        player.animation.isRemovedOnCompletion = false
        player.speed = 1
    }

    private func settleToIdle(after duration: TimeInterval, generation: Int) {
        let delay = max(0.6, min(duration, 4.0))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self,
                  self.playbackGeneration == generation,
                  !self.paused,
                  self.currentStateKey != PetLogicalState.idle.rawValue else { return }
            self.play(state: PetLogicalState.idle.rawValue)
        }
    }

    /// Resolve a logical state to a glTF clip name present in `clipPlayers`.
    private func resolveClipName(for logical: String, in model: PetDefinition.Model3D) -> String? {
        let clips = model.clips ?? [:]
        // 1. Direct petdef mapping for this logical state.
        if let mapped = clips[logical], clipPlayers[mapped] != nil { return mapped }
        // 2. Logical aliases (mirror the 2D backend's choreography table).
        for alias in Self.clipCandidates(for: logical) {
            if let mapped = clips[alias], clipPlayers[mapped] != nil { return mapped }
        }
        // 3. petdef default-ish: first mapped clip that actually loaded.
        for (_, clipName) in clips where clipPlayers[clipName] != nil { return clipName }
        // 4. Any harvested player at all.
        return clipPlayers.keys.first
    }

    /// A gentle vertical bob for static models / reduced-clip pets, so an idle
    /// pet reads as alive without a rig. Skipped under reduced motion.
    private func applyIdleBob() {
        guard let contentRoot, !reducedMotion, !paused else { return }
        contentRoot.removeAction(forKey: Self.idleBobActionKey)
        let up = SCNAction.moveBy(x: 0, y: 0.06, z: 0, duration: 1.1)
        up.timingMode = .easeInEaseOut
        let down = up.reversed()
        let bob = SCNAction.repeatForever(.sequence([up, down]))
        contentRoot.runAction(bob, forKey: Self.idleBobActionKey)
    }

    /// Add a camera and key light if the imported scene didn't ship one, so the
    /// model is actually visible. Idempotent.
    private func ensureCameraAndLights(in scene: SCNScene) {
        // Frame with a PERSPECTIVE camera fit to the model's actual bounding
        // sphere (SceneKit-computed, skin-aware) so a model of any native scale
        // is centered and fully in frame. The previous fixed *orthographic*
        // camera (orthographicScale 2.75 at z=4.2) assumed a perfectly
        // pre-normalized ~2-unit model centered at the origin; real founder rigs
        // (sub-centimeter native scale, skinned) ended up mis-framed and the
        // panel rendered nothing even though the geometry decoded and rasterized.
        let sphere = scene.rootNode.boundingSphere
        let center = sphere.center
        let radius = CGFloat(sphere.radius)
        let safeRadius = (radius.isFinite && radius > 0) ? radius : 1

        let cameraNode = scene.rootNode.childNode(withName: "pet.camera", recursively: true) ?? {
            let node = SCNNode()
            node.name = "pet.camera"
            node.camera = SCNCamera()
            scene.rootNode.addChildNode(node)
            return node
        }()
        let camera = cameraNode.camera ?? SCNCamera()
        cameraNode.camera = camera
        camera.usesOrthographicProjection = false
        camera.fieldOfView = 60
        // Pull back ~3 sphere-radii: frames the model at a comfortable size in the
        // panel without clipping, and tolerates the model sitting slightly off the
        // bounding-sphere centre once skinned.
        let distance = safeRadius * 3
        // Keep the near/far planes GENEROUS. A skinned mesh can deform well beyond
        // its bind-pose bounding sphere, so a tight frustum (distance ± a couple
        // radii) clips the entire model and the panel renders nothing. A small
        // near plane and a far plane far past the model avoid clipping.
        camera.zNear = 0.01
        camera.zFar = Double(distance + safeRadius * 200)
        cameraNode.position = SCNVector3(center.x, center.y, center.z + distance)
        cameraNode.look(at: center)
        scnView.pointOfView = cameraNode

        if scene.rootNode.childNode(withName: "pet.key", recursively: true) == nil {
            let light = SCNNode()
            light.name = "pet.key"
            light.light = SCNLight()
            light.light?.type = .omni
            light.position = SCNVector3(2, 4, 5)
            scene.rootNode.addChildNode(light)
        }
    }

    // MARK: Logical → clip aliases

    /// Bridge canonical logical states to common GLB clip slugs, mirroring the
    /// SpriteKit backend's `atlasCandidates` so behavior graphs are form-agnostic.
    private static func clipCandidates(for logical: String) -> [String] {
        switch logical {
        case "idle":   return ["idle"]
        case "wander": return ["walk", "travel", "scuttle"]
        case "drag":   return ["walk", "travel", "scuttle"]
        case "listen": return ["listen", "wave", "idle"]
        case "greeting": return ["wave", "listen", "idle"]
        case "think":  return ["think", "confused", "clean", "scoop", "work", "idle"]
        case "speak":  return ["nod", "listen", "wave", "talk", "work", "idle"]
        case "work":   return ["clean", "scoop", "work", "idle"]
        case "clean":  return ["clean", "scoop", "work", "idle"]
        case "scoop":  return ["scoop", "clean", "work", "idle"]
        case "sleep":  return ["sleep", "doze", "idle"]
        case "react":  return ["cheer", "clap", "jump", "dance", "celebrate", "react", "idle"]
        case "success": return ["victory", "cheer", "celebrate", "clap", "jump", "dance", "react", "idle"]
        default:       return []
        }
    }

    private static func shouldLoop(logical: String, clipName: String) -> Bool {
        let looping = Set([
            "idle", "idleVar", "walk", "wander", "listen", "think", "sleep",
            "doze", "sip", "phone", "sitDown"
        ])
        return looping.contains(logical) || looping.contains(clipName)
    }

    private func installInteractionRecognizers() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleRotationPan(_:)))
        scnView.addGestureRecognizer(pan)

        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
        scnView.addGestureRecognizer(magnify)

        scnView.onScrollScale = { [weak self] deltaY in
            guard let self else { return }
            // Scroll resizes the whole pet (its panel); the camera fills the view
            // so the rendered pet scales with the window instead of clipping.
            self.resizePanel(by: exp(deltaY * InteractionDefaults.scrollScaleSensitivity))
            self.persistWindowFrame()
        }
    }

    /// Plain drag repositions the floating pet; Option-drag rotates the model.
    @objc private func handleRotationPan(_ recognizer: NSPanGestureRecognizer) {
        let rotating = NSEvent.modifierFlags.contains(.option)
        switch recognizer.state {
        case .began:
            if rotating {
                let t = recognizer.translation(in: scnView)
                rotateModel(by: t.x * InteractionDefaults.rotationSensitivity)
                recognizer.setTranslation(.zero, in: scnView)
            } else {
                dragStartWindowOrigin = scnView.window?.frame.origin
                dragStartMouse = NSEvent.mouseLocation
            }
        case .changed:
            if rotating {
                let t = recognizer.translation(in: scnView)
                rotateModel(by: t.x * InteractionDefaults.rotationSensitivity)
                recognizer.setTranslation(.zero, in: scnView)
                if abs(t.x) > 1 { play(state: "lookAround") }
            } else if let window = scnView.window,
                      let origin = dragStartWindowOrigin, let start = dragStartMouse {
                // Absolute cursor tracking avoids feedback jitter as the window moves.
                let now = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(x: origin.x + (now.x - start.x),
                                              y: origin.y + (now.y - start.y)))
            }
        case .ended, .cancelled:
            if !rotating { persistWindowFrame() }
            dragStartWindowOrigin = nil
            dragStartMouse = nil
        default:
            break
        }
    }

    @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            resizePanel(by: max(0.5, 1 + recognizer.magnification))
            recognizer.magnification = 0
        case .ended, .cancelled:
            persistWindowFrame()
        default:
            break
        }
    }

    /// Resize the floating pet's panel (aspect-locked, clamped), anchored at the
    /// bottom centre so the pet grows from where it sits. The SCNView autoresizes
    /// and the camera fills the view, so the rendered pet scales with the panel.
    func resizePanel(by factor: CGFloat) {
        guard factor.isFinite, factor > 0, let window = scnView.window else { return }
        let frame = window.frame
        let newWidth = min(InteractionDefaults.maxPanelWidth,
                           max(InteractionDefaults.minPanelWidth, frame.width * factor))
        let newHeight = newWidth * InteractionDefaults.panelAspect
        let origin = NSPoint(x: frame.midX - newWidth / 2, y: frame.minY)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: newWidth, height: newHeight)), display: true)
        (window as? PetPanel)?.clamp(to: (window as? PetPanel)?.bestScreen)
    }

    private func persistWindowFrame() {
        guard let window = scnView.window else { return }
        PetWindowState.store(window.frame, for: definition.id)
    }

    private static func storedYaw(for petID: String) -> CGFloat {
        let value = UserDefaults.standard.double(forKey: InteractionDefaults.yawPrefix + petID)
        return value.isFinite ? CGFloat(value) : 0
    }

    private static func storeYaw(_ yaw: CGFloat, for petID: String) {
        UserDefaults.standard.set(Double(yaw), forKey: InteractionDefaults.yawPrefix + petID)
    }

    private static func storedScale(for petID: String) -> CGFloat {
        let value = UserDefaults.standard.double(forKey: InteractionDefaults.scalePrefix + petID)
        guard value.isFinite, value > 0 else { return 1 }
        return clampedScale(CGFloat(value))
    }

    private static func storeScale(_ scale: CGFloat, for petID: String) {
        UserDefaults.standard.set(Double(clampedScale(scale)), forKey: InteractionDefaults.scalePrefix + petID)
    }

    private static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(InteractionDefaults.maximumScale, max(InteractionDefaults.minimumScale, scale))
    }

    private static func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 0 }
        let twoPi = CGFloat.pi * 2
        var value = angle.truncatingRemainder(dividingBy: twoPi)
        if value > .pi { value -= twoPi }
        if value < -.pi { value += twoPi }
        return value
    }
}

private final class InteractivePetSceneView: SCNView, PetDropHostingView {
    var onScrollScale: ((CGFloat) -> Void)?

    /// Drop delegate installed by ``PetCompanionController``; `nil` until the
    /// controller wires it, so an unconfigured view is drop-through rather than
    /// a silent no-op. Held weakly — the controller owns the delegate, so the
    /// view observes without forming a controller↔view↔delegate retain cycle.
    weak var dropDelegate: PetAttachmentDropDelegate?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        if delta != 0 {
            onScrollScale?(delta)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: File drag-and-drop

    /// Register the types the pet accepts. Called by the controller after it
    /// installs ``dropDelegate`` so the view participates in AppKit's drag
    /// session only when wired.
    func registerPetDropTypes() {
        registerForDraggedTypes(PetAttachmentDropDelegate.acceptableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        petDropEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        petDropEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        petDropPerform(sender)
    }
}

// MARK: - Pet window frame persistence

/// Persists the floating pet panel's frame (position + size) per pet id so a
/// repositioned / resized companion stays put across relaunches.
enum PetWindowState {
    private static let prefix = "pet.window.frame."

    static func store(_ frame: NSRect, for petID: String) {
        let value = "\(frame.origin.x),\(frame.origin.y),\(frame.size.width),\(frame.size.height)"
        UserDefaults.standard.set(value, forKey: prefix + petID)
    }

    static func storedFrame(for petID: String) -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + petID) else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0,
              parts.allSatisfy({ $0.isFinite }) else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}

// MARK: - Renderer registration

extension SceneKitPetRenderer {
    /// Install the SceneKit 3D backend for `model3d` forms while leaving atlas
    /// forms on the SpriteKit backend. The integrator calls this once at launch
    /// after ``SpriteKitPetRenderer/registerAsDefault(on:)`` so 2D stays default
    /// and 3D routes here.
    @MainActor
    static func register(on controller: PetCompanionController) {
        let spriteFactory = controller.rendererFactory
        controller.rendererFactory = { definition, form in
            switch form {
            case .model3d:
                return SceneKitPetRenderer(definition: definition, form: form)
            case .atlas2d:
                return spriteFactory(definition, form)
            }
        }
    }
}
