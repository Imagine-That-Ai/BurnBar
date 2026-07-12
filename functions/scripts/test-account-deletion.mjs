import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  eraseUserAccount,
  eraseUserCloudData,
  isFirebaseAuthUserNotFound,
  isSecretVersionAlreadyErased,
  providerSecretRefDocumentID,
  userWorkspaceID,
} from "../lib/accountDeletion.js";

class FakeDocument {
  constructor(path, data = {}, exists = false) {
    this.path = path;
    this.id = path.split("/").pop();
    this.data = data;
    this.exists = exists;
    this.collections = new Map();
    this.ref = this;
  }

  get(field) {
    if (arguments.length > 0) return this.data[field];
    return Promise.resolve({
      exists: this.exists,
      get: (name) => this.data[name],
    });
  }

  async listCollections() {
    return [...this.collections.values()];
  }

  async set(data, options = {}) {
    this.data = options.merge ? { ...this.data, ...data } : { ...data };
    this.exists = true;
  }
}

class FakeCollection {
  constructor(path) {
    this.path = path;
    this.docs = [];
  }

  async listDocuments() {
    return this.docs;
  }

  where(field, op, value) {
    assert.equal(op, "==");
    const docs = this.docs.filter((doc) => doc.data[field] === value);
    return {
      async get() {
        return { docs };
      },
    };
  }
}

class FakeBatch {
  constructor(deletedPaths) {
    this.deletedPaths = deletedPaths;
    this.pending = [];
  }

  delete(ref) {
    this.pending.push(ref.path);
  }

  create(ref, data) {
    if (ref.exists) throw new Error(`document already exists: ${ref.path}`);
    ref.data = { ...data };
    ref.exists = true;
  }

  set(ref, data, options = {}) {
    ref.data = options.merge ? { ...ref.data, ...data } : { ...data };
    ref.exists = true;
  }

  async commit() {
    this.deletedPaths.push(...this.pending);
    this.pending = [];
  }
}

class FakeFirestore {
  constructor() {
    this.rootCollections = new Map();
    this.documents = new Map();
    this.deletedPaths = [];
  }

  collection(path) {
    // eraseUserCloudData reads provider_account_secret_refs plus the root push
    // queues (voip_outbound / fcm_outbound) — T-PRV-02. Return a registered
    // collection if present, otherwise an empty one so the walk is a no-op.
    assert.ok(
      [
        "provider_account_secret_refs",
        "voip_outbound",
        "fcm_outbound",
        "credential_transfers",
        "hermes_gateway_token_index",
        "hermes_gateway_device_sessions",
        "cli_link_sessions",
      ].includes(path),
      `unexpected root collection read: ${path}`,
    );
    return this.rootCollections.get(path) ?? new FakeCollection(path);
  }

  doc(path) {
    const [collectionID, docID] = path.split("/");
    const collection = this.rootCollections.get(collectionID);
    const rooted = collection?.docs.find((doc) => doc.id === docID);
    if (rooted) return rooted;
    if (!this.documents.has(path)) this.documents.set(path, new FakeDocument(path));
    return this.documents.get(path);
  }

  batch() {
    return new FakeBatch(this.deletedPaths);
  }

  addRootCollection(collection) {
    this.rootCollections.set(collection.path, collection);
  }
}

function collection(path, docs = []) {
  const value = new FakeCollection(path);
  value.docs = docs;
  return value;
}

function doc(path, data = {}, childCollections = []) {
  const value = new FakeDocument(path, data, true);
  for (const child of childCollections) {
    value.collections.set(child.path, child);
  }
  return value;
}

function auditOptions() {
  const intent = {
    seq: 0,
    ts: "2026-07-10T00:00:00.000Z",
    actor: "user:test",
    action: "account.delete.intent",
    domain: "account",
    prevHash: "",
  };
  const canonical = JSON.stringify(intent);
  return {
    actor: "user:test",
    domain: "account",
    appendAuditEventRequired: async () => ({
      ...intent,
      hash: createHash("sha256").update(canonical).digest("hex"),
    }),
  };
}

