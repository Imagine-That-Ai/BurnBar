#!/usr/bin/env node
/**
 * test-inline-script-budget.mjs — built-output gate for inline script bytes.
 *
 * Marketing pages ship with `Cache-Control: no-cache` (revalidated on every
 * navigation), so inline script bytes re-download with every fresh HTML body
 * and can never cache independently of the page. The big background scripts
 * (ember swarm, dot constellation, easter-egg FX, pretext shrinkwrap) were
 * externalized into hashed immutable /_assets modules for exactly that reason
 * — 57KB/page of inline JS became a one-time ~10KB gzip download.
 *
 * This gate keeps the win locked in. The regression it polices is silent:
 * Astro re-inlines any processed script whose bundled chunk falls below
 * `vite.build.assetsInlineLimit` (4096 bytes) — so merely *shrinking*
 * src/scripts/dotConstellation.ts or pretextShrinkwrap.ts could quietly put
 * kilobytes back into all 30+ pages. A fat new `is:inline` script would too.
 *
 * Intentionally-inline scripts stay comfortably under the budget: the
 * pre-paint theme resolver (~558 B) and the header scroll handler (~987 B).
 * JSON-LD payloads are data, not executable JS, and are exempt.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const DIST = join(ROOT, "dist");

// Largest legitimate inline script today is ~1,028 B; the smallest chunk that
// could be re-inlined is ~3,912 B. 2,500 B splits the two with headroom.
const INLINE_SCRIPT_BUDGET_BYTES = 2500;

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

const htmlFiles = walk(DIST).filter((f) => f.endsWith(".html"));
assert.ok(htmlFiles.length > 10, `expected a built dist/, found ${htmlFiles.length} HTML files`);

const inlineScript = /<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/gi;
let checked = 0;
for (const file of htmlFiles) {
  const html = readFileSync(file, "utf8");
  for (const [, attrs, body] of html.matchAll(inlineScript)) {
    if (/type=["']application\/ld\+json["']/i.test(attrs)) continue; // data, not JS
    checked += 1;
    const bytes = Buffer.byteLength(body);
    assert.ok(
      bytes < INLINE_SCRIPT_BUDGET_BYTES,
      `${relative(ROOT, file)} inlines a ${bytes} B script (budget ${INLINE_SCRIPT_BUDGET_BYTES} B). ` +
        `Pages always revalidate (no-cache), so inline JS re-downloads with every fresh HTML body — move it to ` +
        `src/scripts/ so it bundles into a hashed immutable /_assets module, and make sure ` +
        `the chunk stays above vite.build.assetsInlineLimit or Astro will re-inline it.`
    );
  }
}

console.log(
  `✓ inline script budget: ${checked} executable inline script(s) across ${htmlFiles.length} pages, all under ${INLINE_SCRIPT_BUDGET_BYTES} B.`
);
