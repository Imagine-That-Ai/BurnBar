#!/usr/bin/env node
/**
 * N-1 snapshot gate for the daemon RPC method catalog.
 *
 * Wire ids are a compatibility surface: an N-1 client may call any method in
 * this snapshot, so a removal or rename breaks released clients while an
 * addition is safe. This gate pins the sorted catalog in
 * fixtures/daemon-rpc-methods.snapshot.json and fails on ANY drift:
 *
 *   * removed ids  -> hard failure; the method must stay (freeze, not
 *                     delete) or the removal ships as a deliberate, reviewed
 *                     breaking change with the snapshot regenerated.
 *   * added ids    -> failure until acknowledged; regenerate the snapshot so
 *                     the new method shows up explicitly in review.
 *
 * Regenerate (after review): node tools/schema-sync/check-rpc-snapshot.mjs --update
 * Run via check-drift.sh (CI: fast-feedback schema-drift job) or directly.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseTspStringEnum } from "./emit/parse-tsp-enum.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const snapshotPath = join(__dirname, "fixtures/daemon-rpc-methods.snapshot.json");
const tspPath = join(__dirname, "typespec/domains/daemon-rpc.tsp");
const GENERATED_BY = "tools/schema-sync/check-rpc-snapshot.mjs --update";

const live = parseTspStringEnum(tspPath, "RpcMethod")
  .map((member) => member.value)
  .sort();

if (process.argv.includes("--update")) {
  writeFileSync(snapshotPath, JSON.stringify({ generatedBy: GENERATED_BY, methodCount: live.length, methods: live }, null, 2) + "\n");
  console.log(`rpc snapshot updated: ${live.length} method(s) pinned.`);
  process.exit(0);
}

let snapshot;
try {
  snapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));
} catch (error) {
  console.error(`rpc snapshot check FAILED: cannot read ${snapshotPath} (${String(error.message ?? error)})`);
  process.exit(1);
}
if (snapshot.methodCount !== snapshot.methods.length) {
  console.error(
    `rpc snapshot check FAILED: snapshot is self-inconsistent (methodCount ${snapshot.methodCount} != ${snapshot.methods.length} methods). ` +
      `Regenerate it: node tools/schema-sync/check-rpc-snapshot.mjs --update`
  );
  process.exit(1);
}
const pinned = new Set(snapshot.methods);
const liveSet = new Set(live);
const removed = snapshot.methods.filter((id) => !liveSet.has(id)).sort();
const added = live.filter((id) => !pinned.has(id)).sort();

if (removed.length > 0 || added.length > 0) {
  if (removed.length > 0) {
    console.error(
      `rpc snapshot check FAILED: ${removed.length} method(s) vanished from the .tsp catalog — N-1 clients may still call them: ${removed.join(", ")}. ` +
        `Restore the wire id(s), or ship the removal as a reviewed breaking change and regenerate the snapshot.`
    );
  }
  if (added.length > 0) {
    console.error(
      `rpc snapshot check FAILED: ${added.length} new method(s) not yet pinned in the snapshot: ${added.join(", ")}. ` +
        `Regenerate the snapshot so the addition shows up in review: node tools/schema-sync/check-rpc-snapshot.mjs --update`
    );
  }
  process.exit(1);
}
console.log(`rpc snapshot check passed: ${live.length} method(s) match the N-1 snapshot.`);
