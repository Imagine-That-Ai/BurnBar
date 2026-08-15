/**
 * Firestore rules tests for the Memory Power-Up wallet.
 *
 * The owner reads `memoryWallet/current` for the store UI. Grants, the ledger,
 * and all writes are server-only.
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

const aliceUid = "alice-memory-wallet-uid";
const bobUid = "bob-memory-wallet-uid";
const walletPath = `users/${aliceUid}/memoryWallet/current`;
const grantPath = `users/${aliceUid}/memoryWallet/current/grants/stripe_cs_test`;
const ledgerPath = `users/${aliceUid}/memoryWalletLedger/debit_res1`;

function walletDoc() {
  return {
    schemaVersion: 1,
    textTokens: 1_000_000,
    multimodalTokens: 0,
    pendingTextTokens: 0,
    pendingMultimodalTokens: 0,
    updatedAt: Timestamp.fromMillis(Date.now()),
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
    await setDoc(doc(context.firestore(), walletPath), walletDoc());
    await setDoc(doc(context.firestore(), grantPath), { remainingTokens: 1_000_000 });
    await setDoc(doc(context.firestore(), ledgerPath), { type: "debit", tokens: 1 });
  });

  await step("owner can read their memory wallet cache", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, walletPath)));
  });

  await step("other users cannot read the memory wallet cache", async () => {
    await assertFails(getDoc(doc(bobDB, walletPath)));
  });

  await step("unauthenticated users cannot read the memory wallet cache", async () => {
    await assertFails(getDoc(doc(unauthDB, walletPath)));
  });

  await step("owner cannot mint wallet credits", async () => {
    await assertFails(setDoc(doc(aliceDB, walletPath), { textTokens: 99_000_000 }));
  });

  await step("owner cannot mutate wallet credits", async () => {
    await assertFails(updateDoc(doc(aliceDB, walletPath), { textTokens: 0 }));
  });

  await step("owner cannot delete the wallet cache", async () => {
    await assertFails(deleteDoc(doc(aliceDB, walletPath)));
  });

  await step("owner cannot read grant documents", async () => {
    await assertFails(getDoc(doc(aliceDB, grantPath)));
  });

  await step("owner cannot read the memory wallet ledger", async () => {
    await assertFails(getDoc(doc(aliceDB, ledgerPath)));
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
