/**
 * Linux App Check enrollment and challenge records are callable-only state.
 * The Admin SDK may manage them, but no Firebase client may read or mutate them.
 */
import { initializeTestEnvironment, assertFails } from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deleteDoc, doc, getDoc, setDoc, updateDoc } from "firebase/firestore";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);
const ownerUid = "linux-owner";
const otherUid = "linux-other";

let testEnv;
let runs = 0;
let failures = 0;

async function step(name, operation) {
  runs += 1;
  try {
    await operation();
    console.log(`PASS ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}`);
    console.error(error);
  }
}

async function assertClientCannotAccess(db, path) {
  const reference = doc(db, path);
  await assertFails(getDoc(reference));
  await assertFails(setDoc(reference, { injected: true }));
  await assertFails(updateDoc(reference, { injected: true }));
  await assertFails(deleteDoc(reference));
}

async function main() {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: FIRESTORE_HOST,
      port: FIRESTORE_PORT,
    },
  });
  await testEnv.clearFirestore();

  const devicePath = `users/${ownerUid}/linux_app_check_devices/linux_device`;
  const challengePath = `users/${ownerUid}/linux_app_check_challenges/challenge`;
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, devicePath), { status: "approved" });
    await setDoc(doc(db, challengePath), { consumed: false });
  });

  const ownerDb = testEnv.authenticatedContext(ownerUid).firestore();
  const otherDb = testEnv.authenticatedContext(otherUid).firestore();
  const anonymousDb = testEnv.unauthenticatedContext().firestore();

  await step("owner cannot bypass callable-only Linux App Check state", async () => {
    await assertClientCannotAccess(ownerDb, devicePath);
    await assertClientCannotAccess(ownerDb, challengePath);
  });
  await step("other users cannot access Linux App Check state", async () => {
    await assertClientCannotAccess(otherDb, devicePath);
    await assertClientCannotAccess(otherDb, challengePath);
  });
  await step("anonymous clients cannot access Linux App Check state", async () => {
    await assertClientCannotAccess(anonymousDb, devicePath);
    await assertClientCannotAccess(anonymousDb, challengePath);
  });
}

try {
  await main();
} finally {
  await testEnv?.cleanup();
}

console.log(`\n${runs - failures}/${runs} Linux App Check rules checks passed`);
if (failures > 0) process.exitCode = 1;
