/**
 * Firestore rules tests for Mercury media budget split (ADR 006).
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, getDoc, setDoc, Timestamp } from "firebase/firestore";

const PROJECT_ID = "burnbar-test";
const rules = readFileSync(new URL("../firestore.rules", import.meta.url), "utf8");

const aliceUid = "alice-media-budget";
const operatorUid = "operator-media-budget";

function authed(uid, claims = {}) {
  return testEnv.authenticatedContext(uid, claims).firestore();
}

let testEnv;

async function seedOperatorClaim(uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    // Claims are injected via authenticatedContext in tests — no seed needed.
  });
}

console.log("media-budget rules tests");

testEnv = await initializeTestEnvironment({
  projectId: PROJECT_ID,
  firestore: { rules, host: "127.0.0.1", port: 8080 },
});

await testEnv.clearFirestore();

const publicDoc = {
  level: "normal",
  lastEvaluatedAt: Timestamp.now(),
  activeEnvelope: {
    screenShareDailyMinutes: 120,
    screenSharePerSessionMinutes: 60,
    videoCallDailyMinutes: 240,
    videoCallPerCallMinutes: 30,
    fileTransferDailyGBIn: 5,
    fileTransferDailyGBOut: 5,
  },
  schemaVersion: 1,
};

const metricsDoc = {
  level: "normal",
  projectedMonthEndUSD: 42.5,
  monthToDateUSD: 10.2,
  lastEvaluatedAt: Timestamp.now(),
};

await testEnv.withSecurityRulesDisabled(async (ctx) => {
  const admin = ctx.firestore();
  await setDoc(doc(admin, "ops/media_budget_status/state/current"), publicDoc);
  await setDoc(doc(admin, "ops/media_budget_status/metrics/current"), metricsDoc);
});

const aliceDB = authed(aliceUid);
const operatorDB = authed(operatorUid, { burnbarOperator: true });
const unauthDB = testEnv.unauthenticatedContext().firestore();

await assertSucceeds(getDoc(doc(aliceDB, "ops/media_budget_status/state/current")));
await assertFails(getDoc(doc(aliceDB, "ops/media_budget_status/metrics/current")));
await assertFails(getDoc(doc(unauthDB, "ops/media_budget_status/state/current")));
await assertFails(getDoc(doc(unauthDB, "ops/media_budget_status/metrics/current")));
await assertSucceeds(getDoc(doc(operatorDB, "ops/media_budget_status/metrics/current")));

await assertFails(
  setDoc(doc(aliceDB, "ops/media_budget_status/state/current"), {
    level: "hard_cap",
  })
);

console.log("media-budget: all assertions passed");
await testEnv.cleanup();
