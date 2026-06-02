#!/usr/bin/env node
/**
 * OpenBurnBar Wiki -> mem0 Sync
 *
 * Mirrors the canonical Droid wiki (`droid-wiki/`) into the BurnBar mem0 project
 * as verbatim, retrievable chunks so agents can search for the exact knowledge a
 * task needs instead of bulk-loading whole wiki pages or AGENTS.md.
 *
 * Design invariants:
 *   - Store chunks VERBATIM. We call the mem0 REST API with `infer:false`; mem0's
 *     default inference path summarizes structured docs and the MCP add_memory
 *     tool cannot disable it. `infer:false` requires a `user_id` scope to persist.
 *   - Idempotent + incremental. A committed manifest (droid-wiki/.mem0-manifest.json)
 *     maps "<source_path>#<chunk_index>" -> { memory_id, content_hash }. Re-running
 *     with no wiki change makes zero API writes.
 *   - Fail open. With no API key the script logs a skip and exits 0 so commits,
 *     forks, and CI without secrets never break.
 *
 * Scope: user_id="burnbar", app_id="burnbar" (override with --user-id / --app-id).
 * Agents retrieve with: search_memories(filters={"AND":[{"user_id":"burnbar"}]}).
 *
 * Usage:
 *   # Full reconcile (nightly / first run). Prints a plan, then applies:
 *   node scripts/wiki/mem0-sync.mjs --all
 *
 *   # Preview the plan without touching mem0 or the manifest:
 *   node scripts/wiki/mem0-sync.mjs --all --dry-run
 *
 *   # Incremental: only the wiki files a commit changed (post-commit hook):
 *   node scripts/wiki/mem0-sync.mjs --changed-from-commit HEAD
 *
 *   # Verbose per-chunk logging:
 *   node scripts/wiki/mem0-sync.mjs --all --verbose
 *
 * Env:
 *   MEM0_BURNBAR_API_KEY (preferred) or MEM0_API_KEY - the BurnBar mem0 project key.
 *
 * Exit codes: 0 success or graceful skip, 1 unexpected error.
 */

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { buildDesired, planActions, runPool } from "../lib/verbatim-chunker.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const MEM0_BASE = "https://api.mem0.ai";

function parseArgs(argv) {
  const args = {
    all: false,
    changedFromCommit: null,
    dryRun: false,
    verbose: false,
    wikiRoot: "droid-wiki",
    userId: "burnbar",
    appId: "burnbar",
    concurrency: 5,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--all") args.all = true;
    else if (a === "--dry-run") args.dryRun = true;
    else if (a === "--verbose") args.verbose = true;
    else if (a === "--changed-from-commit") args.changedFromCommit = argv[++i];
    else if (a === "--wiki-root") args.wikiRoot = argv[++i];
    else if (a === "--user-id") args.userId = argv[++i];
    else if (a === "--app-id") args.appId = argv[++i];
    else if (a === "--concurrency") args.concurrency = Number(argv[++i]);
    else if (a === "--help" || a === "-h") args.help = true;
    else throw new Error(`Unknown argument: ${a}`);
  }
  return args;
}

const log = (...m) => console.log("[wiki->mem0]", ...m);

// Wiki discovery + chunking + manifest-diff + worker pool now live in the shared
// `scripts/lib/verbatim-chunker.mjs` so per-member Pensieve ingestion reuses the
// exact same lossless chunker. See that file's golden test for parity proof.

// -- Manifest -----------------------------------------------------------------

function loadManifest(manifestAbs, userId, appId) {
  if (existsSync(manifestAbs)) {
    const m = JSON.parse(readFileSync(manifestAbs, "utf8"));
    m.entries = m.entries || {};
    return m;
  }
  return { schema_version: 1, project: "burnbar", scope: { user_id: userId, app_id: appId }, entries: {} };
}

function writeManifest(manifestAbs, manifest) {
  // Sort entry keys so the committed file has a stable, reviewable diff.
  const sorted = {};
  for (const k of Object.keys(manifest.entries).sort()) sorted[k] = manifest.entries[k];
  manifest.entries = sorted;
  writeFileSync(manifestAbs, JSON.stringify(manifest, null, 2) + "\n");
}

// -- mem0 REST client (verbatim store via infer=false) ------------------------

