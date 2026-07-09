#!/usr/bin/env node
import { initializeApp, getApps } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { pathToFileURL } from "node:url";

const DEFAULT_DATABASE = "(default)";

function usage() {
  console.log(`Usage: node scripts/community-leaderboard-canary.mjs [options]

Synthetic authenticated-read canary for public Community leaderboard docs.
It signs in with a short-lived Firebase custom token, reads through Firestore REST, and validates rule-visible shapes.

Options:
  --project <id>             Firebase project id. Defaults to FIREBASE_PROJECT, OPENBURNBAR_FIREBASE_PROJECT, or GCLOUD_PROJECT.
  --api-key <key>            Firebase Web API key. Defaults to FIREBASE_WEB_API_KEY.
  --uid <uid>                Synthetic auth uid. Default community-canary.
  --threshold-doc <id>       Expected below-threshold leaderboard doc id.
  --live-doc <id>            Expected live leaderboard doc id.
  --revoked-anon-id <id>     An anonId that must not appear in the live doc.
  --database <id>            Firestore database id. Default ${DEFAULT_DATABASE}.
  --strict                   Missing optional revoked exclusion evidence fails the canary.
  --json                     Emit JSON only.
  --help                     Show this help.
`);
}

export function parseArgs(argv = process.argv, env = process.env) {
  const options = {
    project: env.FIREBASE_PROJECT || env.OPENBURNBAR_FIREBASE_PROJECT || env.GCLOUD_PROJECT || "",
    apiKey: env.FIREBASE_WEB_API_KEY || "",
    uid: env.COMMUNITY_CANARY_UID || "community-canary",
    thresholdDoc: env.COMMUNITY_CANARY_THRESHOLD_DOC || "",
    liveDoc: env.COMMUNITY_CANARY_LIVE_DOC || "",
    revokedAnonId: env.COMMUNITY_CANARY_REVOKED_ANON_ID || "",
    database: env.FIRESTORE_DATABASE || DEFAULT_DATABASE,
    strict: false,
    json: false,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--strict") {
      options.strict = true;
      continue;
    }
    if (arg === "--json") {
      options.json = true;
      continue;
    }
    if (arg === "--project") {
      options.project = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--api-key") {
      options.apiKey = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--uid") {
      options.uid = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--threshold-doc") {
      options.thresholdDoc = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--live-doc") {
      options.liveDoc = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--revoked-anon-id") {
      options.revokedAnonId = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--database") {
      options.database = requireValue(argv, ++index, arg);
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  return options;
}

function requireValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function hasNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function docName(data) {
  return typeof data?.name === "string" ? data.name.split("/").pop() ?? "" : "";
}

function pass(label, detail = "") {
  return { label, ok: true, detail };
}

function fail(label, detail) {
  return { label, ok: false, detail };
}

function summarizeChecks(checks) {
  return checks.every((check) => check.ok);
}

function entries(value) {
  return Array.isArray(value) ? value : [];
}

export function validateThresholdDoc(doc, expectedDocId = "") {
  const id = docName(doc) || expectedDocId;
  const checks = [];
  checks.push(doc ? pass("document exists", id) : fail("document exists", expectedDocId || "missing"));
  if (!doc) return { docId: expectedDocId, ok: false, checks };

  checks.push(doc.belowThreshold === true ? pass("belowThreshold true") : fail("belowThreshold true", String(doc.belowThreshold)));
  checks.push(entries(doc.entries).length === 0 ? pass("entries empty") : fail("entries empty", `${entries(doc.entries).length} entries`));
  checks.push(hasNumber(doc.kThreshold) && doc.kThreshold >= 10 ? pass("kThreshold >= 10", String(doc.kThreshold)) : fail("kThreshold >= 10", String(doc.kThreshold)));
  checks.push(hasNumber(doc.cohortSize) && doc.cohortSize === 0 ? pass("cohortSize withheld as 0") : fail("cohortSize withheld as 0", String(doc.cohortSize)));
  return { docId: id, ok: summarizeChecks(checks), checks };
}

export function validateLiveDoc(doc, options = {}) {
  const id = docName(doc) || options.expectedDocId || "";
  const checks = [];
  checks.push(doc ? pass("document exists", id) : fail("document exists", options.expectedDocId || "missing"));
  if (!doc) return { docId: options.expectedDocId ?? "", ok: false, checks };

  const leaderboardEntries = entries(doc.entries);
  checks.push(doc.belowThreshold === false ? pass("belowThreshold false") : fail("belowThreshold false", String(doc.belowThreshold)));
  checks.push(leaderboardEntries.length > 0 ? pass("entries present", String(leaderboardEntries.length)) : fail("entries present", "0 entries"));
  checks.push(hasNumber(doc.cohortSize) && doc.cohortSize >= 10 ? pass("cohortSize >= 10", String(doc.cohortSize)) : fail("cohortSize >= 10", String(doc.cohortSize)));
  checks.push(leaderboardEntries.every((entry) => typeof entry.anonId === "string" && !entry.uid && !entry.email) ? pass("entries are anonymous") : fail("entries are anonymous", "uid/email field present or anonId missing"));

  if (options.revokedAnonId) {
    const found = leaderboardEntries.some((entry) => entry.anonId === options.revokedAnonId);
    checks.push(!found ? pass("revoked anonId excluded", options.revokedAnonId) : fail("revoked anonId excluded", options.revokedAnonId));
  } else if (options.strict) {
    checks.push(fail("revoked anonId excluded", "--revoked-anon-id is required in --strict mode"));
  } else {
    checks.push({ label: "revoked anonId excluded", ok: true, skipped: true, detail: "no revoked anonId supplied" });
  }

  return { docId: id, ok: summarizeChecks(checks), checks };
}

export function summarizeCanary({ thresholdDoc, liveDoc }, options = {}) {
  const threshold = validateThresholdDoc(thresholdDoc, options.thresholdDoc);
  const live = validateLiveDoc(liveDoc, {
    expectedDocId: options.liveDoc,
    revokedAnonId: options.revokedAnonId,
    strict: options.strict,
  });
  return {
    generatedAt: new Date().toISOString(),
    ok: threshold.ok && live.ok,
    threshold,
    live,
  };
}

export function decodeFirestoreValue(value) {
  if (!value || typeof value !== "object") return undefined;
  if ("nullValue" in value) return null;
  if ("booleanValue" in value) return Boolean(value.booleanValue);
  if ("integerValue" in value) return Number(value.integerValue);
  if ("doubleValue" in value) return Number(value.doubleValue);
  if ("timestampValue" in value) return value.timestampValue;
  if ("stringValue" in value) return value.stringValue;
  if ("arrayValue" in value) return (value.arrayValue.values ?? []).map(decodeFirestoreValue);
  if ("mapValue" in value) return decodeFirestoreFields(value.mapValue.fields ?? {});
  return undefined;
}

export function decodeFirestoreFields(fields) {
  return Object.fromEntries(Object.entries(fields ?? {}).map(([key, value]) => [key, decodeFirestoreValue(value)]));
}

function decodeFirestoreDocument(raw) {
  return { name: raw.name, ...decodeFirestoreFields(raw.fields ?? {}) };
}

async function signInWithCustomToken(apiKey, customToken) {
  const response = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${encodeURIComponent(apiKey)}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: customToken, returnSecureToken: true }),
  });
  if (!response.ok) throw new Error(`custom-token sign-in failed: ${response.status} ${await response.text()}`);
  const data = await response.json();
  if (!data.idToken) throw new Error("custom-token sign-in returned no idToken");
  return data.idToken;
}

