/**
 * Kernel registry — the single source of truth for which backdrops exist.
 *
 * The switcher renders this list and the host constructs from it. Adding a
 * backdrop is: write `kernels/<x>.ts` exporting a factory, add one entry here.
 *
 * Lazy loading: `constellation` and `swarmEmber` (the Linux dashboard default)
 * are imported eagerly so first paint is instant on both shells. Every other
 * kernel's heavy GLSL + helpers are loaded on-demand via dynamic `import()`
 * wrapped in `lazyKernel()`. The proxy exposes `id`/`label`/`substrate`
 * synchronously so the host can size the canvas and pick the right context
 * immediately; the real factory is imported on first `init()`/`frame()`.
 */

import type { GlCapabilities } from "./gl/glCapabilities";
// Eager: these are the default first-paint paths for the macOS and Linux
// shells. Keeping the Linux 2D default eager avoids a transparent canvas while
// a WebKitGTK/Tauri dynamic chunk is still resolving.
import { createConstellationKernel } from "./kernels/constellationKernel";
import { createSwarmEmberKernel } from "./kernels/swarmEmberKernel";
import { lazyKernel } from "./lazyKernel";
import type {
  KernelDescriptor,
  KernelId,
  KernelResolution,
  KernelResolutionReason,
  KernelSubstrate,
} from "./types";

