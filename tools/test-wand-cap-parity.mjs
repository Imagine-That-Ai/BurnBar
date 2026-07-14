#!/usr/bin/env node
/**
 * Fails if any shipped Wand fan-out cap copy drifts from
 * packages/entitlements/src/catalog.ts (WAND_PARALLEL_CAPS).
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const catalogJsPath = path.join(repoRoot, "packages/entitlements/lib/catalog.js");

if (!existsSync(catalogJsPath)) {
  console.error(
    `test-wand-cap-parity: ${path.relative(repoRoot, catalogJsPath)} not found.\n` +
      "Build the entitlements package first: bash scripts/build-entitlements.sh",
  );
  process.exit(2);
}

const { WAND_PARALLEL_CAPS } = await import(pathToFileURL(catalogJsPath).href);
const expected = {
  free: WAND_PARALLEL_CAPS.free,
  cloud: WAND_PARALLEL_CAPS.cloud,
  pro: WAND_PARALLEL_CAPS.pro,
  ultra: WAND_PARALLEL_CAPS.ultra,
};

function readRepo(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function numberFrom(source, pattern, label) {
  const match = pattern.exec(source);
  assert.ok(match, `${label}: pattern not found`);
  return Number(match[1]);
}

function assertCaps(label, actual) {
  assert.deepEqual(actual, expected, `${label} Wand cap ladder drifted from packages/entitlements`);
}

const swift = readRepo("OpenBurnBarCore/Sources/OpenBurnBarKernelModels/Membership/GatedFeature.swift");
assertCaps("Swift WandFanOut.maxParallel", {
  free: numberFrom(swift, /case \.none:\s*return\s+(\d+)/, "Swift free cap"),
  cloud: numberFrom(swift, /case \.cloud:\s*return\s+(\d+)/, "Swift cloud cap"),
  pro: numberFrom(swift, /case \.pro:\s*return\s+(\d+)/, "Swift pro cap"),
  ultra: numberFrom(swift, /case \.ultra:\s*return\s+(\d+)/, "Swift ultra cap"),
});

const kotlin = readRepo("android/app/src/main/java/com/openburnbar/ui/pro/GatedFeature.kt");
assertCaps("Kotlin WandFanOut.maxParallel", {
  free: numberFrom(kotlin, /CloudTier\.NONE\s*->\s*(\d+)/, "Kotlin free cap"),
  cloud: numberFrom(kotlin, /CloudTier\.CLOUD\s*->\s*(\d+)/, "Kotlin cloud cap"),
  pro: numberFrom(kotlin, /CloudTier\.PRO\s*->\s*(\d+)/, "Kotlin pro cap"),
  ultra: numberFrom(kotlin, /CloudTier\.ULTRA\s*->\s*(\d+)/, "Kotlin ultra cap"),
});

const website = readRepo("website/src/data/site.ts");
assertCaps("website pricing allowance", {
  free: numberFrom(website, /id:\s*"free"[\s\S]*?wandParallelMax:\s*(\d+)/, "website free cap"),
  cloud: numberFrom(website, /id:\s*"cloud"[\s\S]*?wandParallelMax:\s*(\d+)/, "website cloud cap"),
  pro: numberFrom(website, /id:\s*"cloud_pro"[\s\S]*?wandParallelMax:\s*(\d+)/, "website pro cap"),
  ultra: numberFrom(website, /id:\s*"ultra"[\s\S]*?wandParallelMax:\s*(\d+)/, "website ultra cap"),
});

const functionsUsage = readRepo("functions/src/callables/dataDomainUsage.ts");
assert.match(
  functionsUsage,
  /import\s+\{\s*WAND_PARALLEL_CAPS\s*\}\s+from\s+"@openburnbar\/entitlements";/,
  "Functions dataDomainUsage must import WAND_PARALLEL_CAPS from @openburnbar/entitlements",
);
assert.match(
  functionsUsage,
  /export function wandParallelMaxForDataTier\(tier: DataTier\): number \{\s*return WAND_PARALLEL_CAPS\[tier\];\s*\}/,
  "Functions wandParallelMaxForDataTier must return the canonical table lookup",
);

const rules = readRepo("firestore.rules");
assertCaps("firestore.rules wandFanOutCap", {
  free: numberFrom(rules, /hasActiveHostedQuotaEntitlement\(userId\) \? \d+\s*: (\d+);/, "rules free cap"),
  cloud: numberFrom(rules, /hasActiveHostedQuotaEntitlement\(userId\) \? (\d+)/, "rules cloud cap"),
  pro: numberFrom(rules, /hasActiveProMaxEntitlement\(userId\) \? (\d+)/, "rules pro cap"),
  ultra: numberFrom(rules, /hasActiveUltraEntitlement\(userId\) \? (\d+)/, "rules ultra cap"),
});

console.log("Wand cap parity matches packages/entitlements across Swift, Kotlin, website, Functions, and rules.");
