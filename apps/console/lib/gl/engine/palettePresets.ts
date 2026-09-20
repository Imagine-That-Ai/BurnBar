/**
 * Palette presets — curated, multi-color schemes the user can apply to recolor
 * EVERY world at once (all 34 kernels + the glyphs + the glass UI).
 *
 * A preset is a full {@link KernelPalette} pair (dark + light), so applying one
 * is deterministic — it never inherits a stray channel from the previous look.
 * Each scheme leads with a four-stop accent ramp (the same iris→cyan→violet→rose
 * slot convention every kernel reads via `accentRamp`), tuned separately for the
 * deep-ink dark canvas and the pearl light canvas so both modes are first-class.
 *
 * These are intentionally intricate: each ramp is a small journey across the
 * wheel (not four shades of one hue), chosen to stay legible behind glass text
 * while reading as a single emotional idea — dusk, reef, oxidized copper, etc.
 */

import type { KernelPalette, RGB } from "./types";

export interface PalettePreset {
  id: string;
  label: string;
  /** One-line evocation shown under the swatch. */
  blurb: string;
  /** A tiny emoji glyph for the gallery tile. */
  emoji: string;
  dark: KernelPalette;
  light: KernelPalette;
}

/** Compact builder so the table below stays readable. */
function scheme(
  theme: "dark" | "light",
  bg: RGB,
  accents: [RGB, RGB, RGB, RGB],
  ink: RGB,
  intensity: number,
): KernelPalette {
  return { theme, bg, accents, ink, intensity };
}

/**
 * The default "Studio" identity, surfaced as a preset so "Reset" is just
 * "apply Studio". Mirrors palette.ts DARK/LIGHT exactly (kept in sync by the
 * palettePresets test).
 */
const STUDIO: PalettePreset = {
  id: "studio",
  label: "Studio",
  blurb: "The house identity — iris-led jewel tones over deep ink.",
  emoji: "✦",
  dark: scheme(
    "dark",
    [7, 8, 15],
    [
      [131, 142, 255], // iris
      [120, 220, 232], // cyan
      [176, 142, 255], // violet
      [255, 150, 182], // soft rose
    ],
    [232, 236, 255],
    1,
  ),
  light: scheme(
    "light",
    [244, 246, 251],
    [
      [84, 96, 222],
      [32, 150, 176],
      [124, 96, 212],
      [212, 104, 140],
    ],
    [38, 42, 70],
    0.78,
  ),
};