export const KERNELS: KernelDescriptor[] = [
  {
    id: "constellation",
    label: "Constellation",
    blurb: "Provider marks assemble from the swarm, then whirl off.",
    substrate: "2d",
    create: createConstellationKernel,
  },
  {
    id: "flow",
    label: "Flow Field",
    blurb: "A curl-noise wind drawn as silky streamlines.",
    substrate: "2d",
    create: () =>
      lazyKernel("flow", "Flow Field", "2d", () =>
        import("./kernels/flowFieldKernel").then((m) => m.createFlowFieldKernel)),
  },
  {
    id: "aurora",
    label: "Aurora",
    blurb: "Domain-warped light, drifting in slow ribbons.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("aurora", "Aurora", "webgl2", () =>
        import("./kernels/auroraKernel").then((m) => m.createAuroraKernel)),
  },
  {
    id: "mesh",
    label: "Iridescent Mesh",
    blurb: "A living gradient mesh with fine grain.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("mesh", "Iridescent Mesh", "webgl2", () =>
        import("./kernels/meshKernel").then((m) => m.createMeshKernel)),
  },
  {
    id: "moire",
    label: "Moiré",
    blurb: "Light interfering through a breathing crystal lattice.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("moire", "Moiré", "webgl2", () =>
        import("./kernels/moireKernel").then((m) => m.createMoireKernel)),
  },
  {
    id: "volumetric",
    label: "Volumetric",
    blurb: "Crepuscular shafts of light through an unseen medium.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("volumetric", "Volumetric", "webgl2", () =>
        import("./kernels/volumetricKernel").then((m) => m.createVolumetricKernel)),
  },
  {
    id: "lic",
    label: "Flow Imaging",
    blurb: "The same wind as Flow, rendered as honest silk.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("lic", "Flow Imaging", "webgl2", () =>
        import("./kernels/licKernel").then((m) => m.createLicKernel)),
  },
  // ── Wave-2 — eight feat-of-engineering kernels (append-only). ──
  {
    id: "fluid-aurora",
    label: "Fluid Aurora",
    blurb: "Domain-warped fluid ribbons — the 2026 mainstream background standard.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("fluid-aurora", "Fluid Aurora", "webgl2", () =>
        import("./kernels/fluidAuroraKernel").then((m) => m.createFluidAuroraKernel)),
  },
  {
    id: "cloudfield",
    label: "Cloud Field",
    blurb: "Raymarched cloudscape from a 280-char demoscene kernel — infinite sky.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("cloudfield", "Cloud Field", "webgl2", () =>
        import("./kernels/cloudFieldKernel").then((m) => m.createCloudFieldKernel)),
  },
  {
    id: "plasma-orbs",
    label: "Plasma Orbs",
    blurb: "Five glassy metaball orbs drift, fuse, and refract — 2026's chrome-orb standard.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("plasma-orbs", "Plasma Orbs", "webgl2", () =>
        import("./kernels/plasmaOrbsKernel").then((m) => m.createPlasmaOrbsKernel)),
  },
  {
    id: "blobs-mesh",
    label: "Blobs Mesh",
    blurb: "Four softly-blending blobs of palette color drift through simplex noise — the 2026 fluid-mesh-gradient standard.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("blobs-mesh", "Blobs Mesh", "webgl2", () =>
        import("./kernels/blobsMeshKernel").then((m) => m.createBlobsMeshKernel)),
  },
  {
    id: "retro-plasma",
    label: "Retro Plasma",
    blurb: "Future Crew's 1993 four-sine plasma — the canonical demoscene fragment shader, ported verbatim.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("retro-plasma", "Retro Plasma", "webgl2", () =>
        import("./kernels/retroPlasmaKernel").then((m) => m.createRetroPlasmaKernel)),
  },
  {
    id: "inversion-lattice",
    label: "Inversion Lattice",
    blurb: "A 2D Apollonian circle-inversion fractal — infinitely-nested luminous rings.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("inversion-lattice", "Inversion Lattice", "webgl2", () =>
        import("./kernels/inversionLatticeKernel").then((m) => m.createInversionLatticeKernel)),
  },
  {
    id: "vogel-bloom",
    label: "Vogel Bloom",
    blurb: "A golden-angle phyllotaxis seed field — a slowly rotating sunflower head of glowing dots.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("vogel-bloom", "Vogel Bloom", "webgl2", () =>
        import("./kernels/vogelBloomKernel").then((m) => m.createVogelBloomKernel)),
  },
  {
    id: "crystal-drift",
    label: "Crystal Drift",
    blurb: "Drifting Voronoi glass cells with glowing palette seams.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("crystal-drift", "Crystal Drift", "webgl2", () =>
        import("./kernels/crystalDriftKernel").then((m) => m.createCrystalDriftKernel)),
  },
  {
    id: "ripple-lattice",
    label: "Ripple Lattice",
    blurb: "A breathing dot lattice that ripples with concentric sonar waves under the cursor.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("ripple-lattice", "Ripple Lattice", "webgl2", () =>
        import("./kernels/rippleLatticeKernel").then((m) => m.createRippleLatticeKernel)),
  },
  {
    id: "liquid-lumen",
    label: "Liquid Lumen",
    blurb: "Many small charges fuse into one flowing lava-lamp color field.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("liquid-lumen", "Liquid Lumen", "webgl2", () =>
        import("./kernels/liquidLumenKernel").then((m) => m.createLiquidLumenKernel)),
  },
  {
    id: "spectral-drift",
    label: "Spectral Drift",
    blurb: "Oriented ribbons of band-limited Gabor noise — brushed-metal grain that combs around the pointer.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("spectral-drift", "Spectral Drift", "webgl2", () =>
        import("./kernels/spectralDriftKernel").then((m) => m.createSpectralDriftKernel)),
  },
  {
    id: "mycelium-mesh",
    label: "Mycelium Mesh",
    blurb: "Domain-warped ridged-fbm veins knit a breathing mycelial network that reaches toward the cursor.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("mycelium-mesh", "Mycelium Mesh", "webgl2", () =>
        import("./kernels/myceliumMeshKernel").then((m) => m.createMyceliumMeshKernel)),
  },
  {
    id: "oilfield",
    label: "Oilfield",
    blurb: "A living painting: an fbm color field flattened into oil-paint brush patches by a Kuwahara filter.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("oilfield", "Oilfield", "webgl2", () =>
        import("./kernels/oilfieldKernel").then((m) => m.createOilfieldKernel)),
  },
  {
    id: "suminagashi-drift",
    label: "Suminagashi Drift",
    blurb: "Closed-form ink-on-water marbling — drifting drops raked by combs into swirled marble bands.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("suminagashi-drift", "Suminagashi Drift", "webgl2", () =>
        import("./kernels/suminagashiDriftKernel").then((m) => m.createSuminagashiDriftKernel)),
  },
  {
    id: "kinetic-stipple",
    label: "Kinetic Stipple",
    blurb: "A curl-noise wind streams an advected density as discrete, variable-size stipple dots.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("kinetic-stipple", "Kinetic Stipple", "webgl2", () =>
        import("./kernels/kineticStippleKernel").then((m) => m.createKineticStippleKernel)),
  },
  {
    id: "agent1",
    label: "Agent 1",
    blurb: "Domain-warped generative mesh fluid — organic color blobs drift and merge like liquid silk.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("agent1", "Agent 1", "webgl2", () =>
        import("./kernels/agent1Kernel").then((m) => m.createAgent1Kernel)),
  },
  // ── Agent 7: generative AI-to-shader pipeline kernel ──
  {
    id: "neural-bloom",
    label: "Neural Bloom",
    blurb: "Latent FBM fed through a tiny MLP palette network — an organic, ever-shifting AI-generated colour field.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("neural-bloom", "Neural Bloom", "webgl2", () =>
        import("./kernels/neuralBloomKernel").then((m) => m.createNeuralBloomKernel)),
  },
  // ── Agent 10: Aether Lattice — volumetric raymarching + quasicrystal interference ──
  {
    id: "aether-lattice",
    label: "Aether Lattice",
    blurb: "Quasicrystal interference modulates a volumetric medium — luminous, aperiodic lattice shafts breathe through the fog.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("aether-lattice", "Aether Lattice", "webgl2", () =>
        import("./kernels/aetherLatticeKernel").then((m) => m.createAetherLatticeKernel)),
  },
  // ── Signal worlds: two call-sign emblems. Each is a bespoke backdrop (a
  //    sweeping searchlight cone / a charged storm cell with sheet lightning)
  //    paired with a 4-style suite authored in styles/<world>/. ──
  {
    id: "bat-signal",
    label: "Beacon",
    blurb: "A sweeping searchlight beam catches the provider emblem on a low cloud bank — volumetric god-rays, lens bloom, drifting dust.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("bat-signal", "Beacon", "webgl2", () =>
        import("./kernels/beamProjectorKernel").then((m) => m.createBeamProjectorKernel)),
  },
  {
    id: "storm-signal",
    label: "Tempest",
    blurb: "A charged slate storm cell billows behind the emblem — rolling mesocyclone mass with intermittent sheet and fork lightning.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("storm-signal", "Tempest", "webgl2", () =>
        import("./kernels/stormCellKernel").then((m) => m.createStormCellKernel)),
  },
  // ── Paper-craft world: origami/kirigami/sumi/quilling on a warm kozo sheet. ──
  {
    id: "origami",
    label: "Origami",
    blurb: "A hand-made kozo paper sheet — warm fibers, laid lines, a deckle edge — the quiet stage for folded, cut, washed, and quilled marks.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("origami", "Origami", "webgl2", () =>
        import("./kernels/paperfieldKernel").then((m) => m.createPaperfieldKernel)),
  },
  // ── Diffusion worlds: ink wicking into wet fibre + thin-film oil sheen. ──
  {
    id: "ink-diffusion",
    label: "Ink Diffusion",
    blurb: "Ink wicks into wet fibre — capillary chromatography fronts bleed, darken at the rim, and separate into spectral halos.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("ink-diffusion", "Ink Diffusion", "webgl2", () =>
        import("./kernels/inkDiffusionKernel").then((m) => m.createInkDiffusionKernel)),
  },
  {
    id: "petroleum-sheen",
    label: "Petroleum Sheen",
    blurb: "Computed thin-film interference on a flowing oil film — nested oil-slick rainbows drift and marble over deep water.",
    substrate: "webgl2",
    create: () =>
      lazyKernel("petroleum-sheen", "Petroleum Sheen", "webgl2", () =>
        import("./kernels/petroleumSheenKernel").then((m) => m.createPetroleumSheenKernel)),
  },
  // ── CUBELOVE voxel world: eight ways to love a cube. ──
  // ── CUBELOVE premium: WebGPU sparse-voxel path tracer. Degrades to `voxel`. ──
  // ── Boids murmuration: classic Reynolds flocking on the 2D substrate. ──
  {
    id: "boids",
    label: "Boids",
    blurb: "A living murmuration — hundreds of birds flocking as one.",
    substrate: "2d",
    create: () =>
      lazyKernel("boids", "Boids", "2d", () =>
        import("./kernels/boidsKernel").then((m) => m.createBoidsKernel)),
  },
  {
    id: "swarmEmber",
    label: "Swarm Ember",
    blurb: "Embers murmurate into the BurnBar flame, hold with heat, and dissolve.",
    substrate: "2d",
    create: () => createSwarmEmberKernel({ enableSwarmSparkles: true, logoHero: true }),
  },
  ];

