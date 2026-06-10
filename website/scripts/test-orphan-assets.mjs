#!/usr/bin/env node
/**
 * @fileoverview Orphaned-public-asset guard.
 *
 * Astro copies every file in `public/` verbatim into `dist/`, so unreferenced
 * assets ship in every Firebase deploy forever. A June 2026 audit found 5.2MB
 * (~33% of dist) of orphans — superseded screenshots, crest JPGs replaced by
 * SVGs, and a popover screenshot replaced by the BarMockup.astro DOM render.
 *
 * This scan fails when a `public/` file is referenced nowhere in the source
 * tree. "Referenced" is deliberately lenient — a basename or root-relative
 * URL substring match anywhere in src/, public text files, or astro.config —
 * so dynamic path concatenation (e.g. `/brand/providers/${id}.png`) never
 * false-positives. Externally consumed paths with no on-site reference are
 * allowlisted below.
 *
 * Run via: `node scripts/test-orphan-assets.mjs`.
 */

import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const PUBLIC = path.join(ROOT, "public");

// Served on purpose without any on-site reference. Directories end with "/".
const ALLOWLIST_PREFIXES = [
  "downloads/", // sbom/checksums/release-metadata — fetched by release tooling
  "press/", // externally hot-linked press assets (declare a README inside)
];
const ALLOWLIST_FILES = new Set([
  "robots.txt", // crawler convention, never linked
  ".well-known/security.txt", // RFC 9116 convention, never linked
  "data/models.json", // consumed by the iOS app, not the site
]);

// File types whose text can carry asset references.
const CORPUS_EXTENSIONS = new Set([
  ".astro",
  ".css",
  ".html",
  ".js",
  ".json",
  ".md",
  ".mdx",
  ".mjs",
  ".svg",
  ".ts",
  ".tsx",
  ".txt",
  ".webmanifest",
  ".xml",
]);

async function walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walk(full)));
    } else if (entry.name !== ".DS_Store") {
      files.push(full);
    }
  }
  return files;
}

// ───────────────────────── reference corpus ────────────────────────────────

const corpusPaths = [
  ...(await walk(path.join(ROOT, "src"))),
  ...(await walk(PUBLIC)),
  path.join(ROOT, "astro.config.mjs"),
].filter((p) => CORPUS_EXTENSIONS.has(path.extname(p).toLowerCase()));

const corpus = await Promise.all(
  corpusPaths.map(async (p) => ({ path: p, text: await readFile(p, "utf8") }))
);

// ───────────────────────────── orphan scan ─────────────────────────────────

const assets = await walk(PUBLIC);
const orphans = [];
let allowlisted = 0;

for (const asset of assets) {
  const rel = path.relative(PUBLIC, asset).split(path.sep).join("/");
  if (ALLOWLIST_FILES.has(rel) || ALLOWLIST_PREFIXES.some((p) => rel.startsWith(p))) {
    allowlisted += 1;
    continue;
  }
  const name = path.posix.basename(rel);
  // A file's own content never counts as a reference to itself.
  const referenced = corpus.some(
    (doc) => doc.path !== asset && (doc.text.includes(name) || doc.text.includes(`/${rel}`))
  );
  if (!referenced) {
    orphans.push(rel);
  }
}

assert.deepEqual(
  orphans,
  [],
  `public/ contains ${orphans.length} orphaned asset(s) referenced nowhere in src/, public/, or astro.config.mjs:\n` +
    orphans.map((rel) => `  - public/${rel}`).join("\n") +
    "\nDelete them, reference them, or allowlist them in scripts/test-orphan-assets.mjs " +
    "(externally consumed files belong under public/press/ or public/downloads/)."
);

console.log(
  `orphan-assets: all ${assets.length - allowlisted} scanned public assets are referenced ` +
    `(${allowlisted} allowlisted)`
);
