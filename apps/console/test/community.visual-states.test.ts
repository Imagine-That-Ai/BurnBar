import { describe, expect, it } from "vitest";

import { defaultCommunityConsent } from "@/lib/community/localConsent";
import type { CommunityConsentDoc } from "@/lib/community/types";
import {
  LOCAL_PARTICIPATION_PAUSED_COPY,
  buildCommunityView,
  lookingGlassExportCopy,
  type CommunityViewState,
} from "@/lib/community/viewModel";

function grantedConsent(partial: Partial<CommunityConsentDoc> = {}): CommunityConsentDoc {
  const base = defaultCommunityConsent();
  return {
    ...base,
    l2Rankings: "granted",
    l2Tiers: { world: "granted", country: "granted", region: "granted", city: "granted" },
    locationConsent: "granted",
    l3LookingGlass: "granted",
    ...partial,
  };
}

function stableVisualSnapshot(view: CommunityViewState) {
  return {
    showInvite: view.showInvite,
    isPreviewData: view.isPreviewData,
    hero: view.hero.modelMixSummary,
    peerCohortCount: view.peerCohortTokens.length,
    purposeCategories: view.purposeBreakdown.map((slice) => slice.category),
    consentPreview: view.consentPreview,
    cityConfidenceCopy: view.cityConfidenceCopy,
    lookingGlassExport: view.lookingGlassExport,
    leaderboards: view.leaderboards.map((board) => ({
      tier: board.tier,
      geoKey: board.geoKey,
      belowThreshold: board.belowThreshold,
      cohortSize: board.cohortSize,
      entryAnonIds: board.entries.map((entry) => entry.anonId),
    })),
  };
}

describe("community visual states (console)", () => {
  it("opted-out L2 shows invite and empty cohort", () => {
    const view = buildCommunityView(defaultCommunityConsent(), "30d");
    expect(stableVisualSnapshot(view)).toMatchObject({
      showInvite: true,
      isPreviewData: false,
      peerCohortCount: 0,
      purposeCategories: [],
      leaderboards: expect.arrayContaining([
        expect.objectContaining({ tier: "city", belowThreshold: true, entryAnonIds: [] }),
      ]),
    });
    expect(view.leaderboards.every((b) => b.entries.length === 0)).toBe(true);
  });

  it("city tier with location denied stays below threshold without individual rows", () => {
    const view = buildCommunityView(
      grantedConsent({ locationConsent: "declined", l2Tiers: { world: "granted", country: "granted", region: "granted", city: "granted" } }),
      "30d",
    );
    const city = view.leaderboards.find((board) => board.tier === "city");
    expect(city?.belowThreshold).toBe(true);
    expect(city?.entries).toEqual([]);
    expect(city?.geoKey).not.toBe("San Francisco");
    expect(view.cityConfidenceCopy).toMatch(/paused until city consent and a manual city label/i);
  });

  it("opted-in L2 shows preview-only empty boards without fabricated ranks", () => {
    const view = buildCommunityView(grantedConsent({ manualCityInput: "Portland" }), "30d");
    expect(view.showInvite).toBe(false);
    expect(view.isPreviewData).toBe(true);
    expect(view.peerCohortTokens).toEqual([]);
    expect(view.leaderboards.every((b) => b.entries.length === 0 && b.belowThreshold)).toBe(true);
    const city = view.leaderboards.find((b) => b.tier === "city");
    expect(city?.geoKey).toBe("Portland");
    expect(view.hero.modelMixSummary).toMatch(/preview only/i);
  });

  it("renders live share snapshot and leaderboard docs when signed-in data exists", () => {
    const view = buildCommunityView(grantedConsent({ manualCityInput: "Portland" }), "30d", {
      shareSnapshot: {
        windows: {
          today: { totalTokens: 100, costUSD: 0.1 },
          sevenDay: { totalTokens: 700, costUSD: 0.7 },
          thirtyDay: { totalTokens: 12_500, costUSD: 12.5 },
          ninetyDay: { totalTokens: 30_000, costUSD: 30 },
          allTime: { totalTokens: 100_000, costUSD: 100 },
        },
        modelMix: { "claude-opus": 0.7, "gpt-4.1": 0.3 },
        purposeMix: { coding: 8, research: 2 },
      },
      leaderboards: [
        {
          window: "30d",
          tier: "world",
          geoKey: "world",
          entries: [
            { rank: 1, anonId: "anon-a", totalTokens: 20_000, costUSD: 20, movement: "up" },
            { rank: 2, anonId: "anon-b", totalTokens: 12_500, costUSD: 12.5, movement: "same" },
          ],
          percentiles: { p50: 10_000, p75: 15_000, p90: 20_000, p99: 25_000 },
          cohortSize: 12,
          belowThreshold: false,
          kThreshold: 10,
          updatedAt: "2026-07-09T00:00:00.000Z",
        },
      ],
    });

    expect(view.isPreviewData).toBe(false);
    expect(view.statusMessage).toMatch(/live community data synced/i);
    expect(view.hero.tokens).toBe(12_500);
    expect(view.hero.modelMixSummary).toContain("claude-opus 70%");
    expect(view.peerCohortTokens).toEqual([20_000, 12_500]);
    expect(view.purposeBreakdown.map((slice) => slice.category)).toEqual(["coding", "research"]);
  });

  it("all_time window id is accepted for view build", () => {
    const view = buildCommunityView(grantedConsent(), "all_time");
    expect(view.isPreviewData).toBe(true);
  });

  it("local revoke copy matches paused participation messaging", () => {
    expect(LOCAL_PARTICIPATION_PAUSED_COPY).toMatchInlineSnapshot(
      `"Participation paused locally. Sync revoke when signed in online."`,
    );
  });

  it("Looking Glass export ready and error copy stay user-visible and stable", () => {
    expect(lookingGlassExportCopy("ready")).toMatchInlineSnapshot(`
      {
        "message": "Looking Glass export ready: download link expires in 15 minutes and never feeds leaderboards.",
        "state": "ready",
      }
    `);
    expect(lookingGlassExportCopy("error")).toMatchInlineSnapshot(`
      {
        "message": "Looking Glass export failed: no traces left the device; try again after reconnecting.",
        "state": "error",
      }
    `);
  });
});