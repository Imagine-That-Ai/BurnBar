/**
 * In-memory Firestore double for the team roster authority tests.
 *
 * It exists as its own module for two reasons: `teamRoster.test.ts` would
 * otherwise blow the 600-line lint ceiling, and the double has real behaviour
 * worth stating once — `FieldValue.delete()` really deletes (so a re-join
 * cannot leave a stale `removedAt` behind), a batch commit can be made to fail
 * at a chosen chunk (so the chunked-rotation retry contract is testable), and
 * `where(...)` chains resolve as equality predicates.
 *
 * The store is a module singleton so `vi.mock("../adminRuntime.js", ...)` can
 * resolve it from an async factory: mock factories run during the test file's
 * import phase, before the test file's own top-level statements. For the same
 * reason this module imports NOTHING from `../teamRoster.js`: that would close
 * a cycle through the mocked `adminRuntime` and deadlock the import graph.
 */
import { createHash } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

type Doc = Record<string, unknown>;

process.env.ENFORCE_APP_CHECK = "false";
const store = new Map<string, Record<string, unknown>>();
const stats = {
  batches: 0,
  maxBatchSize: 0,
  failCommitAtBatch: new Set<number>(),
  /** How many times each document path has been WRITTEN, for "exactly one row write". */
  writesByPath: new Map<string, number>(),
  /** Transactions entered so far (see `onTransaction`). */
  transactions: 0,
  /**
   * Fires at the START of each transaction, before its body runs, with the
   * 1-based transaction number. It is the harness's way to land a CONCURRENT
   * write inside the window a read-then-write guard is meant to close: a test
   * that mutates the store here is doing what another caller's commit would
   * have done between the outer read and the transactional one.
   */
  onTransaction: null as ((transactionNumber: number) => void) | null,
  /**
   * The same window, for code that commits through `db.batch()` instead of a
   * transaction — it fires at the START of each batch commit, before its writes
   * land, with the 1-based batch number.
   *
   * It exists so a race test can be written ONCE and stay honest across the
   * fix: register the concurrent write on both hooks and the test lands it in
   * the guard's window whether the guard is (wrongly) a query-then-batch or
   * (rightly) inside a transaction. Without it, moving a guard into a
   * transaction would silently disarm the very test that proves the move.
   */
  onBatchCommit: null as ((batchNumber: number) => void) | null,
};
const users = new Map<string, { uid: string }>();

/** Narrows the Firestore sentinel duck type without asserting it. */
function hasIsEqual(value: unknown): value is { isEqual: (other: unknown) => boolean } {
  return typeof value === "object" && value !== null && typeof Reflect.get(value, "isEqual") === "function";
}

/** `FieldValue.delete()` really deletes here, so a re-join cannot leave a stale `removedAt`. */
function isDeleteSentinel(value: unknown): boolean {
  return hasIsEqual(value) && value.isEqual(FieldValue.delete());
}

function applyWrite(existing: Doc | undefined, data: Doc, merge: boolean): Doc {
  const next: Doc = merge ? { ...(existing ?? {}), ...data } : { ...data };
  for (const [key, value] of Object.entries(next)) {
    if (isDeleteSentinel(value)) delete next[key];
  }
  return next;
}

function recordWrite(path: string): void {
  stats.writesByPath.set(path, (stats.writesByPath.get(path) ?? 0) + 1);
}

function docRef(path: string) {
  return {
    path,
    get: async () => {
      const data = store.get(path);
      return {
        exists: data !== undefined,
        id: path.split("/").pop() ?? path,
        ref: docRef(path),
        data: () => data,
        get: (field: string) => data?.[field],
      };
    },
    set: async (data: Doc, options?: { merge?: boolean }) => {
      recordWrite(path);
      store.set(path, applyWrite(store.get(path), data, options?.merge === true));
    },
    update: async (data: Doc) => {
      recordWrite(path);
      store.set(path, applyWrite(store.get(path), data, true));
    },
    delete: async () => {
      store.delete(path);
    },
  };
}

function collectionRef(path: string) {
  const prefix = `${path}/`;
  const directDocs = () =>
    [...store.entries()]
      .filter(([key]) => key.startsWith(prefix) && !key.slice(prefix.length).includes("/"))
      .map(([key, data]) => ({
        id: key.slice(prefix.length),
        ref: docRef(key),
        exists: true,
        data: () => data,
        get: (field: string) => data[field],
      }));

  function query(predicates: Array<{ field: string; value: unknown }>, take?: number) {
    return {
      where: (field: string, op: string, value: unknown) =>
        op === "==" ? query([...predicates, { field, value }], take) : query(predicates, take),
      /** Real enough for an existence probe: `.limit(1).get()` returns at most one doc. */
      limit: (count: number) => query(predicates, count),
      get: async () => {
        const matched = directDocs().filter((entry) => predicates.every((p) => entry.get(p.field) === p.value));
        const docs = take === undefined ? matched : matched.slice(0, take);
        return { docs, size: docs.length, empty: docs.length === 0 };
      },
    };
  }

  return {
    doc: (id: string) => docRef(`${path}/${id}`),
    where: (field: string, op: string, value: unknown) => query([]).where(field, op, value),
    get: async () => {
      const docs = directDocs();
      return { docs, size: docs.length, empty: docs.length === 0 };
    },
  };
}

