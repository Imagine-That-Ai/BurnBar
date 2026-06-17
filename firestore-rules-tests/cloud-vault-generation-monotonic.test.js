/**
 * Firestore rules tests for V-41 — CloudVault rotation generation is monotonic
 * non-decreasing at the rules layer (defense-in-depth behind the server-only
 * `rotateCloudVaultKey` callable, which enforces strict generation = current+1).
 *
 * `users/{uid}/cloud_vault_state/current` is client-writable, and client writes
 * are pinned to the CURRENT `vaultKeyID` (rotation is server-only). The new
 * `vaultGenerationMonotonic()` guard additionally proves a client can never:
 *   - roll `vaultGeneration` BACKWARD (rollback / replay of an older generation), or
 *   - DROP the `vaultGeneration` field once recorded, then launder a lower value
 *     back in on a subsequent write.
 * A legacy doc that never carried a generation may adopt one (first-set); from
 * then on it can only climb. Equal (idempotent / metadata-only) writes are allowed.
 *
 * Run with:
 *   cd firestore-rules-tests && npm run test:cloud-vault-generation-monotonic
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, setDoc, Timestamp } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-uid";
const vaultKeyID = "v1_" + "a".repeat(32);

// A full, rules-valid `cloud_vault_state/current` document. `vaultGeneration` is
// applied only when the override key is present (so we can also build the
// legacy "no generation" shape and the "generation removed" shape).
function stateDoc(overrides = {}) {
  const base = {
    uid: aliceUid,
    vaultKeyID,
    keyVersion: 1,
    algorithm: "AES-256-GCM",
    status: "active",
    createdByDeviceId: "mac-1",
    createdAt: Timestamp.fromMillis(Date.now()),
    updatedAt: Timestamp.fromMillis(Date.now()),
    schemaVersion: 2,
  };
  const doced = { ...base, ...overrides };
  if (overrides.vaultGeneration === undefined && !("vaultGeneration" in overrides)) {
    // default: include a generation unless the caller explicitly omits it
    doced.vaultGeneration = 2;
  }
  if (overrides.vaultGeneration === null) {
    delete doced.vaultGeneration; // explicit "no generation field" shape
  }
  return doced;
}

let testEnv;
let runs = 0;
let failures = 0;

async function step(name, fn) {
  runs += 1;
  try {
    await fn();
    console.log(`PASS ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}`);
    console.error(error);
  }
}

const statePath = `users/${aliceUid}/cloud_vault_state/current`;

async function seedCurrent(overrides) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), statePath), stateDoc(overrides));
  });
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

  const aliceDB = () => testEnv.authenticatedContext(aliceUid).firestore();

  await step("CREATE first vault state with a generation succeeds", async () => {
    await testEnv.clearFirestore();
    await assertSucceeds(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: 1 })));
  });

  await step("UPDATE bumping generation forward (5 -> 6) succeeds", async () => {
    await testEnv.clearFirestore();
    await seedCurrent({ vaultGeneration: 5 });
    await assertSucceeds(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: 6 })));
  });

  await step("UPDATE keeping the same generation (idempotent/metadata) succeeds", async () => {
    await testEnv.clearFirestore();
    await seedCurrent({ vaultGeneration: 5 });
    await assertSucceeds(
      setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: 5, createdByDeviceId: "mac-2" }))
    );
  });

  await step("UPDATE rolling generation BACKWARD (5 -> 3) is rejected", async () => {
    await testEnv.clearFirestore();
    await seedCurrent({ vaultGeneration: 5 });
    await assertFails(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: 3 })));
  });

  await step("UPDATE DROPPING the generation field once recorded is rejected (anti-laundering)", async () => {
    await testEnv.clearFirestore();
    await seedCurrent({ vaultGeneration: 5 });
    // null override => stateDoc emits a doc with NO vaultGeneration field.
    await assertFails(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: null })));
  });

  await step("UPDATE with a non-int generation is rejected", async () => {
    await testEnv.clearFirestore();
    await seedCurrent({ vaultGeneration: 5 });
    await assertFails(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: "6" })));
  });

  await step("LEGACY doc with no generation may first-set a generation", async () => {
    await testEnv.clearFirestore();
    await seedCurrent({ vaultGeneration: null }); // legacy: current exists, no generation
    await assertSucceeds(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: 7 })));
  });

  await step("after first-set on a legacy doc, rolling backward is rejected", async () => {
    await testEnv.clearFirestore();
    await seedCurrent({ vaultGeneration: null });
    await assertSucceeds(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: 7 })));
    await assertFails(setDoc(doc(aliceDB(), statePath), stateDoc({ vaultGeneration: 6 })));
  });

  await testEnv.cleanup();
  console.log(`\n${runs - failures}/${runs} cases passed`);
  if (failures > 0) process.exit(1);
}

main().catch(async (error) => {
  console.error(error);
  if (testEnv) await testEnv.cleanup();
  process.exit(2);
});
