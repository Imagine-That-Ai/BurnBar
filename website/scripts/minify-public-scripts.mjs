#!/usr/bin/env node
/**
 * minify-public-scripts.mjs — post-build minifier for public/ scripts.
 *
 * Astro copies public/ into dist/ verbatim, so platform-mockups.js and
 * router-rundown-hydrate.js bypass Vite and would otherwise ship ~40KB of
 * readable source. This step minifies only the dist/ copies — the public/
 * sources stay readable for editing and for the source-level gates
 * (test-platform-mockups.mjs, test-router-copy.mjs), which run pre-build.
 *
 * CSP is unaffected: both files load via <script src> under script-src
 * 'self' — no inline hashes involve their content.
 *
 * Runs after `astro build` in the `build` / `build:offline` scripts, before
 * the dist-level gates, so what gets verified is what ships.
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { transform } from "esbuild";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIST = path.join(ROOT, "dist");
const FILES = ["platform-mockups.js", "router-rundown-hydrate.js"];

for (const name of FILES) {
  const file = path.join(DIST, name);
  const source = await readFile(file, "utf8");
  const { code } = await transform(source, { loader: "js", minify: true });
  assert.ok(
    code.length > 0 && code.length < source.length,
    `${name}: minification produced no savings (${source.length} B → ${code.length} B)`
  );
  await writeFile(file, code);
  console.log(`minify-public-scripts: ${name} ${source.length} B → ${code.length} B`);
}
