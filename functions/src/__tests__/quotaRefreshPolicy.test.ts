import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { QuotaRefreshPolicy, QuotaSignalTier } from "../quotaRefreshPolicy.js";

type QuotaRefreshWindowKind =
  | "rollingHours"
  | "rollingDays"
  | "daily"
  | "weekly"
  | "monthly"
  | "lifetime"
  | "custom";

type FixtureCase = {
  name: string;
  tier: keyof typeof QuotaSignalTier;
  tierValue: number;
  now: string;
  fetchedAt: string;
  remainingFraction: number | null;
  windowKind: QuotaRefreshWindowKind;
  resetsAt: string | null;
  expectedTTLSeconds: number;
  expectedNextRefreshAt: string;
  lastProbeAt: string | null;
  probesToday: number;
  dailyProbeBudget: number;
  expectedShouldSpendProbe: boolean;
};

type FixtureFile = {
  cases: FixtureCase[];
};

const fixturePath = resolve(
  __dirname,
  "../../../OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/quota-refresh-policy-fixtures.json",
);
const fixture: FixtureFile = JSON.parse(readFileSync(fixturePath, "utf8"));

describe("QuotaRefreshPolicy", () => {
  it("matches the shared Swift/TypeScript quota refresh policy fixture", () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(12);

    for (const testCase of fixture.cases) {
      const now = new Date(testCase.now);
      const ttl = QuotaRefreshPolicy.adaptiveTTL(
        testCase.remainingFraction,
        testCase.windowKind,
        testCase.resetsAt,
        now,
      );
      const nextRefreshAt = QuotaRefreshPolicy.nextRefreshAfter(
        {
          fetchedAt: testCase.fetchedAt,
          remainingFraction: testCase.remainingFraction,
          windowKind: testCase.windowKind,
          resetsAt: testCase.resetsAt,
        },
        now,
      );
      const shouldSpendProbe = QuotaRefreshPolicy.shouldSpendProbe(
        testCase.lastProbeAt,
        testCase.probesToday,
        testCase.dailyProbeBudget,
        now,
      );

      expect(QuotaSignalTier[testCase.tier], testCase.name).toBe(testCase.tierValue);
      expect(ttl, testCase.name).toBe(testCase.expectedTTLSeconds);
      expect(nextRefreshAt.toISOString(), testCase.name).toBe(testCase.expectedNextRefreshAt);
      expect(shouldSpendProbe, testCase.name).toBe(testCase.expectedShouldSpendProbe);
    }
  });
});
