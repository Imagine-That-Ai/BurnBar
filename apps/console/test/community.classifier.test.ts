import { describe, expect, it } from "vitest";
import goldens from "../../../tests/fixtures/classifier-goldens.json";
import { classifyPurpose, signalFingerprint } from "@/lib/community/classifier";

type Golden = {
  name: string;
  signals: Record<string, unknown>;
  expected?: string;
  minConfidence?: number;
  expectedFingerprint?: string;
  corrections?: { fingerprint: string; correctedTo: string }[];
};

describe("community classifier (console port)", () => {
  for (const g of goldens as Golden[]) {
    it(g.name, () => {
      if (g.expectedFingerprint) {
        expect(signalFingerprint(g.signals as never)).toBe(g.expectedFingerprint);
        return;
      }
      const result = classifyPurpose(
        g.signals as never,
        (g.corrections ?? []) as never,
      );
      expect(result.category).toBe(g.expected);
      if (g.minConfidence !== undefined) {
        expect(result.confidence).toBeGreaterThanOrEqual(g.minConfidence);
      }
    });
  }

  it("normalizes extension case in correction fingerprints", () => {
    expect(signalFingerprint({ fileExtensions: ["TS", "Swift"] })).toBe(
      "ext:swift,ts",
    );
  });
});
