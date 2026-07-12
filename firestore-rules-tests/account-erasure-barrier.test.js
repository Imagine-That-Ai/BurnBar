import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { deleteDoc, doc, getDoc, setDoc } from "firebase/firestore";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-erasure-barrier";
const bobUid = "bob-erasure-barrier";

const testEnv = await initializeTestEnvironment({
  projectId: PROJECT_ID,
  firestore: {
    rules: readFileSync(RULES_PATH, "utf8"),
    host: FIRESTORE_HOST,
    port: FIRESTORE_PORT,
  },
});

try {
  await testEnv.clearFirestore();
  const alice = testEnv.authenticatedContext(aliceUid).firestore();
  const bob = testEnv.authenticatedContext(bobUid).firestore();
  const aliceProfile = doc(alice, `users/${aliceUid}`);
  const bobProfile = doc(bob, `users/${bobUid}`);

  await assertSucceeds(setDoc(aliceProfile, { uid: aliceUid, schemaVersion: 1 }));
  await assertSucceeds(setDoc(bobProfile, { uid: bobUid, schemaVersion: 1 }));

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `account_erasure_tombstones/${aliceUid}`), {
      schemaVersion: 2,
      pending: true,
    });
  });

  await assertFails(getDoc(aliceProfile));
  await assertFails(setDoc(aliceProfile, { uid: aliceUid, schemaVersion: 2 }));
  await assertFails(deleteDoc(aliceProfile));
  await assertFails(getDoc(doc(alice, `account_erasure_tombstones/${aliceUid}`)));
  await assertFails(setDoc(doc(alice, `account_erasure_tombstones/${aliceUid}`), { pending: false }));

  await assertSucceeds(getDoc(bobProfile));
  await assertSucceeds(setDoc(bobProfile, { uid: bobUid, schemaVersion: 2 }));
  console.log("account-erasure Firestore write barrier tests passed");
} finally {
  await testEnv.cleanup();
}
