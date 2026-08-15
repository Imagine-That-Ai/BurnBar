import { test } from "node:test";
import assert from "node:assert/strict";

import {
  functionListArgs,
  run,
  sanitizeEvidenceArtifact,
  secretIdFromResourceName,
} from "./collect-firebase-security-evidence.mjs";

test("functionListArgs binds inventory collection to the requested project", () => {
  assert.deepEqual(functionListArgs("burnbar-production", "us-central1"), [
    "functions",
    "list",
    "--v2",
    "--regions",
    "us-central1",
    "--project",
    "burnbar-production",
  ]);
});

test("run accepts JSON inventories larger than Node's default child-process buffer", () => {
  const payloadLength = 1_100_000;
  const result = run(
    process.execPath,
    [
      "-e",
      `process.stdout.write(JSON.stringify([{value:"x".repeat(${payloadLength})}]))`,
    ],
    { json: true },
  );

  assert.equal(result.ok, true);
  assert.equal(result.stdout[0].value.length, payloadLength);
});

test("run bounds failed-command output instead of publishing raw inventory", () => {
  const result = run(process.execPath, [
    "-e",
    'process.stdout.write("x".repeat(1_100_000)); process.exit(1)',
  ]);

  assert.equal(result.ok, false);
  assert.ok(result.error.length < 20_000);
  assert.doesNotMatch(result.error, /^x{1000}/);
});

test("secretIdFromResourceName preserves a live Secret Manager lookup target", () => {
  assert.equal(
    secretIdFromResourceName(
      "projects/burnbar/secrets/STRIPE_WEBHOOK_SECRET",
      "burnbar",
    ),
    "STRIPE_WEBHOOK_SECRET",
  );
  assert.equal(
    secretIdFromResourceName("STRIPE_WEBHOOK_SECRET", "burnbar"),
    "STRIPE_WEBHOOK_SECRET",
  );
  assert.equal(
    secretIdFromResourceName(
      "projects/246956661961/secrets/STRIPE_WEBHOOK_SECRET",
      "burnbar",
      "246956661961",
    ),
    "STRIPE_WEBHOOK_SECRET",
  );
  assert.equal(
    secretIdFromResourceName(
      "projects/burnbar-staging/secrets/STRIPE_WEBHOOK_SECRET",
      "burnbar",
    ),
    null,
  );
  assert.equal(
    secretIdFromResourceName(
      "projects/[REDACTED]/secrets/[REDACTED]",
      "burnbar",
    ),
    null,
  );
});

