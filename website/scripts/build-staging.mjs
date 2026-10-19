#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  PRODUCTION_FIREBASE_FRAGMENTS,
  loadStagingFirebasePublicConfig
} from "./staging-firebase-public-config.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");
const STAGING_FIREBASE_PUBLIC_CONFIG = loadStagingFirebasePublicConfig();
const env = {
  ...process.env,
  ...STAGING_FIREBASE_PUBLIC_CONFIG,
  // Flags the bundle as non-production: firebaseClient.ts then treats any
  // production fallback as a build failure instead of a convenience (BB-01).
  // Preview-channel builds reuse this same lane — a preview on burnbar-staging
  // must carry exactly these staging identifiers.
  PUBLIC_BURNBAR_ENV: "staging"
};

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: ROOT,
    env,
    encoding: "utf8",
    stdio: "inherit"
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

const npmCli = process.env.npm_execpath;
if (npmCli) run(process.execPath, [npmCli, "run", "build"]);
else run("npm", ["run", "build"]);
run(process.execPath, [join(ROOT, "scripts", "test-firebase-config.mjs")]);

function walk(directory, out = []) {
  for (const entry of readdirSync(directory)) {
    const absolute = join(directory, entry);
    if (statSync(absolute).isDirectory()) walk(absolute, out);
    else out.push(absolute);
  }
  return out;
}

// Staging and preview deployments are never indexable (BB-22): the CI hosting
// config adds X-Robots-Tag to every route, and the artifact itself ships a
// deny-all robots.txt so the rule survives any header slip.
writeFileSync(
  join(DIST, "robots.txt"),
  "User-agent: *\nDisallow: /\n",
  "utf8"
);

const builtAssets = walk(DIST).filter((file) => /\.(?:html|js|mjs)$/u.test(file));
for (const file of builtAssets) {
  const body = readFileSync(file, "utf8");
  for (const forbidden of PRODUCTION_FIREBASE_FRAGMENTS) {
    assert.ok(
      !body.includes(forbidden),
      `${relative(ROOT, file)} contains production Firebase identifier ${forbidden}; ` +
        "staging must never authenticate against the production project."
    );
  }
}

console.log(
  `✓ Staging website build is isolated to ${STAGING_FIREBASE_PUBLIC_CONFIG.PUBLIC_FIREBASE_PROJECT_ID}; ` +
    `${builtAssets.length} built asset(s) contain no production Firebase identifiers.`
);
