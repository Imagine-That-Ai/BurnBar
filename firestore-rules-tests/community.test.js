/**
 * Firestore rules tests for Community paths (consent, profile, share_snapshot, looking_glass, leaderboards).
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, getDoc, setDoc, updateDoc } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-community-rules";
const bobUid = "bob-community-rules";

const shareSnapshotPayload = {
  windows: {
    today: { totalTokens: 1, costUSD: 0 },
    "7d": { totalTokens: 2, costUSD: 0 },
    "30d": { totalTokens: 3, costUSD: 0 },
    "90d": { totalTokens: 4, costUSD: 0 },
    all_time: { totalTokens: 5, costUSD: 0 },
  },
  modelMix: {},
  purposeMix: {},
  schemaVersion: 1,
  updatedAt: "2026-07-09T00:00:00.000Z",
};

let passed = 0;
let failed = 0;

async function step(label, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`  ok: ${label}`);
  } catch (error) {
    failed += 1;
    console.error(`  FAIL: ${label}`, error);
  }
}

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      host: FIRESTORE_HOST,
      port: FIRESTORE_PORT,
      rules: readFileSync(RULES_PATH, "utf8"),
    },
  });
  await testEnv.clearFirestore();

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const bobDB = testEnv.authenticatedContext(bobUid).firestore();
  const unauthDB = testEnv.unauthenticatedContext().firestore();

  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const adminDb = ctx.firestore();
    await setDoc(doc(adminDb, "community_leaderboards", "7d_world_world"), {
      window: "7d",
      tier: "world",
      geoKey: "world",
      entries: [],
      belowThreshold: true,
    });
    await setDoc(doc(adminDb, "community_handles", "taken"), { uid: bobUid });
    await setDoc(doc(adminDb, "users", aliceUid, "community", "consent"), { l2Rankings: "granted" });
    await setDoc(doc(adminDb, "users", aliceUid, "community", "profile"), { anonId: "a1" });
    await setDoc(doc(adminDb, "users", aliceUid, "looking_glass_exports", "exp1"), {
      storagePath: "x",
    });
  });

  await step("authenticated read on community_leaderboards", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, "community_leaderboards", "7d_world_world")));
  });

  await step("client write denied on community_leaderboards", async () => {
    await assertFails(
      setDoc(doc(aliceDB, "community_leaderboards", "new_board"), { window: "7d", entries: [] }),
    );
  });

  await step("community_handles read and write denied", async () => {
    await assertFails(getDoc(doc(aliceDB, "community_handles", "taken")));
    await assertFails(setDoc(doc(aliceDB, "community_handles", "newhandle"), { uid: aliceUid }));
  });

  await step("owner read consent; write denied", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, "users", aliceUid, "community", "consent")));
    await assertFails(
      setDoc(doc(aliceDB, "users", aliceUid, "community", "consent"), { l2Rankings: "granted" }),
    );
  });

  await step("non-owner cannot read consent", async () => {
    await assertFails(getDoc(doc(bobDB, "users", aliceUid, "community", "consent")));
  });

  await step("owner read profile; write denied", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, "users", aliceUid, "community", "profile")));
    await assertFails(
      updateDoc(doc(aliceDB, "users", aliceUid, "community", "profile"), { handle: "h" }),
    );
  });

  await step("owner can write share_snapshot", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, "users", aliceUid, "community", "share_snapshot"), shareSnapshotPayload),
    );
  });

  await step("non-owner cannot read or write share_snapshot", async () => {
    await assertFails(getDoc(doc(bobDB, "users", aliceUid, "community", "share_snapshot")));
    await assertFails(
      setDoc(doc(bobDB, "users", aliceUid, "community", "share_snapshot"), shareSnapshotPayload),
    );
  });

  await step("owner read+write looking_glass traces", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, "users", aliceUid, "looking_glass_traces", "trace1"), { sessionId: "s" }),
    );
    await assertSucceeds(getDoc(doc(aliceDB, "users", aliceUid, "looking_glass_traces", "trace1")));
  });

  await step("non-owner denied on looking_glass traces", async () => {
    await assertFails(getDoc(doc(bobDB, "users", aliceUid, "looking_glass_traces", "trace1")));
    await assertFails(
      setDoc(doc(bobDB, "users", aliceUid, "looking_glass_traces", "trace1"), { sessionId: "x" }),
    );
  });

  await step("owner read exports; write denied", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, "users", aliceUid, "looking_glass_exports", "exp1")));
    await assertFails(
      setDoc(doc(aliceDB, "users", aliceUid, "looking_glass_exports", "exp2"), { storagePath: "y" }),
    );
  });

  await step("unauthenticated denied on community_leaderboards", async () => {
    await assertFails(getDoc(doc(unauthDB, "community_leaderboards", "7d_world_world")));
  });

  await testEnv.cleanup();

  const total = passed + failed;
  console.log(`\n${passed}/${total} community rules cases passed`);
  if (failed > 0) process.exit(1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});