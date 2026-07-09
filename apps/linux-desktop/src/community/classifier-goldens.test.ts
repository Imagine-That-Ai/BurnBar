import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { classifyPurpose } from "./classifier";
import type { ModelPurposeCategory } from "./classifier";

const __dirname2 = dirname(fileURLToPath(import.meta.url));

interface GoldenSignals {
  fileExtensions?: string[];
  model?: string;
  appSurface?: string;
  hasCodeExecution?: boolean;
  hasErrorOutput?: boolean;
  hasSearchResults?: boolean;
  hasMultiStepPlanning?: boolean;
  keywords?: string[];
}

interface GoldenCorrection {
  fingerprint: string;
  correctedTo: ModelPurposeCategory;
}

interface ClassifierGolden {
  name: string;
  signals: GoldenSignals;
  expected?: string;
  minConfidence?: number;
  expectedFingerprint?: string;
  expectedSignal?: string;
  corrections?: GoldenCorrection[];
}

const goldens: ClassifierGolden[] = JSON.parse(
  readFileSync(resolve(__dirname2, "../../../../tests/fixtures/classifier-goldens.json"), "utf-8"),
);

describe("classifier-goldens (cross-platform parity)", () => {
  for (const golden of goldens) {
    it(golden.name, () => {
      if (golden.expectedFingerprint) {
        return;
      }
      const corrections = golden.corrections ?? [];
      const result = classifyPurpose(golden.signals, corrections);
      if (golden.expected) {
        expect(result.category).toBe(golden.expected);
      }
      if (golden.minConfidence != null) {
        expect(result.confidence).toBeGreaterThanOrEqual(golden.minConfidence);
      }
      if (golden.expectedSignal) {
        expect(result.contributingSignals).toContain(golden.expectedSignal);
      }
    });
  }
});