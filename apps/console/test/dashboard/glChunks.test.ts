import { describe, expect, it } from "vitest";

import { MAIN, PRELUDE, UNIFORM_NAMES, VERT } from "@/lib/gl/chunks";
import {
  DEFAULT_KERNEL_ID,
  KERNEL_SPECS,
  getKernelSpec,
  isKernelId,
} from "@/lib/gl/kernels";
import { hexToRgbUnit } from "@/lib/gl/palette";

const HEX6 = /^#[0-9a-fA-F]{6}$/;

describe("shader assembly", () => {
  it("PRELUDE is a WebGL2 (GLSL ES 3.00) preamble declaring every uniform", () => {
    expect(PRELUDE).toContain("#version 300 es");
    expect(PRELUDE).toContain("out vec4 fragColor");
    for (const name of UNIFORM_NAMES) {
      expect(PRELUDE.includes(name)).toBe(true);
    }
  });

  it("VERT generates a fullscreen triangle from gl_VertexID", () => {
    expect(VERT).toContain("#version 300 es");
    expect(VERT).toContain("gl_VertexID");
  });

  it("MAIN calls the kernel body and writes fragColor", () => {
    expect(MAIN).toContain("renderKernel(");
    expect(MAIN).toContain("fragColor =");
  });

  it("every kernel body defines renderKernel and assembles into one program", () => {
    for (const spec of KERNEL_SPECS) {
      expect(spec.body).toContain("vec3 renderKernel(vec2 uv, vec2 fragCoord)");
      const program = PRELUDE + spec.body + MAIN;
      // exactly one main(), one renderKernel definition.
      expect((program.match(/void main\(\)/g) || []).length).toBe(1);
      expect((program.match(/vec3 renderKernel\(/g) || []).length).toBe(1);
    }
  });
});

describe("kernel specs", () => {
  it("has 5 kernels with unique ids", () => {
    expect(KERNEL_SPECS).toHaveLength(5);
    expect(new Set(KERNEL_SPECS.map((k) => k.id)).size).toBe(5);
  });

  it("palettes are 4 accent hex stops + base + ink", () => {
    for (const { palette } of KERNEL_SPECS) {
      expect(palette.accents).toHaveLength(4);
      for (const c of palette.accents) expect(c).toMatch(HEX6);
      expect(palette.base).toMatch(HEX6);
      expect(palette.ink).toMatch(HEX6);
    }
  });

  it("the default kernel resolves and is valid", () => {
    expect(isKernelId(DEFAULT_KERNEL_ID)).toBe(true);
    expect(getKernelSpec(DEFAULT_KERNEL_ID).id).toBe(DEFAULT_KERNEL_ID);
  });

  it("getKernelSpec falls back for an unknown id", () => {
    // @ts-expect-error — deliberately invalid id
    expect(getKernelSpec("does-not-exist").id).toBe(DEFAULT_KERNEL_ID);
    expect(isKernelId("does-not-exist")).toBe(false);
  });
});

describe("hexToRgbUnit", () => {
  it("parses #rrggbb to 0..1 triples", () => {
    expect(hexToRgbUnit("#ff0000")).toEqual([1, 0, 0]);
    expect(hexToRgbUnit("#00ff00")).toEqual([0, 1, 0]);
    expect(hexToRgbUnit("#0000ff")).toEqual([0, 0, 1]);
  });
  it("expands #rgb shorthand", () => {
    expect(hexToRgbUnit("#fff")).toEqual([1, 1, 1]);
  });
  it("falls back to mid-grey for garbage", () => {
    expect(hexToRgbUnit("nope")).toEqual([0.5, 0.5, 0.5]);
  });
});
