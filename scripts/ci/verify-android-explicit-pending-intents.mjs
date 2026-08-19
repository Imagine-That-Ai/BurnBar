#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const defaultRepoRoot = path.resolve(scriptDir, "../..");

export const pendingIntentContracts = [
  {
    file: "android/app/src/main/java/com/openburnbar/data/budget/BudgetNotificationCenter.kt",
    variable: "intent",
    component: "MainActivity",
    sink: "getActivity",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmServiceSupport.kt",
    variable: "openIntent",
    component: "MainActivity",
    sink: "getActivity",
  },
  {
    // Second getActivity in this file: OS-routed quota/mission notification tap.
    file: "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmServiceSupport.kt",
    variable: "openIntent",
    component: "MainActivity",
    sink: "getActivity",
  },
  {
    // AI Inbox push tap-target: opens the deep-linked item in MainActivity.
    // Explicit component, direct package pin, and FLAG_IMMUTABLE, so a hostile
    // app cannot intercept the intent or mutate the item it resolves to.
    file: "android/app/src/main/java/com/openburnbar/services/media/AIInboxNotificationRouting.kt",
    variable: "openIntent",
    component: "MainActivity",
    sink: "getActivity",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmServiceSupport.kt",
    variable: "replyIntent",
    component: "AgentReplyNotificationReceiver",
    sink: "getBroadcast",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmService.kt",
    variable: "acceptIntent",
    component: "IncomingCallActivity",
    sink: "getActivity",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmService.kt",
    variable: "declineIntent",
    component: "IncomingCallActivity",
    sink: "getActivity",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/services/media/MediaSessionForegroundService.kt",
    variable: "launchIntent",
    component: "MainActivity",
    sink: "getActivity",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/menubar/MenuBarService.kt",
    variable: "intent",
    component: "MainActivity",
    sink: "getActivity",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/menubar/MenuBarTileService.kt",
    variable: "intent",
    component: "QuickGlanceActivity",
    sink: "getActivity",
  },
  {
    file: "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSessionGrantNotificationCenter.kt",
    variable: "intent",
    component: "MainActivity",
    sink: "getActivity",
  },
];

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function kotlinFilesUnder(directory) {
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...kotlinFilesUnder(target));
    } else if (entry.isFile() && entry.name.endsWith(".kt")) {
      files.push(target);
    }
  }
  return files;
}

export function pendingIntentCallCount(source) {
  return (
    source.match(/(?:android\.app\.)?PendingIntent\.get(?:Activity|Broadcast|Service)\s*\(/g) ?? []
  ).length;
}

export function verifyPendingIntentContract(source, contract) {
  const variable = escapeRegExp(contract.variable);
  const component = escapeRegExp(contract.component);
  const constructor = new RegExp(
    String.raw`val\s+${variable}\s*=\s*Intent\(\s*[^,\n]+,\s*${component}::class\.java\s*\)`,
  );
  const packagePin = new RegExp(
    String.raw`${variable}\.setPackage\(\s*[^)\n]*packageName[^)\n]*\)`,
  );
  const sink = new RegExp(
    String.raw`(?:android\.app\.)?PendingIntent\.${escapeRegExp(contract.sink)}\([\s\S]{0,320}?\b${variable}\b`,
  );

  assert.match(
    source,
    constructor,
    `${contract.file}: ${contract.variable} must use an explicit component constructor for ${contract.component}`,
  );
  assert.match(
    source,
    packagePin,
    `${contract.file}: ${contract.variable} must be pinned directly to the application package`,
  );
  assert.match(
    source,
    sink,
    `${contract.file}: ${contract.variable} must feed PendingIntent.${contract.sink}`,
  );
}

export function verifyAndroidPendingIntents(repoRoot = defaultRepoRoot) {
  const sourceRoot = path.join(repoRoot, "android/app/src/main/java");
  const files = kotlinFilesUnder(sourceRoot);
  const pendingFiles = files
    .map((file) => ({ file, source: fs.readFileSync(file, "utf8") }))
    .filter(({ source }) => pendingIntentCallCount(source) > 0);
  const actualCallCount = pendingFiles.reduce(
    (total, { source }) => total + pendingIntentCallCount(source),
    0,
  );

  assert.equal(
    actualCallCount,
    pendingIntentContracts.length,
    "Android PendingIntent inventory changed; add every new sink to the explicit-target contract",
  );

  for (const { file, source } of pendingFiles) {
    assert.doesNotMatch(
      source,
      /Intent\s*\(\s*\)\s*(?:\.apply)?/,
      `${path.relative(repoRoot, file)}: zero-argument Intent is forbidden in a PendingIntent source file`,
    );
    assert.doesNotMatch(
      source,
      /Intent\s*\(\s*Intent\.ACTION_VIEW(?:\s*,[^)]*)?\s*\)/,
      `${path.relative(repoRoot, file)}: action-only Intent is forbidden in a PendingIntent source file`,
    );
  }

  for (const contract of pendingIntentContracts) {
    const source = fs.readFileSync(path.join(repoRoot, contract.file), "utf8");
    verifyPendingIntentContract(source, contract);
  }

  return { callCount: actualCallCount, fileCount: pendingFiles.length };
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  const result = verifyAndroidPendingIntents();
  console.log(
    `Android PendingIntent verification passed: ${result.callCount} explicit intents across ${result.fileCount} files.`,
  );
}
