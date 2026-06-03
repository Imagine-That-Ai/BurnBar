import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  bearerTokenFromAuthorizationHeader,
  canonicalHermesGatewayUserCode,
  clampHermesGatewayLimit,
  clientAdvertisesModel,
  destinationDocId,
  effectiveOversightMode,
  gatewayApprovalExpiryISO,
  gatewayTokenExpiryISO,
  generateHermesGatewayBearerToken,
  hashHermesGatewayBearerToken,
  hashHermesGatewayDeviceSecret,
  HERMES_GATEWAY_APPROVAL_TTL_MS,
  HERMES_GATEWAY_DEFAULT_DESTINATION_ID,
  HERMES_GATEWAY_PENDING_MODEL_TTL_MS,
  HERMES_GATEWAY_PRESENCE_WINDOW_MS,
  HERMES_GATEWAY_PROTOCOL_VERSION,
  HERMES_GATEWAY_TOKEN_TTL_MS,
  isHermesGatewayApprovalActionable,
  isHermesGatewayApprovalDoc,
  isHermesGatewayApprovalExpired,
  isHermesGatewayAttachmentManifestDoc,
  isHermesGatewayClientDoc,
  isHermesGatewayClientOnline,
  isHermesGatewayTokenExpired,
  isSha256Hex,
  pendingModelSwitchInFlight,
  publicApprovalView,
  publicClientView,
  makeHermesGatewaySSE,
  parseHermesGatewayCursor,
  randomHermesGatewayUserCode,
  safeEqualHex,
  sanitizeHermesGatewayApprovalSummary,
  sanitizeHermesGatewayDestinationId,
  sanitizeHermesGatewayModelId,
  sanitizeHermesGatewayModelOptions,
  sanitizeHermesGatewayOversightMode,
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
  isHermesGatewayAttachmentManifestDoc({
    id: "att_1",
    clientId: "hgw_client",
    destinationId: "burnbar:home",
    fileName: "image.png",
    contentType: "image/png",
    byteCount: 42,
    storagePath: "users/u/hermes_gateway_attachments/hgw_client/att_1/image.png",
    status: "uploaded",
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:01.000Z",
    expiresAt: "2026-06-01T00:10:00.000Z",
    uploadedAt: "2026-06-01T00:00:01.000Z",
    finalizedAt: "2026-06-01T00:00:01.000Z",
    sha256: "a".repeat(64),
    storageGeneration: "123",
    schemaVersion: 1,
  }),
  true,
);
assert.equal(isHermesGatewayAttachmentManifestDoc({ id: "att_1", status: "pending_upload" }), false);

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

// --- Bearer-token expiry / rotation contracts (B-SEC-5) ---
assert.ok(
  Number.isFinite(HERMES_GATEWAY_TOKEN_TTL_MS) && HERMES_GATEWAY_TOKEN_TTL_MS > 0,
  "HERMES_GATEWAY_TOKEN_TTL_MS must be a positive finite number",
);
// Missing/empty expiresAt is grandfathered as non-expiring.
assert.equal(isHermesGatewayTokenExpired(undefined), false);
assert.equal(isHermesGatewayTokenExpired(null), false);
assert.equal(isHermesGatewayTokenExpired(""), false);
// A past ISO timestamp is expired; a future one is valid.
assert.equal(isHermesGatewayTokenExpired("2000-01-01T00:00:00.000Z"), true);
assert.equal(isHermesGatewayTokenExpired(new Date(Date.now() + 60_000).toISOString()), false);
// Corrupt / non-string values fail closed (treated as expired).
assert.equal(isHermesGatewayTokenExpired(123), true);
assert.equal(isHermesGatewayTokenExpired("garbage"), true);
// gatewayTokenExpiryISO returns now + TTL as a parseable ISO string.
const expiryFrom = 1_700_000_000_000;
assert.equal(gatewayTokenExpiryISO(expiryFrom), new Date(expiryFrom + HERMES_GATEWAY_TOKEN_TTL_MS).toISOString());

// isHermesGatewayClientDoc tolerates the new optional fields and rejects bad types.
const baseClient = {
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
};
assert.equal(isHermesGatewayClientDoc({ ...baseClient, expiresAt: "2026-09-01T00:00:00.000Z" }), true);
assert.equal(isHermesGatewayClientDoc({ ...baseClient, expiresAt: 123 }), false);
assert.equal(isHermesGatewayClientDoc({ ...baseClient, rotatedAt: 123 }), false);

