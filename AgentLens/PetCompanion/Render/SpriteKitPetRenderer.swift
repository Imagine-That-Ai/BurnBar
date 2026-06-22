import AppKit
import CoreGraphics
import SpriteKit

// MARK: - SpriteKitPetRenderer

/// The 2D atlas backend (PLAN C4). Conforms to ``PetRenderer``: it slices the
/// pet's sprite sheet into per-state `SKTexture` strips using the shared
/// 192×208 geometry (anchor 96/196), plays the strip for the current logical
/// state, and energy-gates the `SKView` (`isPaused`) so an occluded/asleep pet
/// costs ~0% CPU (PLAN §4 — pause the **view**, not the scene).
///
/// Frame rects come straight from ``PetDefinition/Atlas2D`` so there is no
/// per-frame metadata to sync with the web runtime — both compute the same
/// `row × cell` math. Sprite filtering is `.nearest` to keep pixel art crisp.
@MainActor
final class SpriteKitPetRenderer: NSObject, PetRenderer {

    // MARK: PetRenderer surface

    let definition: PetDefinition
    private(set) var form: PetForm
    var view: NSView { skView }

    // MARK: SpriteKit state

    private let skView: SKView
    private let scene: SKScene
    private let sprite: SKSpriteNode

    /// The full sheet texture for the current form; per-frame textures are
    /// normalised sub-rects of it. `nil` until assets resolve (placeholder draws).
    private var sheetTexture: SKTexture?
    /// Atlas pixel size (grid × cell), the divisor for normalised sub-rects.
    private var atlasPixelSize: CGSize = .zero
    /// Cached per-logical-state texture strips, keyed by resolved atlas-state key.
    private var stripCache: [String: [SKTexture]] = [:]

    private var currentStateKey: String
    private var facing: CGFloat = 1
    private var reducedMotion = false
    private var ambientFrameRate = 15
    private let animationActionKey = "pet.state"

    // MARK: Init

    init(definition: PetDefinition, form: PetForm) {
        self.definition = definition
        self.form = form

        let cellSize: CGSize
        if let atlas = definition.atlas2d {
            cellSize = CGSize(width: atlas.cell.w, height: atlas.cell.h)
        } else {
            cellSize = PetPanel.defaultSize
        }

        let frame = CGRect(origin: .zero, size: cellSize)
        let view = SKView(frame: frame)
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 15
        // Performance niceties that are safe to leave on for a tiny scene.
        view.showsFPS = false
        view.showsNodeCount = false
        self.skView = view

        let scene = SKScene(size: cellSize)
        scene.backgroundColor = .clear
        scene.scaleMode = .aspectFit
        self.scene = scene

        // Anchor the sprite so its "feet" sit on the atlas baseline. petdef anchor
        // is top-left origin; SpriteKit is bottom-left, so flip the y fraction.
        let node = SKSpriteNode(color: .clear, size: cellSize)
        if let atlas = definition.atlas2d {
            let fx = atlas.anchor.x / max(atlas.cell.w, 1)
            let fyBottom = (atlas.cell.h - atlas.anchor.y) / max(atlas.cell.h, 1)
            node.anchorPoint = CGPoint(x: fx, y: fyBottom)
            node.position = CGPoint(x: cellSize.width * fx, y: cellSize.height * fyBottom)
        } else {
            node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            node.position = CGPoint(x: cellSize.width / 2, y: cellSize.height / 2)
        }
        self.sprite = node
        self.currentStateKey = definition.atlas2d?.defaultState ?? PetLogicalState.idle.rawValue

        super.init()

        scene.addChild(node)
        loadSheet(for: form)
    }

    // MARK: Mount / unmount

    func mount(in container: NSView) {
        skView.frame = container.bounds
        skView.autoresizingMask = [.width, .height]
        if skView.superview !== container {
            container.addSubview(skView)
        }
        if skView.scene == nil {
            skView.presentScene(scene)
        }
        play(state: currentStateKey)
    }

    func unmount() {
        // 2D atlas is cheap to keep resident, but release on unmount to return
        // toward baseline memory and stop the display link entirely.
        skView.isPaused = true
        skView.presentScene(nil)
        skView.removeFromSuperview()
    }

    // MARK: Form swap (C8)

