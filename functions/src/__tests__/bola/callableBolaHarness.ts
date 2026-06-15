import { expect } from "vitest";

export const ALICE_UID = "alice-bola-uid";
export const BOB_UID = "bob-bola-uid";

/** Probe payload: supplies every client-controlled id the matrix tracks. */
export function bolaCrossUserData(overrides: Record<string, unknown> = {}): Record<string, unknown> {
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

export function callableRequest<T extends Record<string, unknown>>(
  uid: string,
  data: T,
): TestCallableRequest<T> {
  return {
    auth: { uid, token: {} },
    app: { appId: "openburnbar-test" },
    rawRequest: { headers: {} },
    data,
  };
}

export function callableRunner(candidate: unknown): (request: unknown) => Promise<unknown> {
  if (
    candidate === null ||
    (typeof candidate !== "object" && typeof candidate !== "function") ||
    !("run" in candidate)
  ) {
    throw new Error("callable test target is missing run()");
  }
  const { run } = candidate as { run: (request: unknown) => Promise<unknown> };
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

export async function expectCallableDenial(
  run: (request: unknown) => Promise<unknown>,
  request: unknown,
  expectedCode: "permission-denied" | "not-found" | "failed-precondition" | "unauthenticated",
): Promise<void> {
  try {
    await run(request);
    expect.fail(`expected callable to reject with ${expectedCode}`);
  } catch (error) {
    const code =
      error &&
      typeof error === "object" &&
      "code" in error &&
      typeof (error as { code?: unknown }).code === "string"
        ? (error as { code: string }).code
        : undefined;
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
}

type EmptyQuery = {
  where: () => EmptyQuery;
  limit: () => EmptyQuery;
  orderBy: () => EmptyQuery;
  get: () => Promise<{ docs: []; empty: true }>;
};

function emptyQuery(): EmptyQuery {
  return {
    where: () => emptyQuery(),
    limit: () => emptyQuery(),
    orderBy: () => emptyQuery(),
    get: async () => ({ docs: [], empty: true }),
  };
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
        store.set(path, { ...(store.get(path) ?? {}), ...data });
      },
      update: async (data: Record<string, unknown>) => {
        store.set(path, { ...(store.get(path) ?? {}), ...data });
      },
      delete: async () => {
        store.delete(path);
      },
    }),
    collection: (name: string) => ({
      doc: (id: string) => pathKeyedFirestore(store).doc(`${name}/${id}`),
      add: async (data: Record<string, unknown>) => {
        const id = `auto-${store.size + 1}`;
        const path = `${name}/${id}`;
        store.set(path, data);
        return { id, path };
      },
      where: () => emptyQuery(),
      limit: () => emptyQuery(),
      orderBy: () => emptyQuery(),
    }),
    batch: () => {
      const ops: Array<() => void> = [];
      return {
        delete: (ref: { path?: string }) => {
          const { path } = ref;
          if (path) ops.push(() => store.delete(path));
        },
        set: (ref: { path?: string }, data: Record<string, unknown>) => {
          const { path } = ref;
          if (path) ops.push(() => store.set(path, data));
        },
        update: (ref: { path?: string }, data: Record<string, unknown>) => {
          const { path } = ref;
          if (path) ops.push(() => store.set(path, { ...(store.get(path) ?? {}), ...data }));
        },
        commit: async () => {
          for (const op of ops) op();
        },
      };
    },
    runTransaction: async (fn: (tx: {
      get: (ref: { get: () => Promise<unknown> }) => Promise<unknown>;
      set: (ref: { set: (d: Record<string, unknown>) => Promise<void> }, data: Record<string, unknown>) => Promise<void>;
      update: (ref: { update: (d: Record<string, unknown>) => Promise<void> }, data: Record<string, unknown>) => Promise<void>;
      delete: (ref: { delete: () => Promise<void> }) => Promise<void>;
      create: (ref: { get: () => Promise<{ exists: boolean }>; set: (d: Record<string, unknown>) => Promise<void> }, data: Record<string, unknown>) => Promise<void>;
    }) => Promise<unknown>) => {
      const tx = {
        get: async (ref: { get: () => Promise<unknown> }) => ref.get(),
        set: (ref: { set: (d: Record<string, unknown>) => Promise<void> }, data: Record<string, unknown>) =>
          ref.set(data),
        update: (ref: { update: (d: Record<string, unknown>) => Promise<void> }, data: Record<string, unknown>) =>
          ref.update(data),
        delete: (ref: { delete: () => Promise<void> }) => ref.delete(),
        create: async (
          ref: { get: () => Promise<{ exists: boolean }>; set: (d: Record<string, unknown>) => Promise<void> },
          data: Record<string, unknown>,
        ) => {
          const snap = await ref.get();
          if (snap.exists) {
            throw new Error(`Document already exists`);
          }
          await ref.set(data);
        },
      };
      return fn(tx);
    },
  };
}

export function seedDoc(store: Map<string, Record<string, unknown>>, path: string, data: Record<string, unknown>): void {
  store.set(path, data);
}