// publicClientView surfaces the new read-only fields, including derived oversight.
const view = publicClientView({
  ...baseClient,
  expiresAt: "2026-09-01T00:00:00.000Z",
  rotatedAt: "2026-06-02T00:00:00.000Z",
  agentVersion: "hermes-agent/1.4.0",
  pendingModelId: "minimax-m2.7-highspeed",
});
assert.equal(view.expiresAt, "2026-09-01T00:00:00.000Z");
assert.equal(view.rotatedAt, "2026-06-02T00:00:00.000Z");
assert.equal(view.agentVersion, "hermes-agent/1.4.0");
assert.equal(view.pendingModelId, "minimax-m2.7-highspeed");
// Oversight mode is derived (never raw): unset -> safe default "supervised".
assert.equal(view.oversightMode, "supervised");
assert.equal(publicClientView({ ...baseClient, oversightMode: "autonomous" }).oversightMode, "autonomous");

// ── Feature 1: runtime state — derived online/offline presence (Δ ≤ 90s).
assert.equal(HERMES_GATEWAY_PRESENCE_WINDOW_MS, 90 * 1000);
assert.equal(HERMES_GATEWAY_PROTOCOL_VERSION, 2); // bumped to 2 for the sealed (E2E) gateway contract
const presenceNow = Date.parse("2026-06-01T00:01:30.000Z");
assert.equal(isHermesGatewayClientOnline("2026-06-01T00:01:00.000Z", presenceNow), true); // 30s ago -> online
assert.equal(isHermesGatewayClientOnline("2026-06-01T00:00:00.000Z", presenceNow), true); // exactly 90s -> online
assert.equal(isHermesGatewayClientOnline("2026-06-01T00:00:00.000Z", presenceNow + 1), false); // 90.001s -> offline
// Fail-closed: a stopped gateway (missing/garbage lastSeenAt) reads OFFLINE, never online.
assert.equal(isHermesGatewayClientOnline(undefined, presenceNow), false);
assert.equal(isHermesGatewayClientOnline("", presenceNow), false);
assert.equal(isHermesGatewayClientOnline("not-a-date", presenceNow), false);
assert.equal(isHermesGatewayClientOnline(123, presenceNow), false);

// ── Feature 2: model switching — catalog membership + pending-switch settling.
const catalogClient = {
  runtimeModelOptions: [
    { providerId: "hermes", providerName: "Hermes", modelId: "minimax-m2.7-highspeed", displayName: "MiniMax" },
    { providerId: "hermes", providerName: "Hermes", modelId: "Hermes-4-405B", displayName: "Hermes 4" },
  ],
};
assert.equal(clientAdvertisesModel(catalogClient, "minimax-m2.7-highspeed"), true);
assert.equal(clientAdvertisesModel(catalogClient, "MINIMAX-M2.7-HIGHSPEED"), true); // case-insensitive
assert.equal(clientAdvertisesModel(catalogClient, "gpt-5"), false);
assert.equal(clientAdvertisesModel({ runtimeModelOptions: [] }, "anything"), false); // empty catalog -> not a member
assert.equal(clientAdvertisesModel({}, "anything"), false); // no catalog -> not a member

const switchNow = Date.parse("2026-06-01T00:00:30.000Z");
assert.equal(HERMES_GATEWAY_PENDING_MODEL_TTL_MS, 2 * 60 * 1000);
// In flight: pending set, runtime hasn't applied it, within TTL.
assert.equal(
  pendingModelSwitchInFlight(
    { pendingModelId: "minimax-m2.7-highspeed", pendingModelRequestedAt: "2026-06-01T00:00:00.000Z", runtimeModelId: "old" },
    switchNow,
  ),
  true,
);
// Settled: runtime now reports the requested model (case-insensitive) -> not in flight.
assert.equal(
  pendingModelSwitchInFlight(
    { pendingModelId: "minimax-m2.7-highspeed", pendingModelRequestedAt: "2026-06-01T00:00:00.000Z", runtimeModelId: "MiniMax-M2.7-Highspeed" },
    switchNow,
  ),
  false,
);
// Stale: older than the TTL -> treated as settled so a dropped switch never pins "switching…".
assert.equal(
  pendingModelSwitchInFlight(
    { pendingModelId: "x", pendingModelRequestedAt: "2026-06-01T00:00:00.000Z", runtimeModelId: "old" },
    switchNow + HERMES_GATEWAY_PENDING_MODEL_TTL_MS + 1,
  ),
  false,
);
assert.equal(pendingModelSwitchInFlight({}, switchNow), false); // nothing pending