assert.equal(userWorkspaceID("alice"), "workspace-alice");
assert.equal(providerSecretRefDocumentID("alice", "codex_work"), "alice_codex_work");

{
  const db = new FakeFirestore();
  const secretRefs = collection("provider_account_secret_refs", [
    doc("provider_account_secret_refs/alice_codex", {
      uid: "alice",
      secretVersionName: "projects/p/secrets/codex/versions/1",
    }),
    doc("provider_account_secret_refs/bob_codex", {
      uid: "bob",
      secretVersionName: "projects/p/secrets/bob/versions/1",
    }),
  ]);
  db.addRootCollection(secretRefs);

  // F-RR09-001: root push-queue docs carry uid + cleartext caller name + live
  // push tokens and must be erased on account deletion (they are NOT under the
  // users/{uid} tree the recursive walk covers). Seed both alice and bob so the
  // test proves the deletion is uid-scoped (alice removed, bob untouched).
  db.addRootCollection(
    collection("voip_outbound", [
      doc("voip_outbound/voip-alice-1", { uid: "alice", status: "pending" }),
      doc("voip_outbound/voip-bob-1", { uid: "bob", status: "pending" }),
    ]),
  );
  db.addRootCollection(
    collection("fcm_outbound", [
      doc("fcm_outbound/fcm-alice-1", { uid: "alice", status: "pending" }),
      doc("fcm_outbound/fcm-bob-1", { uid: "bob", status: "pending" }),
    ]),
  );
  for (const [name, ownerField] of [
    ["credential_transfers", "ownerUid"],
    ["hermes_gateway_token_index", "uid"],
    ["hermes_gateway_device_sessions", "uid"],
    ["cli_link_sessions", "ownerUid"],
  ]) {
    db.addRootCollection(
      collection(name, [
        doc(`${name}/alice-owned`, { [ownerField]: "alice" }),
        doc(`${name}/bob-owned`, { [ownerField]: "bob" }),
      ]),
    );
  }

  const chunks = collection("users/alice/session_logs/log1/chunks", [
    doc("users/alice/session_logs/log1/chunks/chunk1"),
  ]);
  const sessionLogs = collection("users/alice/session_logs", [doc("users/alice/session_logs/log1", {}, [chunks])]);
  const user = doc("users/alice", {}, [sessionLogs]);
  db.addRootCollection(collection("users", [user]));

  const versions = collection("workspaces/workspace-alice/teams/team-default/artifacts/a1/versions", [
    doc("workspaces/workspace-alice/teams/team-default/artifacts/a1/versions/v1"),
  ]);
  const artifacts = collection("workspaces/workspace-alice/teams/team-default/artifacts", [
    doc("workspaces/workspace-alice/teams/team-default/artifacts/a1", {}, [versions]),
  ]);
  const team = collection("workspaces/workspace-alice/teams", [
    doc("workspaces/workspace-alice/teams/team-default", {}, [artifacts]),
  ]);
  const workspace = doc("workspaces/workspace-alice", {}, [team]);
  db.addRootCollection(collection("workspaces", [workspace]));

  // T-PRV-02: the root push queues carry per-doc `uid` ownership and must be
  // erased by owner (GDPR Art.17) — alice's are deleted, bob's are left intact.
  db.addRootCollection(
    collection("voip_outbound", [
      doc("voip_outbound/v-alice-1", { uid: "alice" }),
      doc("voip_outbound/v-bob-1", { uid: "bob" }),
    ]),
  );
  db.addRootCollection(
    collection("fcm_outbound", [
      doc("fcm_outbound/f-alice-1", { uid: "alice" }),
      doc("fcm_outbound/f-bob-1", { uid: "bob" }),
    ]),
  );

  const destroyedSecrets = [];
  const summary = await eraseUserCloudData(db, "alice", {
    deleteStorageObjects: async () => {},
    destroyCredential: async (secretVersionName) => {
      destroyedSecrets.push(secretVersionName);
    },
    logger: { warn() {} },
  });

  assert.deepEqual(destroyedSecrets, ["projects/p/secrets/codex/versions/1"]);
  assert.equal(summary.destroyedSecrets, 1);
  assert.equal(summary.failedSecretDestroys, 0);
  assert.equal(summary.deletedStoragePrefixes, 2);
  assert.equal(summary.failedStorageDeletes, 0);
  assert.equal(summary.cloudDataDeleted, true);
  assert.equal(summary.retryRequired, false);
  assert.ok(db.deletedPaths.includes("provider_account_secret_refs/alice_codex"));
  assert.ok(db.deletedPaths.includes("users/alice/session_logs/log1/chunks/chunk1"));
  assert.ok(db.deletedPaths.includes("users/alice/session_logs/log1"));
  assert.ok(db.deletedPaths.includes("users/alice"));
  assert.ok(db.deletedPaths.includes("workspaces/workspace-alice/teams/team-default/artifacts/a1/versions/v1"));
  assert.ok(db.deletedPaths.includes("workspaces/workspace-alice"));
  assert.ok(!db.deletedPaths.includes("provider_account_secret_refs/bob_codex"));
  // T-PRV-02: alice's push-queue docs erased; bob's untouched.
  assert.ok(db.deletedPaths.includes("voip_outbound/v-alice-1"));
  assert.ok(db.deletedPaths.includes("fcm_outbound/f-alice-1"));
  assert.ok(!db.deletedPaths.includes("voip_outbound/v-bob-1"));
  assert.ok(!db.deletedPaths.includes("fcm_outbound/f-bob-1"));
  for (const name of [
    "credential_transfers",
    "hermes_gateway_token_index",
    "hermes_gateway_device_sessions",
    "cli_link_sessions",
  ]) {
    assert.ok(db.deletedPaths.includes(`${name}/alice-owned`), `${name} owner record must be erased`);
    assert.ok(!db.deletedPaths.includes(`${name}/bob-owned`), `${name} cross-user record must remain`);
  }
}