export const DEFAULT_KERNEL_ID: KernelId = "constellation";

/** Lightweight metadata for nav/picker UI — never triggers a dynamic import. */
export interface KernelMeta {
  id: KernelId;
  label: string;
  blurb: string;
  substrate: KernelSubstrate;
  requiresFloatTex?: boolean;
  fallbackId?: KernelId;
}

export const KERNEL_META: KernelMeta[] = KERNELS.map(({ create: _, ...meta }) => meta);

export function getKernelDescriptor(id: KernelId): KernelDescriptor {
  return KERNELS.find((k) => k.id === id) ?? KERNELS[0]!;
}

export function isKernelId(value: string | null | undefined): value is KernelId {
  return !!value && KERNELS.some((k) => k.id === value);
}

/**
 * Resolve which kernel to actually mount, given probed GL capabilities
 * (contract D1). Pure + unit-testable. WebGL kernels fall back to the default
 * when WebGL2 is unavailable; float-requiring sim kernels fall back to their
 * `fallbackId` (or the default) when no renderable float target was PROVEN.
 * Resolution happens BEFORE instantiation, so an unsupported sim factory is
 * never constructed and the canvas is never black.
 */
export function resolveRenderableKernelId(
  id: KernelId,
  caps: GlCapabilities,
  glSupported: boolean,
  lookup: (id: KernelId) => KernelDescriptor = getKernelDescriptor
): KernelId {
  return resolveKernelResolution(id, caps, glSupported, lookup).resolvedId;
}

/**
 * Return the complete, stable explanation for a host kernel choice.
 *
 * Keep this pure so desktop, browser, and test hosts can expose the same
 * receipt without constructing a canvas or importing a kernel implementation.
 */
export function resolveKernelResolution(
  id: KernelId,
  caps: GlCapabilities,
  glSupported: boolean,
  lookup: (id: KernelId) => KernelDescriptor = getKernelDescriptor
): KernelResolution {
  const requested = lookup(id);
  let resolvedId = id;
  let reason: KernelResolutionReason = "native";

  if (requested.substrate === "webgl2" && !glSupported) {
    resolvedId = DEFAULT_KERNEL_ID;
    reason = "webgl2-unavailable";
  } else if (requested.requiresFloatTex && !caps.colorBufferFloat) {
    resolvedId = requested.fallbackId ?? DEFAULT_KERNEL_ID;
    reason = "float-target-unavailable";
  }

  const resolved = lookup(resolvedId);
  return {
    requestedId: id,
    resolvedId,
    requestedSubstrate: requested.substrate,
    resolvedSubstrate: resolved.substrate,
    reason,
    fallback: resolvedId !== id,
    glSupported,
  };
}
