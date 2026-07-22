import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { deviceLinkId, deviceLinkPath, isDeviceLinkCapability } from "../lib/domains/device-links/index.js";
import { assertConsolidatedServerOnlyCollection } from "../../scripts/lib/firestore-rules-contract.mjs";

assert.equal(isDeviceLinkCapability("owner"), true);
assert.equal(isDeviceLinkCapability("use"), true);
assert.equal(isDeviceLinkCapability("add"), true);
assert.equal(isDeviceLinkCapability("admin"), false);

assert.equal(deviceLinkId("codex_default", "MacBook Pro"), "codex_default_macbook-pro");
assert.equal(
  deviceLinkPath("user-1", "codex_default", "MacBook Pro"),
  "users/user-1/provider_account_device_links/codex_default_macbook-pro",
);

const types = readFileSync(new URL("../src/types/legacy/providers.ts", import.meta.url), "utf8");
assert.match(types, /export type ProviderAccountDeviceLinkDoc = Omit/);
assert.match(types, /capability: DeviceLinkCapability;/);
assert.match(types, /export type DeviceLinkCapability = "owner" \| "use" \| "add";/);
assert.match(types, /export interface RuntimeConnectionPreferenceDoc/);
assert.match(types, /export type RuntimeConnectionPreferenceKind = "hermes" \| "piAgent";/);

const rules = readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8");
assertConsolidatedServerOnlyCollection(rules, "provider_account_device_links");
{
  const start = rules.indexOf("match /users/{userId}/runtime_connection_preferences/");
  assert.notEqual(start, -1, "runtime_connection_preferences rules block must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create, update: if runtimeConnectionPreferenceWrite\(userId, preferenceId\);/);
  assert.match(rules, /request\.resource\.data\.runtimeKind in \["hermes", "piAgent"\]/);
  assert.match(
    rules,
    /preferenceId == request\.resource\.data\.deviceID \+ "_" \+ request\.resource\.data\.runtimeKind/,
  );
}

const indexSource = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
const providerAccountWritesSource = readFileSync(
  new URL("../src/callables/providerAccountWrites.ts", import.meta.url),
  "utf8",
);
for (const exportedName of [
  "adoptProviderAccountForDevice",
  "revokeProviderAccountDeviceLink",
  "backfillProviderAccountDeviceLinks",
  "backfillProviderAccountDeviceLinksScheduled",
]) {
  assert.match(indexSource, new RegExp(`\\b${exportedName}\\b`), `${exportedName} must be exported from index`);
}
assert.match(providerAccountWritesSource, /revokeAllLinksForAccount\(\s*db,\s*uid,\s*accountID\s*\)/);

console.log("Provider account device-link contract invariants passed");