{
  const db = new FakeFirestore();
  db.addRootCollection(
    collection("provider_account_secret_refs", [
      doc("provider_account_secret_refs/alice_codex", {
        uid: "alice",
        secretVersionName: "projects/p/secrets/codex/versions/1",
      }),
    ]),
  );
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const warnings = [];
  const summary = await eraseUserCloudData(db, "alice", {
    deleteStorageObjects: async () => {},
    destroyCredential: async () => {
      throw new Error("destroy failed");
    },
    logger: { warn: (...args) => warnings.push(args) },
  });

  assert.equal(summary.destroyedSecrets, 0);
  assert.equal(summary.failedSecretDestroys, 1);
  assert.equal(summary.cloudDataDeleted, false);
  assert.equal(summary.retryRequired, true);
  assert.equal(warnings.length, 1);
  assert.ok(
    !db.deletedPaths.includes("provider_account_secret_refs/alice_codex"),
    "failed secret ref remains for retry",
  );
  assert.ok(!db.deletedPaths.includes("users/alice"), "identity and trusted-device subtree remain for retry");
}

{
  const db = new FakeFirestore();
  db.addRootCollection(collection("provider_account_secret_refs", []));
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const deletedAuthUsers = [];
  const summary = await eraseUserAccount(db, "alice", {
    deleteStorageObjects: async () => {},
    destroyCredential: async () => {},
    revokeAuthTokens: async () => {},
    deleteAuthUser: async (uid) => {
      deletedAuthUsers.push(uid);
    },
    audit: auditOptions(),
    logger: { warn() {} },
  });

  assert.deepEqual(deletedAuthUsers, ["alice"]);
  assert.equal(summary.deletedAuthUser, true);
  assert.equal(summary.authUserAlreadyMissing, false);
  assert.equal(summary.cloudDataDeleted, true);
  assert.equal(summary.retryRequired, false);
  assert.ok(db.deletedPaths.includes("users/alice"));
}

