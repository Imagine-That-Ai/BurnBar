#!/usr/bin/env node
/**
 * Regression tests for GTM launch copy and upsell trigger assets.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

const launch = await readFile(path.join(ROOT, "src/data/launch.ts"), "utf8");

assert.match(
  launch,
  /OpenBurnBar is the cost meter and remote-control companion for the AI tools you already pay for - not another model subscription\./,
  "launch positioning must match the GTM master-plan copy"
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

for (const trigger of [
  "second-device-sign-in",
  "hosted-quota-refresh",
  "cloud-search",
  "encrypted-backup",
  "remote-mcp-grant"
]) {
  assert.match(
    launch,
    new RegExp(`id: "${trigger}"`),
    `Free to Cloud trigger ${trigger} is required`
  );
}

for (const trigger of [
  "floo-session-start",
  "agent-control-hosted-vision",
  "remote-mac-control",
  "audit-export-notarization",
  "hosted-action-balance-exhausted"
]) {
  assert.match(
    launch,
    new RegExp(`id: "${trigger}"`),
    `Cloud to Cloud Pro trigger ${trigger} is required`
  );
}

assert.doesNotMatch(
  launch,
  /fromTier: "free"[\s\S]{0,160}paywall: "BurnBar Cloud Pro"/,
  "Free users must not see a Cloud Pro prompt before a Group-B action"
);

assert.match(
  launch,
  /BurnBar Cloud adds sync, backup, and search across devices\. BurnBar Cloud Pro adds Data Vault agent memory/,
  "launch email copy must keep Data Vault agent memory in Cloud Pro, not base Cloud"
);

assert.doesNotMatch(
  launch,
  /Mercury|codec|protocol|transport|Pro Max/,
  "launch copy must avoid retired or internal implementation language"
);

console.log("launch-assets: GTM launch assets passed");
