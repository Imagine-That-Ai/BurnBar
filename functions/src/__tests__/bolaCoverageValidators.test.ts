import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import type { EndpointAuthorizationEntry } from "../security/bolaCoverageTypes.js";
import { validateEndpointBolaCoverage } from "../security/bolaCoverageValidators.js";

const COVERAGE_FILE = "functions/src/__tests__/bola/synthetic.bola.test.ts";
const HANDLER_FILE = "callables/synthetic.ts";

const runtimeCoverageSource = `
import { it } from "vitest";
import { callableRunner, expectCallableDenial, tier2CallableProof, ALICE_UID, BOB_UID } from "./callableBolaHarness.js";

it("synthetic rejects cross-user object access", async () => {
  const run = callableRunner({ run: async () => undefined });
  await expectCallableDenial(run, { auth: { uid: ALICE_UID }, data: { uid: BOB_UID } }, "permission-denied");
  await tier2CallableProof(new Map(), { exportedName: "syntheticEndpoint", run });
});
`;

const providerWebhookCoverageSource = `
import { expect, it } from "vitest";
import { ALICE_UID, BOB_UID } from "./callableBolaHarness.js";
import { runHttpHandler } from "../httpHarness.js";

it("synthetic provider webhook rejects cross-user object access", async () => {
  const res = await runHttpHandler(handler, signedProviderRequest({ repository: { full_name: "owner/repo" } }));
  expect(res._status).toBe(200);
  expect(ALICE_UID).not.toEqual(BOB_UID);
});
`;

function syntheticEntry(): EndpointAuthorizationEntry {
  return {
    exportedName: "syntheticEndpoint",
    trigger: "callable",
    authMethod: "Firebase Auth with callable-level ownership checks",
    appCheck: "required",
    tenantSource: "request.auth.uid",
    objectIdsFromClient: ["documentId"],
    ownershipCheck: "handler derives uid from request.auth.uid and validates object path before Admin SDK access",
    handlerModule: HANDLER_FILE,
    bolaCoverage: [
      {
        file: COVERAGE_FILE,
        test: "synthetic rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["syntheticEndpoint"],
        expectedOutcome: "throws",
        expectedCode: "permission-denied",
      },
    ],
    highRiskComputerUse: false,
  };
}

function syntheticProviderWebhookEntry(): EndpointAuthorizationEntry {
  return {
    exportedName: "syntheticProviderWebhook",
    trigger: "provider-webhook",
    authMethod: "provider HMAC signature",
    appCheck: "not-applicable",
    tenantSource: "provider-signed payload mapped server-side",
    objectIdsFromClient: [],
    ownershipCheck: "handler verifies provider signature before mapping payload fields",
    bolaCoverage: [
      {
        file: COVERAGE_FILE,
        test: "synthetic provider webhook rejects cross-user object access",
        kind: "runtime-cross-user",
        covers: ["syntheticProviderWebhook"],
      },
    ],
    highRiskComputerUse: false,
    publicJustification: "Provider webhooks are internet-facing and authenticated by provider signatures.",
  };
}

function writeSyntheticRepo(handlerSource: string, coverageSource = runtimeCoverageSource): string {
  const repoRoot = mkdtempSync(join(tmpdir(), "openburnbar-bola-validator-"));
  mkdirSync(join(repoRoot, "functions/src/__tests__/bola"), { recursive: true });
  mkdirSync(join(repoRoot, "functions/src/callables"), { recursive: true });
  writeFileSync(join(repoRoot, COVERAGE_FILE), coverageSource);
  writeFileSync(join(repoRoot, "functions/src", HANDLER_FILE), handlerSource);
  return repoRoot;
}

