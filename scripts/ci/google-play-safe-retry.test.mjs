#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  planTrackUpdate,
  publishGooglePlayRelease,
} from "./google-play-safe-retry.mjs";

const AAB_BYTES = "sealed-aab-fixture";
const AAB_SHA256 = createHash("sha256").update(AAB_BYTES).digest("hex");

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), "burnbar-google-play-"));
  const aabPath = join(directory, "OpenBurnBar-1.2.3-Android.aab");
  writeFileSync(aabPath, AAB_BYTES);
  return {
    aabPath,
    manifest: {
      schemaVersion: 1,
      publication: {
        packageName: "com.openburnbar",
        track: "internal",
        releaseStatus: "completed",
        dryRun: false,
      },
      release: {
        versionName: "1.2.3",
        versionCode: 41,
      },
      artifact: {
        fileName: "OpenBurnBar-1.2.3-Android.aab",
        sha256: AAB_SHA256,
      },
    },
  };
}

function jsonResponse(status, value = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () =>
      status === 204 || value === null ? "" : JSON.stringify(value),
  };
}

function fakeGooglePlay({
  bundles = [],
  initialTrack = { track: "internal", releases: [] },
  uploadVersionCode = 41,
  committedTrack = null,
} = {}) {
  const calls = [];
  let insertCount = 0;
  let updatedTrack = initialTrack;
  const fetchImpl = async (url, options = {}) => {
    const method = options.method ?? "GET";
    const parsed = new URL(url);
    const path = parsed.pathname;
    calls.push({ method, path, body: options.body });

    if (
      method === "POST" &&
      path.endsWith("/applications/com.openburnbar/edits")
    ) {
      insertCount += 1;
      return jsonResponse(200, { id: `edit-${insertCount}` });
    }
    if (method === "GET" && path.endsWith("/edits/edit-1/bundles")) {
      return jsonResponse(200, { bundles });
    }
    if (
      method === "POST" &&
      path.endsWith("/edits/edit-1/bundles") &&
      parsed.searchParams.get("uploadType") === "media"
    ) {
      return jsonResponse(200, {
        versionCode: uploadVersionCode,
        sha256: AAB_SHA256,
      });
    }
    if (
      method === "GET" &&
      path.endsWith("/edits/edit-1/tracks/internal")
    ) {
      return jsonResponse(200, initialTrack);
    }
    if (
      method === "PUT" &&
      path.endsWith("/edits/edit-1/tracks/internal")
    ) {
      updatedTrack = JSON.parse(options.body);
      return jsonResponse(200, updatedTrack);
    }
    if (method === "POST" && path.endsWith("/edits/edit-1:commit")) {
      return jsonResponse(200, { id: "edit-1", expiryTimeSeconds: "0" });
    }
    if (
      method === "GET" &&
      path.endsWith("/edits/edit-2/tracks/internal")
    ) {
      return jsonResponse(200, committedTrack ?? updatedTrack);
    }
    if (
      method === "DELETE" &&
      /\/edits\/edit-[12]$/u.test(path)
    ) {
      return jsonResponse(204, null);
    }
    return jsonResponse(404, {
      error: { message: `Unhandled fake route: ${method} ${path}` },
    });
  };
  return { fetchImpl, calls };
}

function publish(fake, overrides = {}) {
  const input = fixture();
  return publishGooglePlayRelease({
    fetchImpl: fake.fetchImpl,
    accessToken: "test-token",
    manifest: input.manifest,
    aabPath: input.aabPath,
    apiRoot: "https://example.test/androidpublisher/v3",
    uploadRoot: "https://example.test/upload/androidpublisher/v3",
    ...overrides,
  });
}

test("track planning refuses rollback and unrelated mutable releases", () => {
  assert.throws(
    () =>
      planTrackUpdate(
        {
          track: "internal",
          releases: [{ status: "completed", versionCodes: ["42"] }],
        },
        41,
        "OpenBurnBar 1.2.3",
        "completed",
      ),
    /Refusing Google Play rollback/u,
  );
  for (const status of ["draft", "inProgress", "halted"]) {
    assert.throws(
      () =>
        planTrackUpdate(
          {
            track: "internal",
            releases: [{ status, versionCodes: ["40"] }],
          },
          41,
          "OpenBurnBar 1.2.3",
          "completed",
        ),
      new RegExp(`unrelated ${status}`, "u"),
    );
  }
});

test("exact completed release is a checksum-verified no-op", async () => {
  const fake = fakeGooglePlay({
    bundles: [{ versionCode: 41, sha256: AAB_SHA256 }],
    initialTrack: {
      track: "internal",
      releases: [
        {
          name: "OpenBurnBar 1.2.3",
          status: "completed",
          versionCodes: ["41"],
        },
      ],
    },
  });
  const result = await publish(fake);
  assert.equal(result.action, "already_current");
  assert.equal(result.uploaded, false);
  assert.equal(result.committed, false);
  assert.equal(result.readback.status, "completed");
  assert.ok(
    fake.calls.some(
      ({ method, path }) =>
        method === "GET" && path.endsWith("/edits/edit-2/tracks/internal"),
    ),
  );
  assert.ok(
    fake.calls.some(
      ({ method, path }) =>
        method === "DELETE" && path.endsWith("/edits/edit-2"),
    ),
  );
  assert.ok(!fake.calls.some(({ method }) => method === "PUT"));
  assert.ok(!fake.calls.some(({ path }) => path.endsWith(":commit")));
});

