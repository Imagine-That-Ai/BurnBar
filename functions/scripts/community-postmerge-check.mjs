#!/usr/bin/env node
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { pathToFileURL } from "node:url";

const DEFAULT_DATABASE = "(default)";
const DEFAULT_STALE_HOURS = 48;
const BATCH_LIMIT = 400;

function usage() {
  console.log(`Usage: node scripts/community-postmerge-check.mjs [options]

Read-only by default. Reports active Community participants, below-threshold public boards by tier/window,
and stale public leaderboard docs. Pass --delete-stale to clean stale public boards after review.

Options:
  --project <id>       Firebase project id. Defaults to FIREBASE_PROJECT, OPENBURNBAR_FIREBASE_PROJECT, or GCLOUD_PROJECT.
  --database <id>      Firestore database id. Default ${DEFAULT_DATABASE}.
  --stale-hours <n>    Leaderboards older than this are stale; 0 treats every board as stale (rollback cleanup). Default ${DEFAULT_STALE_HOURS}.
  --delete-stale       Delete stale community_leaderboards docs after counting them.
  --json               Emit JSON only.
  --help               Show this help.
`);
}

export function parseArgs(argv = process.argv, env = process.env) {
  const options = {
    project: env.FIREBASE_PROJECT || env.OPENBURNBAR_FIREBASE_PROJECT || env.GCLOUD_PROJECT || "",
    database: env.FIRESTORE_DATABASE || DEFAULT_DATABASE,
    staleHours: DEFAULT_STALE_HOURS,
    deleteStale: false,
    json: false,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--delete-stale") {
      options.deleteStale = true;
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
    if (arg === "--database") {
      options.database = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--stale-hours") {
      options.staleHours = Number.parseFloat(requireValue(argv, ++index, arg));
      if (!Number.isFinite(options.staleHours) || options.staleHours < 0) {
        throw new Error("--stale-hours must be a non-negative number");
      }
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

function asRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value : {};
}

function isGranted(value) {
  return value === "granted";
}

export function isActiveCommunityConsent(data) {
  const doc = asRecord(data);
  const tiers = asRecord(doc.l2Tiers);
  const topLevel = isGranted(doc.l2Rankings);
  return topLevel && (isGranted(tiers.world) || isGranted(tiers.country) || isGranted(tiers.region) || isGranted(tiers.city));
}

function tierWindowKey(doc) {
  const tier = typeof doc.tier === "string" && doc.tier ? doc.tier : "unknown";
  const window = typeof doc.window === "string" && doc.window ? doc.window : "unknown";
  return `${window}/${tier}`;
}

function parseTime(value) {
  if (value instanceof Date) return value.getTime();
  if (typeof value?.toDate === "function") return value.toDate().getTime();
  if (typeof value === "string") {
    const millis = Date.parse(value);
    return Number.isFinite(millis) ? millis : Number.NaN;
  }
  return Number.NaN;
}

export function isStaleLeaderboard(data, nowMs, staleMs) {
  const updatedAt = parseTime(asRecord(data).updatedAt);
  return !Number.isFinite(updatedAt) || updatedAt < nowMs - staleMs;
}

export function summarizeCommunityState({ communityDocs = [], leaderboardDocs = [] }, options = {}) {
  const nowMs = options.nowMs ?? Date.now();
  const staleMs = options.staleMs ?? DEFAULT_STALE_HOURS * 60 * 60 * 1000;
  const activeConsentDocs = communityDocs.filter((doc) => doc.id === "consent" && isActiveCommunityConsent(doc.data));
  const shareSnapshots = communityDocs.filter((doc) => doc.id === "share_snapshot");
  const revokedSnapshots = shareSnapshots.filter((doc) => asRecord(doc.data).revoked === true);
  const belowThresholdByTierWindow = {};
  const staleLeaderboardIds = [];

  for (const doc of leaderboardDocs) {
    const data = asRecord(doc.data);
    if (data.belowThreshold === true) {
      const key = tierWindowKey(data);
      belowThresholdByTierWindow[key] = (belowThresholdByTierWindow[key] ?? 0) + 1;
    }
    if (isStaleLeaderboard(data, nowMs, staleMs)) {
      staleLeaderboardIds.push(doc.id);
    }
  }

  return {
    generatedAt: new Date(nowMs).toISOString(),
    activeCommunityParticipants: activeConsentDocs.length,
    shareSnapshots: shareSnapshots.length,
    revokedShareSnapshots: revokedSnapshots.length,
    belowThresholdByTierWindow,
    publicLeaderboards: leaderboardDocs.length,
    stalePublicLeaderboards: {
      eligible: staleLeaderboardIds.length,
      cleaned: options.cleaned ?? 0,
      ids: options.includeIds ? staleLeaderboardIds : undefined,
    },
  };
}

function requireLiveOptions(options) {
  if (!options.project) throw new Error("--project or FIREBASE_PROJECT is required");
}

function initFirestore(options) {
  requireLiveOptions(options);
  if (getApps().length === 0) initializeApp({ projectId: options.project });
  return getFirestore(getApps()[0], options.database);
}

async function loadCommunityDocs(db) {
  const snap = await db.collectionGroup("community").get();
  return snap.docs.map((doc) => ({ id: doc.id, path: doc.ref.path, data: doc.data() }));
}

async function loadLeaderboardDocs(db) {
  const snap = await db.collection("community_leaderboards").get();
  return snap.docs.map((doc) => ({ id: doc.id, path: doc.ref.path, ref: doc.ref, data: doc.data() }));
}

async function deleteDocs(db, docs) {
  let batch = db.batch();
  let pending = 0;
  let cleaned = 0;
  async function commit() {
    if (pending === 0) return;
    await batch.commit();
    batch = db.batch();
    pending = 0;
  }
  for (const doc of docs) {
    batch.delete(doc.ref);
    pending += 1;
    cleaned += 1;
    if (pending >= BATCH_LIMIT) await commit();
  }
  await commit();
  return cleaned;
}

async function runLiveReport(options) {
  const db = initFirestore(options);
  const nowMs = Date.now();
  const staleMs =
    options.staleHours === 0 ? 0 : options.staleHours * 60 * 60 * 1000;
  const [communityDocs, leaderboardDocs] = await Promise.all([loadCommunityDocs(db), loadLeaderboardDocs(db)]);
  const staleDocs = leaderboardDocs.filter((doc) => isStaleLeaderboard(doc.data, nowMs, staleMs));
  const cleaned = options.deleteStale ? await deleteDocs(db, staleDocs) : 0;
  return summarizeCommunityState(
    { communityDocs, leaderboardDocs },
    { nowMs, staleMs, cleaned, includeIds: true },
  );
}

function printSummary(summary, options) {
  console.log("Community post-merge aggregate check");
  console.log(`Active participants: ${summary.activeCommunityParticipants}`);
  console.log(`Share snapshots: ${summary.shareSnapshots} (${summary.revokedShareSnapshots} revoked tombstones)`);
  console.log(`Public leaderboards: ${summary.publicLeaderboards}`);
  console.log("Below threshold by window/tier:");
  const entries = Object.entries(summary.belowThresholdByTierWindow).sort();
  if (entries.length === 0) console.log("  none");
  for (const [key, count] of entries) console.log(`  ${key}: ${count}`);
  const stale = summary.stalePublicLeaderboards;
  console.log(`Stale public boards eligible: ${stale.eligible}`);
  console.log(`Stale public boards cleaned: ${stale.cleaned}${options.deleteStale ? "" : " (dry-run; pass --delete-stale to delete)"}`);
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  const summary = await runLiveReport(options);
  if (options.json) console.log(JSON.stringify(summary, null, 2));
  else printSummary(summary, options);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
