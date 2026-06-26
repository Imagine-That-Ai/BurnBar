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
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  deleteDoc,
  doc,
  getDoc,
  setDoc,
  Timestamp,
} from "firebase/firestore";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

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

const validPhoneAuthorityDoc = {
  id: "ios-phone-authority-1",
  connectionId: "relay-connection-1",
  peerNodeId: "ios-phone-authority-1",
  deviceId: "iphone-1",
  publicKeyBase64: "A".repeat(44),
  publishedAtMillis: Date.now(),
  protocolVersion: 1,
  schemaVersion: 1,
};

const validAuditExportSignerDoc = {
  id: "a".repeat(64),
  userId: aliceUid,
  // Distinct id (not the shared "mac-1") so the "requires a trusted macOS escrow
  // device" negative assertion has a genuinely un-seeded parent — the emulator never
  // clears Firestore between steps, and "mac-1" is seeded trusted/macOS earlier.
  deviceId: "mac-audit-signer-1",
  signerIdentifier: "openburnbar-trusted-device-ed25519-keychain-v1:abc123",
  signerKind: "openburnbar_trusted_device",
  trustRoot: "openburnbar-trusted-device-keychain-v1",
  algorithm: "ed25519",
  publicKeyBase64: "A".repeat(44),
  publicKeySHA256Hex: "a".repeat(64),
  status: "active",
  publishedAtMillis: Date.now(),
  schemaVersion: 1,
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

async function seedEscrowDevice(testEnv, uid, deviceId, trustState = "trusted", platform = "iOS") {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(doc(dbAdmin, `users/${uid}/escrow_devices/${deviceId}`), {
      deviceId,
      deviceName: "Test iPhone",
      platform,
      trustState,
      createdAt: Timestamp.fromMillis(Date.now()),
      updatedAt: Timestamp.fromMillis(Date.now()),
    });
  });
}

