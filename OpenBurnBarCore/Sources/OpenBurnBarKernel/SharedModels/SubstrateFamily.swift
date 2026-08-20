import Foundation

// MARK: - Substrate Family (the six, 1:1 with the image kernels)

/// The six native swarm-substrate families. These mirror the six "image" WebGL
/// kernel ids 1:1 (`constellation`/`flow`/`aurora`/`mesh`/`moire`/`volumetric`)
/// so the substrate picker can couple *per active kernel theme*, exactly like the
/// imaginethat-llc glyph picker (Image #3).
///
/// `moire` and `volumetric` are first-class here even though the source kit folds
/// them into `mesh`/`aurora` — our `KernelCatalog` has dedicated ids for them and
/// the ported style suites ship full bespoke families for each.
///
/// Mirrors the cross-platform convention of ``AppSkin`` / ``DashboardLayout`` in
/// `ThemePrimitives.swift`: `String`-raw, `CaseIterable`, `Codable`, `Sendable`,
/// with a `displayName` and a `symbolName`.
public enum SubstrateFamily: String, CaseIterable, Codable, Sendable {
    case constellation
    case flow
    case aurora
    case mesh
    case moire
    case volumetric

    public var displayName: String {
        switch self {
        case .constellation: return "Constellation"
        case .flow:          return "Flow Field"
        case .aurora:        return "Aurora"
        case .mesh:          return "Iridescent Mesh"
        case .moire:         return "Moiré"
        case .volumetric:    return "Volumetric"
        }
    }

    /// SF Symbol used in the picker section header.
    public var symbolName: String {
        switch self {
        case .constellation: return "sparkles"
        case .flow:          return "wind"
        case .aurora:        return "sun.haze"
        case .mesh:          return "circle.hexagongrid"
        case .moire:         return "circle.grid.cross"
        case .volumetric:    return "rays"
        }
    }

    /// The idiom family a kernel id belongs to — the single coupling authority the
    /// picker and the renderer both call. Exact-name kernels map to their own
    /// family; everything else falls to its `FAMILY_BY_WORLD` cousin (ported
    /// verbatim from imaginethat `styles/index.ts`), then to a name heuristic,
    /// then to `.constellation` (DOTS — always legible). Pure, total, never throws.
    public static func forKernel(_ kernelID: String) -> SubstrateFamily {
        if let exact = SubstrateFamily(rawValue: kernelID) { return exact }
        if let cousin = familyByWorld[kernelID] { return cousin }
        return guess(kernelID)
    }

    /// Ported verbatim from `FAMILY_BY_WORLD` (imaginethat `styles/index.ts`).
    /// `moire`/`volumetric` are reached only by their exact kernel ids, so the
    /// source's 4-family cousin codomain is preserved here.
    private static let familyByWorld: [String: SubstrateFamily] = [
        "lic": .flow, "caustics": .flow, "wave": .aurora, "boids": .constellation,
        "iridescence": .mesh, "halftone": .mesh, "gyroid": .mesh, "attractor": .constellation,
        "lenia": .aurora, "spiral": .flow, "cgl": .aurora, "fluid": .flow,
        "fluid-aurora": .aurora, "cloudfield": .constellation, "plasma-orbs": .aurora,
        "crystallis": .mesh, "blobs-mesh": .mesh, "retro-plasma": .aurora,
        "inversion-lattice": .mesh, "vogel-bloom": .mesh, "crystal-drift": .mesh,
        "ripple-lattice": .mesh, "liquid-lumen": .aurora, "spectral-drift": .aurora,
        "mycelium-mesh": .mesh, "oilfield": .mesh, "suminagashi-drift": .flow,
        "kinetic-stipple": .constellation, "bat-signal": .aurora,
        "storm-signal": .constellation, "origami": .mesh,
        // Thin-film iridescent sheen reads as Moiré's spectral-interference idiom.
        "petroleum-sheen": .moire,
        "ink-diffusion": .flow
    ]

