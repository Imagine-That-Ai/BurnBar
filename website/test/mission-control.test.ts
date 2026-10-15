import { describe, expect, it } from "vitest";
import { isPublicRelease, MISSION_CONTROL_RELEASE } from "../src/data/mission-control";
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