/** Serialises `db.runTransaction` bodies — see the note on it below. */
let transactionQueue: Promise<unknown> = Promise.resolve();

const db = {
  doc: docRef,
  collection: collectionRef,
  batch: () => {
    const ops: Array<() => Promise<void>> = [];
    return {
      set: (ref: { path: string }, data: Doc, options?: { merge?: boolean }) => {
        ops.push(async () => docRef(ref.path).set(data, options));
      },
      update: (ref: { path: string }, data: Doc) => {
        ops.push(async () => docRef(ref.path).update(data));
      },
      delete: (ref: { path: string }) => {
        ops.push(async () => docRef(ref.path).delete());
      },
      commit: async () => {
        stats.batches += 1;
        stats.maxBatchSize = Math.max(stats.maxBatchSize, ops.length);
        stats.onBatchCommit?.(stats.batches);
        // Lets a test fail one CHUNK of a chunked commit, the way a real
        // Firestore batch can fail mid-rotation (see F5 / the retry contract).
        if (stats.failCommitAtBatch.has(stats.batches)) {
          throw new Error(`simulated batch failure at commit #${stats.batches}`);
        }
        for (const op of ops) await op();
      },
    };
  },
  /**
   * SERIALISED, because that is the property under test.
   *
   * Firestore gives a transaction serialisable isolation: a transaction whose
   * read set changed under it is aborted and re-run, so two overlapping
   * read-then-write transactions cannot both act on the same pre-state. This
   * double models that guarantee with a queue — each transaction body runs to
   * completion, writes included, before the next one starts. What a test built
   * on it can prove is therefore NOT "Firestore serialises" (that is
   * Firestore's contract, not ours) but the thing the code controls: whether
   * the guard and the write it protects are inside the SAME transactional
   * unit. Move either one out and the test fails.
   */
  runTransaction: async <T>(fn: (tx: unknown) => Promise<T>): Promise<T> => {
    const run = async (): Promise<T> => {
      stats.transactions += 1;
      stats.onTransaction?.(stats.transactions);
      const writes: Array<() => Promise<void>> = [];
      const tx = {
        get: (ref: { get: () => Promise<unknown> }) => ref.get(),
        set: (ref: { set: (data: Doc, options?: unknown) => Promise<void> }, data: Doc, options?: unknown) => {
          writes.push(() => ref.set(data, options));
        },
      };
      const result = await fn(tx);
      for (const write of writes) await write();
      return result;
    };
    const attempt = transactionQueue.then(run, run);
    // Keep the queue alive whether this transaction committed or threw.
    transactionQueue = attempt.then(
      () => undefined,
      () => undefined,
    );
    return attempt;
  },
};

const auth = {
  getUserByEmail: async (email: string) => {
    const record = users.get(email.toLowerCase());
    if (!record) throw new Error("auth/user-not-found");
    return record;
  },
};

export const rosterHarness = { store, stats, users, db, auth };

export const TEAM_ID = "team_0123456789abcdef";
export const ADMIN_UID = "roster-admin-uid";
export const MEMBER_UID = "roster-member-uid";
export const OUTSIDER_UID = "roster-outsider-uid";
/**
 * A syntactically real escrow fingerprint: base64 of a 32-byte SHA-256 digest,
 * i.e. 43 base64 characters plus the `=` pad. NOT 64 hex — see
 * `isEscrowPublicKeyFingerprint`. Every fixture below goes through this helper
 * so a test can never again pass a shape no device actually publishes.
 */
export function escrowFingerprint(seedChar: string): string {
  return `${seedChar.repeat(43)}=`;
}

export const DEVICE = { deviceId: "device-a", keyVersion: 1, publicKeyFingerprint: escrowFingerprint("a") };

/**
 * Fixture wrap material, BUILT AT RUNTIME rather than committed. `firestore.rules`
 * only requires `wrappedKeyBase64` to be non-empty base64 under 4 KiB, so a
 * fixture never needs real wrapped bytes — and a committed base64 literal next
 * to a `…Key…` field name is exactly the shape the repo's secret scanner
 * refuses. Same rule as `escrowFingerprint` above: construct, never paste.
 */
