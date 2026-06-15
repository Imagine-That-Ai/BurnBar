/**
 * Storage rules tests (F-RR07-017 / F-RR07-018).
 *
 * Covers:
 *   /users/{userId}/session_logs/**  — owner-only read+write, size ≤10 MB,
 *                                     contentType = application/octet-stream
 *   /avatars/{userId}/profile.jpg   — owner-only read+write (T-AZ-01 fix),
 *                                     size ≤2 MB, contentType = image/jpeg
 *   /{everything else}              — deny all (catch-all)
 *
 * Uses @firebase/rules-unit-testing v5 with the Storage emulator.
 * Run: firebase emulators:exec --only storage --project burnbar-test 'node storage-rules.test.js'
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ref, uploadBytes, getDownloadURL, deleteObject } from "firebase/storage";

const PROJECT_ID = process.env.STORAGE_TEST_PROJECT_ID || "burnbar-test";
const STORAGE_RULES_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "storage.rules"
);
const STORAGE_HOST = process.env.STORAGE_TEST_HOST || "127.0.0.1";
const STORAGE_PORT = Number.parseInt(process.env.STORAGE_TEST_PORT || "9199", 10);

const aliceUid = "alice-storage-uid";
const bobUid = "bob-storage-uid";

const TEN_MB = 10 * 1024 * 1024;
const TWO_MB = 2 * 1024 * 1024;

let passed = 0;
let failed = 0;

async function step(label, fn) {
  try {
    await fn();
    console.log(`PASS ${label}`);
    passed++;
  } catch (err) {
    console.error(`FAIL ${label}: ${err.message ?? err}`);
    failed++;
  }
}

function makeBuf(size) {
  return new Uint8Array(size).fill(0x42);
}

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    storage: {
      rules: readFileSync(STORAGE_RULES_PATH, "utf8"),
      host: STORAGE_HOST,
      port: STORAGE_PORT,
    },
  });

  const aliceStorage = testEnv.authenticatedContext(aliceUid).storage();
  const bobStorage = testEnv.authenticatedContext(bobUid).storage();
  const unauthStorage = testEnv.unauthenticatedContext().storage();

  // ── session_logs: owner write ────────────────────────────────────────────
  await step("owner can upload a session log chunk (octet-stream, ≤10 MB)", async () => {
    const r = ref(aliceStorage, `users/${aliceUid}/session_logs/chunk-001`);
    await assertSucceeds(
      uploadBytes(r, makeBuf(1024), { contentType: "application/octet-stream" })
    );
  });

  await step("session_log upload with wrong contentType is rejected", async () => {
    const r = ref(aliceStorage, `users/${aliceUid}/session_logs/chunk-002`);
    await assertFails(
      uploadBytes(r, makeBuf(512), { contentType: "text/plain" })
    );
  });

  await step("session_log upload over 10 MB is rejected", async () => {
    const r = ref(aliceStorage, `users/${aliceUid}/session_logs/chunk-big`);
    await assertFails(
      uploadBytes(r, makeBuf(TEN_MB + 1), { contentType: "application/octet-stream" })
    );
  });

  await step("bob cannot upload to alice's session_logs", async () => {
    const r = ref(bobStorage, `users/${aliceUid}/session_logs/chunk-bob`);
    await assertFails(
      uploadBytes(r, makeBuf(512), { contentType: "application/octet-stream" })
    );
  });

  await step("unauthenticated user cannot upload session logs", async () => {
    const r = ref(unauthStorage, `users/${aliceUid}/session_logs/chunk-unauth`);
    await assertFails(
      uploadBytes(r, makeBuf(512), { contentType: "application/octet-stream" })
    );
  });

  // ── session_logs: owner read ─────────────────────────────────────────────
  await step("owner can read their own session log chunk", async () => {
    // Seed via admin bypass, then try owner read
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const adminR = ref(ctx.storage(), `users/${aliceUid}/session_logs/chunk-read-seed`);
      await uploadBytes(adminR, makeBuf(64), { contentType: "application/octet-stream" });
    });
    const r = ref(aliceStorage, `users/${aliceUid}/session_logs/chunk-read-seed`);
    await assertSucceeds(getDownloadURL(r));
  });

  await step("bob cannot read alice's session_logs (T-AZ-01 cross-user)", async () => {
    const r = ref(bobStorage, `users/${aliceUid}/session_logs/chunk-read-seed`);
    await assertFails(getDownloadURL(r));
  });

  // ── avatars: owner write ─────────────────────────────────────────────────
  await step("owner can upload their own avatar (JPEG, ≤2 MB)", async () => {
    const r = ref(aliceStorage, `avatars/${aliceUid}/profile.jpg`);
    await assertSucceeds(
      uploadBytes(r, makeBuf(512), { contentType: "image/jpeg" })
    );
  });

  await step("avatar upload with wrong contentType is rejected", async () => {
    const r = ref(aliceStorage, `avatars/${aliceUid}/profile.jpg`);
    await assertFails(
      uploadBytes(r, makeBuf(512), { contentType: "image/png" })
    );
  });

  await step("avatar upload over 2 MB is rejected", async () => {
    const r = ref(aliceStorage, `avatars/${aliceUid}/profile.jpg`);
    await assertFails(
      uploadBytes(r, makeBuf(TWO_MB + 1), { contentType: "image/jpeg" })
    );
  });

  await step("bob cannot upload to alice's avatar path (T-AZ-01)", async () => {
    const r = ref(bobStorage, `avatars/${aliceUid}/profile.jpg`);
    await assertFails(
      uploadBytes(r, makeBuf(512), { contentType: "image/jpeg" })
    );
  });

  // ── avatars: owner-only read (T-AZ-01 fix) ───────────────────────────────
  await step("owner can read their own avatar", async () => {
    const r = ref(aliceStorage, `avatars/${aliceUid}/profile.jpg`);
    await assertSucceeds(getDownloadURL(r));
  });

  await step("bob cannot read alice's avatar (T-AZ-01 fix verified)", async () => {
    // This is the specific property the T-AZ-01 fix must hold: cross-user avatar
    // reads via direct bucket path are denied. Distribution must go through a callable.
    const r = ref(bobStorage, `avatars/${aliceUid}/profile.jpg`);
    await assertFails(getDownloadURL(r));
  });

  await step("unauthenticated user cannot read any avatar", async () => {
    const r = ref(unauthStorage, `avatars/${aliceUid}/profile.jpg`);
    await assertFails(getDownloadURL(r));
  });

  // ── catch-all deny ───────────────────────────────────────────────────────
  await step("catch-all denies write to an arbitrary path", async () => {
    const r = ref(aliceStorage, `arbitrary/path/file.bin`);
    await assertFails(
      uploadBytes(r, makeBuf(64), { contentType: "application/octet-stream" })
    );
  });

  await step("catch-all denies read of an arbitrary path", async () => {
    const r = ref(aliceStorage, `arbitrary/path/file.bin`);
    await assertFails(getDownloadURL(r));
  });

  await testEnv.cleanup();

  const total = passed + failed;
  console.log(`\n${passed}/${total} cases passed`);
  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
