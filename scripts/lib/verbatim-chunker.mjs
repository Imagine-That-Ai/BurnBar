/**
 * Verbatim markdown chunker — shared ingestion library.
 *
 * These are the behavior-preserving pure functions originally defined inline in
 * `scripts/wiki/mem0-sync.mjs` (the maintainer droid-wiki -> mem0 mirror). They
 * are lifted here verbatim so the same lossless chunker, manifest-diff, and
 * worker-pool power BOTH:
 *   - the maintainer wiki sync (`scripts/wiki/mem0-sync.mjs`), and
 *   - per-member Pensieve knowledge ingestion (on-device chunk -> embed ->
 *     encrypt -> commitKnowledgeBatch).
 *
 * Design invariants (must not change — the maintainer sync depends on them):
 *   - Chunks are VERBATIM and lossless. `chunkMarkdown` covers every input line
 *     exactly once; small/shallow pages stay a single whole-file chunk.
 *   - Idempotent manifest diff. `planActions` emits zero creates/updates/deletes
 *     when the desired chunk set matches the committed manifest content hashes.
 *
 * The golden test (`verbatim-chunker.test.mjs`) proves this extraction is
 * byte-identical to the previously committed `droid-wiki/.mem0-manifest.json`.
 */

import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, basename } from "node:path";

// -- Chunking thresholds (tuned to the observed wiki: consistent H2 schema, no front-matter) --
export const WHOLE_FILE_MAX_LINES = 70; // pages below this stay a single chunk
export const MIN_H2_FOR_SPLIT = 3; // pages with fewer H2s than this stay a single chunk

// section (first path segment) -> coarse category for metadata filtering
export const SECTION_CATEGORY = {
  overview: "orientation",
  systems: "architecture",
  apps: "architecture",
  packages: "architecture",
  primitives: "architecture",
  features: "product",
  reference: "api-reference",
  "how-to-contribute": "contributor",
  background: "decisions",
  "cleanup-opportunities": "tech-debt",
  security: "security",
};

export const sha256 = (s) => createHash("sha256").update(s, "utf8").digest("hex");

// -- Discovery + chunking -----------------------------------------------------

export function listMarkdown(rootAbs) {
  const out = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const abs = join(dir, name);
      if (statSync(abs).isDirectory()) {
        walk(abs);
      } else if (name.endsWith(".md")) {
        out.push(abs);
      }
    }
  };
  walk(rootAbs);
  return out.sort();
}

export function deriveCategory(section, sourcePath) {
  if (basename(sourcePath) === ".survey-context.md") return "orientation";
  return SECTION_CATEGORY[section] || "reference";
}

/**
 * Split one markdown file into lossless, verbatim chunks.
 * Segment 0 = everything before the first H2 (H1 + intro). Segments 1..n = each H2 section.
 * Small / shallow pages stay a single whole-file chunk.
 * Returns [{ chunk_index, chunk_heading, text }] covering every line exactly once.
 */
