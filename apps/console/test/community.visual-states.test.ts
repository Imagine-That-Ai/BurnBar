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