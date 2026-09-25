#!/usr/bin/env node
/**
 * Sync built @openburnbar local packages into every Functions codebase vendor
 * dir (3.5 deploy codebases). Replaces the single-codebase
 * functions/scripts/sync-local-packages.mjs for build flows; that script stays
 * for direct functions-only syncs.
 *
 * Sources must already be built (`packages/<name>/lib`); missing sources are
 * skipped with a warning so postinstall stays green on fresh checkouts (the
 * previously synced bytes remain in place). Run scripts/build-functions-all.sh
 * for the authoritative build-then-sync order.
 */
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const CODEBASES = ["functions", "functions-identity", "functions-sync", "functions-media"];
const PACKAGES = ["entitlements", "signal-envelope-contracts", "functions-shared"];

let synced = 0;
for (const packageName of PACKAGES) {
  const sourceRoot = join(repoRoot, "packages", packageName);
  const sourceLib = join(sourceRoot, "lib");
  if (!existsSync(join(sourceLib))) {
    console.warn(
      `sync-functions-vendors: skipping ${packageName} (not built: ${sourceLib} missing)`,
    );
    continue;
  }
  const manifest = JSON.parse(readFileSync(join(sourceRoot, "package.json"), "utf8"));
  for (const codebase of CODEBASES) {
    const targetRoot = join(repoRoot, codebase, "vendor", "openburnbar", packageName);
    rmSync(targetRoot, { recursive: true, force: true });
    mkdirSync(targetRoot, { recursive: true });
    const out = {
      name: manifest.name,
      version: manifest.version,
      private: true,
      type: manifest.type,
      description: manifest.description,
      license: manifest.license,
    };
    if (manifest.main) out.main = manifest.main;
    if (manifest.types) out.types = manifest.types;
    // Transitives install from the vendor manifest (npm follows file: deps),
    // so codebases declare only their own static externals. Relative file:
    // specs resolve against vendor/openburnbar/<pkg>/, which mirrors
    // packages/<pkg>/, so file:../<name> keeps working from vendor.
    if (manifest.dependencies) {
      out.dependencies = { ...manifest.dependencies };
      // Host-provided: shared resolves the WASM through the deploying
      // codebase's node_modules at runtime (require.resolve walks up from the
      // vendored lib). The source-manifest file: path is dev/test-only and
      // would escape the codebase dir in Cloud Build, so strip it here.
      // functions/ and functions-sync declare the dep directly.
      for (const hostProvided of ["@openburnbar/domain-core-wasm"]) {
        delete out.dependencies[hostProvided];
      }
    }
    // Deep-import-only runtime: map @scope/pkg/<path>.js onto lib/<path>.js
    // so deployed code never spells the build output dir.
    if (packageName === "functions-shared") {
      out.exports = { "./package.json": "./package.json", "./*.js": "./lib/*.js" };
    }
    writeFileSync(join(targetRoot, "package.json"), `${JSON.stringify(out, null, 2)}\n`);
    cpSync(sourceLib, join(targetRoot, "lib"), {
      recursive: true,
      filter: (source) => !/\.test\.(d\.ts|d\.ts\.map|js|js\.map)$/.test(source),
    });
    synced += 1;
  }
}

console.log(`sync-functions-vendors: synced ${synced} package→codebase vendor(s)`);
