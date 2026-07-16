import Foundation

enum MobileBackdropKernel: String, CaseIterable, Codable, Identifiable, Sendable {
    case constellation
    case flow
    case aurora
    case mesh
    case prismatica
    case moire
    case volumetric
    case iridescence
    case gyroid
    case lic
    case fluidAurora = "fluid-aurora"
    case cloudfield
    case plasmaOrbs = "plasma-orbs"
    case blobsMesh = "blobs-mesh"
    case retroPlasma = "retro-plasma"
    case inversionLattice = "inversion-lattice"
    case vogelBloom = "vogel-bloom"
    case crystalDrift = "crystal-drift"
    case rippleLattice = "ripple-lattice"
    case liquidLumen = "liquid-lumen"
    case spectralDrift = "spectral-drift"
    case myceliumMesh = "mycelium-mesh"
    case oilfield
    case suminagashiDrift = "suminagashi-drift"
    case kineticStipple = "kinetic-stipple"
    case agent1
    case neuralBloom = "neural-bloom"
    case aetherLattice = "aether-lattice"
    case batSignal = "bat-signal"
    case stormSignal = "storm-signal"
    case origami
    case inkDiffusion = "ink-diffusion"
    case petroleumSheen = "petroleum-sheen"
    case boids
    case voxel
    case starAtlas = "star-atlas"
    case skyAscent = "sky-ascent"
    case openWorldArmada = "open-world-armada"
    case genesis
    case singularity
    case knotField = "knot-field"
    case hypersphere

    static let storageKey = "mobileBackdropKernel"
    static let livingThemeStorageKey = "burnbar.livingThemes.selectedKernel"
    /// Keep first launch on the original provider-dot look. The heavier
    /// app.burnbar.ai-inspired kernels remain opt-in from Settings.
    static let defaultKernel: MobileBackdropKernel = .constellation

    var id: String { rawValue }

    static var websiteKernelIDs: [String] {
        allCases.map(\.rawValue)
    }

    /// Kernels implemented by the shared offline WebGL bundle used for the
    /// in-app backdrop. Living Themes may additionally use native renderers.
    static let appBackdropKernelIDs: Set<String> = [
        "constellation", "flow", "aurora", "mesh", "moire", "volumetric", "lic",
        "fluid-aurora", "cloudfield", "plasma-orbs", "blobs-mesh", "retro-plasma",
        "inversion-lattice", "vogel-bloom", "crystal-drift", "ripple-lattice",
        "liquid-lumen", "spectral-drift", "mycelium-mesh", "oilfield",
        "suminagashi-drift", "kinetic-stipple", "agent1", "neural-bloom",
        "aether-lattice", "bat-signal", "storm-signal", "origami", "ink-diffusion",
        "petroleum-sheen", "boids"
    ]

    static var appBackdropKernels: [MobileBackdropKernel] {
        allCases.filter { appBackdropKernelIDs.contains($0.rawValue) }
    }

    static func resolved(_ rawValue: String) -> MobileBackdropKernel {
        MobileBackdropKernel(rawValue: rawValue) ?? defaultKernel
    }

    var label: String {
        switch self {
        case .constellation: return "Constellation"
        case .flow: return "Flow Field"
        case .aurora: return "Aurora"
        case .mesh: return "Iridescent Mesh"
        case .prismatica: return "Prismatica"
        case .moire: return "Moiré"
        case .volumetric: return "Volumetric"
        case .iridescence: return "Iridescence"
        case .gyroid: return "Gyroid"
        case .lic: return "Flow Imaging"
        case .fluidAurora: return "Fluid Aurora"
        case .cloudfield: return "Cloud Field"
        case .plasmaOrbs: return "Plasma Orbs"
        case .blobsMesh: return "Blobs Mesh"
        case .retroPlasma: return "Retro Plasma"
        case .inversionLattice: return "Inversion Lattice"
        case .vogelBloom: return "Vogel Bloom"
        case .crystalDrift: return "Crystal Drift"
        case .rippleLattice: return "Ripple Lattice"
        case .liquidLumen: return "Liquid Lumen"
        case .spectralDrift: return "Spectral Drift"
        case .myceliumMesh: return "Mycelium Mesh"
        case .oilfield: return "Oilfield"
        case .suminagashiDrift: return "Suminagashi Drift"
        case .kineticStipple: return "Kinetic Stipple"
        case .agent1: return "Agent 1"
        case .neuralBloom: return "Neural Bloom"
        case .aetherLattice: return "Aether Lattice"
        case .batSignal: return "Beacon"
        case .stormSignal: return "Tempest"
        case .origami: return "Origami"
        case .inkDiffusion: return "Ink Diffusion"
        case .petroleumSheen: return "Petroleum Sheen"
        case .boids: return "Boids"
        case .voxel: return "Voxel"
        case .starAtlas: return "Star Atlas"
        case .skyAscent: return "Sky Ascent"
        case .openWorldArmada: return "Voxel Armada"
        case .genesis: return "Genesis"
        case .singularity: return "Singularity"
        case .knotField: return "Knot Field"
        case .hypersphere: return "Hypersphere"
        }
    }

