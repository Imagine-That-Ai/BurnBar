#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const preparer = join(scriptDir, "prepare-scoped-functions-deploy.mjs");
const repoRoot = join(scriptDir, "..", "..");
const root = mkdtempSync(join(tmpdir(), "openburnbar-scoped-functions-"));
const functionsDir = join(root, "functions");
const libDir = join(functionsDir, "lib");

function resetFixture(manifestOverrides = {}) {
  rmSync(functionsDir, { recursive: true, force: true });
  mkdirSync(join(libDir, "callables"), { recursive: true });
  writeFileSync(
    join(functionsDir, "package.json"),
    '{"name":"fixture","main":"lib/index.js"}\n',
  );
  writeFileSync(
    join(libDir, "callables", "selected.js"),
    "exports.selected = () => 'selected';\n",
  );
  writeFileSync(
    join(libDir, "callables", "unrelated.js"),
    "throw new Error('unrelated module loaded');\n",
  );
  writeFileSync(
    join(functionsDir, "staging-deploy-targets.json"),
    `${JSON.stringify(
      {
        schemaVersion: "openburnbar.staging-function-targets.v1",
        targets: {
          selected: { module: "./callables/selected.js", export: "selected" },
          unrelated: {
            module: "./callables/unrelated.js",
            export: "unrelated",
          },
          ...manifestOverrides,
        },
      },
      null,
      2,
    )}\n`,
  );
}

function run(targets) {
  return spawnSync(
    process.execPath,
    [preparer, "--targets", targets, "--functions-dir", functionsDir],
    { encoding: "utf8" },
  );
}

function expectFailure(label, targets) {
  const result = run(targets);
  if (result.status === 0) throw new Error(`${label}: expected failure`);
}

try {
  resetFixture();
  const selected = run("functions:selected");
  if (selected.status !== 0)
    throw new Error(
      `selected target failed:\n${selected.stdout}${selected.stderr}`,
    );
  const packageJson = JSON.parse(
    readFileSync(join(functionsDir, "package.json"), "utf8"),
  );
  if (packageJson.main !== "lib/staging-scoped-index.cjs")
    throw new Error("package main was not scoped");
  if (Object.keys(packageJson.scripts ?? {}).length !== 0)
    throw new Error("scoped package retained executable scripts");
  const require = createRequire(import.meta.url);
  const exports = require(join(libDir, "staging-scoped-index.cjs"));
  if (
    exports.selected() !== "selected" ||
    Object.keys(exports).join(",") !== "selected"
  ) {
    throw new Error(
      "generated entrypoint did not isolate the requested export",
    );
  }

  resetFixture();
  expectFailure("unknown target", "functions:unknown");
  if (
    JSON.parse(readFileSync(join(functionsDir, "package.json"), "utf8"))
      .main !== "lib/index.js"
  ) {
    throw new Error("failed preparation mutated package main");
  }

  resetFixture({
    traversal: { module: "./../outside.js", export: "traversal" },
  });
  expectFailure("path traversal", "functions:traversal");

  resetFixture();
  expectFailure("duplicate target", "functions:selected,functions:selected");

  resetFixture({
    missing: { module: "./callables/missing.js", export: "missing" },
  });
  expectFailure("missing compiled module", "functions:missing");

  resetFixture();
  const allFunctions = run("");
  if (allFunctions.status !== 0)
    throw new Error(`all-functions mode failed:\n${allFunctions.stderr}`);
  if (
    JSON.parse(readFileSync(join(functionsDir, "package.json"), "utf8"))
      .main !== "lib/index.js"
  ) {
    throw new Error("all-functions mode changed package main");
  }
  if (
    Object.keys(
      JSON.parse(readFileSync(join(functionsDir, "package.json"), "utf8"))
        .scripts ?? {},
    ).length !== 0
  ) {
    throw new Error("all-functions mode retained executable scripts");
  }

  const productionManifest = JSON.parse(
    readFileSync(
      join(repoRoot, "functions", "staging-deploy-targets.json"),
      "utf8",
    ),
  );
  const requiredCommercialTargets = [
    "burnBarHermesGateway",
    "latestRouterRundown",
    "startCliLink",
    "pollCliLink",
    "createStripeBurnBarProCheckoutSession",
    "createStripeBurnBarProPortalSession",
    "verifyGooglePlayBurnBarProSubscription",
    "verifyGooglePlayCloudProTopUp",
    "stripeBurnBarProWebhook",
    "googlePlayDeveloperNotifications",
    "reconcileGooglePlayVoidedPurchasesDaily",
    "beginEntitlementBinding",
    "verifyHostedQuotaEntitlement",
    "verifyCloudProTopUp",
    "restoreHostedQuotaEntitlement",
    "appStoreServerNotificationsV2",
    "reconcileHostedEntitlementsDaily",
  ];
  for (const target of requiredCommercialTargets) {
    const entry = productionManifest.targets?.[target];
    if (
      !entry ||
      typeof entry.module !== "string" ||
      typeof entry.export !== "string"
    ) {
      throw new Error(
        `commercial staging target ${target} is missing a valid manifest binding`,
      );
    }
  }

  console.log(
    "PASS: scoped staging Functions entrypoint isolates approved targets and fails closed.",
  );
} finally {
  rmSync(root, { recursive: true, force: true });
}