{
  const db = new FakeFirestore();
  db.addRootCollection(
    collection("provider_account_secret_refs", [
      doc("provider_account_secret_refs/alice_codex", {
        uid: "alice",
        secretVersionName: "projects/p/secrets/codex/versions/1",
      }),
    ]),
  );
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const deletedAuthUsers = [];
  const summary = await eraseUserAccount(db, "alice", {
    deleteStorageObjects: async () => {},
    destroyCredential: async () => {
      throw new Error("destroy failed");
    },
    revokeAuthTokens: async () => {},
    deleteAuthUser: async (uid) => {
      deletedAuthUsers.push(uid);
    },
    audit: auditOptions(),
    logger: { warn() {} },
  });

  assert.deepEqual(deletedAuthUsers, []);
  assert.equal(summary.failedSecretDestroys, 1);
  assert.equal(summary.retryRequired, true);
  assert.equal(summary.cloudDataDeleted, false);
  assert.equal(summary.deletedAuthUser, false);
  assert.equal(summary.authUserAlreadyMissing, false);
  assert.ok(!db.deletedPaths.includes("users/alice"));
}

{
  const db = new FakeFirestore();
  db.addRootCollection(collection("provider_account_secret_refs", []));
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const userNotFound = new Error("No such user.");
  userNotFound.code = "auth/user-not-found";
  const summary = await eraseUserAccount(db, "alice", {
    deleteStorageObjects: async () => {},
    destroyCredential: async () => {},
    revokeAuthTokens: async () => {},
    deleteAuthUser: async () => {
      throw userNotFound;
    },
    audit: auditOptions(),
    logger: { warn() {} },
  });

  assert.equal(summary.deletedAuthUser, false);
  assert.equal(summary.authUserAlreadyMissing, true);
}

{
  assert.equal(isFirebaseAuthUserNotFound({ code: "auth/user-not-found" }), true);
  assert.equal(isFirebaseAuthUserNotFound({ errorInfo: { code: "auth/user-not-found" } }), true);
  assert.equal(isFirebaseAuthUserNotFound({ code: "auth/too-many-requests" }), false);
  assert.equal(isSecretVersionAlreadyErased({ code: 404 }), true);
  assert.equal(
    isSecretVersionAlreadyErased({
      code: 9,
      message: "Secret Version projects/p/secrets/s/versions/1 has been destroyed.",
    }),
    true,
  );
  assert.equal(isSecretVersionAlreadyErased({ code: 9, message: "secret is disabled" }), false);
}

// A crash can happen after Secret Manager destroys the version but before the
// Firestore ref commit. The retry must treat "already destroyed" as success.
{
  const db = new FakeFirestore();
  db.addRootCollection(
    collection("provider_account_secret_refs", [
      doc("provider_account_secret_refs/alice_codex", {
        uid: "alice",
        secretVersionName: "projects/p/secrets/codex/versions/1",
      }),
    ]),
  );
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const summary = await eraseUserCloudData(db, "alice", {
    destroyCredential: async () => {
      throw Object.assign(new Error("Secret Version has been destroyed"), { code: 9 });
    },
    deleteStorageObjects: async () => {},
  });

  assert.equal(summary.destroyedSecrets, 1);
  assert.equal(summary.failedSecretDestroys, 0);
  assert.equal(summary.cloudDataDeleted, true);
  assert.ok(db.deletedPaths.includes("provider_account_secret_refs/alice_codex"));
}

