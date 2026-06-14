import assert from "node:assert/strict";
import {
  eraseUserAccount,
  eraseUserCloudData,
  isFirebaseAuthUserNotFound,
  providerSecretRefDocumentID,
  userWorkspaceID,
} from "../lib/accountDeletion.js";

class FakeDocument {
  constructor(path, data = {}) {
    this.path = path;
    this.id = path.split("/").pop();
    this.data = data;
    this.collections = new Map();
    this.ref = this;
  }

  get(field) {
    return this.data[field];
  }

  async listCollections() {
    return [...this.collections.values()];
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

  async commit() {
    this.deletedPaths.push(...this.pending);
    this.pending = [];
  }
}

class FakeFirestore {
  constructor() {
    this.rootCollections = new Map();
    this.deletedPaths = [];
  }

  collection(path) {
    // eraseUserCloudData reads provider_account_secret_refs plus the root push
    // queues (voip_outbound / fcm_outbound) — T-PRV-02. Return a registered
    // collection if present, otherwise an empty one so the walk is a no-op.
    assert.ok(
      ["provider_account_secret_refs", "voip_outbound", "fcm_outbound"].includes(path),
      `unexpected root collection read: ${path}`,
    );
    return this.rootCollections.get(path) ?? new FakeCollection(path);
  }

  doc(path) {
    const [collectionID, docID] = path.split("/");
    const collection = this.rootCollections.get(collectionID);
    return collection?.docs.find((doc) => doc.id === docID) ?? new FakeDocument(path);
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
  const value = new FakeDocument(path, data);
  for (const child of childCollections) {
    value.collections.set(child.path, child);
  }
  return value;
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

  const chunks = collection("users/alice/session_logs/log1/chunks", [
    doc("users/alice/session_logs/log1/chunks/chunk1"),
  ]);
  const sessionLogs = collection("users/alice/session_logs", [
    doc("users/alice/session_logs/log1", {}, [chunks]),
  ]);
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
}

{
  const db = new FakeFirestore();
  db.addRootCollection(collection("provider_account_secret_refs", [
    doc("provider_account_secret_refs/alice_codex", {
      uid: "alice",
      secretVersionName: "projects/p/secrets/codex/versions/1",
    }),
  ]));
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
  assert.equal(warnings.length, 1);
  assert.ok(db.deletedPaths.includes("provider_account_secret_refs/alice_codex"));
  assert.ok(db.deletedPaths.includes("users/alice"));
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
    deleteAuthUser: async (uid) => {
      deletedAuthUsers.push(uid);
    },
    logger: { warn() {} },
  });

  assert.deepEqual(deletedAuthUsers, ["alice"]);
  assert.equal(summary.deletedAuthUser, true);
  assert.equal(summary.authUserAlreadyMissing, false);
  assert.ok(db.deletedPaths.includes("users/alice"));
}

{
  const db = new FakeFirestore();
  db.addRootCollection(collection("provider_account_secret_refs", [
    doc("provider_account_secret_refs/alice_codex", {
      uid: "alice",
      secretVersionName: "projects/p/secrets/codex/versions/1",
    }),
  ]));
  db.addRootCollection(collection("users", [doc("users/alice")]));
  db.addRootCollection(collection("workspaces", []));

  const deletedAuthUsers = [];
  const summary = await eraseUserAccount(db, "alice", {
    deleteStorageObjects: async () => {},
    destroyCredential: async () => {
      throw new Error("destroy failed");
    },
    deleteAuthUser: async (uid) => {
      deletedAuthUsers.push(uid);
    },
    logger: { warn() {} },
  });

  assert.deepEqual(deletedAuthUsers, []);
  assert.equal(summary.failedSecretDestroys, 1);
  assert.equal(summary.deletedAuthUser, false);
  assert.equal(summary.authUserAlreadyMissing, false);
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
    deleteAuthUser: async () => {
      throw userNotFound;
    },
    logger: { warn() {} },
  });

  assert.equal(summary.deletedAuthUser, false);
  assert.equal(summary.authUserAlreadyMissing, true);
}

{
  assert.equal(isFirebaseAuthUserNotFound({ code: "auth/user-not-found" }), true);
  assert.equal(isFirebaseAuthUserNotFound({ errorInfo: { code: "auth/user-not-found" } }), true);
  assert.equal(isFirebaseAuthUserNotFound({ code: "auth/too-many-requests" }), false);
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
  assert.ok(deletedPrefixes.includes("avatars/alice"), "must delete the avatar object");
}

// A storage deletion failure must NOT fail the erase (best-effort), but must warn.
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
  assert.equal(warnings.length, 2, "one warning per failed storage prefix");
  assert.ok(db.deletedPaths.includes("users/alice"), "Firestore tree still erased despite storage failure");
}

console.log("account-deletion storage-prefix tests passed");
