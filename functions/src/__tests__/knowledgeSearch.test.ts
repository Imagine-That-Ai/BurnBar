import { describe, expect, it } from "vitest";
import { requireCloakedQueryVector, clampLimit } from "../callables/knowledgeSearch.js";

describe("searchKnowledge input validation", () => {
  it("accepts exactly 384 finite numbers", () => {
    const vec = Array.from({ length: 384 }, (_, i) => i / 1000);
    expect(requireCloakedQueryVector(vec)).toHaveLength(384);
  });
  it("rejects wrong dimensions", () => {
    expect(() => requireCloakedQueryVector([1, 2, 3])).toThrow(/384-dimension/);
    expect(() => requireCloakedQueryVector(Array(385).fill(0))).toThrow(/384-dimension/);
  });
  it("rejects non-finite values", () => {
    const bad = Array(384).fill(0);
    bad[7] = Number.NaN;
    expect(() => requireCloakedQueryVector(bad)).toThrow(/finite/);
  });
  it("rejects non-arrays", () => {
    expect(() => requireCloakedQueryVector("nope")).toThrow();
    expect(() => requireCloakedQueryVector(undefined)).toThrow();
  });
  it("clamps limit to [1, 50]", () => {
    expect(clampLimit(undefined)).toBe(10);
    expect(clampLimit(0)).toBe(1);
    expect(clampLimit(999)).toBe(50);
    expect(clampLimit(25)).toBe(25);
  });
});