    /// Heuristic family for a never-before-seen kernel id (mirrors source `guessFamily`).
    private static func guess(_ id: String) -> SubstrateFamily {
        let w = id.lowercased()
        if w.range(of: #"crystal|lattice|mesh|tile|facet|prism|gyroid|moire|nacre|grid"#,
                   options: .regularExpression) != nil { return .mesh }
        if w.range(of: #"lumen|plasma|aurora|glow|light|spectral|caustic|neon|ember|fire"#,
                   options: .regularExpression) != nil { return .aurora }
        if w.range(of: #"flow|liquid|ink|drift|silk|sumi|fluid|water|current|wave|stream"#,
                   options: .regularExpression) != nil { return .flow }
        return .constellation
    }
}

// MARK: - Shared persistence keys

/// Shared `@AppStorage` / `UserDefaults` keys for substrate selection. Read
/// identically by the core renderer, the macOS desktop-wallpaper host, and iOS —
/// all bind these exact keys in `UserDefaults.standard`, mirroring
/// `KernelBackdropPreferences`.
public enum SwarmSubstratePreferences {
    /// The single selected substrate id, e.g. `"plain"`, `"constellation.starfire"`.
    /// Default ``SubstrateCatalog/plainID`` (`"plain"`) — nothing changes until opt-in.
    public static let substrateKey = "swarmSubstrate"
    /// Master gate so the picker can be toggled off without losing the pick.
    public static let enabledKey = "swarmSubstrateEnabled"
    /// Shared kernel id key read by every native swarm host when resolving which
    /// substrate family should render. Matches the macOS kernel backdrop picker.
    public static let backdropKernelKey = "backdropKernel"
    /// The bundled kernel fallback used when no explicit kernel has been chosen.
    public static let defaultKernelID = "fluid-aurora"

    /// The live selected id, clamped to a real catalog entry. Defaults to plain.
    public static var currentID: String {
        let raw = UserDefaults.standard.string(forKey: substrateKey) ?? SubstrateCatalog.plainID
        return SubstrateCatalog.byID[raw] != nil ? raw : SubstrateCatalog.plainID
    }

    /// Whether the substrate layer is enabled (default off ⇒ identical to today).
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }
}

/// When the WebGL kernel is the living backdrop, the native SwarmCanvas is only
/// the host for an explicitly chosen substrate. It is not a second wallpaper.
///
/// Provider glyphs default to the full roster, so treating a non-empty glyph
/// list as a mount trigger always stacked a 900-particle `TimelineView` on top
/// of WebGL. Glyphs belong in `SwarmColorDriver` (environmental light), not a
/// second simulator.
public enum KernelSwarmOverlayPolicy {
    public static func shouldMountCanvas(substrateEnabled: Bool, substrateID: String) -> Bool {
        substrateEnabled
            && !substrateID.isEmpty
            && substrateID != SubstrateCatalog.plainID
    }
}

// MARK: - Family accent ramp (ported from _family/defaults.ts FAMILY_ACCENT)

/// Per-family accent pair used by picker tiles and as the substrate `stage`
/// fallback. Channels ported from the source `FAMILY_ACCENT` table (0–255 → 0–1).
public enum FamilyAccent {
    public static func a(_ fam: SubstrateFamily) -> RGBA {
        switch fam {
        case .constellation: return RGBA(r: 131/255, g: 142/255, b: 1.0)
        case .flow:          return RGBA(r: 86/255, g: 198/255, b: 224/255)
        case .aurora:        return RGBA(r: 170/255, g: 130/255, b: 1.0)
        case .mesh:          return RGBA(r: 1.0, g: 120/255, b: 180/255)
        case .moire:         return RGBA(r: 188/255, g: 208/255, b: 1.0)
        case .volumetric:    return RGBA(r: 120/255, g: 180/255, b: 1.0)
        }
    }

    public static func a2(_ fam: SubstrateFamily) -> RGBA {
        switch fam {
        case .constellation: return RGBA(r: 150/255, g: 200/255, b: 1.0)
        case .flow:          return RGBA(r: 150/255, g: 236/255, b: 232/255)
        case .aurora:        return RGBA(r: 236/255, g: 150/255, b: 232/255)
        case .mesh:          return RGBA(r: 1.0, g: 186/255, b: 140/255)
        case .moire:         return RGBA(r: 150/255, g: 150/255, b: 1.0)
        case .volumetric:    return RGBA(r: 1.0, g: 200/255, b: 150/255)
        }
    }
}
