#!/usr/bin/env node
/**
 * Generate bolaVictimSeeds.generated.ts from endpointAuthorizationCatalog.
 * Seeds victim-tenant Firestore paths for tier-2 BOLA isolation proofs.
 */
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseGeneratedLiteral } from "./generated-literal-parser.mjs";

const repoRoot = resolve(import.meta.dirname, "../..");
const catalogPath = resolve(repoRoot, "functions/src/security/endpointAuthorizationCatalog.generated.ts");
const outPath = resolve(repoRoot, "functions/src/__tests__/bola/bolaVictimSeeds.generated.ts");

const catalogSource = readFileSync(catalogPath, "utf8");
const catalogMatch = catalogSource.match(
  /export const endpointAuthorizationCatalog:\s*EndpointAuthorizationEntry\[\]\s*=\s*(\[[\s\S]*\])\s*as\s*EndpointAuthorizationEntry\[\];/u,
);
if (!catalogMatch) {
  console.error("Could not parse catalog");
  process.exit(1);
}
const catalog = parseGeneratedLiteral(catalogMatch[1]);

/** Default probe values — must match bolaCrossUserData() in callableBolaHarness.ts */
const PROBE = {
  accountID: "bob-account",
  deviceID: "bob-device",
  deviceId: "bob-device",
  clientId: "bob-client",
  attachmentId: "bob-att",
  connectionId: "bob-conn",
  eventId: "bob-event",
  code: "ABCDEFGHJKMN",
  transferId: `ct_${"b".repeat(24)}`,
  deviceCode: "bob-device-code",
  docID: "bob-doc",
  documentID: "bob-doc",
  repoId: "bob-repo",
  sourceManifestId: "bob-src",
  identityKeyId: "bob-id",
  callerDeviceId: "bob-device",
  pairedDeviceId: "bob-paired",
  sessionId: "bob-session",
  pairingId: "bob-pair",
  requestId: "bob-request",
  approvalId: "bob-approval",
  provider: "openai",
  roleId: "host",
  peerNodeId: "bob-peer",
  keyId: "bob-key",
  recoveryId: "bob-recovery",
  // Team proofs pass an explicit payload (the team callables validate the
  // teamId shape), so this value is only used to shape the victim seeds.
  teamId: "team_bbbbbbbbbbbbbbbb",
  // MUST stay identical to the token acceptTeamInvite's BOLA proof sends
  // (functions/src/__tests__/bola/teamRoster.bola.test.ts). The invite below is
  // seeded so Alice's call reaches the `inviteeUid` comparison instead of
  // stopping at "no such invite" (PR1 review F10 / N-6).
  inviteToken: `inv_${"a".repeat(40)}`,
};

const BOB = "__BOB_UID__";

function bobPath(subpath) {
  return `users/${BOB}/${subpath}`;
}

function globalPath(subpath) {
  return subpath;
}

function secretRefPath(accountID) {
  return `provider_account_secret_refs/${BOB}_${accountID}`;
}

function deviceLinkPath(accountID, deviceID) {
  return `users/${BOB}/provider_account_device_links/${accountID}_${deviceID}`;
}

