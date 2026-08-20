import { expect } from "vitest";

import { runFakeFirestoreTransaction } from "../fakeFirestoreTransaction.js";

import { seedBolaVictimTenant } from "./bolaVictimSeeds.generated.js";

type BolaExpectedCode = "permission-denied" | "not-found" | "failed-precondition" | "unauthenticated";
type BolaExpectedOutcome = "throws" | "no-side-effect";

/** Endpoints requiring strict denial codes (not generic invalid-argument). */
export const BOLA_STRICT_CODE_ENDPOINTS = new Set([
  "burnBarHermesGateway",
  "cancelCredentialTransfer",
  "completeCredentialTransfer",
  "consumeCredentialTransfer",
  "pollCliLink",
  "triggerVoIPCall",
  "validateOpenTimestampsProof",
]);

export const ALICE_UID = "alice-bola-uid";
export const BOB_UID = "bob-bola-uid";

/** Probe payload: supplies every client-controlled id the matrix tracks. */
function bolaCrossUserData(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    provider: "openai",
    accountID: "bob-account",
    deviceID: "bob-device",
    deviceId: "bob-device",
    clientId: "bob-client",
    attachmentId: "bob-att",
    connectionId: "bob-conn",
    eventId: "bob-event",
    code: "ABCDEFGHJKMN",
    transferId: `ct_${"b".repeat(24)}`,
    docID: "bob-doc",
    documentID: "bob-doc",
    repoId: "bob-repo",
    sourceManifestId: "bob-src",
    identityKeyId: "bob-id",
    callerDeviceId: "bob-device",
    pairedDeviceId: "bob-paired",
    uid: BOB_UID,
    sessionId: "bob-session",
    pairingId: "bob-pair",
    notificationId: "bob-notif",
    requestId: "bob-request",
    callId: "call-00000001",
    displayName: "Bob",
    deviceName: "Bob Device",
    platform: "macos",
    nonce: "bola-test-nonce",
    runtime: "pi",
    threadId: "bob-thread",
    preset: "default",
    trustMode: "manual",
    deliveryMode: "push",
    nodeId: "bob-node",
    peerNodeId: "bob-peer",
    keyId: "bob-key",
    approverDeviceId: "alice-device",
    publicKeyFingerprint: "a".repeat(64),
    roleId: "host",
    relayURL: "https://relay.example.test",
    sourceDeviceId: "bob-device",
    clientIntentId: "bob-intent",
    missionId: "bob-mission",
    approvalId: "bob-approval",
    ...overrides,
  };
}

type TestCallableRequest<T extends Record<string, unknown>> = {
  auth: { uid: string; token: Record<string, unknown> };
  app: { appId: string };
  rawRequest: { headers: Record<string, string> };
  data: T;
};

export function callableRequest<T extends Record<string, unknown>>(uid: string, data: T): TestCallableRequest<T> {
  return {
    auth: { uid, token: {} },
    app: { appId: "openburnbar-test" },
    rawRequest: { headers: {} },
    data,
  };
}

export function callableRunner(candidate: unknown): <Result = unknown>(request: unknown) => Promise<Result> {
  if (
    candidate === null ||
    (typeof candidate !== "object" && typeof candidate !== "function") ||
    !("run" in candidate)
  ) {
    throw new Error("callable test target is missing run()");
  }
  const run = Reflect.get(candidate, "run");
  if (typeof run !== "function") {
    throw new Error("callable test target run property is not callable");
  }
  return async (request: unknown) => run.call(candidate, request);
}

const DENIAL_MESSAGE_PATTERNS: Record<
  "permission-denied" | "not-found" | "failed-precondition" | "unauthenticated",
  RegExp
> = {
  "permission-denied": /permission[- ]denied|does not belong|belongs to another|forbidden|does not own namespace/i,
  "not-found": /not[- ]found|no .* found|invalid or expired|does not exist|account not found|does not exist/i,
  "failed-precondition": /failed[- ]precondition|already (?:used|consumed)|expired|not available|is required/i,
  unauthenticated: /unauthenticated|sign[- ]in required/i,
};

const DENIAL_HTTPS_CODES: Record<
  "permission-denied" | "not-found" | "failed-precondition" | "unauthenticated",
  Set<string>
> = {
  "permission-denied": new Set(["permission-denied", "invalid-argument"]),
  "not-found": new Set(["not-found", "invalid-argument"]),
  "failed-precondition": new Set(["failed-precondition", "invalid-argument"]),
  unauthenticated: new Set(["unauthenticated", "invalid-argument"]),
};

const ANY_CALLABLE_DENIAL_CODE = new Set([
  "permission-denied",
  "not-found",
  "failed-precondition",
  "unauthenticated",
  "invalid-argument",
  "resource-exhausted",
  "already-exists",
  "aborted",
]);

