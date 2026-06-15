/**
 * Firestore rules tests for escrow_grants field allowlist (F-RR07-006).
 *
 * The escrow_grants collection carries credential-transfer authorisations.
 * Before this fix the rule accepted any key set; now it uses hasOnly on both
 * create and update.
 *
 * Create shape (Mac writer — MacEscrowCredentialProducer.swift):
 *   { sourceDeviceId, targetDeviceId, providerId, credentialKind, status, grantedAt }
 *
 * Update shape (server revoke merge-patch — computerUseSecurity.ts revokeEscrowDeviceTrust):
 *   { status, revokedAt }  (affectedKeys only)
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, setDoc, updateDoc, Timestamp, deleteDoc } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-escrow-uid";
const bobUid = "bob-escrow-uid";

// Minimal valid create payload (mirrors MacEscrowCredentialProducer.swift:244-251)
function validGrantDoc() {
  return {
    sourceDeviceId: "mac-device-abc123",
    targetDeviceId: "phone-device-xyz789",
    providerId: "anthropic",
    credentialKind: "api_key",
    status: "granted",
    grantedAt: Timestamp.fromMillis(Date.now()),
  };
}

let passed = 0;
let failed = 0;

async function step(label, fn) {
  try {
    await fn();
    console.log(`PASS ${label}`);
    passed++;
  } catch (err) {
    console.error(`FAIL ${label}: ${err.message ?? err}`);
    failed++;
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

  const grantPath = (id) => `users/${aliceUid}/escrow_grants/${id}`;

  // ── CREATE: legit shape ──────────────────────────────────────────────────
  await step("owner can create an escrow grant with the exact Mac-writer shape", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, grantPath("grant-1")), validGrantDoc())
    );
  });

  // ── CREATE: extra unknown field is rejected ──────────────────────────────
  await step("create with an extra unknown field is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, grantPath("grant-extra-1")), {
        ...validGrantDoc(),
        arbitraryBlob: "attacker-controlled data",
      })
    );
  });

  await step("create smuggling a ciphertext field is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, grantPath("grant-extra-2")), {
        ...validGrantDoc(),
        encryptedPayload: ["not", "allowed"],
      })
    );
  });

  await step("create with a plaintext api_key field is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, grantPath("grant-extra-3")), {
        ...validGrantDoc(),
        apiCredential: ["not", "allowed"],
      })
    );
  });

  // ── CREATE: required field missing is rejected ───────────────────────────
  await step("create without credentialKind is rejected", async () => {
    const { credentialKind, ...missing } = validGrantDoc();
    await assertFails(
      setDoc(doc(aliceDB, grantPath("grant-missing-1")), missing)
    );
  });

  await step("create without grantedAt is rejected", async () => {
    const { grantedAt, ...missing } = validGrantDoc();
    await assertFails(
      setDoc(doc(aliceDB, grantPath("grant-missing-2")), missing)
    );
  });

  // ── CREATE: bad enum values ──────────────────────────────────────────────
  await step("create with unknown credentialKind is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, grantPath("grant-badenum-1")), {
        ...validGrantDoc(),
        credentialKind: "ssh_key",
      })
    );
  });

  await step("create with status revoked is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, grantPath("grant-badstatus-1")), {
        ...validGrantDoc(),
        status: "revoked",
      })
    );
  });

  // ── CREATE: cross-user is rejected ───────────────────────────────────────
  await step("bob cannot write to alice's escrow_grants", async () => {
    await assertFails(
      setDoc(doc(bobDB, grantPath("grant-1")), validGrantDoc())
    );
  });

  await step("unauthenticated user cannot write escrow_grants", async () => {
    await assertFails(
      setDoc(doc(unauthDB, grantPath("grant-unauth")), validGrantDoc())
    );
  });

  // ── UPDATE: seed a legit grant first ────────────────────────────────────
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), grantPath("grant-to-revoke")), validGrantDoc());
    await setDoc(doc(ctx.firestore(), grantPath("grant-stable")), validGrantDoc());
  });

  // ── UPDATE: valid server-revoke patch ────────────────────────────────────
  await step("owner can apply the server-revoke patch (status + revokedAt)", async () => {
    await assertSucceeds(
      setDoc(
        doc(aliceDB, grantPath("grant-to-revoke")),
        { status: "revoked", revokedAt: Timestamp.fromMillis(Date.now()) },
        { merge: true }
      )
    );
  });

  await step("owner cannot change status back to granted on a revoked grant", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, grantPath("grant-to-revoke")),
        { status: "granted" },
        { merge: true }
      )
    );
  });

  await step("owner cannot update a grant that is already revoked", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, grantPath("grant-to-revoke")),
        { revokedAt: Timestamp.fromMillis(Date.now() + 1000) },
        { merge: true }
      )
    );
  });

  // ── UPDATE: extra field on revoke is rejected ────────────────────────────
  await step("update cannot add an extra field beyond status+revokedAt", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, grantPath("grant-stable")),
        {
          status: "revoked",
          revokedAt: Timestamp.fromMillis(Date.now()),
          maliciousField: "injected",
        },
        { merge: true }
      )
    );
  });

  await step("update cannot change sourceDeviceId", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, grantPath("grant-stable")),
        { sourceDeviceId: "attacker-device" },
        { merge: true }
      )
    );
  });

  // ── DELETE: owner can delete ─────────────────────────────────────────────
  await step("owner can delete an escrow grant", async () => {
    await assertSucceeds(
      deleteDoc(doc(aliceDB, grantPath("grant-1")))
    );
  });

  await step("bob cannot delete alice's escrow grant", async () => {
    await assertFails(
      deleteDoc(doc(bobDB, grantPath("grant-to-revoke")))
    );
  });

  // ── READ ─────────────────────────────────────────────────────────────────
  await step("owner can read their escrow grants", async () => {
    const { getDoc } = await import("firebase/firestore");
    await assertSucceeds(
      getDoc(doc(aliceDB, grantPath("grant-stable")))
    );
  });

  await step("bob cannot read alice's escrow grants", async () => {
    const { getDoc } = await import("firebase/firestore");
    await assertFails(
      getDoc(doc(bobDB, grantPath("grant-stable")))
    );
  });

  await testEnv.cleanup();

  const total = passed + failed;
  console.log(`\n${passed}/${total} cases passed`);
  if (failed > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
