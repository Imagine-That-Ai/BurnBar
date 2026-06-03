#!/usr/bin/env node
//
// Production-safe operator runner for functions/src/callables/privacyBackfill.ts.
//
// This is deliberately narrower than scrub-chat-cloud-plaintext.mjs:
// - uses the same sealed-gated deletion rules as the deployed callable/scheduler
// - strips Hermes Gateway relayed plaintext via the reviewed gatewayRelayed gate
// - bumps the reseal watermark
// - never logs raw document paths, values, or user ids
//
// Requires --apply so it cannot be run accidentally.

import { createHash } from "node:crypto";
import { createRequire } from "node:module";

const requireFromFunctions = createRequire(new URL("../../functions/package.json", import.meta.url));

const options = parseArgs(process.argv.slice(2));
if (options.help || (!options.allUsers && options.uids.length === 0) || !options.apply) {
  printHelp();
  process.exit(options.help ? 0 : 2);
}

if (options.projectId) {
  process.env.GCLOUD_PROJECT = options.projectId;
  process.env.GOOGLE_CLOUD_PROJECT = options.projectId;
}

let getFirestore;
let backfillUserPrivacy;
let PRIVACY_RESEAL_EPOCH;

try {
  ({ getFirestore } = requireFromFunctions("firebase-admin/firestore"));
  ({ backfillUserPrivacy, PRIVACY_RESEAL_EPOCH } = requireFromFunctions("./lib/callables/privacyBackfill.js"));
} catch (error) {
  console.error("Unable to load firebase-admin or the built privacy backfill.");
  console.error("Run `npm --prefix functions run build` first, then retry.");
  console.error(String(error));
  process.exit(127);
}

const db = getFirestore();
const uids = options.allUsers ? await listAllUserIds(db) : options.uids;
const totals = emptyStats();

console.log(`Applying sealed-gated privacy backfill for ${uids.length} user(s).`);
console.log(`Reseal epoch: ${PRIVACY_RESEAL_EPOCH}`);

for (const [index, uid] of uids.entries()) {
  const label = hashUid(uid);
  const startedAt = Date.now();
  console.log(`- user=${label} index=${index + 1}/${uids.length} status=started`);
  const stats = await backfillUserPrivacy(db, uid, (event) => {
    if (event.phase === "started") {
      console.log(`  collection=${event.collection} user=${label} status=started`);
      return;
    }
    console.log(
      [
        `  collection=${event.collection}`,
        `user=${label}`,
        "status=completed",
        `durationMs=${event.durationMs}`,
        `scanned=${event.scannedDocs}`,
        `updated=${event.updatedDocs}`,
        `deletedFields=${event.deletedFields}`,
      ].join(" "),
    );
  });
  mergeStats(totals, stats);
  console.log(
    [
      `- user=${label}`,
      `index=${index + 1}/${uids.length}`,
      `durationMs=${Date.now() - startedAt}`,
      `scanned=${stats.scannedDocs}`,
      `updated=${stats.updatedDocs}`,
      `deletedFields=${stats.deletedFields}`,
      `resealBumped=${stats.resealBumped}`,
    ].join(" "),
  );
}

console.log(
  [
    "Done:",
    `users=${uids.length}`,
    `scanned=${totals.scannedDocs}`,
    `updated=${totals.updatedDocs}`,
    `deletedFields=${totals.deletedFields}`,
    `resealBumpedUsers=${totals.resealBumpedUsers}`,
  ].join(" "),
);

function emptyStats() {
  return { scannedDocs: 0, updatedDocs: 0, deletedFields: 0, resealBumpedUsers: 0 };
}

function mergeStats(into, from) {
  into.scannedDocs += Number(from.scannedDocs || 0);
  into.updatedDocs += Number(from.updatedDocs || 0);
  into.deletedFields += Number(from.deletedFields || 0);
  if (from.resealBumped) into.resealBumpedUsers += 1;
}

async function listAllUserIds(firestore) {
  const refs = await firestore.collection("users").listDocuments();
  return refs.map((ref) => ref.id);
}

function hashUid(uid) {
  return createHash("sha256").update(uid).digest("hex").slice(0, 12);
}

function parseArgs(argv) {
  const parsed = {
    allUsers: false,
    apply: false,
    help: false,
    projectId: undefined,
    uids: [],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--all-users":
        parsed.allUsers = true;
        break;
      case "--apply":
        parsed.apply = true;
        break;
      case "--project":
      case "--project-id":
        index += 1;
        if (!argv[index]) throw new Error(`${arg} requires a value`);
        parsed.projectId = argv[index];
        break;
      case "--uid":
        index += 1;
        if (!argv[index]) throw new Error("--uid requires a value");
        parsed.uids.push(argv[index]);
        break;
      case "--help":
      case "-h":
        parsed.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return parsed;
}

function printHelp() {
  console.log(`Usage:
  node scripts/privacy/backfill-privacy-plaintext.mjs --uid <uid> --apply [--project <id>]
  node scripts/privacy/backfill-privacy-plaintext.mjs --all-users --apply [--project <id>]

Runs the sealed-gated privacy backfill from functions/src/callables/privacyBackfill.ts
against production Firestore using Application Default Credentials or
GOOGLE_APPLICATION_CREDENTIALS. Requires --apply by design; it logs only counts
and hashed user ids, never document paths or field values.`);
}
