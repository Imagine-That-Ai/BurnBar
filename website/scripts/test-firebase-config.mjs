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

// The real public apiKey for the "burnbar" Firebase project, mirrored from
// website/src/lib/firebaseClient.ts (and apps/console/lib/firebaseClient.ts).
// Sign-in is dead in production if this string is absent from the built bundle.
const PRODUCTION_API_KEY = "AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4";

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

// Check 2: the real production apiKey must actually be present in the bundle.
const apiKeyPresent = files.some((file) => readFileSync(file, "utf8").includes(PRODUCTION_API_KEY));
assert.ok(
  apiKeyPresent,
  `the production Firebase apiKey ("${PRODUCTION_API_KEY}") is missing from every built asset in dist/. ` +
    `Without it, signInWithPopup fails and /link + /hermes/connect cannot authenticate. ` +
    `Verify src/lib/firebaseClient.ts ships the real public "burnbar" project config as its fallback.`
);

console.log(
  `✓ Firebase config: scanned ${files.length} built asset(s); no placeholder present and the production apiKey is bundled.`
);
