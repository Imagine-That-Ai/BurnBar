#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  parseVersionCode,
  planTrackUpdate,
  publishInternalRelease,
  versionCodesFromTrack,
} from "./publish-internal-release.mjs";

function fixtureAab() {
  const directory = mkdtempSync(join(tmpdir(), "openburnbar-play-publish-"));
  const path = join(directory, "OpenBurnBar.aab");
  writeFileSync(path, "signed-aab-fixture");
  return path;
}

function fakePublisher({
  bundles = [],
  initialTrack = { track: "internal", releases: [] },
  uploadVersionCode = 41,
  committedTrack = null,
} = {}) {
  const calls = [];
  let insertCount = 0;
  let updatedTrack = initialTrack;
  const publisher = {
    calls,
    edits: {
      insert: async ({ packageName }) => {
        insertCount += 1;
        calls.push(["insert", packageName]);
        return { data: { id: `edit-${insertCount}` } };
      },
      delete: async ({ editId }) => {
        calls.push(["delete", editId]);
        return { data: {} };
      },
      commit: async ({ editId }) => {
        calls.push(["commit", editId]);
        return { data: {} };
      },
      bundles: {
        list: async ({ editId }) => {
          calls.push(["bundles.list", editId]);
          return { data: { bundles } };
        },
        upload: async ({ editId, media }) => {
          calls.push([
            "bundles.upload",
            editId,
            media.mimeType,
            Boolean(media.body),
          ]);
          return { data: { versionCode: uploadVersionCode } };
        },
      },
      tracks: {
        get: async ({ editId, track }) => {
          calls.push(["tracks.get", editId, track]);
          if (editId === "edit-1") return { data: initialTrack };
          return { data: committedTrack ?? updatedTrack };
        },
        update: async ({ editId, track, requestBody }) => {
          calls.push(["tracks.update", editId, track, requestBody]);
          updatedTrack = requestBody;
          return { data: requestBody };
        },
      },
    },
  };
  return publisher;
}

test("version-code and track helpers reject rollback and preserve exact completed reruns", () => {
  assert.equal(parseVersionCode("41"), 41);
  assert.throws(
    () => parseVersionCode("0"),
    /Invalid positive Android version code/u,
  );
  assert.throws(() => parseVersionCode("2100000001"), /outside Google Play/u);
  assert.deepEqual(
    versionCodesFromTrack({
      releases: [{ versionCodes: ["40", "41"] }, { versionCodes: ["41"] }],
    }),
    [40, 41],
  );
  assert.deepEqual(
    planTrackUpdate(
      {
        track: "internal",
        releases: [{ status: "completed", versionCodes: ["41"] }],
      },
      41,
      "OpenBurnBar 1.0.31",
    ),
    {
      action: "already_current",
      updateRequired: false,
      requestBody: null,
      priorVersionCodes: [41],
    },
  );
  assert.throws(
    () =>
      planTrackUpdate(
        {
          track: "internal",
          releases: [{ status: "completed", versionCodes: ["42"] }],
        },
        41,
        "OpenBurnBar 1.0.31",
      ),
    /Refusing Google Play rollback/u,
  );
  assert.throws(
    () =>
      planTrackUpdate(
        {
          track: "internal",
          releases: [{ status: "inProgress", versionCodes: ["40"] }],
        },
        41,
        "OpenBurnBar 1.0.31",
      ),
    /Refusing to replace inProgress/u,
  );
});

test("new AAB is uploaded, committed, and read back at the exact expected version", async () => {
  const androidpublisher = fakePublisher({
    bundles: [{ versionCode: 40 }],
    initialTrack: {
      track: "internal",
      releases: [{ status: "completed", versionCodes: ["40"] }],
    },
  });
  const receipt = await publishInternalRelease({
    androidpublisher,
    aabPath: fixtureAab(),
    packageName: "com.openburnbar",
    track: "internal",
    expectedVersionCode: 41,
    versionName: "1.0.31",
    releaseName: "OpenBurnBar 1.0.31",
  });

  assert.equal(receipt.action, "uploaded_and_committed");
  assert.equal(receipt.uploaded, true);
  assert.equal(receipt.committed, true);
  assert.equal(receipt.versionCode, 41);
  assert.deepEqual(receipt.readback.versionCodes, [41]);
  assert.match(receipt.aab.sha256, /^[0-9a-f]{64}$/u);
  assert.ok(androidpublisher.calls.some(([name]) => name === "bundles.upload"));
  assert.ok(androidpublisher.calls.some(([name]) => name === "tracks.update"));
  assert.ok(androidpublisher.calls.some(([name]) => name === "commit"));
});

test("existing bundle is promoted without re-upload and exact current version is a no-op", async () => {
  const promotable = fakePublisher({
    bundles: [{ versionCode: 41 }],
    initialTrack: {
      track: "internal",
      releases: [{ status: "completed", versionCodes: ["40"] }],
    },
  });
  const promoted = await publishInternalRelease({
    androidpublisher: promotable,
    aabPath: fixtureAab(),
    packageName: "com.openburnbar",
    track: "internal",
    expectedVersionCode: 41,
    versionName: "1.0.31",
    releaseName: "OpenBurnBar 1.0.31",
  });
  assert.equal(promoted.action, "existing_bundle_committed");
  assert.equal(promoted.uploaded, false);
  assert.ok(!promotable.calls.some(([name]) => name === "bundles.upload"));

  const current = fakePublisher({
    bundles: [{ versionCode: 41 }],
    initialTrack: {
      track: "internal",
      releases: [
        {
          status: "completed",
          versionCodes: ["41"],
          name: "OpenBurnBar 1.0.31",
        },
      ],
    },
  });
  const unchanged = await publishInternalRelease({
    androidpublisher: current,
    aabPath: fixtureAab(),
    packageName: "com.openburnbar",
    track: "internal",
    expectedVersionCode: 41,
    versionName: "1.0.31",
    releaseName: "OpenBurnBar 1.0.31",
  });
  assert.equal(unchanged.action, "already_current");
  assert.equal(unchanged.committed, false);
  assert.ok(!current.calls.some(([name]) => name === "tracks.update"));
  assert.ok(!current.calls.some(([name]) => name === "commit"));
  assert.ok(current.calls.some(([name]) => name === "delete"));
});

test("mismatched upload response fails closed and deletes the uncommitted edit", async () => {
  const androidpublisher = fakePublisher({
    bundles: [],
    uploadVersionCode: 99,
  });
  await assert.rejects(
    publishInternalRelease({
      androidpublisher,
      aabPath: fixtureAab(),
      packageName: "com.openburnbar",
      track: "internal",
      expectedVersionCode: 41,
      versionName: "1.0.31",
      releaseName: "OpenBurnBar 1.0.31",
    }),
    /uploaded version code 99, expected 41/u,
  );
  assert.ok(
    androidpublisher.calls.some(
      ([name, editId]) => name === "delete" && editId === "edit-1",
    ),
  );
  assert.ok(!androidpublisher.calls.some(([name]) => name === "commit"));
});