export function chunkMarkdown(text) {
  const lines = text.split("\n");
  const h2Idx = [];
  for (let i = 0; i < lines.length; i++) {
    if (/^##\s+\S/.test(lines[i])) h2Idx.push(i);
  }
  if (lines.length < WHOLE_FILE_MAX_LINES || h2Idx.length < MIN_H2_FOR_SPLIT) {
    return [{ chunk_index: 0, chunk_heading: null, text: text.trimEnd() }];
  }
  const bounds = [0, ...h2Idx, lines.length];
  const chunks = [];
  for (let s = 0; s < bounds.length - 1; s++) {
    const seg = lines.slice(bounds[s], bounds[s + 1]).join("\n").trim();
    if (!seg) continue; // skip an empty preamble (file starting directly with an H2)
    const headingLine = lines[bounds[s]];
    const chunk_heading = /^##\s+/.test(headingLine) ? headingLine.replace(/^##\s+/, "").trim() : null;
    chunks.push({ chunk_index: chunks.length, chunk_heading, text: seg });
  }
  return chunks;
}

export function firstH1(text) {
  for (const line of text.split("\n")) {
    if (/^#\s+\S/.test(line)) return line.replace(/^#\s+/, "").trim();
  }
  return null;
}

/**
 * Build the desired chunk set keyed by "<source_path>#<chunk_index>".
 *
 * The maintainer wiki sync calls this with no options, which reproduces the
 * original droid-wiki behavior byte-for-byte (`source: "droid-wiki"`). Member
 * Pensieve ingestion passes `{ sourceLabel: "member-knowledge", sourceKind,
 * sourceSlug }` so the sealed chunk metadata carries the member source tags
 * documented in the Pensieve plan. The chunker, hashing, and key scheme are
 * identical across both callers.
 *
 * @param {string} rootAbs absolute folder to walk
 * @param {Set<string>|null} fileFilter optional set of relative source paths to include
 * @param {{ sourceLabel?: string, sourceKind?: string, sourceSlug?: string }} [options]
 */
export function buildDesired(rootAbs, fileFilter, options = {}) {
  const { sourceLabel = "droid-wiki", sourceKind, sourceSlug } = options;
  const desired = new Map();
  for (const abs of listMarkdown(rootAbs)) {
    const sourcePath = relative(rootAbs, abs).split("\\").join("/");
    if (fileFilter && !fileFilter.has(sourcePath)) continue;
    const raw = readFileSync(abs, "utf8");
    const pageTitle = firstH1(raw) || sourcePath;
    const segments = sourcePath.split("/");
    const section = basename(sourcePath) === ".survey-context.md" ? "root" : segments[0];
    const subsection = segments.length > 2 ? segments[1] : null;
    const fileHash = sha256(raw);
    for (const c of chunkMarkdown(raw)) {
      const key = `${sourcePath}#${c.chunk_index}`;
      const metadata = {
        source: sourceLabel,
        source_path: sourcePath,
        page_title: pageTitle,
        section,
        subsection,
        chunk_heading: c.chunk_heading,
        chunk_index: c.chunk_index,
        category: deriveCategory(section, sourcePath),
        file_hash: fileHash,
      };
      // Member-knowledge source tags are added only when provided so the
      // maintainer wiki metadata stays byte-identical.
      if (sourceKind !== undefined) metadata.sourceKind = sourceKind;
      if (sourceSlug !== undefined) metadata.sourceSlug = sourceSlug;
      desired.set(key, { key, text: c.text, contentHash: sha256(c.text), metadata });
    }
  }
  return desired;
}

// -- Manifest reconcile -------------------------------------------------------

/**
 * Diff the desired chunk set against a committed manifest.
 * Returns { creates, updates, deletes }. Re-running with unchanged content
 * (same content_hash) yields three empty arrays — the idempotency contract.
 *
 * Manifest entries are `{ "<source_path>#<chunk_index>": { memory_id|vectorId, content_hash } }`.
 * `idField` selects which prior id field to thread onto updates/deletes
 * ("memory_id" for the wiki mem0 mirror, "vectorId" for Pensieve).
 */
export function planActions(desired, manifest, fileFilter, idField = "memory_id") {
  const creates = [];
  const updates = []; // content changed -> delete old + create new
  const deletes = []; // present in manifest, gone from desired

  for (const [key, d] of desired) {
    const prev = manifest.entries[key];
    if (!prev) creates.push(d);
    else if (prev.content_hash !== d.contentHash) updates.push({ ...d, oldId: prev[idField] });
  }
  for (const [key, prev] of Object.entries(manifest.entries)) {
    if (desired.has(key)) continue;
    // In incremental mode only reconcile deletes for files we actually examined.
    if (fileFilter && !fileFilter.has(key.split("#")[0])) continue;
    deletes.push({ key, [idField]: prev[idField] });
  }
  return { creates, updates, deletes };
}

/** Bounded-concurrency worker pool. Runs `worker(item)` over `items`, at most `concurrency` at a time. */
export async function runPool(items, concurrency, worker) {
  let i = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (i < items.length) {
      const idx = i++;
      await worker(items[idx]);
    }
  });
  await Promise.all(runners);
}