const WRAPPED_FIXTURE_B64 = Buffer.from("wrapped-fixture", "utf8").toString("base64");

export function seed(path: string, data: Doc): void {
  rosterHarness.store.set(path, data);
}

export function seedTeam(overrides: Doc = {}): void {
  seed(`team_rosters/${TEAM_ID}`, {
    teamId: TEAM_ID,
    name: "Core Platform",
    activeKeyVersion: 1,
    retainedKeyVersions: [1],
    burnedKeyVersions: [],
    slugKeyId: null,
    keyRotationRequired: false,
    membershipEpoch: 0,
    // Mirrors what `createTeam` writes: "no re-seal pass has finished" is a
    // stored null, not an absent field (D16 / P22, PR 4).
    rewrapCompletedKeyVersion: null,
    rewrapJobId: null,
    createdBy: ADMIN_UID,
    schemaVersion: 1,
    ...overrides,
  });
}

export function seedMember(uid: string, overrides: Doc = {}): void {
  seed(`team_rosters/${TEAM_ID}/members/${uid}`, {
    uid,
    teamId: TEAM_ID,
    role: "member",
    status: "active",
    escrowDeviceFingerprints: [],
    activeTeamKeyVersion: 1,
    invitedBy: ADMIN_UID,
    schemaVersion: 1,
    ...overrides,
  });
}

/** An invite document as `inviteMember` would have persisted it. */
export function seedInvite(inviteeUid: string, token: string, role: string): void {
  const tokenHash = createHash("sha256").update(token, "utf8").digest("hex");
  seed(`team_rosters/${TEAM_ID}/invites/${tokenHash}`, {
    teamId: TEAM_ID,
    tokenHash,
    inviteeUid,
    role,
    status: "pending",
    invitedBy: ADMIN_UID,
    schemaVersion: 1,
    expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
  });
}

export function seedTrustedDevice(uid: string, device = DEVICE): void {
  seed(`users/${uid}/escrow_devices/${device.deviceId}`, { trustState: "trusted" });
  seed(`users/${uid}/escrow_public_keys/${device.deviceId}_${device.keyVersion}`, {
    deviceId: device.deviceId,
    keyVersion: device.keyVersion,
    publicKeyFingerprint: device.publicKeyFingerprint,
    algorithm: "ECIES-P256-AESGCM",
  });
}

/**
 * A published envelope, shaped exactly as `firestore.rules` allows it to be
 * written: id-bound fields, the recipient's PINNED fingerprint, and `wrappedBy`
 * naming its author. Coverage verification reads every one of these back.
 */
export function seedEnvelope(uid: string, keyVersion: number | "slug", device = DEVICE, overrides: Doc = {}): string {
  // Mirrors `teamKeyEnvelopeId`, written out rather than imported to keep this
  // module free of any edge into the module under test (see the note above).
  const slot = keyVersion === "slug" ? "slug" : `v${keyVersion}`;
  const id = `${uid}_${device.deviceId}_${device.keyVersion}_${slot}`;
  seed(`team_key_envelopes/${TEAM_ID}/envelopes/${id}`, {
    teamId: TEAM_ID,
    uid,
    deviceId: device.deviceId,
    escrowKeyVersion: device.keyVersion,
    keySlot: slot,
    algorithm: "ECIES-P256-AESGCM",
    wrappedKeyBase64: WRAPPED_FIXTURE_B64,
    recipientPublicKeyFingerprint: device.publicKeyFingerprint,
    wrappedBy: ADMIN_UID,
    ...overrides,
  });
  return id;
}

/**
 * Read a seeded/written document, failing LOUDLY when the path holds nothing.
 * Tests used to assert `store.get(path) as Doc`, which turned a missing write
 * into an empty spread and a green assertion; this turns it into a failure.
 */
export function storedDoc(path: string): Doc {
  const data = rosterHarness.store.get(path);
  if (!data) throw new Error(`no document at ${path}`);
  return data;
}

export function inviteDocs(): Array<[string, Doc]> {
  return [...rosterHarness.store.entries()].filter(([path]) => path.includes("/invites/"));
}

export function auditActions(): string[] {
  return [...rosterHarness.store.entries()]
    .filter(([path]) => path.includes("/audit_log/"))
    .map(([, data]) => String(data.action));
}

export async function caught(action: () => Promise<unknown>): Promise<HttpsError> {
  try {
    await action();
  } catch (error) {
    if (error instanceof HttpsError) return error;
    throw error;
  }
  throw new Error("expected the roster authority to reject this call");
}
