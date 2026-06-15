#!/usr/bin/env node
/**
 * Regenerate endpointAuthorizationCatalog.generated.ts from functions/src/index.ts.
 *
 * The catalog is the single source of matrix rows. Hand-edit overrides in
 * CATALOG_OVERRIDES below when generator defaults are insufficient.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "../..");
const indexPath = resolve(repoRoot, "functions/src/index.ts");
const outPath = resolve(repoRoot, "functions/src/security/endpointAuthorizationCatalog.generated.ts");

function exportedNames() {
  const source = readFileSync(indexPath, "utf8");
  const names = [];
  for (const match of source.matchAll(/export\s+\{([\s\S]*?)\}\s+from\s+"[^"]+";/g)) {
    for (const part of match[1].split(",")) {
      const raw = part.trim();
      if (!raw) continue;
      names.push(raw.split(/\s+as\s+/u).pop()?.trim() ?? raw);
    }
  }
  return [...new Set(names)].sort((a, b) => a.localeCompare(b));
}

function parseGeneratedLiteral(source) {
  try {
    return JSON.parse(source);
  } catch {
    return Function(`"use strict"; return (${source});`)();
  }
}

/** Endpoint-specific overrides merged onto scaffold defaults during regeneration. */
const CATALOG_OVERRIDES = {
  burnBarHermesGateway: {
    trigger: "http",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/hermesGateway.bola.test.ts",
        test: "burnBarHermesGateway rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["burnBarHermesGateway"],
        expectedOutcome: "throws",
        expectedCode: "not-found",
      },
    ],
  },
  consumeCredentialTransfer: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/credentialTransfer.bola.test.ts",
        test: "consumeCredentialTransfer rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["consumeCredentialTransfer"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  validateOpenTimestampsProof: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/openTimestamps.bola.test.ts",
        test: "validateOpenTimestampsProof rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["validateOpenTimestampsProof"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  pollCliLink: {
    trigger: "http",
    authMethod: "deviceCode plus deviceSecretHash proof (no Firebase Auth)",
    appCheck: "not-applicable",
    tenantSource: "cli_link_sessions/{deviceCode} resolved server-side",
    objectIdsFromClient: ["deviceCode"],
    ownershipCheck: "poll requires matching deviceSecretHash for the deviceCode session",
    handlerModule: "callables/cliLink.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/pairing.bola.test.ts",
        test: "pollCliLink rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["pollCliLink"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
  },
  revokeProviderAccountDeviceLink: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/deviceLinks.bola.test.ts",
        test: "revokeProviderAccountDeviceLink rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["revokeProviderAccountDeviceLink"],
        expectedOutcome: "no-side-effect",
      },
    ],
  },
  deleteProviderCredential: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/providerAccounts.bola.test.ts",
        test: "deleteProviderCredential rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["deleteProviderCredential"],
        expectedOutcome: "no-side-effect",
      },
    ],
  },
  revokeRemoteMcpClient: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/remoteMcp.bola.test.ts",
        test: "revokeRemoteMcpClient rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["revokeRemoteMcpClient"],
        expectedOutcome: "no-side-effect",
      },
      {
        file: "functions/src/__tests__/highRiskOwnerActionCallableGuards.test.ts",
        test: "revokeRemoteMcpClient calls enforceHighRiskOwnerAction with actionKind",
        kind: "static-high-risk-wiring",
        covers: ["revokeRemoteMcpClient"],
      },
    ],
    highRiskComputerUse: true,
    actionKind: "remote_mcp_grant_revoke",
  },
  startCliLink: {
    trigger: "http",
    authMethod: "public rate-limited device enrollment (no tenant objects)",
    appCheck: "not-applicable",
    tenantSource: "server-generated deviceCode",
    objectIdsFromClient: [],
    ownershipCheck: "creates ephemeral cli_link_sessions without cross-tenant reads",
    handlerModule: "callables/cliLink.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "public health endpoints do not expose tenant objects",
        kind: "not-applicable-public",
        covers: ["startCliLink"],
        publicJustification: "Public CLI link bootstrap mints a fresh deviceCode; no uid-scoped object ids.",
      },
    ],
  },
  sendFcmOutbound: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "trigger document path and server-side uid field",
    objectIdsFromClient: [],
    ownershipCheck: "trigger fires only on server-written fcm_outbound docs scoped by uid",
    handlerModule: "fcmAndroidSender.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["sendFcmOutbound"],
      },
    ],
  },
  sendVoIPOutbound: {
    trigger: "firestore-trigger",
    authMethod: "Firebase Functions event trigger (not client-callable)",
    appCheck: "not-applicable",
    tenantSource: "trigger document path and server-side uid field",
    objectIdsFromClient: [],
    ownershipCheck: "trigger fires only on server-written voip_outbound docs scoped by uid",
    handlerModule: "apnsSender.ts",
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/authOnly.bola.test.ts",
        test: "platform triggers are not client-callable",
        kind: "platform-trigger",
        covers: ["sendVoIPOutbound"],
      },
    ],
  },
  triggerVoIPCall: {
    bolaCoverage: [
      {
        file: "functions/src/__tests__/bola/voipPush.bola.test.ts",
        test: "triggerVoIPCall rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["triggerVoIPCall"],
        expectedOutcome: "no-side-effect",
        expectedCode: "failed-precondition",
      },
    ],
  },
};

function defaultEntry(exportedName) {
  return {
    exportedName,
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["accountID"],
    ownershipCheck: "handler derives uid from request.auth.uid and validates object path before Admin SDK access",
    handlerModule: "callables/shared.ts",
    bolaCoverage: [
      {
        file: `functions/src/__tests__/bola/${exportedName}.bola.test.ts`,
        test: `${exportedName} rejects cross-user object access`,
        kind: "runtime-cross-user",
        covers: [exportedName],
        expectedOutcome: "throws",
        expectedCode: "not-found",
      },
    ],
    highRiskComputerUse: false,
  };
}

const names = exportedNames();
const existing = readFileSync(outPath, "utf8");
const existingJson = existing.match(/export const endpointAuthorizationCatalog:\s*EndpointAuthorizationEntry\[\]\s*=\s*(\[[\s\S]*\])\s*as\s*EndpointAuthorizationEntry\[\];/u);
if (!existingJson) {
  console.error("Could not parse existing catalog — aborting to avoid data loss.");
  process.exit(1);
}

const prior = parseGeneratedLiteral(existingJson[1]);
const priorByName = Object.fromEntries(prior.map((row) => [row.exportedName, row]));

const merged = names.map((exportedName) => {
  const base = priorByName[exportedName] ?? defaultEntry(exportedName);
  const override = CATALOG_OVERRIDES[exportedName];
  return override ? { ...base, ...override, exportedName } : base;
});

const header = `/** AUTO-GENERATED by scripts/generate-endpoint-catalog.mjs — do not hand-edit rows. */
import type { EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

export const endpointAuthorizationCatalog: EndpointAuthorizationEntry[] = `;

writeFileSync(
  outPath,
  `${header}${JSON.stringify(merged)} as EndpointAuthorizationEntry[];
`,
);

console.log(`Wrote ${merged.length} catalog entries to ${outPath}`);