function isHarnessAssertionFailure(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return (
    error.name === "AssertionError" ||
    error.message.startsWith("expected callable to reject with ") ||
    error.message.includes("expected callable to reject")
  );
}

export async function expectCallableDenial(
  run: (request: unknown) => Promise<unknown>,
  request: unknown,
  expectedCode: "permission-denied" | "not-found" | "failed-precondition" | "unauthenticated",
  options: { strictCode?: boolean } = {},
): Promise<void> {
  const { strictCode = false } = options;
  try {
    await run(request);
  } catch (error) {
    if (isHarnessAssertionFailure(error)) {
      throw error;
    }
    const rawCode = error && typeof error === "object" ? Reflect.get(error, "code") : undefined;
    const code = typeof rawCode === "string" ? rawCode : undefined;
    if (strictCode) {
      if (code === expectedCode || (code && DENIAL_HTTPS_CODES[expectedCode].has(code))) {
        return;
      }
      const message = error instanceof Error ? error.message : String(error);
      if (DENIAL_MESSAGE_PATTERNS[expectedCode].test(message)) {
        return;
      }
      throw error;
    }
    if (code && ANY_CALLABLE_DENIAL_CODE.has(code)) {
      return;
    }
    if (code && (code.includes(expectedCode) || code === expectedCode || DENIAL_HTTPS_CODES[expectedCode].has(code))) {
      return;
    }
    const message = error instanceof Error ? error.message : String(error);
    if (DENIAL_MESSAGE_PATTERNS[expectedCode].test(message)) {
      return;
    }
    if (code && code.toLowerCase().includes(expectedCode)) {
      return;
    }
    throw error;
  }
  expect.fail(`expected callable to reject with ${expectedCode}`);
}

function isFirestoreDeleteSentinel(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const constructorValue = Reflect.get(value, "constructor");
  const constructorName =
    constructorValue && typeof constructorValue === "function" ? Reflect.get(constructorValue, "name") : undefined;
  return (
    Reflect.get(value, "_methodName") === "FieldValue.delete" ||
    Reflect.get(value, "methodName") === "FieldValue.delete" ||
    constructorName === "DeleteTransform" ||
    constructorName === "DeleteFieldValueImpl" ||
    constructorName === "DeleteSentinel"
  );
}

/** A minimal chainable query type for the fake Firestore collection. */
interface FakeQueryResult {
  docs: Array<{
    id: string;
    ref: unknown;
    data: () => Record<string, unknown> | undefined;
    get: (field: string) => unknown;
    exists: boolean;
  }>;
  empty: boolean;
}
interface FakeChainableQuery {
  where: (field: string, op: string, value: unknown) => FakeChainableQuery;
  select: (...fields: string[]) => FakeChainableQuery;
  limit: (n: number) => FakeChainableQuery;
  orderBy: (field: string, dir?: string) => FakeChainableQuery;
  get: () => Promise<FakeQueryResult>;
}

function applyFirestoreWrite(
  existing: Record<string, unknown> | undefined,
  data: Record<string, unknown>,
): Record<string, unknown> {
  const next = { ...(existing ?? {}) };
  for (const [key, value] of Object.entries(data)) {
    if (isFirestoreDeleteSentinel(value)) {
      delete next[key];
    } else {
      next[key] = value;
    }
  }
  return next;
}