function makeClient(apiKey) {
  const headers = { Authorization: `Token ${apiKey}`, "Content-Type": "application/json" };
  async function call(method, path, body) {
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(`${MEM0_BASE}${path}`, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });
      if (res.status === 429 || res.status >= 500) {
        if (attempt < 4) {
          await new Promise((r) => setTimeout(r, 500 * 2 ** attempt));
          continue;
        }
      }
      const txt = await res.text();
      if (!res.ok) throw new Error(`mem0 ${method} ${path} -> ${res.status}: ${txt.slice(0, 300)}`);
      return txt ? JSON.parse(txt) : null;
    }
  }
  return {
    async create(text, userId, appId, metadata) {
      const out = await call("POST", "/v1/memories/", {
        messages: [{ role: "user", content: text }],
        user_id: userId,
        app_id: appId,
        infer: false,
        metadata,
      });
      const id = out?.results?.[0]?.id;
      if (!id) throw new Error(`create returned no memory id (verbatim add did not persist): ${JSON.stringify(out).slice(0, 200)}`);
      return id;
    },
    delete: (id) => call("DELETE", `/v1/memories/${id}/`),
  };
}

// -- Main ---------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(1, 45).join("\n"));
    return;
  }
  if (!args.all && !args.changedFromCommit) {
    throw new Error("Specify a mode: --all or --changed-from-commit <ref>");
  }

  const wikiRootAbs = join(REPO_ROOT, args.wikiRoot);
  if (!existsSync(wikiRootAbs)) throw new Error(`Wiki root not found: ${wikiRootAbs}`);
  const manifestAbs = join(wikiRootAbs, ".mem0-manifest.json");

  // Resolve which files to examine.
  let fileFilter = null;
  if (args.changedFromCommit) {
    let changed = [];
    try {
      const out = execFileSync(
        "git",
        ["diff-tree", "--no-commit-id", "--name-only", "-r", args.changedFromCommit],
        { cwd: REPO_ROOT, encoding: "utf8" },
      );
      changed = out.split("\n").filter(Boolean);
    } catch (e) {
      log(`could not read git diff for ${args.changedFromCommit}; nothing to sync`);
      return;
    }
    const prefix = `${args.wikiRoot}/`;
    const wikiChanged = changed
      .filter((p) => p.startsWith(prefix) && p.endsWith(".md"))
      .map((p) => p.slice(prefix.length));
    if (wikiChanged.length === 0) {
      if (args.verbose) log("commit touched no wiki markdown; skipping");
      return;
    }
    fileFilter = new Set(wikiChanged);
    log(`incremental: ${wikiChanged.length} changed wiki file(s)`);
  }

  const desired = buildDesired(wikiRootAbs, fileFilter);
  const manifest = loadManifest(manifestAbs, args.userId, args.appId);
  const { creates, updates, deletes } = planActions(desired, manifest, fileFilter);

  log(
    `plan: ${creates.length} create, ${updates.length} update, ${deletes.length} delete ` +
      `(desired ${desired.size} chunks, manifest ${Object.keys(manifest.entries).length})`,
  );
  if (args.verbose || args.dryRun) {
    for (const c of creates) log(`  + create ${c.key}`);
    for (const u of updates) log(`  ~ update ${u.key}`);
    for (const d of deletes) log(`  - delete ${d.key}`);
  }

  if (creates.length === 0 && updates.length === 0 && deletes.length === 0) {
    log("already in sync - zero writes");
    return;
  }
  if (args.dryRun) {
    log("dry-run: no changes applied");
    return;
  }

  const apiKey = process.env.MEM0_BURNBAR_API_KEY || process.env.MEM0_API_KEY;
  if (!apiKey) {
    log("mem0 sync skipped (no MEM0_BURNBAR_API_KEY / MEM0_API_KEY in env)");
    return;
  }
  const client = makeClient(apiKey);

  // Deletes first (frees space + clears stale ids), then updates (delete+create), then creates.
  await runPool(deletes, args.concurrency, async (d) => {
    await client.delete(d.memory_id);
    delete manifest.entries[d.key];
    if (args.verbose) log(`  deleted ${d.key}`);
  });
  await runPool(updates, args.concurrency, async (u) => {
    await client.delete(u.oldId).catch((e) => log(`  warn: stale delete ${u.key}: ${e.message}`));
    const id = await client.create(u.text, args.userId, args.appId, u.metadata);
    manifest.entries[u.key] = { memory_id: id, content_hash: u.contentHash };
    if (args.verbose) log(`  updated ${u.key}`);
  });
  await runPool(creates, args.concurrency, async (c) => {
    const id = await client.create(c.text, args.userId, args.appId, c.metadata);
    manifest.entries[c.key] = { memory_id: id, content_hash: c.contentHash };
    if (args.verbose) log(`  created ${c.key}`);
  });

  writeManifest(manifestAbs, manifest);
  log(`done. manifest now tracks ${Object.keys(manifest.entries).length} chunks -> ${relative(REPO_ROOT, manifestAbs)}`);
}

main().catch((e) => {
  console.error("[wiki->mem0] error:", e.message);
  process.exit(1);
});