test("sanitizeEvidenceArtifact keeps proof signals but removes raw cloud inventory", () => {
  const projectId = ["prod", "project", "123"].join("-");
  const projectNumber = ["123456", "789012"].join("");
  const viewerRole = ["roles", "viewer"].join("/");
  const releaseBotEmail = ["release-bot", `${projectId}.iam.gserviceaccount.com`].join("@");
  const personEmail = ["person", "example.com"].join("@");
  const releaseBotMember = ["serviceAccount", releaseBotEmail].join(":");
  const personMember = ["user", personEmail].join(":");
  const evidence = {
    schemaVersion: 1,
    collectedAt: "2026-06-25T18:00:00.000Z",
    collector: "scripts/ops/collect-firebase-security-evidence.mjs",
    mode: {
      strict: true,
      regions: ["us-central1"],
      kmsLocations: ["global"],
      appCheckServices: ["firestore.googleapis.com"],
    },
    ok: true,
    summary: {
      projectCollected: true,
      functionInventoryCollected: true,
      storageBucketInventoryCollected: true,
    },
    project: {
      ok: true,
      projectId,
      projectNumber,
      lifecycleState: "ACTIVE",
      labels: { owner: "infra" },
    },
    authContext: {
      gcloudProject: {
        ok: true,
        command: ["gcloud", "config", "get-value", "project"],
        stdout: projectId,
      },
      firebaseProjects: {
        ok: false,
        command: ["firebase", "projects:list", "--project", projectId],
        error: `projects/${projectId} failed`,
      },
    },
    iam: {
      ok: true,
      project: {
        version: 1,
        bindings: [
          {
            role: viewerRole,
            members: [releaseBotMember, personMember],
          },
        ],
      },
    },
    functions: {
      ok: true,
      regions: {
        "us-central1": {
          ok: true,
          count: 1,
          functions: [
            {
              name: `projects/${projectId}/locations/us-central1/functions/api`,
              state: "ACTIVE",
              updateTime: "2026-06-25T18:00:00Z",
              url: "https://api-us-central1.a.run.app",
              ingressSettings: "ALLOW_INTERNAL_AND_GCLB",
              serviceAccountEmail: releaseBotEmail,
              secretEnvironmentVariableNames: ["PAYMENT_WEBHOOK_SECRET"],
              labels: { runtime: "node" },
            },
          ],
        },
      },
    },
    storageBuckets: {
      ok: true,
      bucketCount: 1,
      buckets: [
        {
          ok: true,
          name: `${projectId}.firebasestorage.app`,
          url: `gs://${projectId}.firebasestorage.app`,
          location: "US",
          storageClass: "STANDARD",
          uniformBucketLevelAccess: true,
          publicAccessPrevention: "enforced",
          retentionPolicy: { retentionPeriod: "604800s" },
          encryption: {
            defaultKmsKeyName:
              `projects/${projectId}/locations/global/keyRings/ring/cryptoKeys/key`,
          },
          lifecycle: { rule: [] },
          iamPolicy: {
            bindings: [
              {
                role: "roles/storage.objectViewer",
                members: [releaseBotMember],
              },
            ],
          },
        },
      ],
    },
    rules: {
      ok: false,
      firestoreIndexes: {
        ok: false,
        localSha256: "local-indexes",
        deployedSha256: "deployed-indexes",
        drift: true,
        error: `firestore indexes for ${projectId} failed`,
      },
    },
    secrets: {
      ok: true,
      secretCount: 1,
      secrets: [
        {
          ok: true,
          name: `projects/${projectId}/secrets/payment-webhook`,
          labels: { tier: "prod" },
          replication: {
            userManaged: {
              replicas: [
                {
                  location: "us-central1",
                  customerManagedEncryption: {
                    kmsKeyName:
                      `projects/${projectId}/locations/us-central1/keyRings/secrets/cryptoKeys/main`,
                  },
                },
              ],
            },
          },
          topics: [`projects/${projectId}/topics/secret-rotate`],
          iamPolicy: { bindings: [] },
        },
      ],
    },
    kms: {
      ok: true,
      locations: {
        global: {
          ok: true,
          keyRingCount: 1,
          keyCount: 1,
          keyRings: [
            {
              ok: true,
              name: `projects/${projectId}/locations/global/keyRings/prod`,
              keyCount: 1,
              keys: [
                {
                  ok: true,
                  name: `projects/${projectId}/locations/global/keyRings/prod/cryptoKeys/main`,
                  purpose: "ENCRYPT_DECRYPT",
                  protectionLevel: "SOFTWARE",
                  primaryState: "ENABLED",
                  iamPolicy: { bindings: [] },
                },
              ],
            },
          ],
        },
      },
    },
  };

  const sanitized = sanitizeEvidenceArtifact(evidence);
  const encoded = JSON.stringify(sanitized);

  assert.equal(sanitized.publicationMode, "sanitized-operational-evidence");
  assert.equal(sanitized.ok, true);
  assert.equal(sanitized.functions.regions["us-central1"].count, 1);
  assert.equal(sanitized.storageBuckets.bucketCount, 1);
  assert.equal(sanitized.storageBuckets.buckets[0].hasEncryptionConfig, true);
  assert.deepEqual(sanitized.secrets.secrets[0].replicationPolicy, {
    mode: "userManaged",
    replicaCount: 1,
  });
  assert.deepEqual(sanitized.iam.project.bindings[0].memberTypes, [
    "serviceAccount",
    "user",
  ]);
  assert.deepEqual(sanitized.authContext.firebaseProjects.command, [
    "firebase",
  ]);
  assert.match(sanitized.rules.firestoreIndexes.error, /REDACTED/);

  assert.doesNotMatch(encoded, /prod-project-123/);
  assert.doesNotMatch(encoded, /123456789012/);
  assert.doesNotMatch(encoded, /api-us-central1\.a\.run\.app/);
  assert.doesNotMatch(encoded, /firebasestorage\.app/);
  assert.doesNotMatch(encoded, /PAYMENT_WEBHOOK_SECRET/);
  assert.doesNotMatch(encoded, /release-bot@/);
  assert.doesNotMatch(encoded, /person@example\.com/);
  assert.doesNotMatch(encoded, /payment-webhook/);
});
