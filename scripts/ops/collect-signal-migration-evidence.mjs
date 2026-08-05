#!/usr/bin/env node
/**
 * Collect release evidence from aggregate-only Signal migration counters.
 *
 * The source documents contain only day/collection/platform counters. This tool
 * never queries user collections and never emits uid, document paths/ids,
 * ciphertext, keys, hashes, or payload data.
 */

import { createRequire } from "node:module";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const REQUIRED_COLLECTIONS = [
  "conversations",
  "chat_threads",
  "mobile_assistant_chats",
  "cli_sessions",
  "cli_agent_mission_requests",
  "text_snippets",
  "rollback_requests",
  "approval_policies",
  "agent_identities",
  "subscription_topics",
];

const PRODUCERS = ["ios", "macos", "android", "unknown"];
const COUNT_FIELDS = [
  "totalWrites",
  "createWrites",
  "updateWrites",
  "deleteWrites",
  "signalSealedWrites",
  "legacySealedWrites",
  "mixedEnvelopeWrites",
  "plaintextOnlyWrites",
];

function parseArgs(argv) {
  const args = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) throw new Error(`Unexpected argument: ${token}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${token}`);
    args.set(token.slice(2), value);
    index += 1;
  }
  for (const required of ["project", "start", "end", "release", "source-commit", "output"]) {
    if (!args.has(required)) throw new Error(`Missing required --${required}`);
  }
  return args;
}

function canonicalDay(raw, label) {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(raw)) throw new Error(`${label} must use YYYY-MM-DD.`);
  const date = new Date(`${raw}T00:00:00.000Z`);
  if (!Number.isFinite(date.valueOf()) || date.toISOString().slice(0, 10) !== raw) {
    throw new Error(`${label} is not a valid UTC day.`);
  }
  return date;
}

function daysInclusive(startRaw, endRaw) {
  const start = canonicalDay(startRaw, "--start");
  const end = canonicalDay(endRaw, "--end");
  if (end < start) throw new Error("--end must be on or after --start.");
  const days = [];
  for (let cursor = start; cursor <= end; cursor = new Date(cursor.valueOf() + 86_400_000)) {
    days.push(cursor.toISOString().slice(0, 10));
  }
  if (days.length > 31) throw new Error("Evidence windows are capped at 31 days.");
  return days;
}

function nonnegativeInteger(raw, field) {
  const value = Number(raw ?? 0);
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`${field} must be a non-negative integer.`);
  return value;
}

function emptyCounts() {
  return Object.fromEntries(COUNT_FIELDS.map((field) => [field, 0]));
}

export function aggregateCounterDocuments(documents) {
  const byCollection = Object.fromEntries(REQUIRED_COLLECTIONS.map((collection) => [collection, emptyCounts()]));
  const byProducer = Object.fromEntries(PRODUCERS.map((producer) => [producer, emptyCounts()]));
  let counterDocuments = 0;

  for (const raw of documents) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("Counter data must be an object.");
    const collection = raw.collection;
    const producer = raw.producer;
    if (!REQUIRED_COLLECTIONS.includes(collection)) throw new Error(`Unexpected migration collection: ${String(collection)}`);
    if (!PRODUCERS.includes(producer)) throw new Error(`Unexpected producer bucket: ${String(producer)}`);
    if (raw.schemaVersion !== 1) throw new Error("Counter schemaVersion must be 1.");
    counterDocuments += 1;
    for (const field of COUNT_FIELDS) {
      const value = nonnegativeInteger(raw[field], field);
      byCollection[collection][field] += value;
      byProducer[producer][field] += value;
    }
  }

  const totals = emptyCounts();
  for (const counts of Object.values(byCollection)) {
    for (const field of COUNT_FIELDS) totals[field] += counts[field];
  }
  return { counterDocuments, totals, byCollection, byProducer };
}

export function buildEvidence({ projectId, release, sourceCommit, start, end, capturedAt, documents }) {
  return {
    schemaVersion: 1,
    evidenceKind: "aggregate_signal_migration_telemetry",
    release,
    projectId,
    sourceCommit,
    capturedAt,
    window: { start, end, timezone: "UTC" },
    privacy: {
      classification: "aggregate_only_no_user_or_content_data",
      containsUserIdentifiers: false,
      containsDocumentIdentifiersOrPaths: false,
      containsPayloadCiphertextOrKeys: false,
      producerBuckets: PRODUCERS,
    },
    requiredCollections: REQUIRED_COLLECTIONS,
    ...aggregateCounterDocuments(documents),
  };
}

async function main(argv) {
  const args = parseArgs(argv);
  const days = daysInclusive(args.get("start"), args.get("end"));
  const requireFromFunctions = createRequire(resolve("functions/package.json"));
  const { applicationDefault, getApps, initializeApp } = requireFromFunctions("firebase-admin/app");
  const { getFirestore } = requireFromFunctions("firebase-admin/firestore");
  if (getApps().length === 0) {
    initializeApp({ credential: applicationDefault(), projectId: args.get("project") });
  }
  const db = getFirestore();
  const documents = [];
  for (const day of days) {
    const snapshot = await db.collection(`ops_signal_migration_daily/${day}/counters`).get();
    for (const document of snapshot.docs) documents.push(document.data());
  }
  const evidence = buildEvidence({
    projectId: args.get("project"),
    release: args.get("release"),
    sourceCommit: args.get("source-commit"),
    start: args.get("start"),
    end: args.get("end"),
    capturedAt: new Date().toISOString(),
    documents,
  });
  const output = resolve(args.get("output"));
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
  process.stdout.write(`Wrote aggregate-only Signal migration evidence: ${output}\n`);
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`ERROR: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