    func setForm(_ form: PetForm) {
        guard form != self.form else { return }
        self.form = form
        stripCache.removeAll(keepingCapacity: true)
        loadSheet(for: form)
        play(state: currentStateKey)
    }

    // MARK: Playback

    func play(state: String) {
        currentStateKey = state
        guard let atlas = definition.atlas2d,
              let resolved = resolveAtlasState(state, in: atlas) else {
            return
        }
        let desc = resolved.descriptor
        let frames = strip(forResolvedKey: resolved.key, descriptor: desc, atlas: atlas)

        sprite.removeAction(forKey: animationActionKey)
        // Face direction via x-scale sign (travel states lean into motion).
        sprite.xScale = abs(sprite.xScale) * (facing < 0 ? -1 : 1)

        guard !frames.isEmpty else { return }
        sprite.size = CGSize(width: atlas.cell.w, height: atlas.cell.h)

        if frames.count == 1 || reducedMotion {
            // Reduced motion (or single-frame state): settle on the key pose.
            sprite.texture = frames[0]
            return
        }

        let fps = max(desc.fps, 1)
        let frameTime = 1.0 / Double(fps)
        let animate = SKAction.animate(with: frames, timePerFrame: frameTime,
                                       resize: false, restore: false)
        sprite.run(desc.loop ? .repeatForever(animate) : animate, withKey: animationActionKey)
    }

    func setFacing(_ direction: CGFloat) {
        let sign: CGFloat = direction < 0 ? -1 : 1
        guard sign != (facing < 0 ? -1 : 1) else { facing = sign; return }
        facing = sign
        sprite.xScale = abs(sprite.xScale) * sign
    }

    // MARK: Energy gating (PLAN §4)

    func setPaused(_ paused: Bool) {
        // Pause the *view* so the GPU/display link goes idle; the scene graph and
        // textures stay resident for an instant resume.
        skView.isPaused = paused
        if !paused {
            // Re-assert in case a non-looping action stranded while paused.
            play(state: currentStateKey)
        }
    }

    func setAmbientFrameRate(_ fps: Int) {
        ambientFrameRate = max(fps, 1)
        skView.preferredFramesPerSecond = ambientFrameRate
    }

    func setReducedMotion(_ reduced: Bool) {
        guard reduced != reducedMotion else { return }
        reducedMotion = reduced
        play(state: currentStateKey)
    }

    func socketPoint(_ name: String) -> CGPoint? {
        guard let atlas = definition.atlas2d, let p = atlas.socketPoint(name) else { return nil }
        let size = skView.bounds.size == .zero
            ? CGSize(width: atlas.cell.w, height: atlas.cell.h)
            : skView.bounds.size
        guard atlas.cell.w > 0, atlas.cell.h > 0 else { return nil }
        return CGPoint(x: p.x / atlas.cell.w * size.width,
                       y: p.y / atlas.cell.h * size.height)
    }

    func containsVisibleContent(at point: CGPoint) -> Bool {
        let scenePoint = scene.convertPoint(fromView: point)
        guard sprite.calculateAccumulatedFrame().contains(scenePoint) else { return false }
        let localPoint = sprite.convert(scenePoint, from: scene)
        let size = sprite.size
        guard size.width > 0, size.height > 0 else { return false }

        let normalized = CGPoint(
            x: (localPoint.x / size.width) + sprite.anchorPoint.x,
            y: (localPoint.y / size.height) + sprite.anchorPoint.y
        )
        let horizontalInset: CGFloat = 0.14
        return (horizontalInset...(1 - horizontalInset)).contains(normalized.x)
            && (0.06...0.96).contains(normalized.y)
    }

    // MARK: Sheet loading

    /// Resolve the form's image to an `SKTexture`. Looks the bundled resource up
    /// by name (PNG master / webp / the `sprite` fallback) and slices on demand.
    private func loadSheet(for form: PetForm) {
        guard let atlas = definition.atlas2d else { sheetTexture = nil; return }
        atlasPixelSize = atlas.atlasPixelSize

        let imageName: String
        switch form {
        case .atlas2d(let name): imageName = name
        case .model3d:
            // A 3D form on the 2D backend: fall back to the atlas image so the
            // controller still shows something until the SceneKit backend (C5).
            imageName = atlas.image ?? "sprite"
        }

        if let image = Self.loadImage(named: imageName, petID: definition.id, in: .main),
           let tex = Self.makeTexture(from: image) {
            tex.filteringMode = .nearest
            sheetTexture = tex
        } else {
            sheetTexture = nil
        }
    }

