import CoreGraphics
import Foundation

// MARK: - PetDefinition

/// Swift `Codable` mirror of the shared `@imaginethat/petcore` `PetDefinition`
/// (PLAN §3, `schema: "petdef/1"`). The JSON is the wire format: this struct and
/// the TypeScript `PetDefinition` decode the **same** `petdef.json` / `pet.json`.
///
/// The schema is a strict *superset* of today's `pet.json` (the 17 atlas pets and
/// the Codex exporter keep working unchanged), so every field beyond the legacy
/// `pet.json` core is optional. A legacy `pet.json` that carries top-level
/// `grid`/`cell`/`anchor`/`states` (the PET-ATLAS-CONTRACT shape) is normalised
/// into an ``PetDefinition/Atlas2D`` via ``PetDefinition/init(from:)``.
///
/// `Sendable` so the definition can cross actor boundaries: it is a pure value
/// type with no reference members, mirroring the app's value-model convention.
struct PetDefinition: Codable, Hashable, Sendable {
    /// Schema tag, e.g. `"petdef/1"`. Absent in legacy `pet.json`.
    var schema: String?
    var id: String
    var name: String
    /// Pet family, e.g. `"sweeper"`.
    var kind: String?
    var displayName: String?
    /// Catalog grouping used by the form picker (e.g. Founders / Legends).
    var group: String?
    var description: String?
    /// Identity swatches (locked palette per the atlas contract).
    var palette: [String]?

    /// 2D sprite-atlas form. Present for every atlas pet.
    var atlas2d: Atlas2D?
    /// Optional 3D form (rigged or static GLB). `nil` for atlas-only pets.
    var model3d: Model3D?

    /// JSON-serialisable behavior graph (weighted transitions). See ``Behavior``.
    var behavior: PetBehaviorGraph?

    /// Mechanic + locomotion identifiers used by the shared choreography tables.
    var behaviorMechanic: String?
    var locomotion: String?

    /// Agent wiring (desktop providers, web function, persona, voice lines).
    var agent: AgentConfig?

    /// IP / licensing metadata that travels with the asset bundle.
    var license: License?

    enum CodingKeys: String, CodingKey {
        case schema, id, name, kind, displayName, group, description, palette
        case atlas2d, model3d, forms, behavior, behaviorMechanic, locomotion, agent, license
        // Legacy top-level `pet.json` atlas keys (PET-ATLAS-CONTRACT v1).
        case legacyGrid = "grid"
        case legacyCell = "cell"
        case legacyAnchor = "anchor"
        case legacyAtlas = "atlas"
        case legacyStates = "states"
        case legacyDefault = "default"
        case legacySpritesheet = "spritesheet"
        case legacySpritesheetPath = "spritesheetPath"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        palette = try c.decodeIfPresent([String].self, forKey: .palette)
        let canonicalForms = try c.decodeIfPresent([PetDefinitionForm].self, forKey: .forms) ?? []
        model3d = try c.decodeIfPresent(Model3D.self, forKey: .model3d)
            ?? canonicalForms.compactMap(\.model3d).first
        behavior = try c.decodeIfPresent(PetBehaviorGraph.self, forKey: .behavior)
        behaviorMechanic = try c.decodeIfPresent(String.self, forKey: .behaviorMechanic)
        locomotion = try c.decodeIfPresent(String.self, forKey: .locomotion)
        agent = try c.decodeIfPresent(AgentConfig.self, forKey: .agent)
        license = try c.decodeIfPresent(License.self, forKey: .license)

