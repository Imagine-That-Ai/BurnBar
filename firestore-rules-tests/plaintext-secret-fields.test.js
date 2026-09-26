/**
 * Firestore rules tests for the plaintext-secret denylist
 * (hasNoPlaintextSecretFields in firestore.rules).
 *
 * Owner-writable collections without a strict key allowlist
 * (devices, provider_connections, cloud_profile/*, escrow_audit_events, ...)
 * rely on the denylist as the backstop against persisting cleartext
 * credentials. The denylist has two layers:
 *   1. Flat: top-level document keys must not name a secret field
 *      (camelCase and snake_case twins).
 *   2. Nested: one level down inside known container maps (metadata,
 *      detail, encryption, config, data, payload, params) the same names
 *      are rejected.
 *
 * `users/{uid}/devices/{id}` carries the flat/container probes because its
 * write rule is the deep variant ownerWritableNonSecretDeep (no key
 * allowlist); `escrow_audit_events` covers the real nested `metadata`
 * writer shape (MacEscrowCredentialProducer.swift). One probe per remaining
 * deep-checked collection (usage, budgetRules, cloud_profile) locks the
 * swap against regressions.
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

const aliceUid = "alice-plaintext-denylist-uid";

// Every name the flat denylist must reject (original 12 + extensions).
const DENIED_TOP_LEVEL_KEYS = [
  "apiKey",
  "api_key",
  "token",
  "refreshToken",
  "refresh_token",
  "accessToken",
  "access_token",
  "idToken",
  "id_token",
  "authToken",
  "auth_token",
  "sessionToken",
  "session_token",
  "clientSecret",
  "client_secret",
  "apiSecret",
  "api_secret",
  "appSecret",
  "app_secret",
  "cookie",
  "password",
  "passphrase",
  "mnemonic",
  "seedPhrase",
  "seed_phrase",
  "secret",
  "secretVersionName",
  "otpSecret",
  "totpSecret",
  "totp_secret",
  "webhookSecret",
  "webhook_secret",
  "signingKey",
  "signing_key",
  "privateKey",
  "private_key",
  "encryptionKey",
  "encryption_key",
  "authorization",
  "bearer",
  "credential",
];

// Near-miss keys the exact-match backstop intentionally still allows.
const ALLOWED_NEAR_MISS_KEYS = [
  "tokenUsage",
  "credentialKind",
  "publicKeyBase64",
  "apiKeyHash",
  "secretVersion",
];

const NESTED_CONTAINERS = ["metadata", "detail", "encryption", "config", "data", "payload", "params"];

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

  const devicePath = (id) => `users/${aliceUid}/devices/${id}`;
  const auditPath = (id) => `users/${aliceUid}/escrow_audit_events/${id}`;
  const usagePath = (id) => `users/${aliceUid}/usage/${id}`;
  const budgetRulePath = (id) => `users/${aliceUid}/budgetRules/${id}`;
  const cloudProfilePath = (id) => `users/${aliceUid}/cloud_profile/${id}`;

  // ── Flat layer ──────────────────────────────────────────────────────
  await step("owner can write a device doc with benign keys", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, devicePath("device-benign")), {
        deviceId: "mac-device-abc123",
        platform: "macOS",
        appVersion: "1.2.3",
        updatedAt: Timestamp.fromMillis(Date.now()),
      })
    );
  });

  for (const key of DENIED_TOP_LEVEL_KEYS) {
    await step(`device write carrying top-level "${key}" is rejected`, async () => {
      await assertFails(
        setDoc(doc(aliceDB, devicePath(`device-flat-${key}`)), {
          deviceId: "mac-device-abc123",
          [key]: "super-secret-value",
        })
      );
    });
  }

  for (const key of ALLOWED_NEAR_MISS_KEYS) {
    await step(`device write carrying near-miss "${key}" still succeeds`, async () => {
      await assertSucceeds(
        setDoc(doc(aliceDB, devicePath(`device-nearmiss-${key}`)), {
          deviceId: "mac-device-abc123",
          [key]: "opaque-non-secret-value",
        })
      );
    });
  }

  // ── Nested layer: real escrow audit-event shape ─────────────────────
  await step("escrow audit event with benign nested metadata succeeds", async () => {
    await assertSucceeds(setDoc(doc(aliceDB, auditPath("evt-benign-metadata")), validAuditEvent()));
  });

  await step("escrow audit event with metadata.apiKey is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, auditPath("evt-nested-apikey")), {
        ...validAuditEvent(),
        metadata: { credentialKind: "api_key", apiKey: "sk-ant-secret" },
      })
    );
  });

  await step("escrow audit event with metadata.client_secret is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, auditPath("evt-nested-client-secret")), {
        ...validAuditEvent(),
        metadata: { client_secret: "secret-value" },
      })
    );
  });

  await step("escrow audit event with non-map metadata still succeeds", async () => {
    // Non-map container values bypass the nested check (nothing to descend
    // into), so a plain string metadata MUST succeed.
    await assertSucceeds(
      setDoc(doc(aliceDB, auditPath("evt-string-metadata")), {
        ...validAuditEvent(),
        metadata: "apiKey",
      })
    );
  });

  // ── Nested layer: every container on the allowlist-free devices rule ──
  for (const container of NESTED_CONTAINERS) {
    await step(`device write with ${container}.{refreshToken} is rejected`, async () => {
      await assertFails(
        setDoc(doc(aliceDB, devicePath(`device-nested-${container}`)), {
          deviceId: "mac-device-abc123",
          [container]: { refreshToken: "refresh-secret-value" },
        })
      );
    });

    await step(`device write with benign ${container} map still succeeds`, async () => {
      await assertSucceeds(
        setDoc(doc(aliceDB, devicePath(`device-nested-benign-${container}`)), {
          deviceId: "mac-device-abc123",
          [container]: { credentialKind: "api_key", schemaVersion: 1 },
        })
      );
    });
  }

  // ── Remaining deep-checked collections (swap locks) ───────────────────
  await step("usage create with benign keys succeeds", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, usagePath("usage-benign")), {
        provider: "anthropic",
        messageCount: 1,
      })
    );
  });

  await step("usage create with metadata.sessionToken is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, usagePath("usage-nested")), {
        provider: "anthropic",
        metadata: { sessionToken: "session-secret-value" },
      })
    );
  });

  await step("budgetRules create with data.privateKey is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, budgetRulePath("rule-nested")), {
        enabled: true,
        data: { privateKey: "private-key-material" },
      })
    );
  });

  await step("cloud_profile write with config.apiSecret is rejected", async () => {
    await assertFails(
      setDoc(doc(aliceDB, cloudProfilePath("profile-nested")), {
        uid: aliceUid,
        config: { apiSecret: "api-secret-value" },
      })
    );
  });

  await step("cloud_profile write with benign keys succeeds", async () => {
    await assertSucceeds(
      setDoc(doc(aliceDB, cloudProfilePath("profile-benign")), {
        uid: aliceUid,
        schemaVersion: 1,
      })
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
