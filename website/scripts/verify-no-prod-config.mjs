#!/usr/bin/env node
// BB-01: fail any staging/preview packaging step whose dist contains a
// production Firebase identifier. This is the build-time counterpart to
// verify-staging-deployment.mjs (which checks deployed bytes).

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { PRODUCTION_FIREBASE_FRAGMENTS } from "./staging-firebase-public-config.mjs";

const distDir = process.argv[2] ?? "dist";
const hits = [];

function walk(dir) {
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) {
      walk(path);
      continue;
    }
    if (!/\.(html|js|css|json|txt|xml|webmanifest)$/i.test(entry)) continue;
    const body = readFileSync(path, "utf8");
    for (const needle of PRODUCTION_FIREBASE_FRAGMENTS) {
      if (body.includes(needle)) hits.push(`${path}: ${needle}`);
    }
  }
}

try {
  walk(distDir);
} catch (error) {
  console.error(`verify-no-prod-config: cannot read ${distDir}: ${error.message}`);
  process.exit(1);
}

if (hits.length) {
  console.error("verify-no-prod-config: production Firebase identifiers found in dist:");
  for (const hit of hits) console.error(`  ${hit}`);
  console.error(
    "\nBB-01 gate: staging/preview builds must only embed the burnbar-staging config.\n" +
      "Set STAGING_FIREBASE_PUBLIC_CONFIG_JSON and rebuild via website/scripts/build-staging.mjs."
  );
  process.exit(1);
}

console.log(`verify-no-prod-config: ${distDir} clean of production Firebase identifiers.`);