        // Prefer the modern nested `atlas2d`; otherwise normalise a legacy
        // top-level `pet.json` atlas into the same structure.
        if let nested = try c.decodeIfPresent(Atlas2D.self, forKey: .atlas2d) {
            atlas2d = nested
        } else if let grid = try c.decodeIfPresent(Atlas2D.Grid.self, forKey: .legacyGrid),
                  let cell = try c.decodeIfPresent(Atlas2D.Cell.self, forKey: .legacyCell),
                  let states = try c.decodeIfPresent([String: Atlas2D.State].self, forKey: .legacyStates) {
            let anchor = try c.decodeIfPresent(Atlas2D.Anchor.self, forKey: .legacyAnchor)
                ?? Atlas2D.Anchor(x: Atlas2D.defaultAnchorX, y: Atlas2D.defaultBaselineY)
            let image = try c.decodeIfPresent(String.self, forKey: .legacySpritesheet)
                ?? c.decodeIfPresent(String.self, forKey: .legacySpritesheetPath)
                ?? "spritesheet.webp"
            let def = try c.decodeIfPresent(String.self, forKey: .legacyDefault)
            atlas2d = Atlas2D(
                image: image,
                imageWeb: nil,
                grid: grid,
                cell: cell,
                anchor: anchor,
                states: states,
                default: def,
                sockets: nil
            )
        } else if let canonicalAtlas = canonicalForms.compactMap(\.atlas2d).first {
            atlas2d = canonicalAtlas
        } else {
            atlas2d = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(palette, forKey: .palette)
        try c.encodeIfPresent(atlas2d, forKey: .atlas2d)
        try c.encodeIfPresent(model3d, forKey: .model3d)
        try c.encodeIfPresent(behavior, forKey: .behavior)
        try c.encodeIfPresent(behaviorMechanic, forKey: .behaviorMechanic)
        try c.encodeIfPresent(locomotion, forKey: .locomotion)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(license, forKey: .license)
    }
}

// MARK: - Atlas2D

extension PetDefinition {
    /// 2D sprite-atlas form: an 8×N grid of `cell.w × cell.h` frames.
    /// Geometry matches `.claude/sweep-swarm/PET-ATLAS-CONTRACT.md` (v1).
    struct Atlas2D: Codable, Hashable, Sendable {
        /// Canonical atlas geometry constants (PET-ATLAS-CONTRACT v1).
        static let defaultCellWidth: CGFloat = 192
        static let defaultCellHeight: CGFloat = 208
        static let defaultColumns: Int = 8
        static let defaultAnchorX: CGFloat = 96
        static let defaultBaselineY: CGFloat = 196
        static let defaultSafeInset: CGFloat = 14

        /// Portable PNG master (Swift bundle). The web alt is ``imageWeb``.
        var image: String?
        var imageWeb: String?
        var grid: Grid
        var cell: Cell
        var anchor: Anchor
        /// Logical-state → frame-strip descriptor. Keys are the same logical
        /// state names the behavior graph emits (`idle`/`travel`/`work`/…).
        var states: [String: State]
        var `default`: String?
        /// Fractional anchor points on the cell (e.g. bubble contact, intake).
        var sockets: [String: Socket]?

        struct Grid: Codable, Hashable, Sendable {
            var cols: Int
            var rows: Int
        }

        struct Cell: Codable, Hashable, Sendable {
            var w: CGFloat
            var h: CGFloat
        }

        struct Anchor: Codable, Hashable, Sendable {
            var x: CGFloat
            var y: CGFloat
        }

        struct Socket: Codable, Hashable, Sendable {
            var fx: CGFloat
            var fy: CGFloat
        }

        /// One animation row: `frames` cells starting at column 0 of `row`.
        struct State: Codable, Hashable, Sendable {
            var row: Int
            var frames: Int
            var fps: Int
            var loop: Bool
            /// The signature "working its tool" action (exactly one per pet).
            var hero: Bool?
        }
    }
}

// MARK: - Frame-rect helper (matches the TS `frameRect` math, A2)

extension PetDefinition.Atlas2D {
    /// Top-left-origin pixel rect of `frame` (0-based) within `state`'s row.
    ///
    /// Mirrors the shared TS helper exactly:
    /// `x = frame * cell.w`, `y = row * cell.h`, size = `cell.w × cell.h`.
    /// Frames clamp into `[0, frames)` so an over-run never reads a neighbour row.
    func frameRect(state stateName: String, frame: Int) -> CGRect? {
        guard let state = states[stateName] else { return nil }
        return frameRect(state: state, frame: frame)
    }

    func frameRect(state: State, frame: Int) -> CGRect {
        let clamped = max(0, min(frame, max(state.frames - 1, 0)))
        return CGRect(
            x: CGFloat(clamped) * cell.w,
            y: CGFloat(state.row) * cell.h,
            width: cell.w,
            height: cell.h
        )
    }

    /// Bottom-left-origin (SpriteKit/Core-Graphics texture space) rect for `frame`,
    /// computed from the atlas's total pixel height. Backends that sample a
    /// flipped texture space (SpriteKit) use this; UI that draws top-left uses
    /// ``frameRect(state:frame:)-(State,_)``.
    func textureRect(state: State, frame: Int, atlasPixelHeight: CGFloat) -> CGRect {
        let top = frameRect(state: state, frame: frame)
        return CGRect(
            x: top.minX,
            y: atlasPixelHeight - top.maxY,
            width: top.width,
            height: top.height
        )
    }

    /// Full atlas pixel size derived from `grid` × `cell` (no per-frame metadata).
    var atlasPixelSize: CGSize {
        CGSize(width: CGFloat(grid.cols) * cell.w, height: CGFloat(grid.rows) * cell.h)
    }

