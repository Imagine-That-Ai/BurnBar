/**
 * Pensieve chat-derived memory hook — bring-your-own-inference (the plan's
 * clever core). When an agent session ends, extraction runs on the USER'S own
 * Claude/Codex plan (cost-neutral to BurnBar), distilling the transcript into a
 * few durable, verbatim memories; those are redacted, deduped, embedded +
 * cloaked + sealed on device, and queued for commitKnowledgeBatch.
 *
 *   transcript → runExtractor (claude -p ... --output-format json)  [billed to user]
 *             → parse [{title,text,category,confidence}]
 *             → confidence filter + secret redaction
 *             → dedup (vault-keyed dedupHash) → keep net-new
 *             → embed + cloak + seal → commit (device-authed path)
 *
 * Privacy: every vector carries the VAULT-KEYED `dedupHash`/`slugHmac` the server
 * requires and NO cleartext `contentHash`/`sourcePath` (privacy-leak-remediation-
 * 2026-06-02 §3) — the real path lives only inside the sealed metadata blob.
 *
 * All IO (the extractor spawn, the duplicate check, the commit sink, the
 * filesystem) is injectable so the pipeline is fully unit-testable offline.
 */

import { createHash, createHmac, hkdfSync } from "node:crypto";
import { spawnSync } from "node:child_process";
import { closeSync, constants, mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import { cloakVector, loadDefaultEmbedder, loadVaultKeyBytes, type Embedder } from "./embed.js";
import { sealText } from "./seal.js";
import type { SealedEnvelope } from "./decrypt.js";

export const MIN_CONFIDENCE = 0.6;
const MAX_MEMORY_BYTES = 6 * 1024; // keep each sealed chunk well under requireSealedText's base64 cap

function writePrivateFile(path: string, contents: string): void {
  mkdirSync(dirname(path), { recursive: true });
  const nofollow = constants.O_NOFOLLOW ?? 0;
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | nofollow, 0o600);
  try {
    writeFileSync(fd, contents);
  } finally {
    closeSync(fd);
  }
}

/** The extraction prompt. Asks the user's own model for durable, verbatim, secret-free memories. */
export const EXTRACT_PROMPT = [
  "You are distilling an AI coding session transcript into durable long-term memories.",
  "Return ONLY a JSON array (no prose, no code fence) of at most 8 objects:",
  '  {"title": string, "text": string, "category": string, "confidence": number}',
  "Rules:",
  "- Keep each memory VERBATIM and self-contained (a fact, decision, preference, or gotcha worth recalling weeks later).",
  "- NEVER include secrets: API keys, tokens, passwords, private keys, connection strings. Omit any memory that would require one.",
  "- category is one of: decision, preference, gotcha, architecture, todo, fact.",
  "- confidence in [0,1] = how durably useful this is. Skip ephemeral chatter.",
].join("\n");

export interface ExtractedMemory {
  title: string;
  text: string;
  category: string;
  confidence: number;
}

export interface PreparedVector {
  vectorId: string;
  cloakedVector: number[];
  sealedCiphertext: SealedEnvelope;
  sealedMetadata: SealedEnvelope;
  /**
   * Vault-keyed HMAC(plaintext) — the dedup/idempotency key the server requires
   * (privacy-leak-remediation-2026-06-02 §3). NOT a cleartext SHA-256: the server
   * cannot recompute it from a guessed plaintext, and the same text under two
   * members' keys yields different hashes.
   */
  dedupHash: string;
  /** Vault-keyed HMAC(slug) — the server's content-free source filter key. */
  slugHmac: string;
  sourceKind: "chat_memory";
  chunkIndex: number;
  byteCount: number;
}

function sha256(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/**
 * Vault-keyed dedup/slug HMAC. HKDF-derives a per-user dedup key from the vault
 * key (salt ∅, info `pensieve-dedup:<label>`), then HMAC_SHA256s the value. This
 * is byte-identical to the Swift CloudVaultCrypto helpers and to the server's
 * test fixture (functions/.../knowledgeMemoryDedupHash.test.ts):
 *   HKDF(vaultKey, salt=∅, info="pensieve-dedup:content"|"…:slug") → HMAC(value).
 */
function vaultKeyedHmac(vaultKey: Buffer, label: "content" | "slug", value: string): string {
  const dedupKey = Buffer.from(hkdfSync("sha256", vaultKey, Buffer.alloc(0), `pensieve-dedup:${label}`, 32));
  return createHmac("sha256", dedupKey).update(value, "utf8").digest("hex");
}

// -- secret redaction ---------------------------------------------------------

const SECRET_PATTERNS: Array<{ re: RegExp; label: string }> = [
  { re: /sk-[A-Za-z0-9]{20,}/g, label: "[REDACTED_API_KEY]" },
  { re: /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g, label: "[REDACTED_AWS_KEY]" },
  { re: /ghp_[A-Za-z0-9]{30,}/g, label: "[REDACTED_GH_TOKEN]" },
  { re: /xox[baprs]-[A-Za-z0-9-]{10,}/g, label: "[REDACTED_SLACK_TOKEN]" },
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, label: "[REDACTED_PRIVATE_KEY]" },
  { re: /\b[Bb]earer\s+[A-Za-z0-9._-]{20,}/g, label: "[REDACTED_BEARER]" },
  { re: /\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+/gi, label: "[REDACTED_SECRET]" },
  { re: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, label: "[REDACTED_JWT]" },
];