assert.equal(sanitizeHermesGatewayOversightMode("supervised"), "supervised");
assert.equal(sanitizeHermesGatewayOversightMode("autonomous"), "autonomous");
assert.equal(sanitizeHermesGatewayOversightMode("yolo"), undefined);
assert.equal(effectiveOversightMode(undefined), "supervised"); // safe default
assert.equal(effectiveOversightMode("autonomous"), "autonomous");
assert.equal(effectiveOversightMode("bogus"), "supervised");

// ── Feature 3: oversight gate lifecycle — TTL, expiry fail-closed, idempotency surface.
assert.equal(HERMES_GATEWAY_APPROVAL_TTL_MS, 5 * 60 * 1000);
const gateFrom = 1_700_000_000_000;
assert.equal(gatewayApprovalExpiryISO(gateFrom), new Date(gateFrom + HERMES_GATEWAY_APPROVAL_TTL_MS).toISOString());
assert.equal(isHermesGatewayApprovalExpired("2000-01-01T00:00:00.000Z"), true);
assert.equal(isHermesGatewayApprovalExpired(new Date(Date.now() + 60_000).toISOString()), false);
assert.equal(isHermesGatewayApprovalExpired(undefined), true); // fail-closed: no expiry never blocks an agent
assert.equal(isHermesGatewayApprovalExpired("garbage"), true);
assert.equal(isHermesGatewayApprovalExpired(123), true);

const liveGate = {
  id: "hga_1",
  clientId: "client-1",
  destinationId: "burnbar:home",
  actionId: "run-shell-1",
  toolName: "shell",
  summary: "rm -rf /tmp/build-cache",
  status: "waiting_for_approval",
  requestedAt: "2026-06-01T00:00:00.000Z",
  expiresAt: new Date(Date.now() + 60_000).toISOString(),
  schemaVersion: 1,
};
assert.equal(isHermesGatewayApprovalDoc(liveGate), true);
assert.equal(isHermesGatewayApprovalDoc({ ...liveGate, status: "bogus" }), false);
assert.equal(isHermesGatewayApprovalDoc({ id: "x" }), false);
// Actionable only while waiting AND unexpired.
assert.equal(isHermesGatewayApprovalActionable(liveGate), true);
assert.equal(isHermesGatewayApprovalActionable({ ...liveGate, status: "approved" }), false);
assert.equal(isHermesGatewayApprovalActionable({ ...liveGate, expiresAt: "2000-01-01T00:00:00.000Z" }), false);
// A stale waiting gate reads as "expired" through the public view even before the reaper runs.
assert.equal(publicApprovalView({ ...liveGate, expiresAt: "2000-01-01T00:00:00.000Z" }).status, "expired");
assert.equal(publicApprovalView(liveGate).status, "waiting_for_approval");
// approve/deny terminal states are reported verbatim and carry the device binding.
assert.equal(
  publicApprovalView({ ...liveGate, status: "approved", approvedByDeviceId: "dev-mac" }).approvedByDeviceId,
  "dev-mac",
);
assert.equal(publicApprovalView({ ...liveGate, status: "rejected" }).status, "rejected");
// Summary sanitiser collapses whitespace and caps length.
assert.equal(sanitizeHermesGatewayApprovalSummary("  run\n\tshell   now "), "run shell now");
assert.equal(sanitizeHermesGatewayApprovalSummary("x".repeat(5000)).length, 2000);
assert.equal(sanitizeHermesGatewayApprovalSummary(42), "");

const source = readFileSync(new URL("../src/callables/hermesGateway.ts", import.meta.url), "utf8");
for (const name of [
  "approveHermesGatewayDeviceGrant",
  "listHermesGatewayClients",
  "revokeHermesGatewayClient",
  "rotateHermesGatewayClientToken",
  "enqueueHermesGatewayEvent",
  "setHermesGatewayOversightMode",
  "respondHermesGatewayApproval",
]) {
  assertCallable(source, name);
}
// resolveGatewayGrant must reject expired tokens fail-closed.
assert.match(source, /expired_bearer_token/);
assert.match(source, /isHermesGatewayTokenExpired\(client\.expiresAt\)/);
assert.match(source, /export const burnBarHermesGateway = onRequest/);
assert.match(source, /\/device\/start/);
assert.match(source, /\/device\/poll/);
assert.match(source, /\/destinations/);
assert.match(source, /\/events/);
assert.match(source, /\/messages/);
assert.match(source, /\/attachments\/init/);
assert.match(source, /\/attachments\/finalize/);
assert.match(source, /hermes_gateway_token_index/);