    /// Resolve a named socket into a cell-space point (top-left origin).
    func socketPoint(_ name: String) -> CGPoint? {
        guard let s = sockets?[name] else { return nil }
        return CGPoint(x: s.fx * cell.w, y: s.fy * cell.h)
    }

    /// The default/initial logical state, falling back to `"idle"`.
    var defaultState: String { `default` ?? "idle" }
}

// MARK: - Model3D

extension PetDefinition {
    /// Optional 3D form. The GLB is the cross-runtime master; USDZ is AR-only.
    struct Model3D: Codable, Hashable, Sendable {
        /// `"rigged"` (multi-clip) or `"static"` (single mesh).
        var kind: String?
        var glb: String
        /// Logical-state → named GLB clip (same state vocabulary as atlas states).
        var clips: [String: String]?
        /// Raw semantic clip list from `pets-3d.json`, preserved verbatim by the
        /// sync bridge. This is the reaction brain's source of truth for what a
        /// model actually carries; `clips` may also contain compatibility aliases.
        var clipNames: [String]?
        var preview: String?
        var usdz: String?
        /// Static props grafted onto skeleton sockets (rigged forms only). Mirrors
        /// the web `Model3dForm.props`; the SAME petdef JSON drives both runtimes.
        var props: [PetProp]?

        var availableSemanticClips: Set<String> {
            var names = Set(clipNames ?? [])
            if let clips {
                names.formUnion(clips.keys)
                names.formUnion(clips.values)
            }
            return names
        }
    }

    /// A static prop (tool/hat/accessory) attached to a named skeleton socket and
    /// offset by a bone-local transform. Cross-runtime mirror of petcore `PetProp`.
    struct PetProp: Codable, Hashable, Sendable {
        var id: String
        var glb: String
        /// semantic socket alias ("rightHand") or a raw bone name ("RightHand").
        var socket: String
        var transform: PetPropTransform?
        /// show the prop only while the pet is in one of these logical states.
        var visibleStates: [String]?
        /// hide the prop while in one of these states (e.g. ["sleep"]); hidden wins.
        var hiddenStates: [String]?
        var label: String?
    }

    /// Bone-local offset for an attached prop. `scale` accepts a JSON number
    /// (uniform) or a `[x, y, z]` array — both normalize to three components here.
    struct PetPropTransform: Hashable, Sendable {
        var position: [Double]?
        var rotationEuler: [Double]?
        var scale: [Double]?
    }
}

extension PetDefinition.PetPropTransform: Codable {
    enum CodingKeys: String, CodingKey { case position, rotationEuler, scale }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decodeIfPresent([Double].self, forKey: .position)
        rotationEuler = try c.decodeIfPresent([Double].self, forKey: .rotationEuler)
        if let uniform = try? c.decode(Double.self, forKey: .scale) {
            scale = [uniform, uniform, uniform]
        } else if let vec = try? c.decode([Double].self, forKey: .scale) {
            scale = vec
        } else {
            scale = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(rotationEuler, forKey: .rotationEuler)
        try c.encodeIfPresent(scale, forKey: .scale)
    }
}

extension PetDefinition.PetProp {
    /// Semantic socket aliases → ordered candidate bone names. Mirror of petcore
    /// `SOCKET_BONES`; insulates the data from rig-naming drift. An empty list
    /// (`root`) means "attach to the content root, not a bone".
    static let socketBones: [String: [String]] = [
        "rightHand": ["RightHand", "mixamorig:RightHand", "hand_r", "Hand_R"],
        "leftHand": ["LeftHand", "mixamorig:LeftHand", "hand_l", "Hand_L"],
        "rightForeArm": ["RightForeArm", "mixamorig:RightForeArm", "forearm_r"],
        "leftForeArm": ["LeftForeArm", "mixamorig:LeftForeArm", "forearm_l"],
        "head": ["Head", "mixamorig:Head", "head"],
        "spine": ["Spine2", "Spine1", "Spine", "mixamorig:Spine2", "mixamorig:Spine1", "mixamorig:Spine"],
        "hips": ["Hips", "mixamorig:Hips", "pelvis"],
        "root": [],
    ]

    /// Resolve a socket (alias or raw bone name) against the rig's bone names →
    /// the matching bone, or `nil` for the scene-root socket / no match.
    static func resolveSocketBone(_ socket: String, available: Set<String>) -> String? {
        if let candidates = socketBones[socket] {
            if candidates.isEmpty { return nil }            // "root" → content root
            return candidates.first { available.contains($0) }
        }
        return available.contains(socket) ? socket : nil    // unknown → literal bone name
    }