/** Replace known secret shapes with labels. Returns the cleaned text + a redaction count. */
export function redactSecrets(text: string): { text: string; redactions: number } {
  let out = text;
  let redactions = 0;
  for (const { re, label } of SECRET_PATTERNS) {
    out = out.replace(re, () => {
      redactions += 1;
      return label;
    });
  }
  return { text: out, redactions };
}

// -- parse the extractor output ----------------------------------------------

/** Robustly parse the user-model output (possibly wrapped by `claude -p --output-format json`). */
export function parseExtractedMemories(raw: string): ExtractedMemory[] {
  let payload = raw.trim();

  // `claude -p --output-format json` wraps the model text in { result: "..." }.
  try {
    const outer = JSON.parse(payload) as unknown;
    if (outer && typeof outer === "object" && !Array.isArray(outer)) {
      const result = (outer as { result?: unknown }).result;
      if (typeof result === "string") {payload = result.trim();}
    } else if (Array.isArray(outer)) {
      return normalizeMemories(outer);
    }
  } catch {
    // payload is not the JSON wrapper; fall through to array extraction.
  }

  // Strip a ```json code fence if present, then grab the first JSON array.
  payload = payload.replace(/^```(?:json)?\s*/u, "").replace(/\s*```$/u, "");
  const start = payload.indexOf("[");
  const end = payload.lastIndexOf("]");
  if (start === -1 || end <= start) {return [];}
  try {
    return normalizeMemories(JSON.parse(payload.slice(start, end + 1)));
  } catch {
    return [];
  }
}

function normalizeMemories(raw: unknown): ExtractedMemory[] {
  if (!Array.isArray(raw)) {return [];}
  const out: ExtractedMemory[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") {continue;}
    const rec = item as Record<string, unknown>;
    const text = typeof rec.text === "string" ? rec.text.trim() : "";
    if (!text) {continue;}
    out.push({
      title: typeof rec.title === "string" ? rec.title.trim() : text.slice(0, 60),
      text,
      category: typeof rec.category === "string" ? rec.category.trim() : "fact",
      confidence: typeof rec.confidence === "number" ? rec.confidence : Number(rec.confidence ?? 0),
    });
  }
  return out;
}

// -- prepare for commit -------------------------------------------------------

export interface PrepareDeps {
  embedder: Embedder;
  vaultKey: Buffer;
  cloak?: typeof cloakVector;
  seal?: typeof sealText;
}

/**
 * Redact, filter by confidence, dedup, then embed + cloak + seal each net-new
 * memory into a commitKnowledgeBatch vector entry.
 *
 * The server now requires the vault-keyed `dedupHash`/`slugHmac` and rejects the
 * cleartext `contentHash`/`sourcePath` (privacy-leak-remediation-2026-06-02 §3),
 * so the keyed `dedupHash` is the dedup key, the `vectorId`, and the value passed
 * to `isDuplicate`. The real `source_path` lives ONLY inside the sealed metadata
 * blob (decrypted on device); no cleartext path/hash leaves the device.
 */
export async function prepareMemoriesForCommit(
  memories: ExtractedMemory[],
  sourceSlug: string,
  deps: PrepareDeps,
  isDuplicate: (memory: ExtractedMemory, dedupHash: string) => Promise<boolean> = async () => false,
): Promise<PreparedVector[]> {
  const cloak = deps.cloak ?? cloakVector;
  const seal = deps.seal ?? sealText;
  const slugHmac = vaultKeyedHmac(deps.vaultKey, "slug", sourceSlug);
  const seen = new Set<string>();
  const prepared: PreparedVector[] = [];

  for (const memory of memories) {
    if (memory.confidence < MIN_CONFIDENCE) {continue;}
    const cleaned = redactSecrets(memory.text).text.slice(0, MAX_MEMORY_BYTES);
    if (!cleaned.trim()) {continue;}
    // Vault-keyed dedup hash — opaque to the server. A local non-keyed hash is
    // still used only to label the sealed-metadata source_path fallback below.
    const dedupHash = vaultKeyedHmac(deps.vaultKey, "content", cleaned);
    if (seen.has(dedupHash)) {continue;}
    seen.add(dedupHash);
    if (await isDuplicate(memory, dedupHash)) {continue;}

    const [vector] = await deps.embedder.embed([cleaned]);
    const cloaked = Array.from(cloak(vector, { vaultKey: deps.vaultKey, modelVersion: deps.embedder.modelVersion }));
    const metadata = {
      source: "member-knowledge",
      source_path: `chat/${redactSecrets(memory.title).text.slice(0, 80) || dedupHash.slice(0, 12)}`,
      page_title: redactSecrets(memory.title).text.slice(0, 120),
      section: memory.category,
      category: memory.category,
      chunk_index: 0,
      sourceKind: "chat_memory",
      sourceSlug,
    };
    prepared.push({
      vectorId: dedupHash,
      cloakedVector: cloaked,
      sealedCiphertext: seal(cleaned, deps.vaultKey),
      sealedMetadata: seal(JSON.stringify(metadata), deps.vaultKey),
      dedupHash,
      slugHmac,
      sourceKind: "chat_memory",
      chunkIndex: 0,
      byteCount: Buffer.byteLength(cleaned, "utf8"),
    });
  }
  return prepared;
}