async function fetchLeaderboardDoc({ project, database, idToken, docId }) {
  const escaped = encodeURIComponent(docId);
  const url = `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(project)}/databases/${encodeURIComponent(database)}/documents/community_leaderboards/${escaped}`;
  const response = await fetch(url, { headers: { authorization: `Bearer ${idToken}` } });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Firestore REST read failed for ${docId}: ${response.status} ${await response.text()}`);
  return decodeFirestoreDocument(await response.json());
}

function requireLiveOptions(options) {
  if (!options.project) throw new Error("--project or FIREBASE_PROJECT is required");
  if (!options.apiKey) throw new Error("--api-key or FIREBASE_WEB_API_KEY is required");
  if (!options.thresholdDoc) throw new Error("--threshold-doc or COMMUNITY_CANARY_THRESHOLD_DOC is required");
  if (!options.liveDoc) throw new Error("--live-doc or COMMUNITY_CANARY_LIVE_DOC is required");
}

export async function runLiveCanary(options) {
  requireLiveOptions(options);
  if (getApps().length === 0) initializeApp({ projectId: options.project });
  const customToken = await getAuth().createCustomToken(options.uid, { purpose: "community-leaderboard-canary" });
  const idToken = await signInWithCustomToken(options.apiKey, customToken);
  const thresholdDoc = await fetchLeaderboardDoc({ ...options, idToken, docId: options.thresholdDoc });
  const liveDoc = await fetchLeaderboardDoc({ ...options, idToken, docId: options.liveDoc });
  return summarizeCanary({ thresholdDoc, liveDoc }, options);
}

function printSummary(summary) {
  console.log(`Community leaderboard canary: ${summary.ok ? "PASS" : "FAIL"}`);
  for (const section of [summary.threshold, summary.live]) {
    console.log(`\n${section.docId || "(missing doc)"}`);
    for (const check of section.checks) {
      const marker = check.skipped ? "SKIP" : check.ok ? "ok" : "FAIL";
      console.log(`  ${marker}: ${check.label}${check.detail ? ` — ${check.detail}` : ""}`);
    }
  }
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  const summary = await runLiveCanary(options);
  if (options.json) console.log(JSON.stringify(summary, null, 2));
  else printSummary(summary);
  if (!summary.ok) process.exitCode = 1;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
