import { describe, expect, it } from "vitest";

import {
  DEFAULT_KERNEL_ID,
  KERNELS,
  KERNEL_META,
  getKernelDescriptor,
  isKernelId,
  resolveRenderableKernelId,
} from "@/lib/gl/engine/registry";

const NO_FLOAT = { colorBufferFloat: false, floatBlend: false };
const FLOAT = { colorBufferFloat: true, floatBlend: true };

describe("vendored kernel registry", () => {
  it("ships the curated set with unique ids and matching metadata", () => {
    expect(KERNELS.length).toBe(30);
    expect(KERNEL_META.length).toBe(KERNELS.length);
    expect(new Set(KERNELS.map((k) => k.id)).size).toBe(KERNELS.length);
    // KERNEL_META is import-free metadata (no `create`).
    for (const m of KERNEL_META) {
      expect("create" in m).toBe(false);
      expect(typeof m.label).toBe("string");
      expect(typeof m.blurb).toBe("string");
    }
  });

  it("excludes the dropped sim/swarm/webgpu kernels", () => {
    const ids = new Set<string>(KERNELS.map((k) => k.id));
    for (const dropped of [
      "caustics",
      "wave",
      "boids",
      "attractor",
      "lenia",
      "spiral",
      "cgl",
      "fluid",
      "crystallis",
      "iridescence",
      "halftone",
      "gyroid",
      "voxel",
      "cubelove",
    ]) {
      expect(ids.has(dropped)).toBe(false);
    }
  });

  it("default kernel is the always-renderable 2D constellation", () => {
    expect(DEFAULT_KERNEL_ID).toBe("constellation");
    const def = getKernelDescriptor(DEFAULT_KERNEL_ID);
    expect(def.substrate).toBe("2d");
    expect(isKernelId(DEFAULT_KERNEL_ID)).toBe(true);
  });

  it("isKernelId guards correctly", () => {
    expect(isKernelId("aurora")).toBe(true);
    expect(isKernelId("cubelove")).toBe(false);
    expect(isKernelId("nope")).toBe(false);
    expect(isKernelId(null)).toBe(false);
  });

  it("getKernelDescriptor falls back to the first entry for unknown ids", () => {
    expect(
      getKernelDescriptor("does-not-exist" as unknown as (typeof KERNELS)[number]["id"]).id,
    ).toBe(KERNELS[0]!.id);
  });

  it("never resolves to a black canvas (the D1 guard)", () => {
    // A WebGL2 kernel with no WebGL2 support → the 2D default.
    expect(resolveRenderableKernelId("aurora", NO_FLOAT, false)).toBe(DEFAULT_KERNEL_ID);
    // With WebGL2 present, a single-pass kernel renders itself.
    expect(resolveRenderableKernelId("aurora", FLOAT, true)).toBe("aurora");
    // The 2D default is never gated.
    expect(resolveRenderableKernelId("constellation", NO_FLOAT, false)).toBe("constellation");
  });

  it("every curated kernel resolves to a real, renderable descriptor", () => {
    for (const k of KERNELS) {
      const resolved = resolveRenderableKernelId(k.id, FLOAT, true);
      expect(isKernelId(resolved)).toBe(true);
      // Single-pass/2D kernels (no float requirement) resolve to themselves.
      if (!k.requiresFloatTex) expect(resolved).toBe(k.id);
    }
  });
});