// A malformed ref is the last link to an external secret. It must remain as an
// operator-visible retry manifest instead of being deleted as if no secret existed.
{
  const db = new FakeFirestore();
  db.addRootCollection(
    collection("provider_account_secret_refs", [
      doc("provider_account_secret_refs/alice_codex", {
        uid: "alice",
        secretVersionName: " ",
      }),
    ]),
  );
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const warnings = [];
  const summary = await eraseUserCloudData(db, "alice", {
    destroyCredential: async () => assert.fail("malformed ref must not call Secret Manager"),
    deleteStorageObjects: async () => {},
    logger: { warn: (message) => warnings.push(message) },
  });

  assert.equal(summary.failedSecretDestroys, 1);
  assert.equal(summary.cloudDataDeleted, false);
  assert.equal(summary.retryRequired, true);
  assert.equal(warnings.length, 1);
  assert.ok(!db.deletedPaths.includes("provider_account_secret_refs/alice_codex"));
  assert.ok(!db.deletedPaths.includes("users/alice"));
}

// Storage-orphan fix: account erase must also purge the user's Cloud Storage prefixes.
{
  const db = new FakeFirestore();
  db.addRootCollection(collection("provider_account_secret_refs", []));
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const deletedPrefixes = [];
  await eraseUserCloudData(db, "alice", {
    destroyCredential: async () => {},
    deleteStorageObjects: async (prefix) => {
      deletedPrefixes.push(prefix);
    },
  });

  assert.ok(deletedPrefixes.includes("users/alice/"), "must delete the user storage prefix");
  assert.ok(deletedPrefixes.includes("avatars/alice/"), "must delete only this user's avatar directory");
}

// A storage deletion failure is fail-closed: Firestore/Auth identity remains so
// the same authenticated user can retry the idempotent prefix cleanup.
{
  const db = new FakeFirestore();
  db.addRootCollection(collection("provider_account_secret_refs", []));
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const warnings = [];
  const summary = await eraseUserCloudData(db, "alice", {
    destroyCredential: async () => {},
    deleteStorageObjects: async () => {
      throw new Error("storage unavailable");
    },
    logger: { warn: (...args) => warnings.push(args) },
  });

  assert.equal(summary.failedSecretDestroys, 0, "storage failure is not a secret failure");
  assert.equal(summary.failedStorageDeletes, 2);
  assert.deepEqual(summary.failedStoragePrefixKinds, ["user_data", "avatar"]);
  assert.equal(summary.cloudDataDeleted, false);
  assert.equal(summary.retryRequired, true);
  assert.equal(warnings.length, 2, "one warning per failed storage prefix");
  assert.ok(!db.deletedPaths.includes("users/alice"), "Firestore identity must remain after storage failure");
}

// A partial storage failure can be retried. Both deterministic prefixes are
// attempted again; only the successful retry permits Firestore erasure.
{
  const db = new FakeFirestore();
  db.addRootCollection(collection("provider_account_secret_refs", []));
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  let attempt = 0;
  const calls = [];
  const deleteStorageObjects = async (prefix) => {
    calls.push(prefix);
    if (attempt === 0 && prefix.startsWith("users/")) {
      throw new Error("transient storage failure");
    }
  };

  const first = await eraseUserCloudData(db, "alice", {
    destroyCredential: async () => {},
    deleteStorageObjects,
    logger: { warn() {} },
  });
  assert.equal(first.failedStorageDeletes, 1);
  assert.equal(first.cloudDataDeleted, false);
  assert.ok(!db.deletedPaths.includes("users/alice"));

  attempt += 1;
  const second = await eraseUserCloudData(db, "alice", {
    destroyCredential: async () => {},
    deleteStorageObjects,
    logger: { warn() {} },
  });
  assert.equal(second.failedStorageDeletes, 0);
  assert.equal(second.deletedStoragePrefixes, 2);
  assert.equal(second.cloudDataDeleted, true);
  assert.equal(second.retryRequired, false);
  assert.ok(db.deletedPaths.includes("users/alice"));
  assert.deepEqual(calls, ["users/alice/", "avatars/alice/", "users/alice/", "avatars/alice/"]);
}

console.log("account-deletion fail-closed retry tests passed");
