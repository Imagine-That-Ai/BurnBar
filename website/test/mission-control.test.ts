import { describe, expect, it } from "vitest";
import {
  contrastRatio,
  deepen,
  describeArchitectures,
  isPublicRelease,
  MISSION_CONTROL_DEEP,
  MISSION_CONTROL_RELEASE,
  MISSION_CONTROL_STYLE,
  releaseEvidence
} from "../src/data/mission-control";
import tokens from "../src/data/mission-control-tokens.json";
import type { MissionControlRelease } from "../src/data/mission-control";

const artifact = {
  url: "https://downloads.example.com/Mission-Control-1.0.0.dmg",
  sha256: "a".repeat(64)
};

const verifiedRelease: MissionControlRelease = {
  ...MISSION_CONTROL_RELEASE,
  state: "published",
  version: "1.0.0",
  artifact,
  developerIDVerified: true,
  notarization: "accepted",
  stapled: true,
  publicDownloadVerified: true,
  cleanInstallVerified: true,
  releaseNotesUrl: "https://example.com/releases/1.0.0",
  verifiedAt: "2026-10-15T00:00:00Z"
};

describe("Mission Control download gate", () => {
  it("withholds the current unreleased build", () => {
    expect(isPublicRelease(MISSION_CONTROL_RELEASE)).toBe(false);
  });

  it("offers a release only after all distribution evidence is present", () => {
    expect(isPublicRelease(verifiedRelease)).toBe(true);
  });

  it.each([
    { state: "preparing" },
    { version: null },
    { artifact: null },
    { architectures: [] },
    { developerIDVerified: false },
    { notarization: "pending" },
    { stapled: false },
    { publicDownloadVerified: false },
    { cleanInstallVerified: false },
    { releaseNotesUrl: null },
    { verifiedAt: null },
    { verifiedAt: "not-a-date" },
    { artifact: { ...artifact, url: "http://example.com/app.dmg" } },
    { artifact: { ...artifact, url: "https://" } },
    { artifact: { ...artifact, url: "https://user:password@example.com/app.dmg" } },
    { artifact: { ...artifact, sha256: "missing" } }
  ])("withholds incomplete release evidence: %j", (change) => {
    expect(isPublicRelease({ ...verifiedRelease, ...change })).toBe(false);
  });
});

describe("Mission Control release evidence", () => {
  it("lists every check as outstanding for the current manifest", () => {
    const evidence = releaseEvidence(MISSION_CONTROL_RELEASE);
    expect(evidence.filter((check) => check.done).map((check) => check.id)).toEqual([]);
  });

  it("marks every check done for a verified release", () => {
    expect(releaseEvidence(verifiedRelease).every((check) => check.done)).toBe(true);
  });

  it("keeps the visible checklist and the download gate in lockstep", () => {
    for (const check of releaseEvidence(verifiedRelease)) {
      expect(check.label.length).toBeGreaterThan(0);
    }
    expect(isPublicRelease(MISSION_CONTROL_RELEASE)).toBe(
      releaseEvidence(MISSION_CONTROL_RELEASE).every((check) => check.done)
    );
  });

  it("describes architectures without inventing support", () => {
    expect(describeArchitectures(["arm64", "x86_64"])).toBe("Apple silicon and Intel");
    expect(describeArchitectures(["arm64"])).toBe("Apple silicon");
    expect(describeArchitectures([])).toBe("");
  });
});

describe("Mission Control tokens", () => {
  it("derives brand foreground variants that clear WCAG AA on the light surface", () => {
    for (const color of Object.values(MISSION_CONTROL_DEEP)) {
      expect(contrastRatio(color, tokens.colors.lightRaised)).toBeGreaterThanOrEqual(4.5);
      expect(contrastRatio(color, tokens.colors.lightBase)).toBeGreaterThanOrEqual(4.5);
    }
  });

  it("only deepens as far as needed", () => {
    expect(deepen(tokens.colors.ink, tokens.colors.lightBase)).toBe(
      tokens.colors.ink.toUpperCase()
    );
  });

  it("derives CSS variables from the shared token source", () => {
    expect(MISSION_CONTROL_STYLE).toContain(`--mc-pink:${tokens.colors.brandPrimary}`);
    expect(MISSION_CONTROL_STYLE).toContain(`--mc-orange:${tokens.colors.brandSecondary}`);
    expect(MISSION_CONTROL_STYLE).toContain(`--mc-canary:${tokens.colors.brandTertiary}`);
    expect(MISSION_CONTROL_STYLE).toContain(`--mc-r-xl:${tokens.radii.xl}px`);
    expect(MISSION_CONTROL_STYLE).not.toMatch(/undefined|NaN/);
  });
});