export const PALETTE_PRESETS: PalettePreset[] = [
  STUDIO,
  {
    id: "aurora-borealis",
    label: "Aurora Borealis",
    blurb: "Polar night — emerald curtains bleeding into electric violet.",
    emoji: "🌌",
    dark: scheme(
      "dark",
      [4, 10, 14],
      [
        [64, 224, 168], // emerald
        [72, 214, 232], // glacier cyan
        [128, 152, 255], // periwinkle
        [196, 132, 255], // violet
      ],
      [224, 244, 240],
      1,
    ),
    light: scheme(
      "light",
      [240, 248, 246],
      [
        [16, 158, 124],
        [28, 150, 176],
        [86, 100, 214],
        [142, 86, 206],
      ],
      [24, 46, 44],
      0.8,
    ),
  },
  {
    id: "ember-forge",
    label: "Ember Forge",
    blurb: "Molten metal — ember orange cooling through coral to ash violet.",
    emoji: "🔥",
    dark: scheme(
      "dark",
      [14, 7, 6],
      [
        [255, 138, 56], // ember
        [255, 92, 92], // coral
        [240, 84, 142], // hot rose
        [168, 110, 220], // ash violet
      ],
      [255, 236, 222],
      1,
    ),
    light: scheme(
      "light",
      [251, 244, 240],
      [
        [214, 96, 24],
        [212, 64, 72],
        [200, 60, 120],
        [134, 78, 188],
      ],
      [56, 30, 24],
      0.82,
    ),
  },
  {
    id: "coral-reef",
    label: "Coral Reef",
    blurb: "Shallow lagoon — turquoise water, living coral, anemone gold.",
    emoji: "🪸",
    dark: scheme(
      "dark",
      [5, 13, 16],
      [
        [54, 226, 214], // turquoise
        [88, 200, 255], // lagoon blue
        [255, 126, 142], // living coral
        [255, 196, 96], // anemone gold
      ],
      [226, 246, 248],
      1,
    ),
    light: scheme(
      "light",
      [240, 250, 250],
      [
        [16, 168, 162],
        [30, 138, 206],
        [224, 86, 104],
        [212, 144, 36],
      ],
      [20, 48, 50],
      0.8,
    ),
  },
  {
    id: "ultraviolet",
    label: "Ultraviolet",
    blurb: "Synthwave dusk — magenta horizon over indigo, cut by cyan neon.",
    emoji: "🌃",
    dark: scheme(
      "dark",
      [10, 6, 20],
      [
        [255, 92, 196], // magenta
        [150, 96, 255], // indigo violet
        [96, 132, 255], // electric blue
        [80, 230, 240], // cyan neon
      ],
      [240, 228, 255],
      1,
    ),
    light: scheme(
      "light",
      [246, 242, 252],
      [
        [206, 48, 156],
        [120, 72, 214],
        [70, 96, 214],
        [24, 158, 178],
      ],
      [40, 26, 64],
      0.8,
    ),
  },
  {
    id: "verdigris",
    label: "Verdigris",
    blurb: "Oxidized copper — patina teal over bronze, weathered to jade.",
    emoji: "🗿",
    dark: scheme(
      "dark",
      [8, 13, 12],
      [
        [72, 204, 180], // patina teal
        [122, 196, 138], // weathered jade
        [206, 178, 110], // aged bronze
        [224, 142, 96], // rust highlight
      ],
      [228, 240, 232],
      1,
    ),
    light: scheme(
      "light",
      [242, 248, 244],
      [
        [22, 150, 132],
        [70, 152, 96],
        [160, 130, 56],
        [186, 100, 56],
      ],
      [28, 44, 40],
      0.8,
    ),
  },
  {
    id: "blackcurrant",
    label: "Blackcurrant",
    blurb: "Orchard at midnight — berry crimson, plum, and frosted mint.",
    emoji: "🍇",
    dark: scheme(
      "dark",
      [12, 7, 14],
      [
        [226, 76, 122], // berry crimson
        [168, 92, 198], // plum
        [120, 110, 224], // blue-violet
        [120, 224, 184], // frosted mint
      ],
      [240, 228, 240],
      1,
    ),
    light: scheme(
      "light",
      [249, 244, 250],
      [
        [196, 52, 100],
        [142, 70, 174],
        [92, 86, 200],
        [36, 162, 124],
      ],
      [48, 28, 50],
      0.8,
    ),
  },
  {
    id: "solar-flare",
    label: "Solar Flare",
    blurb: "Chromosphere — white-gold core through amber to plasma red.",
    emoji: "☀️",
    dark: scheme(
      "dark",
      [16, 9, 4],
      [
        [255, 224, 130], // white-gold
        [255, 168, 64], // amber
        [255, 110, 64], // plasma orange
        [236, 72, 96], // flare red
      ],
      [255, 240, 220],
      1,
    ),
    light: scheme(
      "light",
      [252, 247, 238],
      [
        [206, 158, 28],
        [212, 120, 24],
        [210, 76, 36],
        [196, 52, 76],
      ],
      [54, 32, 18],
      0.82,
    ),
  },
  {
    id: "abyssal",
    label: "Abyssal",
    blurb: "Deep sea — bioluminescent cyan and jellyfish violet in the dark.",
    emoji: "🌊",
    dark: scheme(
      "dark",
      [3, 7, 16],
      [
        [40, 200, 224], // biolum cyan
        [64, 140, 240], // deep blue
        [134, 108, 232], // jellyfish violet
        [196, 96, 200], // anglerfish magenta
      ],
      [214, 234, 248],
      1,
    ),
    light: scheme(
      "light",
      [238, 244, 250],
      [
        [18, 146, 174],
        [34, 102, 200],
        [96, 80, 200],
        [150, 64, 168],
      ],
      [18, 38, 58],
      0.8,
    ),
  },
  {
    id: "sakura-dusk",
    label: "Sakura Dusk",
    blurb: "Blossom hour — petal pink, wisteria, and the last warm sky.",
    emoji: "🌸",
    dark: scheme(
      "dark",
      [14, 9, 13],
      [
        [255, 158, 192], // petal pink
        [214, 142, 232], // wisteria
        [150, 150, 240], // dusk periwinkle
        [255, 192, 150], // warm sky
      ],
      [248, 234, 240],
      1,
    ),
    light: scheme(
      "light",
      [251, 245, 248],
      [
        [220, 102, 150],
        [168, 96, 200],
        [104, 104, 210],
        [212, 134, 78],
      ],
      [52, 32, 44],
      0.78,
    ),
  },
  {
    id: "monochrome-ink",
    label: "Monochrome Ink",
    blurb: "Graphite study — a single luminous channel, sumi restraint.",
    emoji: "⬛",
    dark: scheme(
      "dark",
      [9, 10, 12],
      [
        [210, 216, 230], // bright ink
        [150, 160, 184], // steel
        [104, 116, 146], // slate
        [232, 236, 244], // highlight
      ],
      [235, 238, 245],
      0.92,
    ),
    light: scheme(
      "light",
      [245, 246, 248],
      [
        [70, 78, 96],
        [104, 112, 132],
        [140, 148, 168],
        [40, 46, 60],
      ],
      [28, 32, 42],
      0.74,
    ),
  },
  {
    id: "petrol-slick",
    label: "Petrol Slick",
    blurb: "Oil on wet asphalt — a thin-film rainbow over deep tar.",
    emoji: "🛢️",
    dark: scheme(
      "dark",
      [8, 10, 14], // deep wet tar
      [
        [96, 180, 255], // thin-film blue
        [120, 240, 200], // interference teal-green
        [200, 150, 255], // violet fringe
        [255, 168, 120], // gold-copper crest
      ],
      [228, 236, 248],
      1,
    ),
    light: scheme(
      "light",
      [240, 242, 246], // pale wet sheen
      [
        [58, 140, 214],
        [40, 176, 150],
        [150, 104, 210],
        [206, 122, 70],
      ],
      [34, 40, 54],
      0.76,
    ),
  },
  {
    id: "sumi-bleed",
    label: "Sumi Bleed",
    blurb: "Ink wicking into damp kozo — indigo running to vermillion.",
    emoji: "🖋️",
    dark: scheme(
      "dark",
      [12, 13, 17], // wet dark wash
      [
        [120, 196, 224], // running indigo front
        [150, 226, 214], // cool dye edge
        [196, 156, 232], // mulberry separation
        [255, 150, 130], // vermillion bleed
      ],
      [232, 234, 240],
      0.98,
    ),
    light: scheme(
      "light",
      [243, 240, 232], // warm kozo paper
      [
        [44, 120, 168],
        [36, 150, 150],
        [150, 92, 180],
        [206, 84, 72],
      ],
      [30, 28, 32],
      0.76,
    ),
  },
];

export const DEFAULT_PRESET_ID = "studio";

export function getPreset(id: string): PalettePreset | undefined {
  return PALETTE_PRESETS.find((p) => p.id === id);
}
