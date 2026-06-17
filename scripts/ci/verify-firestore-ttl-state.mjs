#!/usr/bin/env node
/**
 * Verify deployed Firestore TTL policies (run-09: F-RR09-001 / F-RR09-007).
 *
 * `firestore.indexes.json` declares `ttl:true` field overrides, and `firebase
 * deploy --only firestore:indexes` (firebase-tools >=11.5) applies them. But a
 * TTL policy can fail to materialise (CREATING -> NEEDS_REPAIR, or never created
 * on an older CLI / partial deploy). Without proof, ephemeral docs that carry a
 * uid + push tokens + identifying metadata (voip_outbound, fcm_outbound,
 * agent_notification_events) could accumulate forever — the exact gap behind
 * F-RR09-001 that local code alone cannot prove closed.
 *
 * This script reads the live TTL state for EVERY declared `ttl:true` override
 * via the Firestore Admin API and fails the deploy unless each is ACTIVE (or
 * CREATING — an acceptable transient right after deploy). It is the automated
 * form of the "B3 deploy readback" the fix-audit flagged as release-blocking.
 *
 * Run (post-deploy, with gcloud creds):
 *   node scripts/ci/verify-firestore-ttl-state.mjs [project]
 * Exit: 0 = every declared TTL is ACTIVE/CREATING; 1 = one or more missing.
 *
 * Auth mirrors scripts/ci/check-firestore-deploy-drift.mjs.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const project = process.env.FIREBASE_PROJECT || process.argv[2] || "burnbar";
const database = process.env.FIRESTORE_DATABASE || "(default)";
// States we accept as "the policy exists and will delete expired docs".
const HEALTHY_STATES = new Set(["ACTIVE", "CREATING"]);

function accessToken() {
  if (process.env.GOOGLE_OAUTH_ACCESS_TOKEN)
    return process.env.GOOGLE_OAUTH_ACCESS_TOKEN;
  return execFileSync("gcloud", ["auth", "print-access-token"], {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

/** GET a single Firestore field's metadata (includes ttlConfig.state). */
async function getField(collectionGroup, fieldPath, token) {
  const safeCollectionGroup = safeFirestoreSegment(collectionGroup, "collection group");
  const safeFieldPath = safeFirestoreFieldPath(fieldPath);
  const safeProject = safeFirestoreSegment(project, "project");
  const safeDatabase = safeFirestoreDatabase(database);
  // `database` is the literal `(default)` path segment (the Firestore Admin API
  // rejects a percent-encoded `%28default%29`), so it is interpolated as-is;
  // the collection group and field are encoded defensively.
  const url =
    `https://firestore.googleapis.com/v1/projects/${safeProject}` +
    `/databases/${safeDatabase}/collectionGroups/${encodeURIComponent(safeCollectionGroup)}` +
    `/fields/${encodeURIComponent(safeFieldPath)}`;
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      "X-Goog-User-Project": process.env.GOOGLE_CLOUD_QUOTA_PROJECT || project,
    },
  });
  if (response.status === 404) return { notFound: true };
  if (!response.ok) {
    throw new Error(
      `Firestore Admin API ${collectionGroup}.${fieldPath} failed: ${response.status} ${await response.text()}`,
    );
  }
  return response.json();
}

function safeFirestoreSegment(value, label) {
  const text = String(value ?? "");
  if (!/^[A-Za-z0-9_-]+$/.test(text)) {
    throw new Error(`Unsafe Firestore ${label}: ${text}`);
  }
  return text;
}

function safeFirestoreDatabase(value) {
  const text = String(value ?? "");
  if (text === "(default)") return text;
  return safeFirestoreSegment(text, "database");
}

function safeFirestoreFieldPath(value) {
  const text = String(value ?? "");
  if (!/^[A-Za-z0-9_.`]+$/.test(text) || text.includes("..")) {
    throw new Error(`Unsafe Firestore field path: ${text}`);
  }
  return text;
}

async function main() {
  const indexes = JSON.parse(
    readFileSync(resolve(repoRoot, "firestore.indexes.json"), "utf8"),
  );
  const ttlOverrides = (indexes.fieldOverrides ?? []).filter(
    (o) => o && o.ttl === true,
  );
  if (ttlOverrides.length === 0) {
    console.error(
      "verify-firestore-ttl-state: no ttl:true field overrides found — nothing to verify (unexpected).",
    );
    process.exit(1);
  }

  const token = accessToken();
  const failures = [];
  for (const { collectionGroup, fieldPath } of ttlOverrides) {
    let field;
    try {
      field = await getField(collectionGroup, fieldPath, token);
    } catch (err) {
      failures.push(
        `${collectionGroup}.${fieldPath}: API error — ${err.message}`,
      );
      continue;
    }
    const state = field?.ttlConfig?.state;
    if (field?.notFound || !state) {
      failures.push(
        `${collectionGroup}.${fieldPath}: NO active TTL policy (run \`gcloud firestore fields ttls update ${fieldPath} --collection-group=${collectionGroup} --enable-ttl --project=${project}\`)`,
      );
    } else if (!HEALTHY_STATES.has(state)) {
      failures.push(
        `${collectionGroup}.${fieldPath}: TTL policy state is ${state} (expected ACTIVE/CREATING) — needs repair`,
      );
    } else {
      console.log(`  ✓ ${collectionGroup}.${fieldPath} TTL policy is ${state}`);
    }
  }

  if (failures.length > 0) {
    console.error(
      `\nFirestore TTL verification FAILED (${failures.length}):\n  ✗ ` +
        failures.join("\n  ✗ "),
    );
    console.error(
      "\nEphemeral PII/token collections must have a LIVE TTL policy (F-RR09-001 / F-RR09-007).",
    );
    process.exit(1);
  }
  console.log(
    `\nAll ${ttlOverrides.length} declared Firestore TTL policies are live on project ${project}.`,
  );
}

main().catch((err) => {
  console.error(`verify-firestore-ttl-state: ${err.message}`);
  process.exit(1);
});