function seedsForEndpoint(entry) {
  const name = entry.exportedName;
  const seeds = [];
  const push = (path, data = { ownerUid: BOB, status: "active", schemaVersion: 1 }) => {
    seeds.push({ path, data });
  };

  const ids = new Set(entry.objectIdsFromClient ?? []);

  if (name.includes("CredentialTransfer")) {
    push(globalPath(`credential_transfers/${PROBE.transferId}`), {
      ownerUid: BOB,
      schemaVersion: 2,
      state: "ready",
      consumed: false,
      payload: `v2.${"s".repeat(22)}.${"i".repeat(16)}.${"c".repeat(32)}`,
    });
  }

  if (name === "pollCliLink" || name === "completeCliLink" || ids.has("deviceCode")) {
    push(globalPath(`cli_link_sessions/${PROBE.deviceCode}`), {
      userCode: PROBE.code,
      status: "approved",
      ownerUid: "BOB_UID",
    });
  }

  if (name.includes("HermesGateway") || name.includes("hermesGateway")) {
    if (ids.has("clientId") || name.includes("Client") || name.includes("Grant") || name.includes("Oversight") || name.includes("enqueue")) {
      push(bobPath(`hermes_gateway_clients/${PROBE.clientId}`));
    }
    if (ids.has("attachmentId")) {
      push(bobPath(`hermes_gateway_attachments/${PROBE.attachmentId}`));
    }
    if (ids.has("approvalId")) {
      push(bobPath(`hermes_gateway_approvals/${PROBE.approvalId}`));
    }
    if (name.includes("rotateHermesGatewayClientToken")) {
      push(globalPath("hermes_gateway_token_index/bob-token-hash"), { uid: BOB, clientId: PROBE.clientId });
    }
    if (name.includes("approveHermesGatewayDeviceGrant")) {
      push(globalPath(`hermes_gateway_device_sessions/${PROBE.deviceCode}`), { uid: BOB });
    }
  }

  if (name.includes("Hermes") && name.includes("Pairing")) {
    push(bobPath(`hermes_pairings/${PROBE.pairingId}`));
    if (name.includes("complete")) {
      push(bobPath(`hermes_connections/${PROBE.connectionId}`));
    }
  }

  if (name.includes("PiAgent")) {
    push(bobPath(`pi_agent_pairings/${PROBE.pairingId}`));
    if (name.includes("Connection") || name.includes("complete")) {
      push(bobPath(`pi_agent_connections/${PROBE.connectionId}`));
    }
  }

  if (name.includes("HermesConnection") || (name.includes("Hermes") && ids.has("connectionId"))) {
    push(bobPath(`hermes_connections/${PROBE.connectionId}`));
  }

  if (ids.has("accountID") || name.includes("ProviderAccount") || name.includes("Quota")) {
    push(bobPath(`provider_accounts/${PROBE.accountID}`), { provider: PROBE.provider, status: "connected" });
    push(secretRefPath(PROBE.accountID), { secretVersionName: "projects/test/secrets/bob/versions/1" });
    if (name.includes("Credential") || name.includes("HostedQuota") || name.includes("connect")) {
      push(bobPath(`provider_connections/${PROBE.provider}`), { status: "connected" });
    }
  }

  if (ids.has("deviceID") && name.includes("DeviceLink")) {
    push(bobPath(`provider_accounts/${PROBE.accountID}`));
    push(bobPath(`devices/${PROBE.deviceID}`));
    push(deviceLinkPath(PROBE.accountID, PROBE.deviceID), { status: "active" });
  }

  if (ids.has("deviceId") || name.includes("Escrow") || name.includes("Relay") || name.includes("AgentGrant") || name.includes("Mission") || name.includes("Capability")) {
    push(bobPath(`escrow_devices/${PROBE.deviceId}`), { trustRoot: BOB, status: "trusted" });
  }

  if (name.includes("Iroh") || ids.has("connectionId") && name.includes("iroh")) {
    push(bobPath(`iroh_pairing/${PROBE.connectionId}`));
    if (name.includes("PublicKey") || ids.has("roleId")) {
      push(bobPath(`iroh_pairing_keys/${PROBE.roleId}`));
    }
    if (name.includes("PhoneControl") || ids.has("peerNodeId")) {
      push(bobPath(`iroh_pairing/${PROBE.connectionId}/controllers/${PROBE.peerNodeId}`));
    }
  }

  if (name.includes("RelaySender")) {
    push(bobPath(`relay_sender_keys/${PROBE.deviceId}`));
  }

  if (name.includes("AgentCapability") || name.includes("MissionApproval")) {
    push(bobPath(`agent_capability_grant_requests/${PROBE.requestId}`));
    push(bobPath(`cli_agent_mission_requests/${PROBE.requestId}`));
    push(bobPath(`agent_grant_authorities/${PROBE.deviceId}`));
  }

  if (name.includes("AgentGrantAuthority")) {
    push(bobPath(`agent_grant_authorities/${PROBE.deviceId}`));
  }

  if (name.includes("Signal") || name.includes("Prekey") || ids.has("identityKeyId")) {
    push(bobPath(`signal_identity_public_keys/${PROBE.identityKeyId}`), { published: true });
    if (name.includes("claim")) {
      push(bobPath(`signal_identity_public_keys/${PROBE.identityKeyId}/one_time_prekeys/bob-prekey-1`), {
        available: true,
      });
    }
    if (name.includes("Rotation")) {
      push(bobPath(`signal_identity_public_keys/${PROBE.identityKeyId}/rotation_events/bob-rot-1`));
    }
    if (name.includes("Session")) {
      push(bobPath(`signal_identity_public_keys/${PROBE.identityKeyId}/sessions/bob-sess-1`));
    }
  }

  if (name.includes("Encrypted") || name.includes("Search") || name.includes("Conversation") || name.includes("Memory") || name.includes("SessionBlob")) {
    if (ids.has("documentID") || name.includes("Memory") || name.includes("Blob") || name.includes("Index")) {
      push(bobPath(`cloud_search_documents/${PROBE.documentID}`));
      push(bobPath(`project_memory_snapshots/${PROBE.documentID}`));
      push(bobPath(`session_logs/${PROBE.documentID}`));
      push(bobPath(`cloud_search_chunks/bob-chunk-1`), { documentID: PROBE.documentID });
      push(bobPath(`cloud_search_postings/bob-post-1`));
    }
    if (ids.has("sessionId")) {
      push(bobPath(`session_logs/${PROBE.sessionId}`));
    }
  }

  if (name.includes("Knowledge") || ids.has("repoId") || ids.has("sourceManifestId")) {
    push(bobPath(`knowledge_sync_manifests/${PROBE.sourceManifestId}`));
    push(bobPath(`knowledge_repos/${PROBE.repoId}`));
    push(bobPath(`cloud_search_knowledge/bob-knowledge-1`));
  }

  if (name.includes("Notification") || ids.has("eventId")) {
    push(bobPath(`agent_notification_events/${PROBE.eventId}`), { status: "open" });
  }

  if (name.includes("Recovery") || ids.has("recoveryId")) {
    push(bobPath(`account_recovery_methods/${PROBE.recoveryId}`), { status: "pending" });
  }

  if (name.includes("CloudVault") || name.includes("rotateCloudVault")) {
    push(bobPath("cloud_vault_state/current"), { keyGeneration: 1 });
    push(bobPath(`escrow_devices/${PROBE.callerDeviceId}`));
  }

  if (name.includes("RemoteMcp") || (ids.has("clientId") && name.includes("Mcp"))) {
    push(bobPath(`remote_mcp_clients/${PROBE.clientId}`), { active: true });
  }

  if (name.includes("VoIP") || ids.has("pairedDeviceId")) {
    push(bobPath(`devices/${PROBE.pairedDeviceId}`), { voipDeviceToken: "bob-voip" });
  }

  if (name.includes("Team")) {
    push(globalPath(`team_rosters/${PROBE.teamId}`), {
      teamId: PROBE.teamId,
      activeKeyVersion: 1,
      retainedKeyVersions: [1],
      keyRotationRequired: false,
      schemaVersion: 1,
    });
    push(globalPath(`team_rosters/${PROBE.teamId}/members/${BOB}`), {
      uid: BOB,
      teamId: PROBE.teamId,
      role: "admin",
      status: "active",
      activeTeamKeyVersion: 1,
      schemaVersion: 1,
    });
    // A REAL pending invite, bound to Bob, whose id is the hash of the token
    // the attacker presents. Without it the acceptTeamInvite proof refused at
    // `!inviteSnap.exists` — a true refusal, but not the binding the test is
    // named for (PR1 review F10 / N-6). No `expiresAt` is seeded on purpose:
    // the uid comparison runs BEFORE the expiry check, so if that comparison
    // were ever weakened the call would fall through to a `failed-precondition`
    // expiry refusal and the proof's expected `permission-denied` would fail.
    push(
      globalPath(
        `team_rosters/${PROBE.teamId}/invites/${createHash("sha256").update(PROBE.inviteToken, "utf8").digest("hex")}`,
      ),
      {
        teamId: PROBE.teamId,
        inviteeUid: BOB,
        role: "member",
        status: "pending",
        invitedBy: BOB,
        schemaVersion: 1,
      },
    );
  }

  // Fallback: seed generic paths for any remaining object ids
  for (const id of ids) {
    if (id === "uid") continue;
    const value = PROBE[id] ?? `bob-${id}`;
    push(bobPath(`bola_victim/${id}/${value}`));
  }

  // Deduplicate by path
  const seen = new Set();
  return seeds.filter((seed) => {
    if (seen.has(seed.path)) return false;
    seen.add(seed.path);
    return true;
  });
}