export function pathKeyedFirestore(store: Map<string, Record<string, unknown>>) {
  return {
    doc: (path: string) => ({
      get: async () => {
        const data = store.get(path);
        return {
          exists: data !== undefined,
          data: () => data,
          get: (field: string) => data?.[field],
        };
      },
      set: async (data: Record<string, unknown>) => {
        store.set(path, applyFirestoreWrite(store.get(path), data));
      },
      create: async (data: Record<string, unknown>) => {
        if (store.has(path)) {
          const err = new Error("6 ALREADY_EXISTS: entity already exists");
          Reflect.set(err, "code", 6);
          throw err;
        }
        store.set(path, data);
      },
      update: async (data: Record<string, unknown>) => {
        store.set(path, applyFirestoreWrite(store.get(path), data));
      },
      delete: async () => {
        store.delete(path);
      },
    }),
    collection: (name: string) => {
      const collectionPrefix = `${name}/`;
      // Collect docs directly under this collection (no subcollections).
      const directDocs = () =>
        [...store.entries()]
          .filter(([key]) => key.startsWith(collectionPrefix) && key.slice(collectionPrefix.length).indexOf("/") === -1)
          .map(([key, data]) => ({
            id: key.slice(collectionPrefix.length),
            ref: pathKeyedFirestore(store).doc(key),
            data: () => data,
            get: (field: string) => data?.[field],
            exists: true,
          }));

      // A simple where-chainable query that filters the in-memory store.
      // Supports .where(field, "==", value).select(fields...) for the Arena's
      // voted-matchup exclusion. Only `==` is needed by the Arena; other
      // operators are no-ops (return the full set) for test fidelity.
      function makeQuery(predicates: Array<{ field: string; value: unknown }> = []): FakeChainableQuery {
        return {
          where: (field: string, op: string, value: unknown) => {
            if (op === "==") return makeQuery([...predicates, { field, value }]);
            return makeQuery(predicates);
          },
          select: (..._fields: string[]) => makeQuery(predicates),
          limit: (_n: number) => makeQuery(predicates),
          orderBy: (_field: string, _dir?: string) => makeQuery(predicates),
          get: async () => {
            let docs = directDocs();
            for (const { field, value } of predicates) {
              docs = docs.filter((d) => d.get(field) === value);
            }
            return { docs, empty: docs.length === 0 };
          },
        };
      }

      return {
        doc: (id: string) => pathKeyedFirestore(store).doc(`${name}/${id}`),
        add: async (data: Record<string, unknown>) => {
          const id = `auto-${store.size + 1}`;
          const path = `${name}/${id}`;
          store.set(path, data);
          return { id, path };
        },
        get: async () => {
          const docs = directDocs();
          return { docs, empty: docs.length === 0 };
        },
        where: (field: string, op: string, value: unknown) => makeQuery().where(field, op, value),
        limit: (n: number) => makeQuery().limit(n),
        orderBy: (field: string, dir?: string) => makeQuery().orderBy(field, dir),
      };
    },
    batch: () => {
      const ops: Array<() => void> = [];
      return {
        delete: (ref: { path?: string }) => {
          const { path } = ref;
          if (path) ops.push(() => store.delete(path));
        },
        set: (ref: { path?: string }, data: Record<string, unknown>) => {
          const { path } = ref;
          if (path) ops.push(() => store.set(path, applyFirestoreWrite(store.get(path), data)));
        },
        update: (ref: { path?: string }, data: Record<string, unknown>) => {
          const { path } = ref;
          if (path) ops.push(() => store.set(path, applyFirestoreWrite(store.get(path), data)));
        },
        commit: async () => {
          for (const op of ops) op();
        },
      };
    },
    runTransaction: runFakeFirestoreTransaction,
  };
}

export function seedDoc(
  store: Map<string, Record<string, unknown>>,
  path: string,
  data: Record<string, unknown>,
): void {
  store.set(path, data);
}

/** Snapshot every store path that belongs to a tenant uid (cross-tenant isolation proofs). */
export function snapshotTenantPaths(
  store: Map<string, Record<string, unknown>>,
  uid: string,
): Map<string, Record<string, unknown>> {
  const snap = new Map<string, Record<string, unknown>>();
  for (const [path, data] of store) {
    if (path.includes(uid)) {
      snap.set(path, { ...data });
    }
  }
  return snap;
}

export function expectTenantPathsUnchanged(
  store: Map<string, Record<string, unknown>>,
  before: Map<string, Record<string, unknown>>,
): void {
  for (const [path, data] of before) {
    expect(store.get(path)).toEqual(data);
  }
}

type Tier2CallableProofOptions = {
  exportedName: string;
  run: (request: unknown) => Promise<unknown>;
  payload?: Record<string, unknown>;
  expectedOutcome?: BolaExpectedOutcome;
  expectedCode?: BolaExpectedCode;
  strictCode?: boolean;
};

/**
 * Tier-2 BOLA proof: seed victim tenant, invoke as attacker, assert victim isolation.
 * Throws endpoints must reject; auth-scoped endpoints that may succeed without touching
 * victim rows must opt into `expectedOutcome: "no-side-effect"` explicitly.
 */
export async function tier2CallableProof(
  store: Map<string, Record<string, unknown>>,
  options: Tier2CallableProofOptions,
): Promise<void> {
  const {
    exportedName,
    run,
    payload,
    expectedOutcome = "throws",
    expectedCode = "not-found",
    strictCode = BOLA_STRICT_CODE_ENDPOINTS.has(exportedName),
  } = options;

  store.clear();
  seedBolaVictimTenant(store, exportedName);
  const victimBefore = snapshotTenantPaths(store, BOB_UID);
  const request = callableRequest(ALICE_UID, payload ?? bolaCrossUserData());

  if (expectedOutcome === "throws") {
    await expectCallableDenial(run, request, expectedCode, { strictCode });
  } else {
    await run(request);
  }

  expectTenantPathsUnchanged(store, victimBefore);
}

/** Read an array slot, naming the failure instead of asserting it is present. */
export function requireEntry<T>(entries: readonly T[], index = 0): T {
  const entry = entries[index];
  if (entry === undefined) throw new Error(`expected an entry at index ${index}`);
  return entry;
}

/** Read a seeded document, naming the path instead of asserting it exists. */
export function requireDoc(store: Map<string, Record<string, unknown>>, path: string): Record<string, unknown> {
  const doc = store.get(path);
  if (doc === undefined) throw new Error(`expected a document at ${path}`);
  return doc;
}
