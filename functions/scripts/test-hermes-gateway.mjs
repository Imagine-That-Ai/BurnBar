import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  bearerTokenFromAuthorizationHeader,
  canonicalHermesGatewayUserCode,
  clampHermesGatewayLimit,
  destinationDocId,
  generateHermesGatewayBearerToken,
  hashHermesGatewayBearerToken,
  hashHermesGatewayDeviceSecret,
  HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
  isHermesGatewayClientDoc,
  isSha256Hex,
  makeHermesGatewaySSE,
  parseHermesGatewayCursor,
  randomHermesGatewayUserCode,
  safeEqualHex,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayModelId,
  sanitizeHermesGatewayModelOptions,
  sanitizeHermesGatewayScopes,
  sanitizedAttachmentIds,
  serializeHermesGatewayEvent,
  tokenPreview,
} from "../lib/hermesGateway.js";

function assertCallable(source, exportName) {
  assert.match(source, new RegExp(`export const ${exportName}\\b`), `${exportName} must exist`);
  assert.match(source, new RegExp(`wrapCallableHandler\\(\\s*"${exportName}"`), `${exportName} must be wrapped`);
}

const userCode = randomHermesGatewayUserCode();
assert.match(userCode, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
assert.equal(canonicalHermesGatewayUserCode("ab12 cd34"), "AB12-CD34");
assert.equal(canonicalHermesGatewayUserCode("short"), undefined);

const token = generateHermesGatewayBearerToken();
assert.match(token, /^obb_hgw_/);
assert.equal(bearerTokenFromAuthorizationHeader(`Bearer ${token}`), token);
assert.equal(bearerTokenFromAuthorizationHeader("Basic nope"), undefined);
assert.equal(isSha256Hex(hashHermesGatewayBearerToken(token)), true);
assert.equal(safeEqualHex(hashHermesGatewayDeviceSecret("secret"), hashHermesGatewayDeviceSecret("secret")), true);
assert.equal(safeEqualHex(hashHermesGatewayDeviceSecret("secret"), hashHermesGatewayDeviceSecret("other")), false);
assert.match(tokenPreview(token), /^obb_hgw_/);

assert.deepEqual(sanitizeHermesGatewayScopes(["hermes.gateway.read", "bad", "hermes.gateway.write"]), [
  "hermes.gateway.read",
  "hermes.gateway.write",
]);
assert.deepEqual(sanitizeHermesGatewayScopes([]), [
  "hermes.gateway.read",
  "hermes.gateway.write",
  "hermes.gateway.manage",
]);
assert.equal(sanitizeHermesGatewayDestinationId(undefined), HERMES_GATEWAY_DEFAULT_DESTINATION_ID);
assert.equal(sanitizeHermesGatewayDestinationId("burnbar:ops"), "burnbar:ops");
assert.equal(sanitizeHermesGatewayDestinationId("bad/path"), HERMES_GATEWAY_DEFAULT_DESTINATION_ID);
assert.equal(sanitizeHermesGatewayModelId(" minimax-m2.7-highspeed "), "minimax-m2.7-highspeed");
assert.equal(sanitizeHermesGatewayModelId("bad\nmodel"), undefined);
assert.deepEqual(
  sanitizeHermesGatewayModelOptions([
    {
      providerId: "minimax",
      providerName: "MiniMax",
      modelId: "minimax-m2.7-highspeed",
      displayName: "MiniMax M2.7 Highspeed",
    },
    {
      providerId: "dupe",
      modelId: "MINIMAX-M2.7-HIGHSPEED",
    },
    {
      modelId: "claude-opus-4-5",
    },
  ]),
  [
    {
      providerId: "minimax",
      providerName: "MiniMax",
      modelId: "minimax-m2.7-highspeed",
      displayName: "MiniMax M2.7 Highspeed",
    },
    {
      providerId: "hermes",
      providerName: "hermes",
      modelId: "claude-opus-4-5",
      displayName: "claude-opus-4-5",
    },
  ],
);
assert.equal(destinationDocId("burnbar:ops"), "burnbar-ops");
assert.equal(parseHermesGatewayCursor("42"), 42);
assert.equal(parseHermesGatewayCursor("-1"), 0);
assert.equal(clampHermesGatewayLimit("999"), 100);
assert.equal(clampHermesGatewayLimit("0"), 1);
assert.deepEqual(sanitizedAttachmentIds([" a ", "", "bad/path", "b"]), ["a", "b"]);

const event = serializeHermesGatewayEvent({
  id: "evt_1",
  sequence: 1,
  kind: "message",
  destinationId: "burnbar:home",
  targetClientId: "hgw_macbook",
  senderId: "u",
  text: "hello",
  attachmentIds: ["a", 1],
  createdAt: "2026-06-01T00:00:00.000Z",
  schemaVersion: 1,
});
assert.equal(event?.attachmentIds.length, 1);
assert.equal(event?.targetClientId, "hgw_macbook");
const modelSwitchEvent = serializeHermesGatewayEvent({
  id: "evt_model",
  sequence: 2,
  kind: "model_switch",
  destinationId: "burnbar:home",
  senderId: "u",
  text: "/model minimax-m2.7-highspeed",
  modelId: "minimax-m2.7-highspeed",
  attachmentIds: [],
  createdAt: "2026-06-01T00:00:00.000Z",
  schemaVersion: 1,
});
assert.equal(modelSwitchEvent?.kind, "model_switch");
assert.equal(modelSwitchEvent?.modelId, "minimax-m2.7-highspeed");
assert.match(makeHermesGatewaySSE([event], 1), /event: cursor/);

assert.equal(
  isHermesGatewayClientDoc({
    id: "c",
    uid: "u",
    displayName: "Hermes",
    status: "active",
    tokenHash: hashHermesGatewayBearerToken(token),
    tokenPreview: tokenPreview(token),
    scopes: ["hermes.gateway.read"],
    homeDestinationId: "burnbar:home",
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 1,
  }),
  true,
);
assert.equal(isHermesGatewayClientDoc({ id: "partial" }), false);

const source = readFileSync(new URL("../src/callables/hermesGateway.ts", import.meta.url), "utf8");
for (const name of [
  "approveHermesGatewayDeviceGrant",
  "listHermesGatewayClients",
  "revokeHermesGatewayClient",
  "enqueueHermesGatewayEvent",
]) {
  assertCallable(source, name);
}
assert.match(source, /export const burnBarHermesGateway = onRequest/);
assert.match(source, /\/device\/start/);
assert.match(source, /\/device\/poll/);
assert.match(source, /\/destinations/);
assert.match(source, /\/events/);
assert.match(source, /\/messages/);
assert.match(source, /\/attachments\/init/);
assert.match(source, /hermes_gateway_token_index/);
assert.match(source, /assertActiveHermesGatewayEntitlement/);
assert.match(source, /assertActiveHermesGatewayClient/);
assert.match(source, /targetClientId/);
assert.match(source, /event\.targetClientId === grant\.client\.id/);
assert.match(source, /await assertActiveHermesGatewayEntitlement\(index\.uid\);/);
assert.match(source, /getSignedUrl\(\{/);

const indexSource = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
for (const name of [
  "burnBarHermesGateway",
  "approveHermesGatewayDeviceGrant",
  "listHermesGatewayClients",
  "revokeHermesGatewayClient",
  "enqueueHermesGatewayEvent",
]) {
  assert.match(indexSource, new RegExp(`\\b${name}\\b`), `${name} must be exported from index`);
}

const rules = readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8");
for (const collection of [
  "hermes_gateway_clients",
  "hermes_gateway_events",
  "hermes_gateway_messages",
  "hermes_gateway_typing",
  "hermes_gateway_attachments",
  "hermes_gateway_state",
]) {
  const start = rules.indexOf(`match /users/{userId}/${collection}/`);
  assert.notEqual(start, -1, `${collection} rules block must exist`);
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow write: if false;/, `${collection} writes must stay server-owned`);
}
assert.match(rules, /function hermesGatewayDestinationWrite\(userId, destinationId\)/);
assert.match(rules, /match \/users\/\{userId\}\/hermes_gateway_destinations\/\{destinationId\}/);
assert.match(rules, /hasActiveHostedQuotaEntitlement\(userId\)/);
assert.match(rules, /match \/hermes_gateway_device_sessions\/\{sessionId\}/);
assert.match(rules, /match \/hermes_gateway_token_index\/\{tokenHash\}/);

const firebaseConfig = JSON.parse(readFileSync(new URL("../../firebase.json", import.meta.url), "utf8"));
assert.ok(
  firebaseConfig.hosting.rewrites.some(
    (rewrite) =>
      rewrite.source === "/v1/hermes-gateway/**" &&
      rewrite.function?.functionId === "burnBarHermesGateway" &&
      rewrite.function?.region === "us-central1",
  ),
  "Firebase Hosting must route the public Hermes Gateway base path to burnBarHermesGateway",
);

const connectPage = readFileSync(new URL("../../website/src/pages/hermes/connect.astro", import.meta.url), "utf8");
assert.match(connectPage, /approveHermesGatewayDeviceGrant/);
assert.match(connectPage, /googleProvider/);
assert.match(connectPage, /appleProvider/);
assert.match(connectPage, /new URLSearchParams\(window\.location\.search\)/);

console.log("Hermes Gateway contracts, exports, and rule invariants passed");
