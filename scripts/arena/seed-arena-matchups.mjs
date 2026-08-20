#!/usr/bin/env node
/**
 * Seed Firestore `arena_matchups` from the bench repo's seed documents.
 *
 *   node scripts/arena/seed-arena-matchups.mjs --docs /path/to/seed_docs.json [--project burnbar] [--auth adc|firebase-cli] [--dry-run]
 *
 * The input is the JSON array produced by runner/arena_seed_firestore.py
 * (matchup_id, task_id, left/right cells, bundle ids, entry paths, probe).
 * Writes are upserts keyed by matchup_id in batches of 500, so re-running is
 * idempotent (the seed docs are deterministic from the matchup + publish
 * manifests).
 *
 * Auth:
 *  - `--auth adc` (default): Application Default Credentials /
 *    GOOGLE_APPLICATION_CREDENTIALS, matching scripts/privacy/*.
 *  - `--auth firebase-cli`: mint an access token from the signed-in Firebase
 *    CLI session (firebase-tools' own auth stack). The token is used in
 *    process only — never printed, never persisted.
 *
 * The documents carry competitor cell ids (server-side reveal data). This
 * script logs only counts and doc ids, never document contents.
 */
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const requireFromFunctions = createRequire(new URL("../../functions/package.json", import.meta.url));

function parseArgs(argv) {
  const args = { project: "burnbar", auth: "adc", dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--docs") args.docs = argv[++i];
    else if (arg === "--project") args.project = argv[++i];
    else if (arg === "--auth") args.auth = argv[++i];
    else if (arg === "--dry-run") args.dryRun = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.docs) throw new Error("--docs <seed_docs.json> is required");
  if (!["adc", "firebase-cli"].includes(args.auth)) throw new Error("--auth must be adc|firebase-cli");
  return args;
}

async function firebaseCliCredential() {
  // Mint an access token from the signed-in Firebase CLI session: read the
  // CLI's own configstore refresh token and exchange it through
  // firebase-tools' auth stack. Both tokens stay inside this process —
  // never printed, never persisted.
  const auth = requireFromFunctions("/opt/homebrew/lib/node_modules/firebase-tools/lib/auth.js");
  const scopes = requireFromFunctions("/opt/homebrew/lib/node_modules/firebase-tools/lib/scopes.js");
  const { readFileSync: read } = await import("node:fs");
  const { homedir } = await import("node:os");
  const { join } = await import("node:path");
  const store = JSON.parse(read(join(homedir(), ".config", "configstore", "firebase-tools.json"), "utf8"));
  const refreshToken = store && store.tokens && store.tokens.refresh_token;
  if (typeof refreshToken !== "string" || refreshToken.length === 0) {
    throw new Error("no firebase CLI session found; run firebase login");
  }
  const wanted = [scopes.OPENID, scopes.EMAIL, scopes.CLOUD_PLATFORM];
  const mint = async () => (await auth.getAccessToken(refreshToken, wanted)).access_token;
  const first = await mint();
  if (typeof first !== "string" || first.length === 0) {
    throw new Error("firebase CLI session did not yield an access token; run firebase login --reauth");
  }
  return { getAccessToken: async () => ({ access_token: await mint(), expires_in: 3600 }) };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const docs = JSON.parse(readFileSync(args.docs, "utf8"));
  if (!Array.isArray(docs)) throw new Error("seed docs must be a JSON array");
  for (const doc of docs) {
    if (typeof doc.matchup_id !== "string" || doc.matchup_id.length === 0) {
      throw new Error("every seed doc needs a matchup_id string");
    }
  }
  console.log(`loaded ${docs.length} seed doc(s) from ${args.docs}`);
  if (args.dryRun) {
    console.log("dry run: no writes");
    return;
  }

  // The Admin SDK's Firestore client only accepts cert/ADC credentials, so
  // writes go through the Firestore REST commit API with the minted access
  // token. Seed docs contain only strings and booleans; encode explicitly.
  const accessToken =
    args.auth === "firebase-cli" ? await firebaseCliAccessToken() : await adcAccessToken();

  const BATCH = 500;
  let written = 0;
  for (let i = 0; i < docs.length; i += BATCH) {
    const slice = docs.slice(i, i + BATCH);
    const writes = slice.map((doc) => ({
      update: {
        name: `projects/${args.project}/databases/(default)/documents/arena_matchups/${doc.matchup_id}`,
        fields: toFirestoreFields(doc),
      },
    }));
    const res = await fetch(
      `https://firestore.googleapis.com/v1/projects/${args.project}/databases/(default)/documents:commit`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({ writes }),
      },
    );
    if (!res.ok) {
      throw new Error(`commit failed: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
    }
    written += slice.length;
    console.log(`committed ${written}/${docs.length}`);
  }
  console.log(`seeded ${written} arena_matchups doc(s) into project ${args.project}`);
}

function toFirestoreFields(doc) {
  const fields = {};
  for (const [key, value] of Object.entries(doc)) {
    if (typeof value === "string") fields[key] = { stringValue: value };
    else if (typeof value === "boolean") fields[key] = { booleanValue: value };
    else if (value === null || value === undefined) fields[key] = { nullValue: null };
    else throw new Error(`unsupported seed doc field type for ${key}: ${typeof value}`);
  }
  return fields;
}

async function adcAccessToken() {
  const { GoogleAuth } = requireFromFunctions("google-auth-library");
  const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/cloud-platform"] });
  const token = await auth.getAccessToken();
  if (typeof token !== "string" || token.length === 0) {
    throw new Error("ADC did not yield an access token; run gcloud auth application-default login");
  }
  return token;
}

async function firebaseCliAccessToken() {
  const credential = await firebaseCliCredential();
  return (await credential.getAccessToken()).access_token;
}

main().catch((error) => {
  console.error(`seed failed: ${error.message}`);
  process.exit(1);
});
