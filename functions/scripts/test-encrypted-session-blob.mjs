/**
 * Unit tests for the encrypted session-body storage-path contract that the transcript download
 * relies on. `assertUserStoragePath` is the gate `getEncryptedSessionBlobDownloadUrl` runs before
 * minting a signed read URL, and it must accept exactly the path
 * `beginEncryptedSessionBlobUpload` constructs — otherwise every transcript open would fail with an
 * opaque error. These exercise the pure validator with no emulator or Admin SDK initialization.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  assertUserStoragePath,
  resolveEncryptedSessionBlobByteCount,
} from "../lib/callables/shared.js";

const UID = "user-123";
const DOCUMENT_ID = "device-1_session_abc";
const BODY_HASH = "a".repeat(64);

/** Mirrors the template in `beginEncryptedSessionBlobUpload`. */
function canonicalPath(uid = UID, documentID = DOCUMENT_ID, bodyHash = BODY_HASH) {
  return `users/${uid}/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`;
}

test("accepts the canonical encrypted-body path the upload ticket mints", () => {
  assert.doesNotThrow(() => assertUserStoragePath(UID, canonicalPath()));
});

test("accepts a path whose documentID and bodyHash match the expected values", () => {
  assert.doesNotThrow(() => assertUserStoragePath(UID, canonicalPath(), BODY_HASH, DOCUMENT_ID));
});

test("accepts existing legacy storage paths with non-canonical documentID segments for download", () => {
  const legacyDocumentID = "test-device-1_factory_~albertonunez Documents Windsurf Imagine That Ai App 2.0";
  assert.doesNotThrow(() => assertUserStoragePath(UID, canonicalPath(UID, legacyDocumentID, BODY_HASH)));
});

test("keeps commit validation strict when an expected documentID is supplied", () => {
  const legacyDocumentID = "test-device-1_factory_~albertonunez Documents Windsurf Imagine That Ai App 2.0";
  assert.throws(
    () => assertUserStoragePath(UID, canonicalPath(UID, legacyDocumentID, BODY_HASH), BODY_HASH, legacyDocumentID),
    /storagePath.documentID contains unsupported characters/
  );
});

test("rejects a path that belongs to a different user", () => {
  assert.throws(
    () => assertUserStoragePath("intruder", canonicalPath()),
    /Invalid encrypted session storage path/
  );
});

test("rejects a non-users prefix", () => {
  assert.throws(
    () => assertUserStoragePath(UID, `accounts/${UID}/session_logs/${DOCUMENT_ID}/bodies/${BODY_HASH}.json.aesgcm`),
    /Invalid encrypted session storage path/
  );
});

test("rejects the wrong collection segment", () => {
  assert.throws(
    () => assertUserStoragePath(UID, `users/${UID}/audio_logs/${DOCUMENT_ID}/bodies/${BODY_HASH}.json.aesgcm`),
    /Invalid encrypted session storage path/
  );
});

test("rejects a missing bodies segment", () => {
  assert.throws(
    () => assertUserStoragePath(UID, `users/${UID}/session_logs/${DOCUMENT_ID}/${BODY_HASH}.json.aesgcm`),
    /Invalid encrypted session storage path/
  );
});

test("rejects an unexpected file extension", () => {
  assert.throws(
    () => assertUserStoragePath(UID, `users/${UID}/session_logs/${DOCUMENT_ID}/bodies/${BODY_HASH}.json`),
    /Invalid encrypted session storage path/
  );
});

test("rejects a documentID that does not match the expected manifest", () => {
  assert.throws(
    () => assertUserStoragePath(UID, canonicalPath(), BODY_HASH, "device-1_other_session"),
    /does not match documentID/
  );
});

test("rejects a bodyHash that does not match the expected hash", () => {
  assert.throws(
    () => assertUserStoragePath(UID, canonicalPath(), "b".repeat(64), DOCUMENT_ID),
    /does not match bodyHash/
  );
});

test("uses Cloud Storage metadata size as authoritative for idempotent commits", () => {
  const byteCount = resolveEncryptedSessionBlobByteCount({
    metadata: {
      size: "2048",
      contentType: "application/octet-stream",
    },
    maxBytes: 4096,
  });

  assert.equal(byteCount, 2048);
});

test("rejects invalid encrypted body metadata", () => {
  assert.throws(
    () => resolveEncryptedSessionBlobByteCount({
      metadata: {
        size: "2048",
        contentType: "text/plain",
      },
      maxBytes: 4096,
    }),
    /invalid content type/
  );

  assert.throws(
    () => resolveEncryptedSessionBlobByteCount({
      metadata: {
        size: "8192",
        contentType: "application/octet-stream",
      },
      maxBytes: 4096,
    }),
    /exceeds the configured upload limit/
  );
});
