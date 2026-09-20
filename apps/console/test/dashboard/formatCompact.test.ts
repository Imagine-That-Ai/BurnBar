import { describe, expect, it } from "vitest";

import { formatCompact } from "@/components/dashboard/cards/primitives";

describe("formatCompact", () => {
  it("keeps small counts as thousands-grouped integers", () => {
    expect(formatCompact(0)).toBe("0");
    expect(formatCompact(742)).toBe("742");
    expect(formatCompact(999)).toBe("999");
  });

  it("uses K and M below a billion", () => {
    expect(formatCompact(1_200)).toBe("1.2K");
    expect(formatCompact(12_300)).toBe("12K");
    expect(formatCompact(1_200_000)).toBe("1.2M");
    expect(formatCompact(12_000_000)).toBe("12M");
  });

  it("uses B and T so lifetime token totals stay readable", () => {
    // The live all-time rollup was 1.085T tokens; the old M ceiling dumped
    // that as "1085491M".
    expect(formatCompact(1_085_491_000_000)).toBe("1.09T");
    expect(formatCompact(1_085_491_000)).toBe("1.09B");
    expect(formatCompact(1_000_000_000)).toBe("1B");
    expect(formatCompact(1_000_000_000_000)).toBe("1T");
  });

  it("bumps a rounded 1000 of one suffix into the next", () => {
    expect(formatCompact(999_600_000)).toBe("1B");
  });

  it("returns an em dash for non-finite input", () => {
    expect(formatCompact(Number.NaN)).toBe("—");
    expect(formatCompact(Number.POSITIVE_INFINITY)).toBe("—");
  });
});
