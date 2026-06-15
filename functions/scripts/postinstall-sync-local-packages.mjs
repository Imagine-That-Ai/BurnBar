#!/usr/bin/env node
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const functionsRoot = resolve(__dirname, "..");
const repoRoot = resolve(functionsRoot, "..");

const localSyncInputs = [
  resolve(repoRoot, "scripts", "build-signal-envelope-contracts.sh"),
  resolve(repoRoot, "scripts", "build-entitlements.sh"),
  resolve(repoRoot, "packages", "signal-envelope-contracts", "package.json"),
  resolve(repoRoot, "packages", "entitlements", "package.json"),
];

const packagedVendorOutputs = [
  resolve(functionsRoot, "vendor", "openburnbar", "signal-envelope-contracts", "package.json"),
  resolve(functionsRoot, "vendor", "openburnbar", "entitlements", "package.json"),
];

if (localSyncInputs.every((path) => existsSync(path))) {
  const result = spawnSync("npm", ["run", "sync:local-packages"], {
    cwd: functionsRoot,
    stdio: "inherit",
  });
  process.exit(result.status ?? 1);
}

if (packagedVendorOutputs.every((path) => existsSync(path))) {
  console.log(
    "postinstall-sync-local-packages: repo-local package sources are unavailable; using packaged functions/vendor dependencies.",
  );
  process.exit(0);
}

console.error(
  "postinstall-sync-local-packages: neither repo-local package sources nor packaged vendor dependencies are present.",
);
process.exit(1);
