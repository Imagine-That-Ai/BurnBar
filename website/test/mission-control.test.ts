import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  AFAR_ANDROID_INTERNAL_TEST,
  androidInternalTest,
  contrastRatio,
  deepen,
  describeArchitectures,
  isPublicRelease,
  MISSION_CONTROL_DEEP,
  MISSION_CONTROL_DOWNLOAD_READY,
  MISSION_CONTROL_RELEASE,
  MISSION_CONTROL_STYLE,
  parseRelease,
  releaseEvidence
} from "../src/data/mission-control";
import tokens from "../src/data/mission-control-tokens.json";
import androidManifest from "../public/mission-control/android.json";
import releaseManifest from "../public/mission-control/release.json";
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

describe("Mission Control release gate with malformed manifests", () => {
  const verifiedJson: Record<string, unknown> = { ...verifiedRelease };

  it("accepts the verified fixture as raw JSON", () => {
    expect(isPublicRelease(verifiedJson)).toBe(true);
  });

  it.each([
    ["developerIDVerified as the string 'false'", { developerIDVerified: "false" }],
    ["developerIDVerified as the string 'true'", { developerIDVerified: "true" }],
    ["stapled as 1", { stapled: 1 }],
    ["publicDownloadVerified as 'yes'", { publicDownloadVerified: "yes" }],
    ["cleanInstallVerified as null", { cleanInstallVerified: null }],
    ["schemaVersion as the string '1'", { schemaVersion: "1" }],
    ["state with different case", { state: "Published" }],
    ["version as whitespace", { version: "   " }],
    ["version as a number", { version: 1 }],
    ["minimumMacOS as null", { minimumMacOS: null }],
    ["minimumMacOS missing", { minimumMacOS: undefined }],
    ["architectures as a string", { architectures: "arm64" }],
    ["architectures with an empty entry", { architectures: ["arm64", ""] }],
    ["architectures with a non-string entry", { architectures: ["arm64", 64] }],
    ["artifact as a string", { artifact: "https://downloads.example.com/a.dmg" }],
    ["artifact without sha256", { artifact: { url: "https://downloads.example.com/a.dmg" } }],
    ["artifact sha256 as a number", { artifact: { ...artifact, sha256: 1234 } }],
    ["artifact url as an array", { artifact: { ...artifact, url: ["https://x.example"] } }],
    ["notarization as true", { notarization: true }],
    ["releaseNotesUrl as an object", { releaseNotesUrl: { href: "https://example.com" } }],
    ["verifiedAt as a number", { verifiedAt: 1760486400000 }],
    ["verifiedAt as whitespace", { verifiedAt: " " }]
  ])("fails closed without throwing when %s", (_label, change) => {
    const manifest = { ...verifiedJson, ...change };
    expect(() => releaseEvidence(manifest)).not.toThrow();
    expect(isPublicRelease(manifest)).toBe(false);
  });

  it.each([null, undefined, "published", 42, [], [verifiedRelease], true])(
    "fails closed without throwing for a non-object manifest: %j",
    (manifest) => {
      expect(() => releaseEvidence(manifest)).not.toThrow();
      expect(releaseEvidence(manifest).some((check) => check.done)).toBe(false);
      expect(isPublicRelease(manifest)).toBe(false);
    }
  );

  it("normalises display values instead of trusting raw types", () => {
    const parsed = parseRelease({ version: "  1.2.0 ", minimumMacOS: 14, stapled: "true" });
    expect(parsed.version).toBe("1.2.0");
    expect(parsed.minimumMacOS).toBeNull();
    expect(parsed.stapled).toBe(false);
    expect(parsed.architectures).toEqual([]);
    expect(parsed.artifact).toBeNull();
  });

  it("parses the committed manifest into the preparing state with nothing verified", () => {
    expect(MISSION_CONTROL_RELEASE.state).toBe("preparing");
    expect(MISSION_CONTROL_RELEASE.artifact).toBeNull();
    expect(releaseEvidence(MISSION_CONTROL_RELEASE).filter((check) => check.done)).toEqual([]);
  });
});