// Feature 1 — /state route is registered and read-only (must NOT bump the cursor).
assert.match(source, /if \(path === "\/state"\) return await handleGatewayState/);
assert.match(source, /async function handleGatewayState/);
assert.match(source, /protocolVersion: HERMES_GATEWAY_PROTOCOL_VERSION/);
assert.match(source, /online: isHermesGatewayClientOnline\(client\.lastSeenAt, now\)/);
assert.ok(
  !/handleGatewayState[\s\S]*?eventSequence: sequence \+ 1/.test(source),
  "handleGatewayState must never increment the event cursor",
);

// Feature 2 — model_switch validates against the advertised catalog and marks the switch pending.
assert.match(source, /clientAdvertisesModel\(targetClient, requestedModelId\)/);
assert.match(source, /model_not_available/);
assert.match(source, /pendingModelId: requestedModelId, pendingModelRequestedAt: now/);
// Reconciliation clears the pending marker once the runtime reports the applied model.
assert.match(source, /pendingModelId: settled \? FieldValue\.delete\(\)/);

// Feature 3 — oversight routes + hardened resolution semantics (reuse, not fork).
assert.match(source, /if \(path === "\/approvals"\)/);
assert.match(source, /async function handleArmApproval/);
assert.match(source, /async function handleListApprovals/);
// The agent's write scope arms a gate but can NEVER self-approve: resolution is a
// signed-in callable bound to a trusted native escrow device + approvedByDeviceId.
assert.match(source, /enforceHighRiskComputerUseCallable\(request, uid\)/);
assert.match(source, /trustState"\) !== "trusted"/);
assert.match(source, /NATIVE_ESCROW_PLATFORMS\.has\(deviceSnap\.get\("platform"\)\)/);
assert.match(source, /approvedByDeviceId: deviceId/);
assert.match(source, /has already been resolved/); // single-resolution idempotency guard
assert.match(source, /Oversight request has expired/); // expiry guard in the resolver
assert.match(source, /export const reapHermesGatewayApprovals = onSchedule/);
// PRIVACY BOUNDARY (sealed-gateway consistency): the oversight gate is
// CONTROL-PLANE only — the server must NEVER persist a client-supplied free-text
// `summary` (the action detail flows E2E-sealed over the message channel). Assert
// the leak path is gone and the gate stores an empty summary at the boundary.
assert.ok(
  !/handleArmApproval[\s\S]*?sanitizeHermesGatewayApprovalSummary\(body\.summary\)/.test(source),
  "handleArmApproval must NOT persist client-supplied summary text on the sealed gateway",
);
// The stored summary is SERVER-DERIVED from the coarse toolName, never client free-text.
assert.match(source, /const summary = toolName \? `Approve \$\{toolName\} action`/);
// The full human-readable detail must travel over the sealed message channel,
// not the gate doc — the adapter posts it via the sealed send_slash_confirm path.
assert.match(source, /CONTROL-PLANE only/);
// The gateway must NOT write into the E2E-sealed CLI mission collection: assert
// there is no Firestore PATH reference to it (the word may appear in a comment).
assert.ok(
  !/cli_agent_mission_requests\//.test(source),
  "gateway oversight must use hermes_gateway_approvals path, not the sealed cli_agent_mission_requests path",
);
assert.match(source, /hermes_gateway_approvals\/\$\{approvalId\}/);
assert.match(source, /assertActiveHermesGatewayEntitlement/);
assert.match(source, /assertActiveHermesGatewayClient/);
assert.match(source, /targetClientId/);
assert.match(source, /event\.targetClientId === grant\.client\.id/);
assert.match(source, /await assertActiveHermesGatewayEntitlement\(index\.uid\);/);
assert.match(source, /getSignedUrl\(\{/);
assert.match(source, /attachment_size_mismatch/);
assert.match(source, /sha256ForStorageFile/);
assert.match(source, /must be finalized before use/);

const indexSource = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
for (const name of [
  "burnBarHermesGateway",
  "approveHermesGatewayDeviceGrant",
  "listHermesGatewayClients",
  "revokeHermesGatewayClient",
  "rotateHermesGatewayClientToken",
  "enqueueHermesGatewayEvent",
  "setHermesGatewayOversightMode",
  "respondHermesGatewayApproval",
  "reapHermesGatewayApprovals",
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
  "hermes_gateway_approvals",
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
const hostingEntries = Array.isArray(firebaseConfig.hosting)
  ? firebaseConfig.hosting
  : [firebaseConfig.hosting].filter(Boolean);
const hostingRewrites = hostingEntries.flatMap((hosting) =>
  Array.isArray(hosting.rewrites) ? hosting.rewrites : [],
);
assert.ok(
  hostingRewrites.some(
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
