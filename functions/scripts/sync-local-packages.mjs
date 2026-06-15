#!/usr/bin/env node
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const functionsRoot = resolve(__dirname, "..");
const repoRoot = resolve(functionsRoot, "..");

const packages = [
  "entitlements",
  "signal-envelope-contracts",
];

for (const packageName of packages) {
  const sourceRoot = join(repoRoot, "packages", packageName);
  const targetRoot = join(functionsRoot, "vendor", "openburnbar", packageName);
  rmSync(targetRoot, { recursive: true, force: true });
  mkdirSync(targetRoot, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(sourceRoot, "package.json"), "utf8"));
  writeFileSync(
    join(targetRoot, "package.json"),
    `${JSON.stringify({
      name: manifest.name,
      version: manifest.version,
      private: true,
      type: manifest.type,
      description: manifest.description,
      license: manifest.license,
      main: manifest.main,
      types: manifest.types,
    }, null, 2)}\n`,
  );
  cpSync(join(sourceRoot, "lib"), join(targetRoot, "lib"), {
    recursive: true,
    filter: (source) => !/\.test\.(d\.ts|d\.ts\.map|js|js\.map)$/.test(source),
  });
}

console.log(`sync-local-packages: synced ${packages.length} @openburnbar package(s) into functions/vendor`);
