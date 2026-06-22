import test from "node:test";
import assert from "node:assert/strict";

import { assertMem0DeleteScope, deleteManifestMemory } from "./mem0-delete-boundary.mjs";

const matchingMemory = {
  id: "mem-1",
  user_id: "burnbar",
  app_id: "burnbar",
  metadata: {
    source: "droid-wiki",
    source_path: "apps/android-app.md",
    chunk_index: 2,
  },
};

test("deleteManifestMemory fetches and verifies metadata before deleting", async () => {
  const calls = [];
  const client = {
    async get(id) {
      calls.push(["get", id]);
      return matchingMemory;
    },
    async delete(id) {
      calls.push(["delete", id]);
    },
  };

  const result = await deleteManifestMemory({
    client,
    memoryId: "mem-1",
    key: "apps/android-app.md#2",
    userId: "burnbar",
    appId: "burnbar",
  });

  assert.equal(result, "deleted");
  assert.deepEqual(calls, [
    ["get", "mem-1"],
    ["delete", "mem-1"],
  ]);
});

test("deleteManifestMemory treats an already-missing remote memory as safe", async () => {
  let deleted = false;
  const result = await deleteManifestMemory({
    client: {
      async get() {
        return null;
      },
      async delete() {
        deleted = true;
      },
    },
    memoryId: "mem-missing",
    key: "apps/android-app.md#0",
    userId: "burnbar",
    appId: "burnbar",
  });

  assert.equal(result, "missing");
  assert.equal(deleted, false);
});

test("deleteManifestMemory refuses source path mismatches", async () => {
  const client = {
    async get() {
      return matchingMemory;
    },
    async delete() {
      throw new Error("delete must not run");
    },
  };

  await assert.rejects(
    () =>
      deleteManifestMemory({
        client,
        memoryId: "mem-1",
        key: "apps/ios-app/index.md#2",
        userId: "burnbar",
        appId: "burnbar",
      }),
    /source_path mismatch/,
  );
});

test("assertMem0DeleteScope refuses chunk index mismatches", () => {
  assert.throws(
    () =>
      assertMem0DeleteScope(matchingMemory, {
        key: "apps/android-app.md#3",
        userId: "burnbar",
        appId: "burnbar",
      }),
    /chunk_index mismatch/,
  );
});

test("assertMem0DeleteScope refuses non-wiki remote memories", () => {
  assert.throws(
    () =>
      assertMem0DeleteScope(
        {
          ...matchingMemory,
          metadata: { ...matchingMemory.metadata, source: "member-knowledge" },
        },
        {
          key: "apps/android-app.md#2",
          userId: "burnbar",
          appId: "burnbar",
        },
      ),
    /source mismatch/,
  );
});

test("assertMem0DeleteScope refuses user or app boundary mismatches when present", () => {
  assert.throws(
    () =>
      assertMem0DeleteScope(
        { ...matchingMemory, user_id: "other-user" },
        {
          key: "apps/android-app.md#2",
          userId: "burnbar",
          appId: "burnbar",
        },
      ),
    /user_id mismatch/,
  );

  assert.throws(
    () =>
      assertMem0DeleteScope(
        { ...matchingMemory, app_id: "other-app" },
        {
          key: "apps/android-app.md#2",
          userId: "burnbar",
          appId: "burnbar",
        },
      ),
    /app_id mismatch/,
  );
});

test("assertMem0DeleteScope refuses missing metadata and malformed keys", () => {
  assert.throws(
    () =>
      assertMem0DeleteScope(
        { id: "mem-1" },
        {
          key: "apps/android-app.md#2",
          userId: "burnbar",
          appId: "burnbar",
        },
      ),
    /no metadata/,
  );

  assert.throws(
    () =>
      assertMem0DeleteScope(matchingMemory, {
        key: "apps/android-app.md",
        userId: "burnbar",
        appId: "burnbar",
      }),
    /invalid manifest key/,
  );
});
