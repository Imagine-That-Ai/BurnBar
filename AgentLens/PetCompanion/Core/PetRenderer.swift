import AppKit
import CoreGraphics
import Foundation

// MARK: - PetRenderer

/// The contract every visual backend conforms to. C4 implements a SpriteKit 2D
/// backend (atlas → `SKTexture` strips); C5 implements a SceneKit/GLTFKit2 3D
/// backend (GLB → named clips). The coordinator (``PetCompanionController``)
/// talks only to this protocol, so swapping a pet's *form* between 2D and 3D is
/// a renderer swap with an unchanged behavior graph.
///
/// `@MainActor`: renderers own AppKit/SpriteKit/SceneKit view state, which is
/// main-thread-only — matching the app's "AppKit only at the shell, on the main
/// actor" convention.
@MainActor
protocol PetRenderer: AnyObject {
    /// The definition this renderer draws (provides atlas/model geometry + states).
    var definition: PetDefinition { get }

    /// The form this renderer realises (2D atlas vs 3D model).
    var form: PetForm { get }

    /// The root view to install into the panel's `contentView`. Transparent
    /// outside the pet silhouette so the panel stays click-through where empty.
    var view: NSView { get }

    /// Mount the renderer into `container` (add `view` as a subview, set up the
    /// scene/atlas, prime the default state). Idempotent: calling twice re-uses
    /// the existing view. Call once when the panel appears.
    func mount(in container: NSView)

    /// Tear down GPU/scene resources (textures, SceneKit graph) and remove the
    /// view. C5's 3D backend frees its model here to return toward baseline
    /// memory; C4's 2D backend keeps its atlas resident but can release on demand.
    func unmount()

    /// Play `state` (a logical state name, e.g. from ``BehaviorInterpreter/current``).
    /// Resolves to a sprite row (`atlas2d.states[state]`) or a named clip
    /// (`model3d.clips[state]`); falls back to the pet's default state when the
    /// name is unknown. Looping vs once is read from the state descriptor.
    func play(state: String)

    /// Convenience overload for the canonical logical states.
    func play(_ state: PetLogicalState)

    /// Swap the rendered form without recreating the controller/panel (C8 "form
    /// picker … swaps skin without restart"). Re-mounts against `form`'s assets,
    /// preserving the currently-playing logical state.
    func setForm(_ form: PetForm)

    /// Face/lean direction for travel states. `+1` faces right, `-1` faces left.
    /// Drives sprite flipping / model yaw; clamped to the sign.
    func setFacing(_ direction: CGFloat)

    /// Energy gating (PLAN §4 "cost nothing when nobody's looking"). When paused,
    /// the backend stops its display link / sets `SKView.isPaused = true` and
    /// must drop to ~0% CPU. The coordinator pauses on occlusion / display sleep
    /// / screen lock and resumes on wake.
    func setPaused(_ paused: Bool)

    /// Ambient frame-rate ceiling for the *idle* loop (e.g. 12–15 fps ambient,
    /// 10–12 under Low Power Mode, burst to 60 only on interaction). Backends
    /// clamp their preferred frame rate to this.
    func setAmbientFrameRate(_ fps: Int)

    /// Honour `NSWorkspace.accessibilityDisplayShouldReduceMotion`: freeze ambient
    /// wander to a settled frame while keeping functional state changes visible
    /// (PLAN §6). Default behavior may no-op for static forms.
    func setReducedMotion(_ reduced: Bool)

    /// Resolve a named socket (`atlas2d.sockets`, e.g. `"contact"`) to a point in
    /// the renderer view's coordinate space, so the chat bubble can anchor its
    /// tail to the creature. Returns `nil` when the socket is undefined.
    func socketPoint(_ name: String) -> CGPoint?

    /// Whether a click in renderer-view coordinates is close enough to visible
    /// pet content to count as a pet click.
    func containsVisibleContent(at point: CGPoint) -> Bool
}

// MARK: - Default conveniences

extension PetRenderer {
    func play(_ state: PetLogicalState) { play(state: state.rawValue) }

    func setReducedMotion(_ reduced: Bool) {}

    func socketPoint(_ name: String) -> CGPoint? {
        // Default: derive from the atlas socket fractions against the current
        // view size. 3D backends can override with a projected anchor.
        guard let atlas = definition.atlas2d,
              let p = atlas.socketPoint(name) else { return nil }
        let size = view.bounds.size
        let cell = atlas.cell
        guard cell.w > 0, cell.h > 0 else { return nil }
        return CGPoint(x: p.x / cell.w * size.width, y: p.y / cell.h * size.height)
    }

    func containsVisibleContent(at point: CGPoint) -> Bool {
        view.bounds.contains(point)
    }
}

// MARK: - PetForm

/// Which form a renderer realises. Carries the resolved asset reference so the
/// controller can choose a backend and a renderer can locate its files.
enum PetForm: Hashable, Sendable {
    /// 2D sprite atlas. `imageName` is the bundled PNG master resource name.
    case atlas2d(imageName: String)
    /// 3D model. `glbName` is the bundled GLB resource name.
    case model3d(glbName: String)

    var isAtlas: Bool { if case .atlas2d = self { return true } else { return false } }
    var isModel: Bool { if case .model3d = self { return true } else { return false } }
}

extension PetDefinition {
    /// The pet's preferred default form: 2D atlas when present, else 3D model.
    var defaultForm: PetForm? {
        if let atlas = atlas2d {
            return .atlas2d(imageName: atlas.image ?? "sprite")
        }
        if let model = model3d {
            return .model3d(glbName: model.glb)
        }
        return nil
    }
}
