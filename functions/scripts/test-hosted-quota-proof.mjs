import assert from "node:assert/strict";
import test from "node:test";

import {
  assertNotFirestoreEmulator,
  providerAccountSecretRefPath,
  proveHostedQuota,
} from "./prove-hosted-quota-live.mjs";

class FakeDocSnapshot {
  constructor(path, data) {
    this.ref = { path };
    this.id = path.split("/").at(-1);
    this.exists = data !== undefined;
    this._data = data;
  }

  data() {
    return this._data;
  }
}

class FakeDocRef {
  constructor(db, path) {
    this.db = db;
    this.path = path;
    this.id = path.split("/").at(-1);
  }

  async get() {
    return new FakeDocSnapshot(this.path, this.db.store.get(this.path));
  }
}

class FakeQuery {
  constructor(db, collectionPath, filters = [], limitCount = Number.POSITIVE_INFINITY) {
    this.db = db;
    this.collectionPath = collectionPath;
    this.filters = filters;
    this.limitCount = limitCount;
  }

  where(field, op, value) {
    assert.equal(op, "==");
    return new FakeQuery(this.db, this.collectionPath, [...this.filters, { field, value }], this.limitCount);
  }

  limit(limitCount) {
    return new FakeQuery(this.db, this.collectionPath, this.filters, limitCount);
  }

  async get() {
    const prefix = `${this.collectionPath}/`;
    const docs = [];
    for (const [path, data] of this.db.store.entries()) {
      if (!path.startsWith(prefix)) continue;
      if (path.slice(prefix.length).includes("/")) continue;
      if (!this.filters.every((filter) => data?.[filter.field] === filter.value)) continue;
      docs.push(new FakeDocSnapshot(path, data));
    }
    return {
      empty: docs.length === 0,
      docs: docs.slice(0, this.limitCount),
    };
  }
}

class FakeFirestore {
  constructor(seed) {
    this.store = new Map(Object.entries(seed));
  }

  collection(path) {
    return new FakeQuery(this, path);
  }

  doc(path) {
    return new FakeDocRef(this, path);
  }
}

const UID = "user-123";
const ACCOUNT_ID = "codex_default";
const ACCOUNT_PATH = `users/${UID}/provider_accounts/${ACCOUNT_ID}`;
const SNAPSHOT_PATH = `users/${UID}/quota_snapshots/codex_default_usage`;
const SECRET_REF_PATH = providerAccountSecretRefPath(UID, ACCOUNT_ID);

function validHostedSeed() {
  return {
    [ACCOUNT_PATH]: {
      id: ACCOUNT_ID,
      providerID: "codex",
      status: "connected",
      storageScope: "server_private",
    },
    [SECRET_REF_PATH]: {
      uid: UID,
      accountID: ACCOUNT_ID,
      providerID: "codex",
      secretVersionName: "projects/test/secrets/codex/versions/1",
    },
    [SNAPSHOT_PATH]: {
      providerID: "codex",
      accountID: ACCOUNT_ID,
      accountStorageScope: "server_private",
    },
  };
}

test("hosted quota proof refuses Firestore emulator state", () => {
  assert.throws(
    () => assertNotFirestoreEmulator({ FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080" }),
    /refusing hosted quota proof/i,
  );
  assert.doesNotThrow(() => assertNotFirestoreEmulator({ FIRESTORE_EMULATOR_HOST: "" }));
});

test("hosted quota proof requires server-private account, secret ref, and quota snapshot binding", async () => {
  const evidence = await proveHostedQuota(new FakeFirestore(validHostedSeed()), UID);

  assert.equal(evidence.accountPath, ACCOUNT_PATH);
  assert.equal(evidence.snapshotPath, SNAPSHOT_PATH);
  assert.match(evidence.secretRefPathHash, /^[a-f0-9]{64}$/);
});

test("hosted quota proof rejects client-writable-looking account and snapshot evidence without a secret ref", async () => {
  const seed = validHostedSeed();
  delete seed[SECRET_REF_PATH];

  await assert.rejects(
    () => proveHostedQuota(new FakeFirestore(seed), UID),
    /no server-private secret reference/i,
  );
});

test("hosted quota proof rejects inactive server_private account documents", async () => {
  const seed = validHostedSeed();
  seed[ACCOUNT_PATH] = { ...seed[ACCOUNT_PATH], status: "disabled" };

  await assert.rejects(
    () => proveHostedQuota(new FakeFirestore(seed), UID),
    /no connected server_private Codex provider account/i,
  );
});

test("hosted quota proof rejects mismatched server-private secret refs", async () => {
  const seed = validHostedSeed();
  seed[SECRET_REF_PATH] = { ...seed[SECRET_REF_PATH], providerID: "openai" };

  await assert.rejects(
    () => proveHostedQuota(new FakeFirestore(seed), UID),
    /secret reference does not match/i,
  );
});
