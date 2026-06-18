import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

/**
 * The Amplitude Browser SDK egresses to api2.amplitude.com (US) /
 * api.eu.amplitude.com (EU). Those origins must be in `connect-src` for the
 * post-consent SDK to reach Amplitude. The console owns next.config.mjs (applied
 * by `next dev` and any server runtime) — asserted strictly below.
 *
 * The PRODUCTION CSP for the static export lives in the repo-root firebase.json
 * `console` hosting target, which this subproject does NOT own. Until the
 * orchestrator adds the same origins there, post-consent analytics will be
 * CSP-blocked in production. That requirement is tracked as a TODO so it is
 * visible without red-failing this owned subproject's suite.
 */
const AMPLITUDE_ORIGINS = ["https://api2.amplitude.com", "https://api.eu.amplitude.com"];

describe("analytics CSP — Amplitude egress", () => {
  it("next.config.mjs connect-src allows the Amplitude egress origins", () => {
    const nextConfig = readFileSync(new URL("../next.config.mjs", import.meta.url), "utf8");
    for (const origin of AMPLITUDE_ORIGINS) {
      expect(nextConfig, `next.config connect-src should include ${origin}`).toContain(origin);
    }
  });

  it("does not commit an Amplitude API key in env templates or config", () => {
    const envExample = readFileSync(new URL("../.env.example", import.meta.url), "utf8");
    // The key var is documented but left empty (absent -> dark by construction).
    expect(envExample).toContain("NEXT_PUBLIC_AMPLITUDE_API_KEY=");
    expect(envExample).not.toMatch(/NEXT_PUBLIC_AMPLITUDE_API_KEY=\S/);
  });

  // GATED on the orchestrator: add api2.amplitude.com + api.eu.amplitude.com to
  // the `console` hosting target's connect-src in repo-root firebase.json (the
  // `marketing` target already has them). Owned centrally, not by apps/console.
  it.todo(
    "firebase.json console hosting connect-src includes the Amplitude egress origins (orchestrator-owned)",
  );
});