test("no-op fails closed when the track changed after the initial read", async () => {
  const fake = fakeGooglePlay({
    bundles: [{ versionCode: 41, sha256: AAB_SHA256 }],
    initialTrack: {
      track: "internal",
      releases: [
        {
          name: "OpenBurnBar 1.2.3",
          status: "completed",
          versionCodes: ["41"],
        },
      ],
    },
    committedTrack: {
      track: "internal",
      releases: [{ status: "completed", versionCodes: ["42"] }],
    },
  });
  await assert.rejects(
    publish(fake),
    /readback unexpectedly contains newer version code 42/u,
  );
  assert.ok(!fake.calls.some(({ method }) => method === "PUT"));
  assert.ok(!fake.calls.some(({ path }) => path.endsWith(":commit")));
  assert.ok(
    fake.calls.some(
      ({ method, path }) =>
        method === "DELETE" && path.endsWith("/edits/edit-2"),
    ),
  );
});

test("completed no-op refuses when Play cannot prove the existing bundle bytes", async () => {
  const fake = fakeGooglePlay({
    bundles: [],
    initialTrack: {
      track: "internal",
      releases: [{ status: "completed", versionCodes: ["41"] }],
    },
  });
  await assert.rejects(publish(fake), /refusing an unverifiable no-op/u);
  assert.ok(!fake.calls.some(({ method }) => method === "PUT"));
  assert.ok(!fake.calls.some(({ path }) => path.endsWith(":commit")));
  assert.ok(fake.calls.some(({ method }) => method === "DELETE"));
});

test("existing bundle with different bytes fails before mutation", async () => {
  const fake = fakeGooglePlay({
    bundles: [{ versionCode: 41, sha256: "ab".repeat(32) }],
    initialTrack: {
      track: "internal",
      releases: [{ status: "completed", versionCodes: ["40"] }],
    },
  });
  await assert.rejects(publish(fake), /does not match sealed AAB SHA-256/u);
  assert.ok(!fake.calls.some(({ method }) => method === "PUT"));
  assert.ok(!fake.calls.some(({ path }) => path.endsWith(":commit")));
  assert.ok(fake.calls.some(({ method }) => method === "DELETE"));
});

test("existing matching bundle is reused, committed, and read back", async () => {
  const fake = fakeGooglePlay({
    bundles: [{ versionCode: 41, sha256: AAB_SHA256 }],
    initialTrack: {
      track: "internal",
      releases: [{ status: "completed", versionCodes: ["40"] }],
    },
  });
  const result = await publish(fake);
  assert.equal(result.action, "existing_bundle_committed");
  assert.equal(result.uploaded, false);
  assert.equal(result.committed, true);
  assert.deepEqual(result.readback.versionCodes, [41]);
  assert.ok(
    !fake.calls.some(
      ({ method, path }) =>
        method === "POST" && path.endsWith("/edits/edit-1/bundles"),
    ),
  );
  assert.ok(fake.calls.some(({ path }) => path.endsWith(":commit")));
  assert.ok(
    fake.calls.some(({ path }) =>
      path.endsWith("/edits/edit-2/tracks/internal"),
    ),
  );
});

test("new bundle upload requires the exact expected version code", async () => {
  const mismatched = fakeGooglePlay({ uploadVersionCode: 99 });
  await assert.rejects(
    publish(mismatched),
    /uploaded version code 99, expected 41/u,
  );
  assert.ok(!mismatched.calls.some(({ method }) => method === "PUT"));
  assert.ok(!mismatched.calls.some(({ path }) => path.endsWith(":commit")));
  assert.ok(mismatched.calls.some(({ method }) => method === "DELETE"));

  const matching = fakeGooglePlay();
  const result = await publish(matching);
  assert.equal(result.action, "uploaded_and_committed");
  assert.equal(result.uploaded, true);
  assert.equal(result.readback.status, "completed");
});

test("post-commit readback fails closed when the requested status is absent", async () => {
  const fake = fakeGooglePlay({
    committedTrack: {
      track: "internal",
      releases: [{ status: "draft", versionCodes: ["41"] }],
    },
  });
  await assert.rejects(
    publish(fake),
    /readback did not contain completed version code 41/u,
  );
  assert.ok(fake.calls.some(({ path }) => path.endsWith(":commit")));
  assert.ok(
    fake.calls.some(
      ({ method, path }) =>
        method === "DELETE" && path.endsWith("/edits/edit-2"),
    ),
  );
});

test("draft publication verifies draft status during fresh readback", async () => {
  const fake = fakeGooglePlay();
  const input = fixture();
  input.manifest.publication.releaseStatus = "draft";
  const result = await publishGooglePlayRelease({
    fetchImpl: fake.fetchImpl,
    accessToken: "test-token",
    manifest: input.manifest,
    aabPath: input.aabPath,
    apiRoot: "https://example.test/androidpublisher/v3",
    uploadRoot: "https://example.test/upload/androidpublisher/v3",
  });
  assert.equal(result.requestedReleaseStatus, "draft");
  assert.equal(result.readback.status, "draft");
});
