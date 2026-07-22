package com.openburnbar.ui.settings

/**
 * Native mobile catalog mirroring app.burnbar.ai's backdrop kernel registry.
 *
 * The keys are persisted user data and must stay aligned with
 * apps/console/lib/gl/engine/registry.ts. Mobile renders these with native
 * Canvas families rather than embedding the browser WebGL pipeline.
 */
enum class MobileBackdropKernel(
    val key: String,
    val displayName: String,
    val blurb: String,
    val rendererFamily: MobileBackdropKernelFamily,
) {
    CONSTELLATION("constellation", "Constellation", "Provider marks assemble from the swarm, then whirl off.", MobileBackdropKernelFamily.CONSTELLATION),
    FLOW("flow", "Flow Field", "A curl-noise wind drawn as silky streamlines.", MobileBackdropKernelFamily.FLOW),
    AURORA("aurora", "Aurora", "Domain-warped light, drifting in slow ribbons.", MobileBackdropKernelFamily.RIBBONS),
    MESH("mesh", "Iridescent Mesh", "A living gradient mesh with fine grain.", MobileBackdropKernelFamily.ORBS),
    PRISMATICA("prismatica", "Prismatica", "Prismatic facets turn slowly through spectral light.", MobileBackdropKernelFamily.LATTICE),
    MOIRE("moire", "Moiré", "Light interfering through a breathing crystal lattice.", MobileBackdropKernelFamily.LATTICE),
    VOLUMETRIC("volumetric", "Volumetric", "Crepuscular shafts of light through an unseen medium.", MobileBackdropKernelFamily.CLOUDS),
    IRIDESCENCE("iridescence", "Iridescence", "Thin-film color glides across a liquid metallic field.", MobileBackdropKernelFamily.ORBS),
    GYROID("gyroid", "Gyroid", "An infinite triply periodic surface folds through light.", MobileBackdropKernelFamily.LATTICE),
    LIC("lic", "Flow Imaging", "The same wind as Flow, rendered as honest silk.", MobileBackdropKernelFamily.FLOW),
    FLUID_AURORA("fluid-aurora", "Fluid Aurora", "Domain-warped fluid ribbons — the 2026 mainstream background standard.", MobileBackdropKernelFamily.RIBBONS),
    CLOUDFIELD("cloudfield", "Cloud Field", "Raymarched cloudscape from a compact demoscene kernel — infinite sky.", MobileBackdropKernelFamily.CLOUDS),
    PLASMA_ORBS("plasma-orbs", "Plasma Orbs", "Glassy metaball orbs drift, fuse, and refract.", MobileBackdropKernelFamily.ORBS),
    BLOBS_MESH("blobs-mesh", "Blobs Mesh", "Softly blending blobs of palette color drift through noise.", MobileBackdropKernelFamily.ORBS),
    RETRO_PLASMA("retro-plasma", "Retro Plasma", "A canonical four-sine demoscene plasma.", MobileBackdropKernelFamily.PLASMA),
    INVERSION_LATTICE("inversion-lattice", "Inversion Lattice", "Nested luminous rings from a circle-inversion lattice.", MobileBackdropKernelFamily.LATTICE),
    VOGEL_BLOOM("vogel-bloom", "Vogel Bloom", "A golden-angle seed field rotating like a glowing sunflower head.", MobileBackdropKernelFamily.BLOOM),
    CRYSTAL_DRIFT("crystal-drift", "Crystal Drift", "Drifting Voronoi glass cells with glowing palette seams.", MobileBackdropKernelFamily.CRYSTAL),
    RIPPLE_LATTICE("ripple-lattice", "Ripple Lattice", "A breathing dot lattice crossed by concentric sonar waves.", MobileBackdropKernelFamily.LATTICE),
    LIQUID_LUMEN("liquid-lumen", "Liquid Lumen", "Small charges fuse into one flowing lava-lamp color field.", MobileBackdropKernelFamily.ORBS),
    SPECTRAL_DRIFT("spectral-drift", "Spectral Drift", "Oriented ribbons of brushed-metal grain.", MobileBackdropKernelFamily.FLOW),
    MYCELIUM_MESH("mycelium-mesh", "Mycelium Mesh", "Ridged veins knit a breathing mycelial network.", MobileBackdropKernelFamily.MYCELIUM),
    OILFIELD("oilfield", "Oilfield", "A flattened oil-paint color field with broad brush patches.", MobileBackdropKernelFamily.MARBLE),
    SUMINAGASHI_DRIFT("suminagashi-drift", "Suminagashi Drift", "Ink-on-water marbling raked into drifting bands.", MobileBackdropKernelFamily.MARBLE),
    KINETIC_STIPPLE("kinetic-stipple", "Kinetic Stipple", "A curl-noise wind rendered as advected stipple dots.", MobileBackdropKernelFamily.FLOW),
    AGENT1("agent1", "Agent 1", "Organic color blobs drift and merge like liquid silk.", MobileBackdropKernelFamily.RIBBONS),
    NEURAL_BLOOM("neural-bloom", "Neural Bloom", "An organic AI-generated color field with blooming latent bands.", MobileBackdropKernelFamily.RIBBONS),
    AETHER_LATTICE("aether-lattice", "Aether Lattice", "Quasicrystal interference breathes through a luminous medium.", MobileBackdropKernelFamily.LATTICE),
    BAT_SIGNAL("bat-signal", "Beacon", "A sweeping searchlight beam catches the emblem on low cloud.", MobileBackdropKernelFamily.BEAM),
    STORM_SIGNAL("storm-signal", "Tempest", "A charged storm cell billows with intermittent lightning.", MobileBackdropKernelFamily.STORM),
    ORIGAMI("origami", "Origami", "Warm kozo paper with quiet folded, cut, washed, and quilled marks.", MobileBackdropKernelFamily.PAPER),
    INK_DIFFUSION("ink-diffusion", "Ink Diffusion", "Ink wicks into wet fiber and separates into spectral halos.", MobileBackdropKernelFamily.MARBLE),
    PETROLEUM_SHEEN("petroleum-sheen", "Petroleum Sheen", "Thin-film oil-slick rainbows drift over deep water.", MobileBackdropKernelFamily.MARBLE),
    BOIDS("boids", "Boids", "A living murmuration — hundreds of birds flocking as one.", MobileBackdropKernelFamily.CONSTELLATION),
    VOXEL("voxel", "Voxel", "A luminous voxel world assembles beyond the glass.", MobileBackdropKernelFamily.CONSTELLATION),
    STAR_ATLAS("star-atlas", "Star Atlas", "A navigable atlas of stars, routes, and deep-space dust.", MobileBackdropKernelFamily.CONSTELLATION),
    SKY_ASCENT("sky-ascent", "Sky Ascent", "An endless climb through radiant atmosphere and cloud.", MobileBackdropKernelFamily.CLOUDS),
    OPEN_WORLD_ARMADA("open-world-armada", "Voxel Armada", "A voxel armada crosses an immense procedural horizon.", MobileBackdropKernelFamily.CONSTELLATION),
    GENESIS("genesis", "Genesis", "Color and structure emerge from a quiet generative origin.", MobileBackdropKernelFamily.RIBBONS),
    SINGULARITY("singularity", "Singularity", "Light bends toward a dense, breathing gravitational core.", MobileBackdropKernelFamily.ORBS),
    KNOT_FIELD("knot-field", "Knot Field", "Luminous strands weave through a field of impossible knots.", MobileBackdropKernelFamily.LATTICE),
    HYPERSPHERE("hypersphere", "Hypersphere", "A higher-dimensional sphere turns through visible space.", MobileBackdropKernelFamily.LATTICE),
    ;

    companion object {
        val DEFAULT: MobileBackdropKernel = FLUID_AURORA
        val websiteKernelIds: List<String> = entries.map { it.key }

        fun fromKey(key: String?): MobileBackdropKernel? {
            if (key.isNullOrBlank()) return null
            return entries.find { it.key == key }
        }

        fun resolved(key: String?): MobileBackdropKernel = fromKey(key) ?: DEFAULT
    }
}

enum class MobileBackdropKernelFamily {
    CONSTELLATION,
    FLOW,
    RIBBONS,
    ORBS,
    LATTICE,
    CLOUDS,
    BLOOM,
    CRYSTAL,
    MYCELIUM,
    MARBLE,
    BEAM,
    STORM,
    PLASMA,
    PAPER,
}
