/**
 * Firestore rules tests for the escrow tamper-evidence log (R-S3).
 *
 * escrow_audit_events is an append-only tamper-evidence log. The owner may
 * read and create events, but MUST NOT be able to update or delete history —
 * those paths are `if false` in rules and reconciled server-side (Admin SDK)
 * only. This mirrors the stricter computer_use_actions header, which likewise
 * forbids owner update/delete.
 *
 * escrow_envelopes carries sealed credential ciphertext. The owner may
 * read/create/update, but MUST NOT be able to delete an envelope from the
 * client; retirement flows through a server-only path so escrow history
 * stays intact.
 *
 * Create shape (Mac writer — MacEscrowCredentialProducer.swift:285-294):
 *   { eventType, actorDeviceId, targetDeviceId, providerId, grantId,
 *     envelopeId, timestamp, metadata: { credentialKind } }
 */
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from "@firebase/rules-unit-testing";
import { readFileSync } from "node:fs";
import { doc, getDoc, setDoc, updateDoc, Timestamp, deleteDoc } from "firebase/firestore";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ID = process.env.FIRESTORE_TEST_PROJECT_ID || "burnbar-test";
const RULES_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "..", "firestore.rules");
const FIRESTORE_HOST = process.env.FIRESTORE_TEST_HOST || "127.0.0.1";
const FIRESTORE_PORT = Number.parseInt(process.env.FIRESTORE_TEST_PORT || "8080", 10);

const aliceUid = "alice-escrow-audit-uid";
const bobUid = "bob-escrow-audit-uid";

// Minimal valid audit event (mirrors MacEscrowCredentialProducer.swift:285-294).
function validAuditEvent() {
  return {
    eventType: "envelope_created",
    actorDeviceId: "mac-device-abc123",
    targetDeviceId: "phone-device-xyz789",
    providerId: "anthropic",
    grantId: "grant-1",
    envelopeId: "env-1",
    timestamp: Timestamp.fromMillis(Date.now()),
    metadata: { credentialKind: "api_key" },
  };
}

// Minimal valid envelope (mirrors validEscrowEnvelopeDocument in firestore.rules).
function validEnvelope(envelopeId) {
  return {
    id: envelopeId,
    grantId: "grant-1",
    sourceDeviceId: "mac-device-abc123",
    targetDeviceId: "phone-device-xyz789",
    providerId: "anthropic",
    credentialKind: "api_key",
    ciphertext: "QUJDREVGR0hJSktMTU5PUA==",
    keyVersion: 1,
    envelopeVersion: 1,
    createdAt: Timestamp.fromMillis(Date.now()),
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

  const auditPath = (id) => `users/${aliceUid}/escrow_audit_events/${id}`;
  const envelopePath = (id) => `users/${aliceUid}/escrow_envelopes/${id}`;

  // ── escrow_audit_events: CREATE stays allowed ────────────────────────────
  await step("owner can create an escrow audit event with the Mac-writer shape", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, auditPath("evt-create-1")), validAuditEvent())
    );
  });

  await step("owner can read their own escrow audit events", async () => {
    await assertSucceeds(getDoc(doc(aliceDB, auditPath("evt-create-1"))));
  });

  await step("bob cannot create an audit event in alice's log", async () => {
    await assertFails(
      setDoc(doc(bobDB, auditPath("evt-cross-user")), validAuditEvent())
    );
  });

  // ── escrow_audit_events: UPDATE is forbidden (append-only) ────────────────
  // Seed a pre-existing event with rules disabled so the mutation attempts
  // target a real document rather than failing on a missing-doc precondition.
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), auditPath("evt-immutable")), validAuditEvent());
  });

  await step("owner CANNOT update their own escrow audit event (tamper-evidence)", async () => {
    await assertFails(
      updateDoc(doc(aliceDB, auditPath("evt-immutable")), { eventType: "tampered" })
    );
  });

  await step("owner CANNOT overwrite an existing audit event via merge", async () => {
    await assertFails(
      setDoc(
        doc(aliceDB, auditPath("evt-immutable")),
        { eventType: "tampered" },
        { merge: true }
      )
    );
  });

  await step("owner CANNOT overwrite an existing audit event via full set", async () => {
    await assertFails(
      setDoc(doc(aliceDB, auditPath("evt-immutable")), {
        ...validAuditEvent(),
        eventType: "tampered",
      })
    );
  });

  // ── escrow_audit_events: DELETE is forbidden ─────────────────────────────
  await step("owner CANNOT delete their own escrow audit event (tamper-evidence)", async () => {
    await assertFails(
      deleteDoc(doc(aliceDB, auditPath("evt-immutable")))
    );
  });

  // ── escrow_envelopes: CREATE stays allowed, DELETE is forbidden ──────────
  await step("owner can create a sealed escrow envelope", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, envelopePath("env-create-1")), validEnvelope("env-create-1"))
    );
  });

  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), envelopePath("env-immutable")), validEnvelope("env-immutable"));
  });

  await step("owner CANNOT delete a sealed escrow envelope (server-only retirement)", async () => {
    await assertFails(
      deleteDoc(doc(aliceDB, envelopePath("env-immutable")))
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
