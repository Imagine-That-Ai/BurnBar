package com.openburnbar.wallpaper.livingthemes

import com.openburnbar.ui.settings.MobileBackdropKernel

enum class LiveTheme(
    val id: String,
    val title: String,
    val assetID: String = id,
) {
    CONSTELLATION("constellation", "Constellation"),
    FLOW("flow", "Flow Field"),
    AURORA("aurora", "Aurora"),
    MESH("mesh", "Iridescent Mesh"),
    PRISMATICA("prismatica", "Prismatica"),
    MOIRE("moire", "Moiré"),
    VOLUMETRIC("volumetric", "Volumetric"),
    IRIDESCENCE("iridescence", "Iridescence"),
    GYROID("gyroid", "Gyroid"),
    LIC("lic", "Flow Imaging"),
    FLUID_AURORA("fluid-aurora", "Fluid Aurora"),
    CLOUD_FIELD("cloudfield", "Cloud Field"),
    PLASMA_ORBS("plasma-orbs", "Plasma Orbs"),
    BLOBS_MESH("blobs-mesh", "Blobs Mesh"),
    RETRO_PLASMA("retro-plasma", "Retro Plasma"),
    INVERSION_LATTICE("inversion-lattice", "Inversion Lattice"),
    VOGEL_BLOOM("vogel-bloom", "Vogel Bloom"),
    CRYSTAL_DRIFT("crystal-drift", "Crystal Drift"),
    RIPPLE_LATTICE("ripple-lattice", "Ripple Lattice"),
    LIQUID_LUMEN("liquid-lumen", "Liquid Lumen"),
    SPECTRAL_DRIFT("spectral-drift", "Spectral Drift"),
    MYCELIUM_MESH("mycelium-mesh", "Mycelium Mesh"),
    OILFIELD("oilfield", "Oilfield"),
    SUMINAGASHI_DRIFT("suminagashi-drift", "Suminagashi Drift"),
    KINETIC_STIPPLE("kinetic-stipple", "Kinetic Stipple"),
    AGENT1("agent1", "Agent 1"),
    NEURAL_BLOOM("neural-bloom", "Neural Bloom"),
    AETHER_LATTICE("aether-lattice", "Aether Lattice"),
    BAT_SIGNAL("bat-signal", "Beacon"),
    STORM_SIGNAL("storm-signal", "Tempest"),
    ORIGAMI("origami", "Origami"),
    INK_DIFFUSION("ink-diffusion", "Ink Diffusion"),
    PETROLEUM_SHEEN("petroleum-sheen", "Petroleum Sheen"),
    BOIDS("boids", "Boids"),
    VOXEL("voxel", "Voxel"),
    STAR_ATLAS("star-atlas", "Star Atlas"),
    SKY_ASCENT("sky-ascent", "Sky Ascent"),
    OPEN_WORLD_ARMADA("open-world-armada", "Voxel Armada"),
    GENESIS("genesis", "Genesis"),
    SINGULARITY("singularity", "Singularity"),
    KNOT_FIELD("knot-field", "Knot Field"),
    HYPERSPHERE("hypersphere", "Hypersphere"),
    ;

    val backdropKernel: MobileBackdropKernel
        get() = MobileBackdropKernel.resolved(id)

    companion object {
        fun fromID(id: String?): LiveTheme = entries.firstOrNull { it.id == id?.trim()?.lowercase() } ?: CONSTELLATION
    }
}

object LivingThemePrefs {
    const val NAME = "living_themes"
    const val KEY_THEME = "theme_id"
    const val KEY_FPS = "max_fps"
    const val DEFAULT_FPS = 20
}
