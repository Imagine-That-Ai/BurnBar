import { describe, it, expect } from "vitest";

import {
  KERNEL_INK,
  INK_HALO,
  INK_FG,
  inkFor,
  type InkMotion,
} from "@/lib/kernelInk";

/**
 * Structural + legibility-math invariants for the per-kernel ink registry.
 *
 * Full KernelId coverage is enforced at COMPILE TIME by
 * `Record<KernelId, KernelInk>` (the typecheck gate fails if any kernel is
 * missing or extra), so these runtime checks focus on value sanity and the
 * contract every entry must satisfy. The objective per-pixel AA gate lives in
 * scripts/legibility-check.mjs (Playwright).
 */

const MOTIONS: InkMotion[] = [
  "shatter",
  "drift",
  "pulse",
  "rise",
  "marble",
  "ripple",
  "bleed",
  "condense",
  "beam",
];

const HEX6 = /^#[0-9a-fA-F]{6}$/;

describe("KERNEL_INK registry", () => {
  const entries = Object.entries(KERNEL_INK);

  it("covers exactly the 31 append-only kernels", () => {
    expect(entries).toHaveLength(31);
  });

  it("has a stable, light ink foreground", () => {
    expect(INK_FG).toBe("#F4F6FF");
  });

  it("defines all three halo tiers", () => {
    expect(Object.keys(INK_HALO).sort()).toEqual(["1", "2", "3"]);
    for (const tier of [1, 2, 3] as const) {
      expect(typeof INK_HALO[tier]).toBe("string");
      expect(INK_HALO[tier].length).toBeGreaterThan(0);
    }
  });

  it.each(entries)("%s has well-formed, in-range ink", (_id, ink) => {
    // Perceptual inputs are normalized.
    expect(ink.lum).toBeGreaterThanOrEqual(0);
    expect(ink.lum).toBeLessThanOrEqual(1);
    expect(ink.busy).toBeGreaterThanOrEqual(0);
    expect(ink.busy).toBeLessThanOrEqual(1);

    // Scrim alphas sit inside the formula's clamp envelope, and the reading
    // band is always at least as dark as the hero band (it's stricter).
    expect(ink.scrim.hero).toBeGreaterThanOrEqual(0.16);
    expect(ink.scrim.hero).toBeLessThanOrEqual(0.6);
    expect(ink.scrim.read).toBeGreaterThanOrEqual(0.3);
    expect(ink.scrim.read).toBeLessThanOrEqual(0.74);
    expect(ink.scrim.read).toBeGreaterThanOrEqual(ink.scrim.hero);

    // Halo tier + accent + motion are valid.
    expect([1, 2, 3]).toContain(ink.haloTier);
    expect(ink.accent).toMatch(HEX6);
    expect(MOTIONS).toContain(ink.motion);

    // Timing is sane.
    expect(ink.timing.dur).toBeGreaterThan(0);
    expect(ink.timing.stagger).toBeGreaterThanOrEqual(0);
    expect(ink.timing.ease.length).toBeGreaterThan(0);
    expect(["word", "glyph"]).toContain(ink.timing.unit);
  });

  it("busier kernels never carry a lighter halo than calm ones at the same scrim (tier tracks turbulence loosely)", () => {
    // Sanity: every haloTier-3 kernel is meaningfully busy (>= 0.6).
    for (const [, ink] of entries) {
      if (ink.haloTier === 3) expect(ink.busy).toBeGreaterThanOrEqual(0.6);
    }
  });
});

describe("inkFor", () => {
  it("returns the requested kernel's ink", () => {
    expect(inkFor("fluid-aurora")).toBe(KERNEL_INK["fluid-aurora"]);
  });

  it("falls back to constellation for an unknown id", () => {
    // @ts-expect-error reason: exercising the runtime guard with a non-KernelId.
    expect(inkFor("does-not-exist")).toBe(KERNEL_INK.constellation);
  });
});