describe("BOLA coverage validators", () => {
  const tempRoots: string[] = [];

  afterEach(() => {
    while (tempRoots.length > 0) {
      const root = tempRoots.pop();
      if (root) rmSync(root, { recursive: true, force: true });
    }
  });

  it("recognizes an apostrophe inside a double-quoted runtime test title", () => {
    const title = "synthetic rejects another host's object";
    const coverageSource = runtimeCoverageSource.replace("synthetic rejects cross-user object access", title);
    const entry = syntheticEntry();
    entry.bolaCoverage[0] = { ...entry.bolaCoverage[0], test: title };
    const repoRoot = writeSyntheticRepo(
      "export async function run(request) { return db.doc(`users/${request.auth.uid}/documents/doc-1`).get(); }",
      coverageSource,
    );
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(entry, repoRoot)).toEqual([]);
  });

  it("rejects object handlers that build users/{uid} from callable payload template data", () => {
    const repoRoot = writeSyntheticRepo(`
export async function run(request) {
  return db.doc(\`users/\${request.data.uid}/documents/\${request.data.documentId}\`).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toContainEqual(
      expect.stringContaining("handler constructs a user namespace from callable payload data"),
    );
  });

  it('rejects object handlers that select collection("users").doc(request.data...)', () => {
    const repoRoot = writeSyntheticRepo(`
export async function run(request) {
  return db.collection("users").doc(request.data.uid).collection("documents").doc(request.data.documentId).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toContainEqual(
      expect.stringContaining("handler constructs a user namespace from callable payload data"),
    );
  });

  it("rejects object handlers that alias callable payload UIDs before building users/{uid}", () => {
    const repoRoot = writeSyntheticRepo(`
export async function run(request) {
  const { uid, documentId } = request.data;
  return db.doc(\`users/\${uid}/documents/\${documentId}\`).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toContainEqual(
      expect.stringContaining("handler constructs a user namespace from callable payload data"),
    );
  });

  it("rejects object handlers when the ownership guard binds a different payload UID", () => {
    const repoRoot = writeSyntheticRepo(`
import { enforceAuthAndAppCheck } from "../auth.js";

export async function run(request) {
  const { uid, otherUid, documentId } = request.data;
  enforceAuthAndAppCheck(request, otherUid);
  return db.doc(\`users/\${uid}/documents/\${documentId}\`).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toContainEqual(
      expect.stringContaining("handler constructs a user namespace from callable payload data"),
    );
  });

  it("rejects object handlers when the matching guard is in another exported handler", () => {
    const repoRoot = writeSyntheticRepo(`
import { enforceAuthAndAppCheck } from "../auth.js";

export async function other(request) {
  enforceAuthAndAppCheck(request, request.data.uid);
  return undefined;
}

export async function run(request) {
  return db.doc(\`users/\${request.data.uid}/documents/\${request.data.documentId}\`).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toContainEqual(
      expect.stringContaining("handler constructs a user namespace from callable payload data"),
    );
  });

  it("rejects object handlers when the matching ownership guard runs after Admin SDK access", () => {
    const repoRoot = writeSyntheticRepo(`
import { enforceAuthAndAppCheck } from "../auth.js";

export async function run(request) {
  const uid = request.data.uid;
  const snapshot = await db.doc(\`users/\${uid}/documents/\${request.data.documentId}\`).get();
  enforceAuthAndAppCheck(request, uid);
  return snapshot;
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toContainEqual(
      expect.stringContaining("handler constructs a user namespace from callable payload data"),
    );
  });

  it("allows object handlers that derive the user namespace from request.auth.uid", () => {
    const repoRoot = writeSyntheticRepo(`
export async function run(request) {
  const uid = request.auth.uid;
  return db.doc(\`users/\${uid}/documents/\${request.data.documentId}\`).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toEqual([]);
  });

  it("allows aliased client-supplied user namespaces when the matching ownership guard runs first", () => {
    const repoRoot = writeSyntheticRepo(`
import { enforceAuthAndAppCheck } from "../auth.js";

export async function run(request) {
  const { uid, documentId } = request.data;
  enforceAuthAndAppCheck(request, uid);
  return db.collection("users").doc(uid).collection("documents").doc(documentId).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toEqual([]);
  });

  it("allows high-risk owner action guards when they bind the matching payload UID first", () => {
    const repoRoot = writeSyntheticRepo(`
import { enforceHighRiskOwnerAction } from "./highRiskOwnerAction.js";

export async function run(request) {
  const { uid, documentId } = request.data;
  await enforceHighRiskOwnerAction(request, uid, { actionKind: "provider_account_delete", subjectId: documentId });
  return db.collection("users").doc(uid).collection("documents").doc(documentId).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toEqual([]);
  });

  it("allows client-supplied user namespace only when an explicit ownership guard is present", () => {
    const repoRoot = writeSyntheticRepo(`
import { assertOwnership } from "../auth.js";

export async function run(request) {
  assertOwnership(request, request.data.uid);
  return db.collection("users").doc(request.data.uid).collection("documents").doc(request.data.documentId).get();
}
`);
    tempRoots.push(repoRoot);

    expect(validateEndpointBolaCoverage(syntheticEntry(), repoRoot)).toEqual([]);
  });

  it("validates provider webhooks with HTTP runtime coverage markers", () => {
    const repoRoot = mkdtempSync(join(tmpdir(), "openburnbar-bola-validator-"));
    tempRoots.push(repoRoot);
    mkdirSync(join(repoRoot, "functions/src/__tests__/bola"), { recursive: true });
    writeFileSync(join(repoRoot, COVERAGE_FILE), providerWebhookCoverageSource);

    expect(validateEndpointBolaCoverage(syntheticProviderWebhookEntry(), repoRoot)).toEqual([]);
  });
});
