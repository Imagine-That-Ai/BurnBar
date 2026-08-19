import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  isHermesConnectionDoc,
  pairingCodeDigest,
  parseHermesPlatform,
  randomPairingCode,
  safeEqualHex,
  sanitizeHermesCapabilities,
  validateHermesEndpointURL,
} from "../lib/hermes.js";
import {
  assertConsolidatedServerOnlyCollection,
  firestoreFunctionBlock,
} from "../../scripts/lib/firestore-rules-contract.mjs";

function assertHttpsError(fn, code) {
  assert.throws(fn, (err) => err?.code === code);
}

function callableExportBlock(source, exportName) {
  const start = source.indexOf(`export const ${exportName}`);
  assert.notEqual(start, -1, `${exportName} must exist`);
  const onCallIndex = source.indexOf("onCall(", start);
  assert.notEqual(onCallIndex, -1, `${exportName} must use onCall`);
  const openParen = source.indexOf("(", onCallIndex);
  let depth = 0;
  for (let i = openParen; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === "(") depth += 1;
    else if (ch === ")") {
      depth -= 1;
      if (depth === 0) {
        const end = source[i + 1] === ";" ? i + 2 : i + 1;
        return source.slice(start, end);
      }
    }
  }
  throw new Error(`Could not find end of ${exportName} onCall export`);
}

