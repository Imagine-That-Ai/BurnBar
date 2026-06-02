/**
 * Golden parity test for the shared verbatim chunker.
 *
 * Proves the extraction of the chunker out of `scripts/wiki/mem0-sync.mjs` is
 * behavior-preserving: `buildDesired` reproduces EVERY currently committed
 * droid-wiki chunk — same key set, same content hashes — as recorded in
 * `droid-wiki/.mem0-manifest.json`. This is a zero-write reconcile proof: if the
 * keys and content hashes match, `planActions(desired, manifest)` emits no
 * creates/updates/deletes, so the maintainer mem0 mirror is unchanged.
 *
 * Run: node --test scripts/lib/verbatim-chunker.test.mjs
 */

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  buildDesired,
  planActions,
  chunkMarkdown,
  firstH1,
  deriveCategory,
  sha256,
  WHOLE_FILE_MAX_LINES,
  MIN_H2_FOR_SPLIT,
} from "./verbatim-chunker.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WIKI_ROOT = join(REPO_ROOT, "droid-wiki");
const MANIFEST = JSON.parse(readFileSync(join(WIKI_ROOT, ".mem0-manifest.json"), "utf8"));

test("buildDesired reproduces every committed droid-wiki chunk byte-identically", () => {
  const desired = buildDesired(WIKI_ROOT, null);
  const desiredKeys = [...desired.keys()].sort();
  const manifestKeys = Object.keys(MANIFEST.entries).sort();

  assert.deepEqual(
    desiredKeys,
    manifestKeys,
    "chunk key set must match the committed manifest exactly (no added/dropped chunks)",
  );

  for (const [key, d] of desired) {
    assert.equal(
      d.contentHash,
      MANIFEST.entries[key].content_hash,
      `content hash drift for ${key} — chunk text changed vs the committed manifest`,
    );
  }
  assert.equal(desired.size, manifestKeys.length, "chunk count must equal manifest entry count");
});

test("planActions is a zero-write no-op when desired matches the committed manifest", () => {
  const desired = buildDesired(WIKI_ROOT, null);
  const { creates, updates, deletes } = planActions(desired, MANIFEST, null);
  assert.deepEqual(
    { creates: creates.length, updates: updates.length, deletes: deletes.length },
    { creates: 0, updates: 0, deletes: 0 },
    "a clean checkout must reconcile to zero mem0 writes",
  );
});

test("planActions detects content change as an update threading the prior id", () => {
  const desired = new Map([
    ["a.md#0", { key: "a.md#0", text: "new", contentHash: "HASH_NEW", metadata: {} }],
  ]);
  const manifest = { entries: { "a.md#0": { memory_id: "m-old", content_hash: "HASH_OLD" } } };
  const { creates, updates, deletes } = planActions(desired, manifest, null);
  assert.equal(creates.length, 0);
  assert.equal(deletes.length, 0);
  assert.equal(updates.length, 1);
  assert.equal(updates[0].oldId, "m-old", "update must carry the prior memory_id for delete+recreate");
});

test("planActions only reconciles deletes for files in the filter (incremental mode)", () => {
  const desired = new Map();
  const manifest = {
    entries: {
      "touched.md#0": { memory_id: "m1", content_hash: "h1" },
      "untouched.md#0": { memory_id: "m2", content_hash: "h2" },
    },
  };
  const filter = new Set(["touched.md"]);
  const { deletes } = planActions(desired, manifest, filter);
  assert.deepEqual(deletes.map((d) => d.key), ["touched.md#0"]);
});

test("chunkMarkdown keeps small/shallow pages a single whole-file chunk", () => {
  const small = "# Title\n\nShort body.\n";
  const chunks = chunkMarkdown(small);
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].chunk_index, 0);
  assert.equal(chunks[0].chunk_heading, null);
  assert.equal(chunks[0].text, "# Title\n\nShort body.");
});

test("chunkMarkdown splits a large page on H2 boundaries and covers every line once", () => {
  const body = Array.from({ length: 24 }, (_, i) => `line ${i}`).join("\n");
  const text =
    "# Title\n\nintro\n\n" +
    `## Alpha\n${body}\n\n` +
    `## Beta\n${body}\n\n` +
    `## Gamma\n${body}\n`;
  assert.ok(text.split("\n").length >= WHOLE_FILE_MAX_LINES, "fixture must exceed the whole-file threshold");
  const chunks = chunkMarkdown(text);
  // preamble (H1 + intro) + 3 H2 sections
  assert.equal(chunks.length, 1 + MIN_H2_FOR_SPLIT);
  assert.deepEqual(chunks.map((c) => c.chunk_heading), [null, "Alpha", "Beta", "Gamma"]);
  assert.equal(chunks[0].chunk_index, 0);
  assert.equal(chunks[3].chunk_index, 3);
});

test("firstH1 returns the first H1 title or null", () => {
  assert.equal(firstH1("noise\n# The Title\nmore\n# Second"), "The Title");
  assert.equal(firstH1("## only an h2\nbody"), null);
});

test("buildDesired tags member-knowledge metadata without disturbing wiki output", () => {
  const desired = buildDesired(WIKI_ROOT, null, {
    sourceLabel: "member-knowledge",
    sourceKind: "repo_docs",
    sourceSlug: "my-repo",
  });
  const first = desired.values().next().value;
  assert.equal(first.metadata.source, "member-knowledge");
  assert.equal(first.metadata.sourceKind, "repo_docs");
  assert.equal(first.metadata.sourceSlug, "my-repo");
  // content hash is still pure text -> identical to the wiki run for the same chunk
  assert.equal(first.contentHash, MANIFEST.entries[first.key].content_hash);
});

test("deriveCategory maps known sections and falls back to reference", () => {
  assert.equal(deriveCategory("security", "security/threats.md"), "security");
  assert.equal(deriveCategory("apps", "apps/android-app.md"), "architecture");
  assert.equal(deriveCategory("nonexistent", "nonexistent/x.md"), "reference");
  assert.equal(deriveCategory("root", ".survey-context.md"), "orientation");
});

test("sha256 is hex sha-256 of the utf8 text", () => {
  assert.equal(sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
});
