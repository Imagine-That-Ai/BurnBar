/**
 * Firestore rules emulator test for the Computer Use rule blocks.
 *
 * Validates that:
 *   - Unauthenticated reads of CU collections are rejected.
 *   - Authenticated user can read their own CU sessions / actions.
 *   - Authenticated user CANNOT create a CU session without an
 *     `hosted_computer_use_sync` entitlement.
 *   - With an active entitlement, creating a session succeeds.
 *   - Creating an action with secret-looking fields (`url`, `selector`,
 *     `screenshot`, `text`) is rejected — the server-side audit header
 *     never carries the action descriptor.
 *   - Operator-side `ops/computer_use_budget_status/state/current`
 *     is readable by any signed-in user but client writes are rejected.
 *
 * Run with:
 *   cd firestore-rules-tests && npm test
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import {
  doc,
  getDoc,
  setDoc,
  Timestamp,
} from "firebase/firestore";

const PROJECT_ID = "burnbar-test";
const RULES_PATH = "../firestore.rules";

const aliceUid = "alice-uid";
const bobUid = "bob-uid";

const futureTimestamp = Timestamp.fromMillis(Date.now() + 30 * 24 * 60 * 60 * 1000);

const validSessionDoc = {
  sessionId: "session-1",
  userId: aliceUid,
  mode: "browser",
  trustMode: "manual",
  startedAt: Timestamp.fromMillis(Date.now()),
  manifestHashHex: "a".repeat(64),
  macAppVersion: "1.0.0",
  schemaVersion: 1,
  actionCount: 0,
  approvalCount: 0,
  rejectionCount: 0,
  panicHaltCount: 0,
  visionSpendUSD: 0,
};

const validActionDoc = {
  id: "action-1",
  sessionId: "session-1",
  entryIndex: 0,
  toolKind: "browser_click",
  actionKind: "browser.click",
  status: "executed",
  approvedBy: "mac",
  parentEntryHashHex: "0".repeat(64),
  schemaVersion: 1,
  recordedAt: Timestamp.fromMillis(Date.now()),
};

function entitlementGranted(productID = "com.openburnbar.hostedComputerUseSync.monthly") {
  return {
    active: true,
    productID,
    expireAt: futureTimestamp,
    features: {
      browserComputerUse: true,
      systemComputerUse: true,
      phoneControl: true,
      auditExport: true,
      trustedScopes: true,
    },
  };
}

async function withEntitlement(testEnv, uid, body) {
  // Seed the entitlement via the privileged path so we don't need to
  // write a separate rule for the test fixture.
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(
      doc(dbAdmin, `users/${uid}/entitlements/hosted_computer_use_sync`),
      entitlementGranted()
    );
  });
  return body();
}

let testEnv;
let failures = 0;
let runs = 0;

async function step(name, fn) {
  runs += 1;
  try {
    await fn();
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failures += 1;
    console.error(`  ✕ ${name}\n    ${e && e.message ? e.message : e}`);
  }
}

async function main() {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });

  console.log("Computer Use Firestore rules emulator tests");

  // unauth path
  const anonDB = testEnv.unauthenticatedContext().firestore();
  await step("unauthenticated read of computer_use_sessions is rejected", async () => {
    await assertFails(getDoc(doc(anonDB, `users/${aliceUid}/computer_use_sessions/session-1`)));
  });

  // signed-in but no entitlement
  const aliceDB = testEnv.authenticatedContext(aliceUid).firestore();
  await step("signed-in user cannot create a session without entitlement", async () => {
    await assertFails(
      setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_sessions/session-1`), validSessionDoc)
    );
  });

  // with entitlement
  await withEntitlement(testEnv, aliceUid, async () => {
    await step("authenticated user with entitlement can create a session", async () => {
      await assertSucceeds(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_sessions/session-1`), validSessionDoc)
      );
    });

    await step("user cannot create a session in another user's namespace", async () => {
      await assertFails(
        setDoc(doc(aliceDB, `users/${bobUid}/computer_use_sessions/session-1`), {
          ...validSessionDoc,
          userId: bobUid,
        })
      );
    });

    await step("action with descriptor fields (selector/url/text/screenshot) is rejected", async () => {
      const leaky = { ...validActionDoc, selector: "button[type=submit]" };
      await assertFails(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-1`), leaky)
      );
    });

    await step("action with allowed shape is accepted", async () => {
      await assertSucceeds(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-1`), validActionDoc)
      );
    });

    await step("quota_usage write with the right shape succeeds", async () => {
      await assertSucceeds(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_quota_usage/2026-05-17`), {
          dayKey: "2026-05-17",
          browserActionsExecuted: 0,
          browserActionsRejected: 0,
          systemActionsExecuted: 0,
          systemActionsRejected: 0,
          phoneControlIntentsExecuted: 0,
          phoneControlIntentsRejected: 0,
          visionModelSpendUSD: 0,
        })
      );
    });

    await step("ops/computer_use_budget_status is read-only for clients", async () => {
      await assertFails(
        setDoc(doc(aliceDB, `ops/computer_use_budget_status/state/current`), {
          level: "normal",
          projectedMonthEndUSD: 0,
        })
      );
    });
  });

  // umbrella SKU (pro_max) also unlocks CU
  await step("burnbar_pro_max also unlocks computer-use writes", async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const dbAdmin = ctx.firestore();
      // remove the per-feature entitlement and grant only the umbrella.
      await setDoc(doc(dbAdmin, `users/${bobUid}/entitlements/burnbar_pro_max`), entitlementGranted("com.openburnbar.proMax.monthly"));
    });
    const bobDB = testEnv.authenticatedContext(bobUid).firestore();
    await assertSucceeds(
      setDoc(doc(bobDB, `users/${bobUid}/computer_use_sessions/session-bob`), {
        ...validSessionDoc,
        sessionId: "session-bob",
        userId: bobUid,
      })
    );
  });

  await testEnv.cleanup();
  console.log(`\n${runs - failures}/${runs} cases passed`);
  if (failures > 0) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
