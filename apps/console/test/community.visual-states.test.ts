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
    expect(stableVisualSnapshot(view)).toMatchInlineSnapshot(`
      {
        "cityConfidenceCopy": "City confidence: no city lookup. Country and region can use locale/timezone; world ranking needs no location.",
        "consentPreview": "L1 unset · L2 unset · L3 unset · Location unset",
        "hero": "Opt in to L2 rankings to preview your share snapshot.",
        "leaderboards": [
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoKey": "city",
            "tier": "city",
          },
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoKey": "region",
            "tier": "region",
          },
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoKey": "country",
            "tier": "country",
          },
          {
            "belowThreshold": true,
            "cohortSize": 0,
            "entryAnonIds": [],
            "geoKey": "world",
            "tier": "world",
          },
        ],
        "lookingGlassExport": {
          "message": "Looking Glass export: grant L3 to create a private bundle; leaderboard rankings never use traces.",
          "state": "idle",
        },
        "peerCohortCount": 0,
        "purposeCategories": [],
        "showInvite": true,
      }
    `);
  });

  it("city tier with location denied stays below threshold without individual rows", () => {
    const view = buildCommunityView(
      grantedConsent({ locationConsent: "declined", l2Tiers: { world: "granted", country: "granted", region: "granted", city: "granted" } }),
      "30d",
    );
    const city = view.leaderboards.find((board) => board.tier === "city");
    expect(city?.belowThreshold).toBe(true);
    expect(city?.entries).toEqual([]);
    expect(city?.geoKey).toBe("city");
    expect(view.cityConfidenceCopy).toMatch(/paused until city consent and a manual city label/i);
  });

  it("live participation exposes anonymous leaderboard rows", () => {
    const view = buildCommunityView(grantedConsent(), "30d");
    const world = view.leaderboards.find((board) => board.tier === "world");
    expect(view.showInvite).toBe(false);
    expect(world?.belowThreshold).toBe(false);
    expect(world?.entries.every((entry) => entry.anonId && !("uid" in entry))).toBe(true);
    expect(stableVisualSnapshot(view).leaderboards.find((b) => b.tier === "world")?.entryAnonIds).toEqual([
      "world-a1",
      "world-b2",
      "world-c3",
    ]);
    expect(view.cityConfidenceCopy).toMatch(/manual city label required/i);
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