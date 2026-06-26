/**
 * Firestore rules tests for the Cloud-Pro monthly allowance meter.
 *
 * The owner reads their own allowance month doc for the console dashboard
 * ("The Wand" fusion card). All writes are server-only (admin SDK), so a client
 * can never mint or mutate its own allowance.
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, getDoc, setDoc, updateDoc, deleteDoc, Timestamp } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-allowance-uid";
const bobUid = "bob-allowance-uid";
const monthKey = "2026-06";
const allowancePath = `users/${aliceUid}/billing/allowances/months/${monthKey}`;

function allowanceDoc(overrides = {}) {
  return {
    schemaVersion: 1,
    includedFusionSearches: 100,
    fusionSearchesUsed: 12,
    topupFusionSearchesPurchased: 0,
    monthlyFusionSearchCap: 1000,
    updatedAt: Timestamp.fromMillis(Date.now()),
    ...overrides,
  };
}

let passed = 0;
let failed = 0;

async function step(label, fn) {
  try {
    await fn();
    console.log(`PASS ${label}`);
    passed += 1;
  } catch (error) {
    console.error(`FAIL ${label}: ${error.message ?? error}`);
    failed += 1;
  }
}

async function main() {
  const testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: FIRESTORE_HOST,
      port: FIRESTORE_PORT,
    },
  });
  await testEnv.clearFirestore();

  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  const bobDB = testEnv.authenticatedContext(bobUid).firestore();
  const unauthDB = testEnv.unauthenticatedContext().firestore();

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), allowancePath), allowanceDoc());
  });

  await step("owner can read their allowance meter", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, allowancePath)));
  });

  await step("other users cannot read the allowance meter", async () => {
    await assertFails(getDoc(doc(bobDB, allowancePath)));
  });

  await step("unauthenticated users cannot read the allowance meter", async () => {
    await assertFails(getDoc(doc(unauthDB, allowancePath)));
  });

  await step("owner cannot create an allowance meter directly", async () => {
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/billing/allowances/months/2026-07`), allowanceDoc()),
    );
  });

  await step("owner cannot mutate their used count directly", async () => {
    await assertFails(updateDoc(doc(aliceDB, allowancePath), { fusionSearchesUsed: 0 }));
  });

  await step("owner cannot delete their allowance meter directly", async () => {
    await assertFails(deleteDoc(doc(aliceDB, allowancePath)));
  });

  await testEnv.cleanup();

  const total = passed + failed;
  console.log(`\n${passed}/${total} cases passed`);
  if (failed > 0) process.exit(1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