// -- orchestration ------------------------------------------------------------

export interface RunMemorySyncOptions {
  transcript: string; // raw transcript text or path contents
  sourceSlug?: string;
  embeddingModelVersion?: string;
  /** Spawn the user's model. Default: `claude -p <EXTRACT_PROMPT> --output-format json`. */
  runExtractor?: (transcript: string) => string;
  loadEmbedder?: () => Promise<Embedder>;
  vaultKey?: () => Buffer | undefined;
  isDuplicate?: (memory: ExtractedMemory, dedupHash: string) => Promise<boolean>;
  /** Sink for the prepared batch. Default: append to the device commit queue. */
  commit?: (batch: { sourceSlug: string; embeddingModelVersion: string; vectors: PreparedVector[] }) => void;
}

function defaultExtractor(transcript: string): string {
  const proc = spawnSync("claude", ["-p", EXTRACT_PROMPT, "--output-format", "json"], {
    input: transcript,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
  if (proc.status !== 0) {
    throw new Error(`claude extraction failed (${proc.status}): ${proc.stderr?.slice(0, 300) ?? ""}`);
  }
  return proc.stdout ?? "";
}

/** Default commit sink: append the sealed batch to the device queue the daemon/app drains. */
export function defaultCommitQueue(batch: { sourceSlug: string; embeddingModelVersion: string; vectors: PreparedVector[] }): void {
  const dir = join(homedir(), ".openburnbar", "pensieve-queue");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${batch.sourceSlug}-${sha256(JSON.stringify(batch.vectors.map((v) => v.vectorId)))}.json`);
  writeFileSync(file, JSON.stringify(batch, null, 2), { mode: 0o600 });
}

/** Full BYO-inference pipeline. Returns the prepared (and committed) batch. */
export async function runMemorySync(options: RunMemorySyncOptions): Promise<{
  sourceSlug: string;
  embeddingModelVersion: string;
  vectors: PreparedVector[];
}> {
  const sourceSlug = options.sourceSlug ?? "chat-memory";
  const runExtractor = options.runExtractor ?? defaultExtractor;
  const loadEmbedder = options.loadEmbedder ?? loadDefaultEmbedder;
  const vaultKeyFn = options.vaultKey ?? loadVaultKeyBytes;
  const commit = options.commit ?? defaultCommitQueue;

  const key = vaultKeyFn();
  if (!key) {throw new Error("Pensieve vault key unavailable — run `openburnbar mcp login`.");}

  const memories = parseExtractedMemories(runExtractor(options.transcript));
  const embedder = await loadEmbedder();
  const vectors = await prepareMemoriesForCommit(memories, sourceSlug, { embedder, vaultKey: key }, options.isDuplicate);
  const batch = { sourceSlug, embeddingModelVersion: options.embeddingModelVersion ?? embedder.modelVersion, vectors };
  if (vectors.length > 0) {commit(batch);}
  return batch;
}

// -- hook install -------------------------------------------------------------

export interface InstallHookOptions {
  harness?: "claude" | "codex";
  settingsPath?: string; // default ~/.claude/settings.json
  command?: string; // default "openburnbar memory run"
}

/**
 * Install the agent SessionEnd hook so a finished session triggers extraction.
 * Merges into the existing settings.json without clobbering other hooks.
 * Returns the settings path written.
 */
export function installMemoryHook(options: InstallHookOptions = {}): string {
  const harness = options.harness ?? "claude";
  const command = options.command ?? "openburnbar memory run";
  const settingsPath = options.settingsPath ?? join(homedir(), ".claude", "settings.json");

  if (harness !== "claude") {
    throw new Error(`Hook install for harness "${harness}" is not yet supported; use the Mac daemon watch instead.`);
  }

  let settings: Record<string, unknown> = {};
  try {
    settings = JSON.parse(readFileSync(settingsPath, "utf8")) as Record<string, unknown>;
  } catch {
    settings = {};
  }
  const hooks = (settings.hooks as Record<string, unknown>) ?? {};
  const sessionEnd = Array.isArray(hooks.SessionEnd) ? (hooks.SessionEnd as Array<Record<string, unknown>>) : [];

  const alreadyInstalled = sessionEnd.some((entry) =>
    Array.isArray(entry.hooks) &&
    (entry.hooks as Array<Record<string, unknown>>).some((h) => h.command === command),
  );
  if (!alreadyInstalled) {
    sessionEnd.push({ hooks: [{ type: "command", command }] });
  }

  const next = { ...settings, hooks: { ...hooks, SessionEnd: sessionEnd } };
  writePrivateFile(settingsPath, JSON.stringify(next, null, 2));
  return settingsPath;
}
