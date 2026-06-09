#!/usr/bin/env node
/**
 * test-trust-copy.mjs — built-output gates for the trust surface. Runs after
 * `astro build` (wired into `npm run verify` behind `links:check`).
 *
 * 1. TRACKER-FREE: the footer says "No analytics, no trackers, no third-party
 *    fonts loaded remotely" — enforce it on what actually ships: no external
 *    <script src> in any built page, and no tracker SDK tokens in the built JS.
 * 2. PAGE ↔ MODULE BINDING: /trust must render every generated claim line and
 *    not-claim verbatim. The drift gates guarantee module == registry; this
 *    closes the remaining gap (page == module) so trust.astro cannot quietly
 *    stop rendering the gated copy.
 * 3. BANNED VOCABULARY: forbidden claim tokens must never appear in built HTML
 *    (the machine version of the launch-guardrail grep).
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const DIST = join(ROOT, "dist");
const GENERATED = join(ROOT, "src", "data", "crypto-claims.generated.ts");

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const files = walk(DIST);
const htmlFiles = files.filter((f) => f.endsWith(".html"));
const jsFiles = files.filter((f) => f.endsWith(".js"));
assert.ok(htmlFiles.length > 10, `expected a built dist/, found ${htmlFiles.length} HTML files`);

// ---------------------------------------------------------------------------
// 1. Tracker-free dist.
// ---------------------------------------------------------------------------

// Any <script src> pointing at another origin is a failure — the site
// self-hosts everything (fonts included).
const externalScript = /<script[^>]+src=["'](?:https?:)?\/\/(?!burnbar\.ai)[^"']+["']/i;
for (const file of htmlFiles) {
  const html = readFileSync(file, "utf8");
  assert.ok(
    !externalScript.test(html),
    `${relative(ROOT, file)} loads a third-party script — the footer's "no trackers" claim must stay verbatim true`
  );
}

// Tracker SDK tokens in built JS (page prose may mention vendors — code must not).
const TRACKER_TOKENS =
  /posthog|googletagmanager|gtag\(|plausible\.io|usefathom|umami\.is|hotjar|mixpanel|browser\.sentry-cdn|ingest\.sentry\.io|@sentry\//i;
for (const file of jsFiles) {
  const js = readFileSync(file, "utf8");
  const match = js.match(TRACKER_TOKENS);
  assert.ok(
    !match,
    `${relative(ROOT, file)} contains tracker token ${JSON.stringify(match?.[0])} — no analytics, no trackers`
  );
}

// ---------------------------------------------------------------------------
// 2. /trust renders every generated claim verbatim.
// ---------------------------------------------------------------------------

const generated = readFileSync(GENERATED, "utf8");
const publicLines = [...generated.matchAll(/"publicLine": (".*")/g)].map((m) => JSON.parse(m[1]));
const notBlock = generated.slice(generated.indexOf("CRYPTO_NOT_CLAIMS"));
// `= [` skips the `string[]` type annotation's brackets; the literal is
// JSON.stringify output, so the slice parses as plain JSON.
const notStart = notBlock.indexOf("= [") + 2;
const notEnd = notBlock.indexOf("] as const", notStart) + 1;
const notClaims = JSON.parse(notBlock.slice(notStart, notEnd));
assert.ok(publicLines.length >= 5, `expected ≥5 publicLines, parsed ${publicLines.length}`);
assert.ok(notClaims.length >= 4, `expected ≥4 not-claims, parsed ${notClaims.length}`);

const unescape = (s) =>
  s
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");

const trustHtml = unescape(readFileSync(join(DIST, "trust", "index.html"), "utf8"));
for (const line of [...publicLines, ...notClaims]) {
  assert.ok(
    trustHtml.includes(line),
    `/trust no longer renders a generated claim verbatim:\n  ${line}\nThe page must render crypto-claims.generated.ts, not paraphrase it.`
  );
}

// The page must never render the internal policy vocabulary.
assert.ok(
  !/policyClaim/.test(readFileSync(join(DIST, "trust", "index.html"), "utf8")),
  "/trust leaks the internal policyClaim field into HTML"
);

// ---------------------------------------------------------------------------
// 3. Banned claim vocabulary never ships.
// ---------------------------------------------------------------------------

const BANNED = [
  /signal[- ]grade/i,
  /signal[- ]quality/i,
  /signal[- ]class\b/i,
  /signal protocol/i,
  /externally audited/i,
  /assistant (?:cannot|can't) read/i,
  /signalEnvelope/i,
  /signalification/i,
  /\bhpke\b/i,
  /RFC ?9180/i,
  /double[- ]ratchet/i,
  /zero[- ]knowledge/i,
  /quantum[- ]proof/i,
  /\bPQ3\b/i
];
// The honest-boundary copy QUOTES the forbidden claim in order to refuse it
// ("we don't say “the assistant can't read your messages,” because that would
// be false") — a denial is the one sanctioned context. Assertions still fail.
const DENIAL_CONTEXT = /(?:don't|do not|never) say/i;
for (const file of htmlFiles) {
  const html = unescape(readFileSync(file, "utf8"));
  for (const pattern of BANNED) {
    const match = html.match(pattern);
    if (match && DENIAL_CONTEXT.test(html.slice(Math.max(0, match.index - 60), match.index))) {
      continue; // quoted denial, explicitly allowed
    }
    assert.ok(
      !match,
      `${relative(ROOT, file)} ships banned claim vocabulary ${JSON.stringify(match?.[0])} (${pattern})`
    );
  }
}

console.log(
  `✓ trust copy gates: ${htmlFiles.length} pages tracker-free, /trust renders all ${
    publicLines.length + notClaims.length
  } generated claim lines verbatim, banned vocabulary absent.`
);
