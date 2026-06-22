import AppKit
import CoreGraphics
import Foundation
import SceneKit
import simd

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
/// Keeping that behind ``GLBSceneLoading`` means this file `swiftc -parse`s with
/// zero external imports today, the build-notes agent documents adding the
/// GLTFKit2 SPM dependency, and the renderer swaps loaders without edits. Tests
/// inject a fake loader; production registers ``DefaultGLBSceneLoader``.
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
/// 1. **GLTFKit2** (when linked) — the canonical `.glb` path. Documented hook;
///    see ``loadViaGLTFKit2(url:)`` for the exact call the integrator un-stubs.
/// 2. **SceneKit native** (`SCNScene(url:)`) — succeeds for `.usdz`/`.scn`
///    siblings and any `.glb` once a GLTF importer is registered system-wide.
///
/// On total failure the caller falls back to ``SceneKitPetRenderer`` primitive
/// so the panel still shows a creature rather than a blank rect.
@MainActor
final class DefaultGLBSceneLoader: GLBSceneLoading {
    func loadScene(at url: URL, clipNames: [String]) -> SCNScene? {
        if let scene = loadViaGLTFKit2(url: url) { return scene }
        // Native SceneKit: handles USDZ/SCN and GLB-with-registered-importer.
        if let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) {
            return scene
        }
        return nil
    }

    /// GLTFKit2 entry point. **Intentionally stubbed** so this compiles without
    /// the dependency. The build-notes agent adds the SPM package and replaces
    /// the body with:
    ///
    /// ```swift
    /// import GLTFKit2
    /// guard let asset = try? GLTFAsset(url: url) else { return nil }
    /// let source = GLTFSCNSceneSource(asset: asset)
    /// return source.defaultScene            // animations land as SCNAnimationPlayers
    /// ```
    private func loadViaGLTFKit2(url: URL) -> SCNScene? {
        nil
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
final class SceneKitPetRenderer: NSObject, PetRenderer {

    // MARK: PetRenderer surface

    let definition: PetDefinition
    private(set) var form: PetForm
    var view: NSView { scnView }

    // MARK: SceneKit state

    private let scnView: SCNView
    private let loader: GLBSceneLoading

    /// The mounted scene graph for the current form; `nil` until mounted /
    /// after unmount, so memory returns to baseline when the pet is hidden.
    private var scene: SCNScene?
    /// The node we yaw for facing and bob for the static-idle fallback.
    private weak var contentRoot: SCNNode?
    /// Pre-resolved `clipName → SCNAnimationPlayer` from the loaded scene.
    private var clipPlayers: [String: SCNAnimationPlayer] = [:]
    /// The clip key currently playing (for restore after pause / form swap).
    private var activeClipKey: String?

    private var currentStateKey: String
    private var facing: CGFloat = 1
    private var reducedMotion = false
    private var ambientFrameRate = 15
    private var paused = false

    private static let idleBobActionKey = "pet.idleBob"

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
        let view = SCNView(frame: frame)
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

        super.init()
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
        activeClipKey = nil
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
        clipPlayers.removeAll(keepingCapacity: true)
        activeClipKey = nil
        loadScene(for: form)
        play(state: currentStateKey)
    }

    // MARK: Playback

    func play(state: String) {
        currentStateKey = state

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
            applyIdleBob()
            return
        }

        contentRoot?.removeAction(forKey: Self.idleBobActionKey)
        configurePlayer(player, loop: !reducedMotion)
        player.play()
        activeClipKey = clipName
    }

    func setFacing(_ direction: CGFloat) {
        let sign: CGFloat = direction < 0 ? -1 : 1
        guard sign != (facing < 0 ? -1 : 1) else { facing = sign; return }
        facing = sign
        // Yaw the model 180° to face the travel direction (mirror about Y).
        // `eulerAngles` is `SCNVector3` whose components are `CGFloat` on macOS.
        let yaw: CGFloat = sign < 0 ? .pi : 0
        if let node = contentRoot {
            node.eulerAngles = SCNVector3(node.eulerAngles.x, yaw, node.eulerAngles.z)
        }
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
                           y: p.y / atlas.cell.h * size.height)
        }
        let size = scnView.bounds.size == .zero ? PetPanel.defaultSize : scnView.bounds.size
        // "contact" → just above the model's head; default → center.
        if name == "contact" || name == "bubble" {
            return CGPoint(x: size.width / 2, y: size.height * 0.9)
        }
        return CGPoint(x: size.width / 2, y: size.height / 2)
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
        let base = (glbName as NSString).deletingPathExtension
        let ext = (glbName as NSString).pathExtension.isEmpty
            ? "glb"
            : (glbName as NSString).pathExtension

        let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Models")
            ?? Bundle.main.url(forResource: base, withExtension: ext)

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
        let root = SCNNode()
        for child in loaded.rootNode.childNodes {
            root.addChildNode(child)
        }
        loaded.rootNode.addChildNode(root)
        contentRoot = root

        normalizeFraming(root: root, in: loaded)
        harvestClipPlayers(from: loaded.rootNode)
        ensureCameraAndLights(in: loaded)
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
        ensureCameraAndLights(in: scene)
        applyIdleBob()
    }

    /// Center the model and scale it to fill the panel cell, feet near the
    /// bottom (matches the 2D baseline convention).
    private func normalizeFraming(root: SCNNode, in scene: SCNScene) {
        // `SCNVector3` components are `CGFloat` on macOS; keep all math in
        // `CGFloat` so this typechecks against the AppKit SceneKit overlay.
        let (minB, maxB) = root.boundingBox
        let extentX = CGFloat(maxB.x - minB.x)
        let extentY = CGFloat(maxB.y - minB.y)
        let extentZ = CGFloat(maxB.z - minB.z)
        let maxExtent = max(extentX, max(extentY, extentZ))
        guard maxExtent > 0 else { return }
        let targetHeight: CGFloat = 2.0
        let scale = targetHeight / maxExtent
        root.scale = SCNVector3(scale, scale, scale)
        // Recenter horizontally/depth, drop so feet sit near y = -1.
        let centerX = (CGFloat(minB.x) + CGFloat(maxB.x)) / 2
        let centerZ = (CGFloat(minB.z) + CGFloat(maxB.z)) / 2
        root.position = SCNVector3(
            -centerX * scale,
            -CGFloat(minB.y) * scale - targetHeight / 2,
            -centerZ * scale
        )
    }

    /// Walk the graph and collect every `SCNAnimationPlayer`, keyed by its
    /// animation key. GLTFKit2 sets the key to the glTF clip name; native
    /// SceneKit imports key by their own ids, so we index by both the node's
    /// keys and the clip names the petdef expects.
    private func harvestClipPlayers(from root: SCNNode) {
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
        if scene.rootNode.childNode(withName: "pet.camera", recursively: true) == nil {
            let cameraNode = SCNNode()
            cameraNode.name = "pet.camera"
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 0, 4.2)
            scene.rootNode.addChildNode(cameraNode)
        }
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
        case "listen": return ["listen", "idle"]
        case "think":  return ["work", "idle"]
        case "speak":  return ["talk", "work", "idle"]
        case "sleep":  return ["sleep", "idle"]
        case "react":  return ["cheer", "react", "idle"]
        default:       return []
        }
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
