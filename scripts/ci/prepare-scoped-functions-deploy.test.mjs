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
const syncDir = join(root, "functions-sync");
const syncLibDir = join(syncDir, "lib");

function writePackage(dir, name) {
  writeFileSync(
    join(dir, "package.json"),
    `{"name":"${name}","main":"lib/index.js"}\n`,
  );
  writeFileSync(
    join(dir, "package-lock.json"),
    '{"name":"fixture","lockfileVersion":3,"requires":true,"packages":{"":{"name":"fixture"}}}\n',
  );
}

function resetFixture(manifestOverrides = {}) {
  rmSync(functionsDir, { recursive: true, force: true });
  rmSync(syncDir, { recursive: true, force: true });
  mkdirSync(join(libDir, "callables"), { recursive: true });
  mkdirSync(join(syncLibDir, "domains"), { recursive: true });
  writePackage(functionsDir, "fixture");
  writePackage(syncDir, "fixture-sync");
  writeFileSync(
    join(libDir, "callables", "selected.js"),
    "exports.selected = () => 'selected';\n",
  );
  writeFileSync(
    join(libDir, "callables", "unrelated.js"),
    "throw new Error('unrelated module loaded');\n",
  );
  writeFileSync(
    join(syncLibDir, "domains", "synced.js"),
    "exports.synced = () => 'synced';\n",
  );
  writeFileSync(
    join(functionsDir, "staging-deploy-targets.json"),
    `${JSON.stringify(
      {
        schemaVersion: "openburnbar.staging-function-targets.v2",
        targets: {
          selected: {
            codebase: "admin",
            module: "./callables/selected.js",
            export: "selected",
          },
          unrelated: {
            codebase: "admin",
            module: "./callables/unrelated.js",
            export: "unrelated",
          },
          synced: {
            codebase: "sync",
            module: "./domains/synced.js",
            export: "synced",
          },
          ...manifestOverrides,
        },
      },
      null,
      2,
    )}\n`,
  );
}

const githubOutputPath = join(root, "github-output");

function run(targets) {
  writeFileSync(githubOutputPath, "");
  return spawnSync(
    process.execPath,
    [preparer, "--targets", targets, "--functions-dir", functionsDir],
    {
      encoding: "utf8",
      env: { ...process.env, GITHUB_OUTPUT: githubOutputPath },
    },
  );
}

function readResolvedTargets() {
  return readFileSync(githubOutputPath, "utf8");
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
  if (
    readResolvedTargets() !==
    "function_targets=functions:selected\ninvolved_codebases=functions\n"
  ) {
    throw new Error(
      "explicit selection did not emit its resolved deploy selectors",
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

  resetFixture({
    badCodebase: {
      codebase: "unknown",
      module: "./callables/selected.js",
      export: "selected",
    },
  });
  expectFailure("unknown codebase", "functions:badCodebase");

  resetFixture();
  writeFileSync(
    join(libDir, "callables", "unrelated.js"),
    "exports.unrelated = () => 'unrelated';\n",
  );
  const reviewedDefaults = run("");
  if (reviewedDefaults.status !== 0)
    throw new Error(
      `reviewed-default mode failed:\n${reviewedDefaults.stderr}`,
    );
  if (
    JSON.parse(readFileSync(join(functionsDir, "package.json"), "utf8"))
      .main !== "lib/staging-scoped-index.cjs"
  ) {
    throw new Error("reviewed-default mode did not scope package main");
  }
  if (
    Object.keys(
      JSON.parse(readFileSync(join(functionsDir, "package.json"), "utf8"))
        .scripts ?? {},
    ).length !== 0
  ) {
    throw new Error("reviewed-default mode retained executable scripts");
  }
  const reviewedEntrypoint = join(libDir, "staging-scoped-index.cjs");
  delete require.cache[require.resolve(reviewedEntrypoint)];
  const reviewedExports = require(reviewedEntrypoint);
  if (
    reviewedExports.selected() !== "selected" ||
    reviewedExports.unrelated() !== "unrelated" ||
    Object.keys(reviewedExports).sort().join(",") !== "selected,unrelated"
  ) {
    throw new Error(
      "blank target input did not export exactly the reviewed staging manifest",
    );
  }
  const reviewedSyncEntrypoint = join(syncLibDir, "staging-scoped-index.cjs");
  delete require.cache[require.resolve(reviewedSyncEntrypoint)];
  const reviewedSyncExports = require(reviewedSyncEntrypoint);
  if (
    reviewedSyncExports.synced() !== "synced" ||
    Object.keys(reviewedSyncExports).join(",") !== "synced"
  ) {
    throw new Error(
      "blank target input did not scope the reviewed sync codebase entrypoint",
    );
  }
  if (
    JSON.parse(readFileSync(join(syncDir, "package.json"), "utf8")).main !==
    "lib/staging-scoped-index.cjs"
  ) {
    throw new Error("reviewed-default mode did not scope the sync package main");
  }
  if (
    readResolvedTargets() !==
    "function_targets=functions:selected,functions:unrelated,functions:synced\n" +
      "involved_codebases=functions,functions-sync\n"
  ) {
    throw new Error(
      "blank target input did not emit the resolved manifest deploy selectors",
    );
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
      typeof entry.codebase !== "string" ||
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
