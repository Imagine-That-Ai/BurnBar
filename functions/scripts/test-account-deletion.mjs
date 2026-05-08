import assert from "node:assert/strict";
import {
  eraseUserCloudData,
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
    assert.equal(path, "provider_account_secret_refs");
    return this.rootCollections.get(path);
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

  const destroyedSecrets = [];
  const summary = await eraseUserCloudData(db, "alice", {
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