    /// Whether the prop should be visible while the pet is in `state`
    /// (`visibleStates` gates show, `hiddenStates` always wins).
    func isVisible(in state: String) -> Bool {
        if let hidden = hiddenStates, hidden.contains(state) { return false }
        if let visible = visibleStates, !visible.isEmpty { return visible.contains(state) }
        return true
    }
}

private struct PetDefinitionForm: Decodable {
    var atlas2d: PetDefinition.Atlas2D?
    var model3d: PetDefinition.Model3D?

    enum CodingKeys: String, CodingKey {
        case kind, modelKind, glb, clips, clipNames, preview, usdz, props
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "atlas2d":
            atlas2d = try PetDefinition.Atlas2D(from: decoder)
            model3d = nil
        case "model3d":
            atlas2d = nil
            model3d = PetDefinition.Model3D(
                kind: try c.decodeIfPresent(String.self, forKey: .modelKind) ?? "rigged",
                glb: try c.decode(String.self, forKey: .glb),
                clips: try c.decodeIfPresent([String: String].self, forKey: .clips),
                clipNames: try c.decodeIfPresent([String].self, forKey: .clipNames),
                preview: try c.decodeIfPresent(String.self, forKey: .preview),
                usdz: try c.decodeIfPresent(String.self, forKey: .usdz),
                props: try c.decodeIfPresent([PetDefinition.PetProp].self, forKey: .props)
            )
        default:
            atlas2d = nil
            model3d = nil
        }
    }
}

// MARK: - AgentConfig

extension PetDefinition {
    struct AgentConfig: Codable, Hashable, Sendable {
        /// Ordered desktop provider ids, e.g. `["hermes","codex","claude"]`.
        var providersDesktop: [String]?
        var webFunction: String?
        var persona: String?
        var voiceLines: String?
    }
}

// MARK: - License

extension PetDefinition {
    struct License: Codable, Hashable, Sendable {
        var ipStatus: String?
        var licenseNote: String?
        var attribution: String?
    }
}

// MARK: - Loading

extension PetDefinition {
    /// Decode a `petdef.json` / `pet.json` from raw bytes.
    static func decode(from data: Data) throws -> PetDefinition {
        try JSONDecoder().decode(PetDefinition.self, from: data)
    }

    /// Decode from a file URL.
    static func load(contentsOf url: URL) throws -> PetDefinition {
        try decode(from: Data(contentsOf: url))
    }

    /// Decode a bundled pet by id, looking for `petdef.json` then `pet.json`
    /// inside a `Pets/<id>/` or synced `Models/<id>/` resource folder, mirroring
    /// the bundle layout in PLAN §3. Returns `nil` if no definition resource is present.
    static func loadBundled(id: String, in bundle: Bundle = .main) -> PetDefinition? {
        if let url = bundle.url(forResource: "petdef", withExtension: "json", subdirectory: "Models/\(id)")
            ?? bundle.url(forResource: "\(id)/petdef", withExtension: "json", subdirectory: "Models") {
            return try? load(contentsOf: url)
        }

        let candidates = ["petdef", "pet"]
        for name in candidates {
            if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Pets/\(id)")
                ?? bundle.url(forResource: "\(id)/\(name)", withExtension: "json", subdirectory: "Pets") {
                return try? load(contentsOf: url)
            }
        }
        return nil
    }
}

// MARK: - 3D model resource lookup

enum PetModelResourceLocator {
    /// Resolve a bundled GLB for a pet. The current synced layout stores
    /// definitions under `Models/<id>/petdef.json` and GLBs at `Models/<file>`,
    /// while older/manual bundles may place the GLB beside the definition.
    static func url(
        for glbName: String,
        petID: String,
        in bundle: Bundle = .main
    ) -> URL? {
        let base = (glbName as NSString).deletingPathExtension
        let ext = (glbName as NSString).pathExtension.isEmpty
            ? "glb"
            : (glbName as NSString).pathExtension

        return bundle.url(forResource: base, withExtension: ext, subdirectory: "Models/\(petID)")
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Models")
            ?? bundle.url(forResource: "\(petID)/\(base)", withExtension: ext, subdirectory: "Models")
            ?? bundle.url(forResource: base, withExtension: ext)
    }

    /// Resolve a bundled PROP GLB (the static objects pets hold). The sync bridge
    /// copies these to `Models/props/<file>`; fall back to `Models/` for older layouts.
    static func propURL(for glbName: String, in bundle: Bundle = .main) -> URL? {
        let base = (glbName as NSString).deletingPathExtension
        let ext = (glbName as NSString).pathExtension.isEmpty ? "glb" : (glbName as NSString).pathExtension
        return bundle.url(forResource: base, withExtension: ext, subdirectory: "Models/props")
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Models")
            ?? bundle.url(forResource: base, withExtension: ext)
    }
}
