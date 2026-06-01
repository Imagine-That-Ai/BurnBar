#!/usr/bin/env node
/**
 * Regression tests for GTM launch copy and upsell trigger assets.
 */

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

async function importTypeScriptModule(relativePath) {
  const sourcePath = path.join(ROOT, relativePath);
  const source = await readFile(sourcePath, "utf8");
  const compiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
      sourceMap: false
    },
    fileName: sourcePath
  }).outputText;
  const tempDir = await mkdtemp(path.join(tmpdir(), "openburnbar-launch-assets-"));
  const modulePath = path.join(tempDir, "launch.mjs");
  await writeFile(modulePath, compiled);
  try {
    return {
      source,
      module: await import(`file://${modulePath}?v=${Date.now()}`)
    };
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

const { source: launch, module: launchModule } = await importTypeScriptModule("src/data/launch.ts");

assert.match(
  launch,
  /OpenBurnBar is the cost meter and remote-control companion for the AI tools you already pay for - not another model subscription\./,
  "launch positioning must match the GTM master-plan copy"
);

assert.equal(
  launchModule.LAUNCH_POSITIONING,
  "OpenBurnBar is the cost meter and remote-control companion for the AI tools you already pay for - not another model subscription.",
  "launch positioning export must match the GTM master-plan copy"
);

for (const channel of [
  "github_release",
  "hacker_news",
  "reddit",
  "indie_hackers",
  "product_hunt",
  "email"
]) {
  assert.match(launch, new RegExp(`channel: "${channel}"`), `${channel} launch post is required`);
}
assert.deepEqual(
  launchModule.LAUNCH_POSTS.map((post) => post.channel).sort(),
  ["email", "github_release", "hacker_news", "indie_hackers", "product_hunt", "reddit"],
  "launch posts must cover the GTM channel set exactly"
);

const requiredFreeToCloud = [
  "second-device-sign-in",
  "hosted-quota-refresh",
  "cloud-search",
  "encrypted-backup",
  "remote-mcp-grant"
];
for (const trigger of requiredFreeToCloud) {
  assert.match(launch, new RegExp(`id: "${trigger}"`), `Free to Cloud trigger ${trigger} is required`);
}

const requiredCloudToCloudPro = [
  "floo-session-start",
  "agent-control-hosted-vision",
  "remote-mac-control",
  "audit-export-notarization",
  "hosted-action-balance-exhausted"
];
for (const trigger of requiredCloudToCloudPro) {
  assert.match(launch, new RegExp(`id: "${trigger}"`), `Cloud to Cloud Pro trigger ${trigger} is required`);
}

const triggerIDs = launchModule.LAUNCH_UPSELL_TRIGGERS.map((trigger) => trigger.id);
assert.equal(new Set(triggerIDs).size, triggerIDs.length, "upsell trigger IDs must be unique");
assert.deepEqual(
  launchModule.FREE_TO_CLOUD_TRIGGERS.map((trigger) => trigger.id).sort(),
  [...requiredFreeToCloud].sort(),
  "Free to Cloud trigger set must match GTM T25 exactly"
);
assert.deepEqual(
  launchModule.CLOUD_TO_CLOUD_PRO_TRIGGERS.map((trigger) => trigger.id).sort(),
  [...requiredCloudToCloudPro].sort(),
  "Cloud to Cloud Pro trigger set must match GTM T25 exactly"
);
for (const trigger of launchModule.FREE_TO_CLOUD_TRIGGERS) {
  assert.equal(trigger.fromTier, "free", `${trigger.id} must start from free`);
  assert.equal(trigger.toTier, "cloud", `${trigger.id} must open BurnBar Cloud`);
  assert.equal(trigger.paywall, "BurnBar Cloud", `${trigger.id} must not open Cloud Pro`);
  assert.equal(trigger.featureGroup, "Group A", `${trigger.id} must be a Group A trigger`);
}
for (const trigger of launchModule.CLOUD_TO_CLOUD_PRO_TRIGGERS) {
  assert.equal(trigger.fromTier, "cloud", `${trigger.id} must start from cloud`);
  assert.equal(trigger.toTier, "cloud_pro", `${trigger.id} must open BurnBar Cloud Pro`);
  assert.equal(trigger.paywall, "BurnBar Cloud Pro", `${trigger.id} must open Cloud Pro`);
  assert.equal(trigger.featureGroup, "Group B", `${trigger.id} must be a Group B trigger`);
}
assert.equal(
  launchModule.LAUNCH_UPSELL_TRIGGERS.some(
    (trigger) => trigger.fromTier === "free" && trigger.toTier === "cloud_pro"
  ),
  false,
  "Free users must never be routed directly to Cloud Pro"
);
assert.equal(
  launchModule.LAUNCH_UPSELL_TRIGGERS.some(
    (trigger) => trigger.fromTier === "free" && trigger.featureGroup === "Group B"
  ),
  false,
  "Free users must not see Group B upsells before a Cloud action path"
);

assert.doesNotMatch(
  launch,
  /fromTier: "free"[\s\S]{0,160}paywall: "BurnBar Cloud Pro"/,
  "Free users must not see a Cloud Pro prompt before a Group-B action"
);

assert.doesNotMatch(
  launch,
  /Mercury|codec|protocol|transport|Pro Max/,
  "launch copy must avoid retired or internal implementation language"
);

console.log("launch-assets: GTM launch assets passed");