const code = randomPairingCode();
assert.match(code, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
assert.equal(pairingCodeDigest("ab12-cd34"), pairingCodeDigest("AB12CD34"));
assert.equal(safeEqualHex(pairingCodeDigest("AB12-CD34"), pairingCodeDigest("ab12cd34")), true);
assert.equal(safeEqualHex(pairingCodeDigest("AB12-CD34"), pairingCodeDigest("AB12-CD35")), false);

assert.equal(validateHermesEndpointURL("https://hermes.example.com/", "directURL"), "https://hermes.example.com");
assert.equal(validateHermesEndpointURL("http://127.0.0.1:8642", "directURL"), "http://127.0.0.1:8642");
assert.equal(validateHermesEndpointURL("http://192.168.1.10:8642", "directURL"), "http://192.168.1.10:8642");
assert.equal(validateHermesEndpointURL(undefined, "relayLink"), undefined);
assertHttpsError(() => validateHermesEndpointURL(undefined, "directURL"), "invalid-argument");
assertHttpsError(() => validateHermesEndpointURL("http://8.8.8.8:8642", "directURL"), "invalid-argument");
assertHttpsError(() => validateHermesEndpointURL("https://token@example.com", "directURL"), "invalid-argument");
assertHttpsError(
  () => validateHermesEndpointURL("https://hermes.example.com?api_key=secret", "directURL"),
  "invalid-argument",
);
assertHttpsError(() => validateHermesEndpointURL("ftp://hermes.example.com", "directURL"), "invalid-argument");

assert.equal(parseHermesPlatform("ios"), "ios");
assert.equal(parseHermesPlatform("ipados"), "ipados");
assert.equal(parseHermesPlatform(undefined), undefined);
assertHttpsError(() => parseHermesPlatform("desktop"), "invalid-argument");

const noisyCapabilities = [
  " chat_completions ",
  "",
  123,
  "x".repeat(65),
  ...Array.from({ length: 40 }, (_, i) => `cap_${i}`),
];
const capabilities = sanitizeHermesCapabilities(noisyCapabilities);
assert.equal(capabilities[0], "chat_completions");
assert.equal(capabilities.includes(""), false);
assert.equal(
  capabilities.some((item) => item.length > 64),
  false,
);
assert.equal(capabilities.length, 32);

assert.equal(
  isHermesConnectionDoc({
    id: "hermes_1",
    displayName: "Hermes",
    mode: "directURL",
    status: "online",
    capabilities: ["chat_completions"],
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    schemaVersion: 1,
  }),
  true,
);
assert.equal(isHermesConnectionDoc({ id: "partial", status: "revoked" }), false);

const rules = readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8");
for (const collection of ["hermes_pairings", "hermes_session_cache", "hermes_audit_events"]) {
  assertConsolidatedServerOnlyCollection(rules, collection);
}
{
  const start = rules.indexOf("match /users/{userId}/hermes_connections/");
  assert.notEqual(start, -1, "hermes_connections rules block must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create: if relayConnectionWrite\(userId, connectionId\);/);
  assert.match(
    block,
    /allow update: if relayConnectionWrite\(userId, connectionId\)\s+&& request\.resource\.data\.mode == "relayLink"\s+&& resource\.data\.mode == "relayLink";/,
  );
  assert.match(rules, /function hasActiveHostedQuotaEntitlement\(userId\)/);
  assert.match(rules, /"com\.openburnbar\.hostedQuotaSync\.cloud\.monthly"/);
  assert.match(rules, /"com\.openburnbar\.pro\.monthly"/);
  assert.match(rules, /entitlement\.expireAt is timestamp/);
  assert.match(rules, /entitlement\.expireAt > request\.time/);
  const relayConnection = firestoreFunctionBlock(rules, "relayConnectionWrite");
  assert.match(relayConnection, /let d = request\.resource\.data;/);
  assert.match(relayConnection, /d\.mode == "relayLink"/);
  assert.match(relayConnection, /d\.id == connectionId/);
  assert.match(
    relayConnection,
    /d\.keys\(\)\.hasOnly\(\[[\s\S]*"advertisedModel"[\s\S]*"relayPublicKey"[\s\S]*"relayEncryption"[\s\S]*"realtimeRelayURL"[\s\S]*"realtimeRelayLastSeenAt"[\s\S]*"realtimeRelayProtocolVersion"[\s\S]*\]\)/,
  );
  assert.match(relayConnection, /d\.relayEncryption == "hpke-auth-p256-hkdfsha256-aes256gcm"/);
  assert.match(relayConnection, /validRealtimeRelayURL\(d\.realtimeRelayURL\)/);
  assert.match(rules, /function validRealtimeRelayURL\(value\) \{[\s\S]*value\.matches\("\^wss:\/\/\[a-z0-9\]/);
  assert.match(rules, /function validRealtimeRelayURL\(value\) \{[\s\S]*!value\.matches\("\^wss:\/\/localhost/);
  assert.match(relayConnection, /d\.realtimeRelayStatus in \["online", "offline", "degraded"\]/);
  assert.match(relayConnection, /d\.realtimeRelayLastSeenAt is string/);
  assert.match(relayConnection, /d\.realtimeRelayProtocolVersion is int/);
  assert.doesNotMatch(
    block,
    /ownerWritableNonSecret\(userId\);/,
    "direct Hermes URLs must not become broadly client-writable",
  );
}
for (const collection of ["hermes_relay_requests"]) {
  const start = rules.indexOf(`match /users/{userId}/${collection}/`);
  assert.notEqual(start, -1, `${collection} rules block must exist`);
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create, update: if relayRequestWrite\(userId, requestId\);/);
  assert.match(
    rules,
    /function relayRequestWrite\(userId, requestId\) \{[\s\S]*hasActiveHostedQuotaEntitlement\(userId\)/,
  );
  const relayRequest = firestoreFunctionBlock(rules, "relayRequestWrite");
  assert.match(relayRequest, /d\.id == requestId/);
  assert.match(
    relayRequest,
    /d\.operation in \["chatCompletions", "cliAgentChat", "cliAgentModelCatalog", "models", "sessions", "sessionDetail", "profiles", "jobs"\]/,
    "Hermes relay requests must allow cliAgentModelCatalog for Mac CLI model pickers",
  );
  assert.match(rules, /match \/chunks\/\{chunkId\}/);
  assert.match(rules, /allow create, update: if relayChunkWrite\(userId, requestId, chunkId\);/);
  const relayChunk = firestoreFunctionBlock(rules, "relayChunkWrite");
  assert.match(relayChunk, /d\.id == chunkId/);
  assert.match(relayChunk, /d\.requestId == requestId/);
}
{
  const start = rules.indexOf("match /users/{userId}/smart_hub_config/");
  assert.notEqual(start, -1, "smart_hub_config rules block must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create, update: if ownerWritableNonSecret\(userId\)/);
  assert.match(
    block,
    /request\.resource\.data\.keys\(\)\.hasOnly\(\[[\s\S]*"dashboardURL"[\s\S]*"voiceRefreshURL"[\s\S]*"pixelClock"[\s\S]*"schemaVersion"[\s\S]*\]\)/,
  );
  assert.match(block, /request\.resource\.data\.enabled is bool/);
  assert.match(block, /request\.resource\.data\.schemaVersion is int/);
  assert.match(block, /validPixelClockConfig\(request\.resource\.data\.pixelClock\)/);
}
{
  const start = rules.indexOf("match /users/{userId}/smart_display_actions/");
  assert.notEqual(start, -1, "smart_display_actions rules block must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create, update: if ownerWritableNonSecret\(userId\)/);
  assert.match(block, /request\.resource\.data\.type in \[/);
  for (const actionType of [
    "pixel_clock_probe",
    "pixel_clock_test",
    "pixel_clock_push",
    "pixel_clock_remove",
    "pixel_clock_update_config",
  ]) {
    assert.match(block, new RegExp(`"${actionType}"`));
  }
  assert.match(block, /request\.resource\.data\.status in \["pending", "completed", "failed"\]/);
  assert.match(block, /validPixelClockConfig\(request\.resource\.data\.pixelClock\)/);
}
{
  const start = rules.indexOf("function validPixelClockConfig(pixelClock)");
  assert.notEqual(start, -1, "validPixelClockConfig helper must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /pixelClock\.host\.size\(\) <= 255/);
  assert.match(block, /pixelClock\.port >= 1[\s\S]*pixelClock\.port <= 65535/);
  assert.match(block, /pixelClock\.layout in \["providerDashboard", "quotaCarousel", "burnStatus", "alertsOnly"\]/);
  assert.match(block, /pixelClock\.palette in \["emberWhimsy", "mercury", "traffic", "monochrome", "rainbow"\]/);
  assert.match(block, /pixelClock\.brightness >= 0[\s\S]*pixelClock\.brightness <= 255/);
  assert.match(block, /pixelClock\.providerIDs\.size\(\) <= 24/);
  assert.match(
    block,
    /pixelClock\.lastProbeStatus in \["unknown", "awtrixReady", "stockUlanziFirmware", "unreachable", "unsupported", "error"\]/,
  );
}
{
  const start = rules.indexOf("function validSmartHubDisplayConfig(displayConfig)");
  assert.notEqual(start, -1, "validSmartHubDisplayConfig helper must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /displayConfig\.palette in \["emberWhimsy", "mercury", "forestSage", "monochrome", "rainbow"\]/);
}
{
  const block = firestoreFunctionBlock(rules, "relayRequestWrite");
  assert.match(block, /d\.schemaVersion >= 2/);
  assert.match(block, /!\("path" in d\)[\s\S]*!\("sessionId" in d\)[\s\S]*!\("body" in d\)[\s\S]*!\("error" in d\)/);
  assert.match(
    block,
    /d\.payloadCiphertext is string[\s\S]*d\.wrappedKey is string[\s\S]*d\.relayEncryption == "hpke-auth-p256-hkdfsha256-aes256gcm"/,
  );
  assert.match(block, /d\.relayKeyVersion == 3/);
  assert.match(
    block,
    /d\.senderPublicKey is string[\s\S]*d\.senderDeviceId is string[\s\S]*d\.senderPeerNodeId is string/,
  );
  assert.match(block, /d\.senderCounter is int[\s\S]*d\.senderCounter >= 0/);
  assert.match(block, /d\.keyId\.matches\("\^relay-v3-\[a-f0-9\]\{24\}\$"\)/);
  assert.doesNotMatch(block, /d\.schemaVersion < 2/);
}
{
  const block = firestoreFunctionBlock(rules, "piRelayRequestWrite");
  assert.match(block, /d\.schemaVersion >= 2[\s\S]*d\.payloadCiphertext is string[\s\S]*d\.wrappedKey is string/);
  assert.doesNotMatch(block, /"body"|"data"|"ciphertext"/);
  assert.doesNotMatch(block, /d\.schemaVersion < 2/);
}
assert.match(
  readFileSync(new URL("../src/callables/hermes.ts", import.meta.url), "utf8"),
  /current\.status === "revoked"/,
);
{
  const indexSource = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
  const hermesSource = readFileSync(new URL("../src/callables/hermes.ts", import.meta.url), "utf8");
  for (const exportedName of [
    "createHermesPairing",
    "completeHermesPairing",
    "listHermesConnections",
    "revokeHermesConnection",
    "updateHermesConnectionStatus",
  ]) {
    assert.match(indexSource, new RegExp(`\\b${exportedName}\\b`), `${exportedName} must be exported from index`);
    const start = hermesSource.indexOf(`export const ${exportedName}`);
    assert.notEqual(start, -1, `${exportedName} must exist in callables/hermes.ts`);
    const block = callableExportBlock(hermesSource, exportedName);
    assert.match(block, /await assertActiveHostedQuotaEntitlement\(uid\);/, `${exportedName} must be premium-gated`);
  }
}
assert.match(firestoreFunctionBlock(rules, "hasNoPlaintextSecretFields"), /!\("secretVersionName" in d\)/);

console.log("Hermes contract and Firestore rule invariants passed");
