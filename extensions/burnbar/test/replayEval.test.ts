import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { evaluateReplayScenario } from "./replay/evaluator";
import type { ReplayEvaluation, ReplayScenario } from "./replay/types";

const fixturesDir = join(__dirname, "replay", "fixtures");
const fixtureNames = readdirSync(fixturesDir)
  .filter((name) => name.endsWith(".input.json"))
  .sort();

describe("BurnBar replay evals", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-03-22T12:00:00.000Z"));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  for (const fixtureName of fixtureNames) {
    it(`matches the golden for ${fixtureName}`, async () => {
      const inputPath = join(fixturesDir, fixtureName);
      const goldenPath = join(fixturesDir, fixtureName.replace(".input.json", ".golden.json"));
      const scenario = loadJson<ReplayScenario>(inputPath);

      const evaluation = await evaluateReplayScenario(scenario);

      if (process.env.UPDATE_BURNBAR_GOLDENS === "1") {
        writeFileSync(goldenPath, `${JSON.stringify(evaluation, null, 2)}\n`, "utf8");
      }

      expect(evaluation).toEqual(loadJson<ReplayEvaluation>(goldenPath));
    });
  }
});

function loadJson<T>(filePath: string): T {
  return JSON.parse(readFileSync(filePath, "utf8")) as T;
}
