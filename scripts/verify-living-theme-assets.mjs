#!/usr/bin/env node

import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const catalogPath = resolve(
  repoRoot,
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LiveTheme.kt",
);
const assetRoot = resolve(
  repoRoot,
  "android/app/src/main/assets/living-themes/kernels",
);
const source = readFileSync(catalogPath, "utf8");
const entryPattern =
  /^\s*[A-Z0-9_]+\("([^"]+)",\s*"[^"]+"(?:,\s*assetID\s*=\s*"([^"]+)")?\),?$/gm;

const entries = [...source.matchAll(entryPattern)].map((match) => ({
  id: match[1],
  assetID: match[2] ?? match[1],
}));

if (entries.length !== 42) {
  throw new Error(`Expected 42 Living Theme entries, found ${entries.length}.`);
}

const ids = new Set(entries.map((entry) => entry.id));
if (ids.size !== entries.length) {
  throw new Error("Living Theme ids must be unique.");
}

const assetIDs = new Set(entries.map((entry) => entry.assetID));
if (assetIDs.size !== entries.length) {
  throw new Error("Every Living Theme must reference its own shader asset.");
}

const missing = entries
  .filter((entry) => !existsSync(resolve(assetRoot, `${entry.assetID}.frag`)))
  .map((entry) => `${entry.id} -> ${entry.assetID}.frag`);

if (missing.length > 0) {
  throw new Error(`Missing shader assets:\n${missing.join("\n")}`);
}

console.log(
  `Verified ${entries.length} Living Themes and all referenced shader assets.`,
);
