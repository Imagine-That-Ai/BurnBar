#!/usr/bin/env node
/**
 * Seed / rotate / pause a promotional campaign in Firestore.
 *
 *   node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra [--project burnbar]
 *   node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --code NEWCODE-2026
 *   node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --deactivate-code XOPEN-ULTRA
 *   node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --pause
 *   node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --status
 *
 * Grant policy comes from config/promo-campaigns.json (reviewed in git). This
 * script writes it to Firestore, which is the runtime source of truth: pausing,
 * re-capping, or rotating a live campaign never needs a deploy.
 *
 * Codes are written as SHA-256 digests at `promo_codes/{digest}`, so the live
 * code string never lands in Firestore, a backup, or a log line. Rotation adds
 * a new digest document and (optionally) deactivates the old one; the campaign
 * and every entitlement it already granted are untouched.
 *
 * Auth: Application Default Credentials / GOOGLE_APPLICATION_CREDENTIALS,
 * matching scripts/privacy/* and scripts/arena/*. Set FIRESTORE_EMULATOR_HOST
 * to target a local emulator instead.
 *
 * Re-running with the same arguments is idempotent: campaign policy is merged
 * and `redemptionCount` is never reset, so a re-seed cannot resurrect an
 * exhausted campaign or double-grant anyone.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const requireFromFunctions = createRequire(path.join(repoRoot, "functions", "package.json"));

const CONFIG_PATH = path.join(repoRoot, "config", "promo-campaigns.json");

function parseArgs(argv) {
  const args = { project: process.env.GCLOUD_PROJECT || "burnbar", dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--campaign") args.campaign = argv[++i];
    else if (arg === "--project") args.project = argv[++i];
    else if (arg === "--code") args.code = argv[++i];
    else if (arg === "--deactivate-code") args.deactivateCode = argv[++i];
    else if (arg === "--pause") args.pause = true;
    else if (arg === "--resume") args.resume = true;
    else if (arg === "--status") args.status = true;
    else if (arg === "--dry-run") args.dryRun = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.campaign) throw new Error("--campaign <id> is required");
  if (args.pause && args.resume) throw new Error("--pause and --resume are mutually exclusive");
  return args;
}

/** Mirrors canonicalizePromoCode/promoCodeDigest in functions/src/promoCampaigns.ts. */
function canonicalizeCode(raw) {
  const canonical = String(raw).replace(/[^A-Za-z0-9]/g, "").toUpperCase();
  if (canonical.length < 4 || canonical.length > 64) {
    throw new Error("code must canonicalize to 4-64 alphanumeric characters");
  }
  return canonical;
}

function codeDigest(canonical) {
  return createHash("sha256").update(canonical).digest("hex");
}

function loadCampaignDefinition(campaignID) {
  const config = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
  const definition = (config.campaigns || []).find((entry) => entry.campaignID === campaignID);
  if (!definition) {
    const known = (config.campaigns || []).map((entry) => entry.campaignID).join(", ") || "none";
    throw new Error(`campaign "${campaignID}" is not defined in config/promo-campaigns.json (known: ${known})`);
  }
  const grantExpiresAtMillis = Date.parse(definition.grantExpiresAt);
  if (!Number.isFinite(grantExpiresAtMillis)) {
    throw new Error(`campaign "${campaignID}" has an unparseable grantExpiresAt`);
  }
  if (grantExpiresAtMillis <= Date.now()) {
    throw new Error(`campaign "${campaignID}" grantExpiresAt is in the past; grants would be born expired`);
  }
  return { ...definition, grantExpiresAtMillis };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const definition = loadCampaignDefinition(args.campaign);

  let initializeApp;
  let getApps;
  let applicationDefault;
  let getFirestore;
  let FieldValue;
  try {
    ({ initializeApp, getApps, applicationDefault } = requireFromFunctions("firebase-admin/app"));
    ({ getFirestore, FieldValue } = requireFromFunctions("firebase-admin/firestore"));
  } catch (error) {
    console.error("Unable to load firebase-admin from functions/node_modules.");
    console.error("Run `npm --prefix functions install` first, then retry.");
    console.error(String(error));
    process.exit(127);
  }

  if (getApps().length === 0) {
    // Against the emulator there are no credentials to resolve; in production
    // the operator's ADC session is the only way in.
    initializeApp(
      process.env.FIRESTORE_EMULATOR_HOST
        ? { projectId: args.project }
        : { credential: applicationDefault(), projectId: args.project },
    );
  }
  const db = getFirestore();
  const campaignRef = db.doc(`promo_campaigns/${definition.campaignID}`);

  if (args.status) {
    const snap = await campaignRef.get();
    if (!snap.exists) {
      console.log(`campaign ${definition.campaignID}: NOT SEEDED`);
      return;
    }
    const data = snap.data();
    console.log(
      JSON.stringify(
        {
          campaignID: data.campaignID,
          active: data.active,
          entitlementID: data.entitlementID,
          productID: data.productID,
          redemptionCount: data.redemptionCount ?? 0,
          maxRedemptions: data.maxRedemptions ?? null,
          grantExpiresAt: new Date(data.grantExpiresAtMillis).toISOString(),
        },
        null,
        2,
      ),
    );
    return;
  }

  const active = args.pause ? false : true;
  const campaignDoc = {
    campaignID: definition.campaignID,
    label: definition.label,
    active,
    entitlementID: definition.entitlementID,
    productID: definition.productID,
    grantExpiresAtMillis: definition.grantExpiresAtMillis,
    schemaVersion: 1,
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (typeof definition.maxRedemptions === "number") campaignDoc.maxRedemptions = definition.maxRedemptions;
  if (definition.startsAt) campaignDoc.startsAtMillis = Date.parse(definition.startsAt);
  if (definition.endsAt) campaignDoc.endsAtMillis = Date.parse(definition.endsAt);

  // Seed the code only when the operator did not ask for a pause/deactivate-only run.
  const codeToSeed = args.pause || args.deactivateCode ? args.code : (args.code ?? definition.defaultCode);
  const canonical = codeToSeed ? canonicalizeCode(codeToSeed) : undefined;
  const digest = canonical ? codeDigest(canonical) : undefined;

  if (args.dryRun) {
    console.log("[dry-run] would write:");
    console.log(`  promo_campaigns/${definition.campaignID} active=${active}`);
    if (digest) console.log(`  promo_codes/${digest} -> ${definition.campaignID} (code not printed)`);
    if (args.deactivateCode) {
      console.log(`  promo_codes/${codeDigest(canonicalizeCode(args.deactivateCode))} active=false`);
    }
    return;
  }

  // `merge` preserves redemptionCount so a re-seed never resets the cap ledger.
  await campaignRef.set(campaignDoc, { merge: true });
  console.log(`campaign ${definition.campaignID}: active=${active} (policy written)`);

  if (digest) {
    await db.doc(`promo_codes/${digest}`).set(
      {
        campaignID: definition.campaignID,
        active: true,
        label: `${definition.campaignID} code`,
        schemaVersion: 1,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    console.log(`code seeded for ${definition.campaignID} (digest ${digest.slice(0, 12)}…, code not printed)`);
  }

  if (args.deactivateCode) {
    const staleDigest = codeDigest(canonicalizeCode(args.deactivateCode));
    await db.doc(`promo_codes/${staleDigest}`).set({ active: false, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    console.log(`code deactivated (digest ${staleDigest.slice(0, 12)}…)`);
  }
}

main().catch((err) => {
  console.error(`seed-promo-campaign: ${err.message}`);
  process.exitCode = 1;
});
