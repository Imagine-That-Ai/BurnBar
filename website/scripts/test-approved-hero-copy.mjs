#!/usr/bin/env node
/**
 * Guards Alberto-approved homepage + first-run marketing copy (2026-08-13).
 * Locked strings must not drift into marketing paraphrase.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const REPO = path.resolve(ROOT, "..");

const index = await readFile(path.join(ROOT, "src/pages/index.astro"), "utf8");
const site = await readFile(path.join(ROOT, "src/data/site.ts"), "utf8");
const onboarding = await readFile(
  path.join(REPO, "AgentLens/Views/Popover/OnboardingView.swift"),
  "utf8"
);

assert.match(index, /Watch your agents\./, "homepage headline must say Watch your agents.");
assert.doesNotMatch(index, /Watch your AI agents\./, "homepage must drop the AI qualifier");
assert.match(
  index,
  /Your agents don't send a receipt\. We do\. Live in the menu bar, from local logs\. No\s+telemetry\. No account\./,
  "homepage sub must match locked receipt copy"
);
assert.match(
  index,
  /src="\/brand\/logo-256\.png"/,
  "homepage hero must use the real brand logo asset"
);
assert.match(
  index,
  /Download for Mac — \{SITE\.macReleaseLatest\}/,
  "homepage CTA must use Download for Mac with shipping version from SITE"
);

assert.match(site, /tagline: "Watch your agents\. Before the bill\."/);
assert.match(
  site,
  /Your agents don't send a receipt\. We do\. Live in the menu bar, from local logs\. No telemetry\. No account\./
);

assert.match(onboarding, /Look up\. That's the app\./);
assert.match(onboarding, /No Dock icon\. The receipt lives in the menu bar\./);
assert.match(
  onboarding,
  /Run Claude or Codex once\. We pick up the local logs\. No account\./
);
assert.match(onboarding, /AppLogoView\(size: 44\)/, "first-run must use AppLogoView brand mark");
assert.match(onboarding, /Text\("Got it"\)/);
assert.doesNotMatch(onboarding, /BurnBarLogoFormationView/, "first-run must not use formation animation as the mark");
assert.doesNotMatch(onboarding, /Welcome to OpenBurnBar/);

console.log("approved-hero-copy: locked homepage + first-run copy passed");
