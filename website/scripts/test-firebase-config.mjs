#!/usr/bin/env node
/**
 * test-firebase-config.mjs — built-output gate for the live Firebase web config.
 *
 * THE REGRESSION THIS POLICES SHIPPED TO PRODUCTION (finding C2): for months
 * website/src/lib/firebaseClient.ts fell back to a fake apiKey
 * ("AIzaSyFakeKeyPlaceholderForBuild") whenever PUBLIC_FIREBASE_* env was unset.
 * CI deploys burnbar.ai with NO .env (the real config is committed as the public
 * fallback, exactly like apps/console), so any reintroduced placeholder gets
 * inlined into the shipped bundle and sign-in on /link and /hermes/connect dies
 * silently — every gate stayed green because none looked at the built output.
 *
 * This gate fails closed on two independent checks against dist/:
 *   1. NO fake/placeholder Firebase identifier may appear anywhere in the build.
 *   2. The real production apiKey MUST appear in at least one built JS asset
 *      (proving the live config actually made it into the bundle).
 *
 * These are PUBLIC client identifiers (not secrets — they ship in every client
 * bundle regardless; security is enforced server-side by Firestore rules + App
 * Check). Committing them as the build-time fallback is the intended pattern.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const DIST = join(ROOT, "dist");

// CI/deploy environments can override these public identifiers when building
// the isolated staging site. A normal production build intentionally falls
// back to the reviewed "burnbar" values mirrored in firebaseClient.ts.
const EXPECTED_PROJECT_ID = process.env.PUBLIC_FIREBASE_PROJECT_ID || "burnbar";
const EXPECTED_API_KEY =
  process.env.PUBLIC_FIREBASE_API_KEY || "AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4";
const EXPECTED_RECAPTCHA_ENTERPRISE_SITE_KEY =
  process.env.PUBLIC_RECAPTCHA_ENTERPRISE_KEY || "6Ld3bAktAAAAAABiZujpMLmUcvSMUPiJk6qENbOg";

// Fragments that must NEVER appear in a shipped asset. Any one of these means a
// fake placeholder fallback was re-inlined and the build would deploy broken auth.
const FORBIDDEN_FRAGMENTS = [
  "FakeKeyPlaceholder",
  "AIzaSyFakeKeyPlaceholderForBuild",
  "1:123456789:web:abcdef",
  "messagingSenderId:\"123456789\"",
];

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const files = walk(DIST).filter((f) => /\.(js|mjs|html)$/.test(f));
assert.ok(files.length > 10, `expected a built dist/, found ${files.length} JS/HTML files`);

// Check 1: no placeholder may survive into the build (scan ALL assets).
for (const file of files) {
  const text = readFileSync(file, "utf8");
  for (const forbidden of FORBIDDEN_FRAGMENTS) {
    assert.ok(
      !text.includes(forbidden),
      `${relative(ROOT, file)} contains forbidden Firebase placeholder "${forbidden}". ` +
        `The fake fallback was re-introduced in src/lib/firebaseClient.ts — restore the real ` +
        `public "burnbar" project config so sign-in works on /link and /hermes/connect.`
    );
  }
}

// Check 2: the selected environment's real public identifiers must actually be
// present in the bundle. This prevents a staging deploy from silently shipping
// a production Firebase client (and vice versa).
const projectIdPresent = files.some((file) =>
  readFileSync(file, "utf8").includes(EXPECTED_PROJECT_ID)
);
assert.ok(
  projectIdPresent,
  `the expected Firebase project id ("${EXPECTED_PROJECT_ID}") is missing from every built asset in dist/.`
);

const apiKeyPresent = files.some((file) => readFileSync(file, "utf8").includes(EXPECTED_API_KEY));
assert.ok(
  apiKeyPresent,
  `the expected Firebase apiKey ("${EXPECTED_API_KEY}") is missing from every built asset in dist/. ` +
    `Without it, signInWithPopup fails and /link + /hermes/connect cannot authenticate. ` +
    `Verify the build environment selects the intended Firebase project.`
);

const appCheckSiteKeyPresent = files.some((file) =>
  readFileSync(file, "utf8").includes(EXPECTED_RECAPTCHA_ENTERPRISE_SITE_KEY)
);
assert.ok(
  appCheckSiteKeyPresent,
  `the expected reCAPTCHA Enterprise site key for "${EXPECTED_PROJECT_ID}" is missing from every built asset in dist/. ` +
    "Without it, App Check-enforced billing and account callables fail from the website."
);

console.log(
  `✓ Firebase config: scanned ${files.length} built asset(s); no placeholder present and ${EXPECTED_PROJECT_ID} Auth + App Check config is bundled.`
);