const runtimeEntries = catalog.filter(
  (entry) =>
    entry.objectIdsFromClient?.length > 0 &&
    entry.bolaCoverage?.some((ref) => ref.kind === "runtime-cross-user" && ref.covers?.includes(entry.exportedName)),
);

const registry = Object.fromEntries(
  runtimeEntries.map((entry) => [entry.exportedName, seedsForEndpoint(entry)]),
);

function indent(level) {
  return "  ".repeat(level);
}

function formatPropertyKey(key) {
  return /^[A-Za-z_$][\w$]*$/u.test(key) ? key : JSON.stringify(key);
}

function formatPrimitive(value) {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" || typeof value === "boolean" || value === null) return String(value);
  throw new TypeError(`Unsupported primitive value in generated BOLA seed fixture: ${String(value)}`);
}

function canInlineArray(value) {
  if (!Array.isArray(value)) return false;
  return value.length === 0 || value.every((item) => item === null || ["string", "number", "boolean"].includes(typeof item));
}

function formatTsLiteral(value, level = 0) {
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    if (canInlineArray(value)) {
      return `[${value.map((item) => formatPrimitive(item)).join(", ")}]`;
    }
    return `[
${value.map((item) => `${indent(level + 1)}${formatTsLiteral(item, level + 1)},`).join("\n")}
${indent(level)}]`;
  }

  if (value && typeof value === "object") {
    const entries = Object.entries(value);
    if (entries.length === 0) return "{}";
    return `{
${entries
  .map(([key, item]) => `${indent(level + 1)}${formatPropertyKey(key)}: ${formatTsLiteral(item, level + 1)},`)
  .join("\n")}
${indent(level)}}`;
  }

  return formatPrimitive(value);
}

