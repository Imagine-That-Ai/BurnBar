/**
 * Firestore rules tests for Mac -> mobile provider account and quota sync.
 *
 * The macOS app writes non-secret ProviderAccountDoc metadata before quota
 * snapshots. A schema mismatch here suppresses the following quota snapshot
 * sync, so this test pins the documented provider_accounts wire shape.
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

const aliceUid = "alice-provider-sync-uid";
const bobUid = "bob-provider-sync-uid";
const accountId = "anthropic-204e35be-aeb2-4f5e-984b-bd5d5025fc5a";
const nowISO = "2026-07-03T05:15:00Z";

function providerAccountDoc(overrides = {}) {
  return {
    id: accountId,
    providerID: "anthropic",
    label: "Claude Code",
    status: "connected",
    credentialKind: "bearer",
    storageScope: "device_keychain",
    redactedLabel: "Stored in Mac Keychain",
    sourceDeviceID: "mac-device-1",
    isDefault: true,
    sortKey: 0,
    lastRefreshAt: nowISO,
    schemaVersion: 1,
    createdAt: nowISO,
    updatedAt: nowISO,
    ...overrides,
  };
}

function quotaSnapshotDoc(overrides = {}) {
  return {
    provider: "claude-code",
    providerID: "anthropic",
    sourceKind: "localCLI",
    sourceId: "mac-device-1",
    sourceID: "mac-device-1",
    source: "Claude Code",
    fetchedAt: Timestamp.fromMillis(Date.now()),
    confidence: "exact",
    statusMessage: "Claude quota from local session.",
    buckets: [
      {
        name: "claude-5h",
        used: 18,
        limit: 100,
        remaining: 82,
        window: "rollingHours",
        meta: { label: "5-hour window", unit: "percent" },
      },
    ],
    schemaVersion: 1,
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
  const accountPath = `users/${aliceUid}/provider_accounts/${accountId}`;
  const quotaPath = `users/${aliceUid}/quota_snapshots/anthropic_${accountId}_mac-device-1`;

  await step("owner can write documented provider account metadata", async () => {
    await assertSucceeds(setDoc(doc(aliceDB, accountPath), providerAccountDoc()));
  });

  await step("provider account write rejects legacy deviceId alias", async () => {
    await assertFails(setDoc(doc(aliceDB, accountPath), providerAccountDoc({ deviceId: "mac-device-1" })));
  });

  await step("provider account write rejects syncedAt field", async () => {
    await assertFails(setDoc(doc(aliceDB, accountPath), providerAccountDoc({ syncedAt: Timestamp.fromMillis(Date.now()) })));
  });

  await step("provider account write rejects timestamp dates", async () => {
    await assertFails(
      setDoc(doc(aliceDB, accountPath), providerAccountDoc({ createdAt: Timestamp.fromMillis(Date.now()) }))
    );
  });

  await step("other users cannot write into the provider account namespace", async () => {
    await assertFails(setDoc(doc(bobDB, accountPath), providerAccountDoc()));
  });

  await step("owner can write quota snapshot after provider metadata", async () => {
    await assertSucceeds(setDoc(doc(aliceDB, quotaPath), quotaSnapshotDoc()));
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