    /// First atlas-state key present for `logical` (via the same candidate aliases
    /// the renderer protocol implies), then the pet's default, then any state.
    private func resolveAtlasState(
        _ logical: String,
        in atlas: PetDefinition.Atlas2D
    ) -> (key: String, descriptor: PetDefinition.Atlas2D.State)? {
        if let exact = atlas.states[logical] { return (logical, exact) }
        for key in Self.atlasCandidates(for: logical) {
            if let s = atlas.states[key] { return (key, s) }
        }
        let fallback = atlas.defaultState
        if let s = atlas.states[fallback] { return (fallback, s) }
        if let first = atlas.states.first { return (first.key, first.value) }
        return nil
    }

    /// Build (and cache) the texture strip for a resolved atlas-state key.
    private func strip(
        forResolvedKey key: String,
        descriptor desc: PetDefinition.Atlas2D.State,
        atlas: PetDefinition.Atlas2D
    ) -> [SKTexture] {
        if let cached = stripCache[key] { return cached }
        guard let sheet = sheetTexture, atlasPixelSize.width > 0, atlasPixelSize.height > 0 else {
            stripCache[key] = []
            return []
        }
        var frames: [SKTexture] = []
        frames.reserveCapacity(max(desc.frames, 1))
        for i in 0..<max(desc.frames, 1) {
            let px = atlas.textureRect(state: desc, frame: i, atlasPixelHeight: atlasPixelSize.height)
            let normalized = CGRect(
                x: px.minX / atlasPixelSize.width,
                y: px.minY / atlasPixelSize.height,
                width: px.width / atlasPixelSize.width,
                height: px.height / atlasPixelSize.height
            )
            let tex = SKTexture(rect: normalized, in: sheet)
            tex.filteringMode = .nearest
            frames.append(tex)
        }
        stripCache[key] = frames
        return frames
    }

    // MARK: Logical → atlas key aliases

    /// Bridge canonical logical states to both modern petdef rows and legacy
    /// sweeper rows (PET-ATLAS-CONTRACT). Mirrors the web runtime's mapping.
    private static func atlasCandidates(for logical: String) -> [String] {
        switch logical {
        case "idle":   return ["idle"]
        case "wander": return ["travel", "scuttle", "walk"]
        case "drag":   return ["travel", "scuttle", "walk"]
        case "listen": return ["listen", "alert", "idle"]
        case "think":  return ["work", "pinch_sweep", "claw_scoop"]
        case "speak":  return ["work", "pinch_sweep"]
        case "sleep":  return ["sleep"]
        case "react":  return ["cheer", "alert"]
        default:       return []
        }
    }

    // MARK: Asset helpers

    /// Resolve a bundled sprite image by resource name. Tries the name verbatim,
    /// then common atlas extensions, then the conventional `Pets/<id>/` subfolder.
    private static func loadImage(named name: String, petID: String, in bundle: Bundle) -> NSImage? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let candidates = ext.isEmpty ? ["png", "webp"] : [ext]

        if let direct = NSImage(named: name) { return direct }
        let subdirectories: [String?] = [nil, "Pets/\(petID)"]
        for e in candidates {
            for subdirectory in subdirectories {
                if let url = bundle.url(forResource: base, withExtension: e, subdirectory: subdirectory),
                   let img = NSImage(contentsOf: url) {
                    return img
                }
            }
        }
        return nil
    }

    private static func makeTexture(from image: NSImage) -> SKTexture? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return SKTexture(cgImage: cg)
    }
}

// MARK: - Renderer registration

extension SpriteKitPetRenderer {
    /// Install the SpriteKit 2D backend as the controller's default renderer
    /// factory. Atlas forms get this backend; 3D forms fall through to it too
    /// until the SceneKit backend (C5) registers itself. The integrator calls
    /// this once at launch (see `PetCompanionFeature.activateIfEnabled`).
    @MainActor
    static func registerAsDefault(on controller: PetCompanionController) {
        controller.rendererFactory = { definition, form in
            SpriteKitPetRenderer(definition: definition, form: form)
        }
    }
}