describe("Afar Android internal test", () => {
  const optInUrl = "https://play.google.com/apps/internaltest/4701516252282422888";
  const internalTest: Record<string, unknown> = {
    schemaVersion: 1,
    state: "internal-test",
    product: "Afar",
    packageName: "app.fleetmissioncontrol.android",
    versionName: "0.1.5",
    versionCode: 105,
    track: "internal",
    audience: "invited-testers",
    optInUrl,
    production: false
  };

  it("shows the committed internal test with its version and Play opt-in link", () => {
    expect(AFAR_ANDROID_INTERNAL_TEST).toEqual({
      versionName: "0.1.5",
      versionCode: 105,
      optInUrl
    });
    expect(androidInternalTest(androidManifest)).toEqual(AFAR_ANDROID_INTERNAL_TEST);
  });

  it("stays independent of the Mac download gate", () => {
    expect(MISSION_CONTROL_DOWNLOAD_READY).toBe(false);
    expect(isPublicRelease(releaseManifest)).toBe(false);
    expect(isPublicRelease({ ...releaseManifest, ...androidManifest })).toBe(false);
    expect(releaseManifest).toMatchObject({ state: "preparing", artifact: null });
  });

  it("publishes no signing, account or local details", () => {
    expect(Object.keys(androidManifest).sort()).toEqual(Object.keys(internalTest).sort());
    expect(JSON.stringify(androidManifest)).not.toMatch(/sha256|cert|@|\/Users\/|\/Volumes\//i);
  });

  it.each([
    ["schemaVersion as the string '1'", { schemaVersion: "1" }],
    ["a published state", { state: "published" }],
    ["the production track", { track: "production" }],
    ["an open-testing track", { track: "beta" }],
    ["a public audience", { audience: "public" }],
    ["production true", { production: true }],
    ["production as the string 'false'", { production: "false" }],
    ["production missing", { production: undefined }],
    ["versionName as whitespace", { versionName: " " }],
    ["versionCode as a string", { versionCode: "105" }],
    ["versionCode as a fraction", { versionCode: 105.5 }],
    ["versionCode zero", { versionCode: 0 }],
    ["optInUrl over http", { optInUrl: optInUrl.replace("https:", "http:") }],
    [
      "optInUrl on another host",
      { optInUrl: "https://play.google.com.example.com/apps/internaltest/1" }
    ],
    [
      "optInUrl as a store listing",
      { optInUrl: "https://play.google.com/store/apps/details?id=app.fleetmissioncontrol.android" }
    ],
    [
      "optInUrl with credentials",
      { optInUrl: "https://user:pass@play.google.com/apps/internaltest/1" }
    ],
    ["optInUrl with a query", { optInUrl: `${optInUrl}?ref=x` }],
    [
      "optInUrl with a non-numeric id",
      { optInUrl: "https://play.google.com/apps/internaltest/abc" }
    ],
    ["optInUrl missing", { optInUrl: undefined }]
  ])("hides the link when %s", (_label, change) => {
    expect(androidInternalTest(internalTest)).not.toBeNull();
    expect(androidInternalTest({ ...internalTest, ...change })).toBeNull();
  });

  it.each([null, undefined, "internal-test", 42, [], true])(
    "hides the link for a non-object manifest: %j",
    (manifest) => {
      expect(androidInternalTest(manifest)).toBeNull();
    }
  );

  it("renders the Android section from the parsed manifest, outside the Mac gate", () => {
    const page = readFileSync(
      new URL("../src/pages/mission-control.astro", import.meta.url),
      "utf8"
    );
    const start = page.indexOf("{android && (");
    const section = page.slice(start, page.indexOf('id="release"')).replace(/\s+/g, " ");
    expect(start).toBeGreaterThan(-1);
    expect(section).toContain("href={android.optInUrl}");
    expect(section).toContain(
      "Invited testers only. Open with the Google account already enrolled in the test; this link does not grant tester access. This is not a public Play Store release."
    );
    expect(section).not.toMatch(/downloadReady|release\.artifact/);
  });
});