async function seedIrohPairing(testEnv, uid, connectionId) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const dbAdmin = ctx.firestore();
    await setDoc(doc(dbAdmin, `users/${uid}/iroh_pairing/${connectionId}`), {
      id: connectionId,
      nodeId: "mac-node-1",
      relayURL: "https://relay.openburnbar.test",
      directAddresses: [],
      publishedAtMillis: Date.now(),
      protocolVersion: 1,
      signature: "sig",
      createdAt: Timestamp.fromMillis(Date.now()),
      updatedAt: Timestamp.fromMillis(Date.now()),
      schemaVersion: 1,
    });
  });
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
      host: FIRESTORE_HOST,
      port: FIRESTORE_PORT,
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

    await step("session create cannot smuggle descriptors, scope rules, or unknown fields", async () => {
      const basePath = `users/${aliceUid}/computer_use_sessions`;
      await assertFails(
        setDoc(doc(aliceDB, `${basePath}/session-create-leak-1`), {
          ...validSessionDoc,
          sessionId: "session-create-leak-1",
          selector: "button[type=submit]",
        })
      );
      await assertFails(
        setDoc(doc(aliceDB, `${basePath}/session-create-leak-2`), {
          ...validSessionDoc,
          sessionId: "session-create-leak-2",
          scopeRules: ["allow browser.click #checkout"],
        })
      );
      await assertFails(
        setDoc(doc(aliceDB, `${basePath}/session-create-leak-3`), {
          ...validSessionDoc,
          sessionId: "session-create-leak-3",
          arbitraryMetadata: "not part of the session contract",
        })
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

    await step("user cannot create action or quota records in another user's namespace", async () => {
      await assertFails(
        setDoc(doc(aliceDB, `users/${bobUid}/computer_use_actions/action-bob`), {
          ...validActionDoc,
          id: "action-bob",
        })
      );
      await assertFails(
        setDoc(doc(aliceDB, `users/${bobUid}/computer_use_quota_usage/2026-05-17`), {
          dayKey: "2026-05-17",
          browserActionsExecuted: 0,
          browserActionsRejected: 0,
          systemActionsExecuted: 0,
          systemActionsRejected: 0,
          phoneControlIntentsExecuted: 0,
          phoneControlIntentsRejected: 0,
          sessionsStarted: 0,
          sessionsCompleted: 0,
          totalSessionSeconds: 0,
          visionModelSpendUSD: 0,
          updatedAt: Timestamp.fromMillis(Date.now()),
        })
      );
    });

    await step("session update cannot mutate userId or add descriptor fields", async () => {
      const path = `users/${aliceUid}/computer_use_sessions/session-1`;
      await assertFails(
        setDoc(
          doc(aliceDB, path),
          {
            ...validSessionDoc,
            userId: bobUid,
          },
          { merge: true }
        )
      );
      await assertFails(setDoc(doc(aliceDB, path), { screenshots: ["plaintext-screen"] }, { merge: true }));
      await assertFails(
        setDoc(
          doc(aliceDB, path),
          {
            actionDescriptors: [{ url: "https://example.test/private" }],
          },
          { merge: true }
        )
      );
    });

    await step("session update cannot mutate mode or trustMode", async () => {
      const path = `users/${aliceUid}/computer_use_sessions/session-1`;
      await assertFails(setDoc(doc(aliceDB, path), { mode: "system" }, { merge: true }));
      await assertFails(setDoc(doc(aliceDB, path), { trustMode: "trusted" }, { merge: true }));
    });

    await step("session update cannot preserve legacy descriptor fields", async () => {
      const path = `users/${aliceUid}/computer_use_sessions/session-legacy-leak`;
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const dbAdmin = ctx.firestore();
        await setDoc(doc(dbAdmin, path), {
          ...validSessionDoc,
          sessionId: "session-legacy-leak",
          selector: "button[type=submit]",
        });
      });
      await assertFails(
        setDoc(
          doc(aliceDB, path),
          {
            endedAt: Timestamp.fromMillis(Date.now()),
            endReason: "completed",
            actionCount: 1,
            approvalCount: 1,
            rejectionCount: 0,
            panicHaltCount: 0,
            visionSpendUSD: 0.02,
            auditHeadHashHex: "b".repeat(64),
            updatedAt: Timestamp.fromMillis(Date.now()),
          },
          { merge: true }
        )
      );
    });

    await step("session end-of-session update with audit head succeeds", async () => {
      await assertSucceeds(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/computer_use_sessions/session-1`),
          {
            endedAt: Timestamp.fromMillis(Date.now()),
            endReason: "completed",
            actionCount: 1,
            approvalCount: 1,
            rejectionCount: 0,
            panicHaltCount: 0,
            visionSpendUSD: 0.02,
            auditHeadHashHex: "b".repeat(64),
            updatedAt: Timestamp.fromMillis(Date.now()),
          },
          { merge: true }
        )
      );
    });

    await step("action with descriptor fields or unknown fields is rejected", async () => {
      const leaky = { ...validActionDoc, selector: "button[type=submit]" };
      await assertFails(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-1`), leaky)
      );
      await assertFails(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-leak-2`), {
          ...validActionDoc,
          id: "action-leak-2",
          screenshots: ["plaintext-screen"],
        })
      );
      await assertFails(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-leak-3`), {
          ...validActionDoc,
          id: "action-leak-3",
          actionDescriptors: [{ url: "https://example.test/private" }],
        })
      );
    });

    await step("action with allowed shape is accepted", async () => {
      await assertSucceeds(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-1`), validActionDoc)
      );
    });

    await step("action spend headers are bounded", async () => {
      await assertSucceeds(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-cost-zero`), {
          ...validActionDoc,
          id: "action-cost-zero",
          visionTokensCostUSD: 0,
        })
      );
      await assertSucceeds(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-cost-ok`), {
          ...validActionDoc,
          id: "action-cost-ok",
          visionTokensCostUSD: 25,
        })
      );
      await assertFails(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-cost-negative`), {
          ...validActionDoc,
          id: "action-cost-negative",
          visionTokensCostUSD: -1,
        })
      );
      await assertFails(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_actions/action-cost-too-high`), {
          ...validActionDoc,
          id: "action-cost-too-high",
          visionTokensCostUSD: 25.01,
        })
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
          sessionsStarted: 0,
          sessionsCompleted: 0,
          totalSessionSeconds: 0,
          visionModelSpendUSD: 0,
          updatedAt: Timestamp.fromMillis(Date.now()),
        })
      );
    });

    await step("quota_usage rejects cross-user and non-contract fields", async () => {
      await assertFails(
        setDoc(doc(aliceDB, `users/${aliceUid}/computer_use_quota_usage/2026-05-18`), {
          dayKey: "2026-05-18",
          browserActionsExecuted: 0,
          browserActionsRejected: 0,
          systemActionsExecuted: 0,
          systemActionsRejected: 0,
          phoneControlIntentsExecuted: 0,
          phoneControlIntentsRejected: 0,
          sessionsStarted: 0,
          sessionsCompleted: 0,
          totalSessionSeconds: 0,
          visionModelSpendUSD: 0,
          updatedAt: Timestamp.fromMillis(Date.now()),
          userId: bobUid,
        })
      );
    });

    await step("iroh pairing trust roots are server-owned", async () => {
      await seedIrohPairing(testEnv, aliceUid, validPhoneAuthorityDoc.connectionId);
      await seedEscrowDevice(testEnv, aliceUid, "mac-1", "trusted", "macOS");
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/iroh_pairing_keys/host`),
          {
            id: "host",
            publicKeyBase64: "A".repeat(44),
            publishedAtMillis: Date.now(),
            protocolVersion: 1,
            schemaVersion: 2,
          }
        )
      );
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/iroh_pairing/new-connection`),
          {
            id: "new-connection",
            nodeId: "attacker-node",
            directAddresses: [],
            publishedAtMillis: Date.now(),
            protocolVersion: 1,
            signature: "A".repeat(44),
            schemaVersion: 2,
          }
        )
      );
    });

    await step("phone-control authority roots are server-owned even for trusted devices", async () => {
      await seedIrohPairing(testEnv, aliceUid, validPhoneAuthorityDoc.connectionId);
      await seedEscrowDevice(testEnv, aliceUid, validPhoneAuthorityDoc.deviceId, "trusted");
      await assertFails(
        setDoc(
          doc(aliceDB, `users/${aliceUid}/iroh_pairing/${validPhoneAuthorityDoc.connectionId}/controllers/${validPhoneAuthorityDoc.peerNodeId}`),
          validPhoneAuthorityDoc
        )
      );
    });

    await step("escrow device metadata can update but identity fields and delete are denied", async () => {
      await seedEscrowDevice(testEnv, aliceUid, "iphone-metadata-1", "trusted");
      const path = `users/${aliceUid}/escrow_devices/iphone-metadata-1`;
      const snap = await getDoc(doc(aliceDB, path));
      const data = snap.data();
      await assertSucceeds(setDoc(doc(aliceDB, path), {
        ...data,
        deviceName: "Renamed iPhone",
        updatedAt: Timestamp.fromMillis(Date.now()),
      }));
      await assertFails(setDoc(doc(aliceDB, path), {
        ...data,
        publicKeyFingerprint: "swapped",
        updatedAt: Timestamp.fromMillis(Date.now()),
      }));
      await assertFails(deleteDoc(doc(aliceDB, path)));
    });

    await step("audit-export signer requires a trusted macOS escrow device", async () => {
      const path = `users/${aliceUid}/escrow_devices/${validAuditExportSignerDoc.deviceId}/computer_use_audit_export_signers/${validAuditExportSignerDoc.publicKeySHA256Hex}`;
      await assertFails(setDoc(doc(aliceDB, path), validAuditExportSignerDoc));
      await seedEscrowDevice(testEnv, aliceUid, validAuditExportSignerDoc.deviceId, "trusted", "macOS");
      await assertSucceeds(setDoc(doc(aliceDB, path), validAuditExportSignerDoc));
      await assertSucceeds(getDoc(doc(aliceDB, path)));
    });

    await step("audit-export signer rejects non-macOS trusted escrow devices", async () => {
      const signer = {
        ...validAuditExportSignerDoc,
        id: "b".repeat(64),
        deviceId: "iphone-audit-signer-1",
        publicKeySHA256Hex: "b".repeat(64),
      };
      const path = `users/${aliceUid}/escrow_devices/${signer.deviceId}/computer_use_audit_export_signers/${signer.publicKeySHA256Hex}`;
      await seedEscrowDevice(testEnv, aliceUid, signer.deviceId, "trusted", "iOS");
      await assertFails(setDoc(doc(aliceDB, path), signer));
    });

    await step("audit-export signer rejects malformed hash, id mismatch, and secret fields", async () => {
      const basePath = `users/${aliceUid}/escrow_devices/${validAuditExportSignerDoc.deviceId}/computer_use_audit_export_signers`;
      await assertFails(setDoc(doc(aliceDB, `${basePath}/not-a-hash`), {
        ...validAuditExportSignerDoc,
        id: "not-a-hash",
        publicKeySHA256Hex: "not-a-hash",
      }));
      await assertFails(setDoc(doc(aliceDB, `${basePath}/${"c".repeat(64)}`), {
        ...validAuditExportSignerDoc,
        id: "c".repeat(64),
        publicKeySHA256Hex: "d".repeat(64),
      }));
      await assertFails(setDoc(doc(aliceDB, `${basePath}/${"e".repeat(64)}`), {
        ...validAuditExportSignerDoc,
        id: "e".repeat(64),
        publicKeySHA256Hex: "e".repeat(64),
        privateKeyBase64: "do-not-store-this",
      }));
    });

    await step("audit-export signer allows revocation update but denies key mutation and delete", async () => {
      const signer = {
        ...validAuditExportSignerDoc,
        id: "f".repeat(64),
        publicKeySHA256Hex: "f".repeat(64),
      };
      const path = `users/${aliceUid}/escrow_devices/${signer.deviceId}/computer_use_audit_export_signers/${signer.publicKeySHA256Hex}`;
      await assertSucceeds(setDoc(doc(aliceDB, path), signer));
      await assertSucceeds(setDoc(doc(aliceDB, path), {
        ...signer,
        status: "revoked",
        revokedAt: Timestamp.fromMillis(Date.now()),
        revokedByDeviceId: signer.deviceId,
      }));
      await assertFails(setDoc(doc(aliceDB, path), {
        ...signer,
        publicKeyBase64: "B".repeat(44),
      }));
      await assertFails(deleteDoc(doc(aliceDB, path)));
    });

    await step("ops/computer_use_budget_status split: public read, metrics operator-only", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        const dbAdmin = ctx.firestore();
        await setDoc(doc(dbAdmin, "ops/computer_use_budget_status/state/current"), {
          level: "normal",
          activeActionsPerRun: 50,
          activeActionsPerDay: 200,
          activeSessionsPerDay: 4,
          perUserDailySpendCeilingUSD: 5,
          updatedAt: Timestamp.now(),
        });
        await setDoc(doc(dbAdmin, "ops/computer_use_budget_status/metrics/current"), {
          level: "normal",
          projectedMonthEndUSD: 100,
          monthToDateUSD: 25,
          updatedAt: Timestamp.now(),
        });
      });

      const operatorDB = testEnv.authenticatedContext("operator-cu", { burnbarOperator: true }).firestore();
      const unauthDB = testEnv.unauthenticatedContext().firestore();

      await assertSucceeds(getDoc(doc(aliceDB, "ops/computer_use_budget_status/state/current")));
      await assertFails(getDoc(doc(aliceDB, "ops/computer_use_budget_status/metrics/current")));
      await assertFails(getDoc(doc(unauthDB, "ops/computer_use_budget_status/state/current")));
      await assertSucceeds(getDoc(doc(operatorDB, "ops/computer_use_budget_status/metrics/current")));

      await assertFails(
        setDoc(doc(aliceDB, "ops/computer_use_budget_status/state/current"), {
          level: "hard_cap",
        })
      );
    });
  });

  // umbrella SKU (pro_max) also unlocks CU
  await step("burnbar_pro_max also unlocks computer-use writes", async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      const dbAdmin = ctx.firestore();
      // remove the per-feature entitlement and grant only the umbrella.
      await setDoc(doc(dbAdmin, `users/${bobUid}/entitlements/burnbar_pro_max`), entitlementGranted("com.openburnbar.proMax.v2.monthly"));
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