    var blurb: String {
        switch self {
        case .constellation: return "Provider marks assemble from the swarm, then whirl off."
        case .flow: return "A curl-noise wind drawn as silky streamlines."
        case .aurora: return "Domain-warped light, drifting in slow ribbons."
        case .mesh: return "A living gradient mesh with fine grain."
        case .prismatica: return "Prismatic facets turn slowly through spectral light."
        case .moire: return "Light interfering through a breathing crystal lattice."
        case .volumetric: return "Crepuscular shafts of light through an unseen medium."
        case .iridescence: return "Thin-film color glides across a liquid metallic field."
        case .gyroid: return "An infinite triply periodic surface folds through light."
        case .lic: return "The same wind as Flow, rendered as honest silk."
        case .fluidAurora: return "Domain-warped fluid ribbons — the 2026 mainstream background standard."
        case .cloudfield: return "Raymarched cloudscape from a compact demoscene kernel — infinite sky."
        case .plasmaOrbs: return "Glassy metaball orbs drift, fuse, and refract."
        case .blobsMesh: return "Softly blending blobs of palette color drift through noise."
        case .retroPlasma: return "A canonical four-sine demoscene plasma."
        case .inversionLattice: return "Nested luminous rings from a circle-inversion lattice."
        case .vogelBloom: return "A golden-angle seed field rotating like a glowing sunflower head."
        case .crystalDrift: return "Drifting Voronoi glass cells with glowing palette seams."
        case .rippleLattice: return "A breathing dot lattice crossed by concentric sonar waves."
        case .liquidLumen: return "Small charges fuse into one flowing lava-lamp color field."
        case .spectralDrift: return "Oriented ribbons of brushed-metal grain."
        case .myceliumMesh: return "Ridged veins knit a breathing mycelial network."
        case .oilfield: return "A flattened oil-paint color field with broad brush patches."
        case .suminagashiDrift: return "Ink-on-water marbling raked into drifting bands."
        case .kineticStipple: return "A curl-noise wind rendered as advected stipple dots."
        case .agent1: return "Organic color blobs drift and merge like liquid silk."
        case .neuralBloom: return "An organic AI-generated color field with blooming latent bands."
        case .aetherLattice: return "Quasicrystal interference breathes through a luminous medium."
        case .batSignal: return "A sweeping searchlight beam catches the emblem on low cloud."
        case .stormSignal: return "A charged storm cell billows with intermittent lightning."
        case .origami: return "Warm kozo paper with quiet folded, cut, washed, and quilled marks."
        case .inkDiffusion: return "Ink wicks into wet fiber and separates into spectral halos."
        case .petroleumSheen: return "Thin-film oil-slick rainbows drift over deep water."
        case .boids: return "A living murmuration — hundreds of birds flocking as one."
        case .voxel: return "A luminous voxel world assembles beyond the glass."
        case .starAtlas: return "A navigable atlas of stars, routes, and deep-space dust."
        case .skyAscent: return "An endless climb through radiant atmosphere and cloud."
        case .openWorldArmada: return "A voxel armada crosses an immense procedural horizon."
        case .genesis: return "Color and structure emerge from a quiet generative origin."
        case .singularity: return "Light bends toward a dense, breathing gravitational core."
        case .knotField: return "Luminous strands weave through a field of impossible knots."
        case .hypersphere: return "A higher-dimensional sphere turns through visible space."
        }
    }

    var rendererFamily: MobileBackdropKernelFamily {
        switch self {
        case .constellation, .boids: return .constellation
        case .flow, .lic, .spectralDrift, .kineticStipple: return .flow
        case .aurora, .fluidAurora, .agent1, .neuralBloom, .genesis: return .ribbons
        case .mesh, .blobsMesh, .liquidLumen, .plasmaOrbs, .singularity, .iridescence: return .orbs
        case .moire, .inversionLattice, .rippleLattice, .aetherLattice, .prismatica, .gyroid, .knotField, .hypersphere: return .lattice
        case .volumetric, .cloudfield, .skyAscent: return .clouds
        case .vogelBloom: return .bloom
        case .crystalDrift: return .crystal
        case .myceliumMesh: return .mycelium
        case .oilfield, .suminagashiDrift, .petroleumSheen, .inkDiffusion: return .marble
        case .batSignal: return .beam
        case .stormSignal: return .storm
        case .retroPlasma: return .plasma
        case .origami: return .paper
        case .voxel, .starAtlas, .openWorldArmada: return .constellation
        }
    }
}

enum MobileBackdropKernelFamily: String, Sendable {
    case constellation
    case flow
    case ribbons
    case orbs
    case lattice
    case clouds
    case bloom
    case crystal
    case mycelium
    case marble
    case beam
    case storm
    case plasma
    case paper
}