const header = `/** AUTO-GENERATED by scripts/generate-bola-victim-seeds.mjs — do not hand-edit. */
import { BOB_UID, seedDoc } from "./callableBolaHarness.js";

export type BolaVictimSeed = {
  path: string;
  data: Record<string, unknown>;
};

export const BOLA_VICTIM_SEEDS: Record<string, BolaVictimSeed[]> = `;

const body = formatTsLiteral(registry);

const footer = ` as Record<string, BolaVictimSeed[]>;

function resolveVictimPath(path: string): string {
  return path.replaceAll("__BOB_UID__", BOB_UID);
}

function resolveVictimData(data: Record<string, unknown>): Record<string, unknown> {
  const resolved: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    resolved[key] = value === "__BOB_UID__" ? BOB_UID : value;
  }
  return resolved;
}

export function seedBolaVictimTenant(store: Map<string, Record<string, unknown>>, exportedName: string): void {
  const seeds = BOLA_VICTIM_SEEDS[exportedName] ?? [];
  for (const seed of seeds) {
    seedDoc(store, resolveVictimPath(seed.path), resolveVictimData(seed.data));
  }
}
`;

writeFileSync(outPath, `${header}${body}${footer}`);
console.log(`Wrote ${runtimeEntries.length} endpoint seed sets to ${outPath}`);
