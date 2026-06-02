import { createHash, createHmac } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { decryptSealedText, hasVaultKey } from "./decrypt.js";
import { readAccessToken } from "./oauth.js";
import { readVaultKey } from "./vaultStore.js";
import { DEFAULT_ENDPOINT, validatedMcpEndpoint } from "./shim.js";

const execFileAsync = promisify(execFile);
const PROTOCOL_VERSION = "2025-11-25";
const DEFAULT_CLEANUP_AFTER_SECONDS = 600;
const MAX_LOCAL_RESUME_MARKDOWN_BYTES = 2 * 1024 * 1024;

export type ResumeMode = "print" | "copy" | "open" | "spawn";

export interface ResumeViaShimOptions {
  sessionId?: string;
  query?: string;
  provider?: string;
  projectName?: string;
  targetHarness?: string;
  targetModel?: string;
  mode?: ResumeMode;
  endpoint?: string;
}

class ResumeCliError extends Error {
  constructor(message: string, readonly exitCode: number) {
    super(message);
  }
}

interface JsonRpcToolResponse {
  result?: { content?: Array<{ type: string; text: string }> };
  error?: { message?: string };
}

const TOKEN_SEARCH_SALT = Buffer.from("OpenBurnBar-CloudSearch-Salt-v1");
const TOKEN_SEARCH_INFO = Buffer.from("OpenBurnBar-CloudSearch-TokenHash-v1");
const SEMANTIC_SEARCH_SALT = Buffer.from("OpenBurnBar-CloudSearch-Semantic-Salt-v1");
const SEMANTIC_SEARCH_INFO = Buffer.from("OpenBurnBar-CloudSearch-SemanticHash-v1");
const STOPWORDS = new Set([
  "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
  "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
  "into", "onto", "can", "could", "should", "would"
]);

export interface RenderedResume {
  kind: string;
  text: string;
  pathPayload?: string;
  targetHarness?: string;
  targetModel?: string;
  targetArgv?: string[];
  workingDirectory?: string;
}

export interface ResumeSpawnCommand {
  command: string;
  args: string[];
  cwd?: string;
  briefingPath?: string;
}

interface SearchHitRecord {
  documentID?: unknown;
  sessionID?: unknown;
  sourceID?: unknown;
  provider?: unknown;
  model?: unknown;
  projectName?: unknown;
  startedAt?: unknown;
  lastMessageAt?: unknown;
  sealedTitle?: unknown;
  sealedSnippet?: unknown;
  sealedBodyPreview?: unknown;
  score?: unknown;
  matchKind?: unknown;
}

function requireVaultKey(): void {
  if (hasVaultKey()) return;
  throw new ResumeCliError(JSON.stringify({
    kind: "error",
    code: "vault_key_unavailable",
    recovery: "Run `openburnbar mcp login` and re-link your vault key from the OpenBurnBar app."
  }), 3);
}

async function callHostedTool(name: string, args: Record<string, unknown>, endpoint = process.env.OPENBURNBAR_MCP_ENDPOINT ?? DEFAULT_ENDPOINT): Promise<unknown> {
  const target = validatedMcpEndpoint(endpoint);
  const token = readAccessToken();
  if (!token) {
    throw new ResumeCliError(JSON.stringify({
      kind: "error",
      code: "mcp_auth_unavailable",
      recovery: "Run `openburnbar mcp login`, pipe a manual token to `openburnbar mcp login --stdin`, or connect from the OpenBurnBar app."
    }), 3);
  }
  const response = await fetch(target, {
    method: "POST",
    headers: {
      "accept": "application/json, text/event-stream",
      "content-type": "application/json",
      "authorization": `Bearer ${token}`,
      "MCP-Protocol-Version": PROTOCOL_VERSION
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: "openburnbar-resume",
      method: "tools/call",
      params: {
        name,
        arguments: args
      }
    })
  });
  const json = await response.json() as JsonRpcToolResponse;
  if (json.error) {
    throw new ResumeCliError(json.error.message ?? "Hosted MCP resume failed.", 1);
  }
  const text = json.result?.content?.find((item) => item.type === "text")?.text;
  if (!text) throw new ResumeCliError("Hosted MCP resume returned no text content.", 1);
  return JSON.parse(text) as unknown;
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function readVaultKeyBytes(): Buffer {
  const raw = readVaultKey();
  const key = raw ? Buffer.from(raw, "base64") : undefined;
  if (!key || key.length !== 32) {
    throw new ResumeCliError(JSON.stringify({
      kind: "error",
      code: "vault_key_unavailable",
      recovery: "Run `openburnbar mcp login` and re-link your vault key from the OpenBurnBar app."
    }), 3);
  }
  return key;
}

function hkdfSha256(input: Buffer, salt: Buffer, info: Buffer, length: number): Buffer {
  const prk = createHmac("sha256", salt.length > 0 ? salt : Buffer.alloc(32)).update(input).digest();
  const chunks: Buffer[] = [];
  let previous = Buffer.alloc(0);
  let written = 0;
  let counter = 1;
  while (written < length) {
    previous = createHmac("sha256", prk)
      .update(previous)
      .update(info)
      .update(Buffer.from([counter]))
      .digest();
    chunks.push(previous);
    written += previous.length;
    counter += 1;
  }
  return Buffer.concat(chunks).subarray(0, length);
}

function normalizedTokens(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/u)
    .filter((token) => token.length >= 2 && !STOPWORDS.has(token));
}

function tokenHashes(text: string, vaultKey: Buffer, limit: number): string[] {
  const searchKey = hkdfSha256(vaultKey, TOKEN_SEARCH_SALT, TOKEN_SEARCH_INFO, 32);
  const hashes: string[] = [];
  const seen = new Set<string>();
  for (const token of normalizedTokens(text)) {
    if (seen.has(token)) continue;
    seen.add(token);
    hashes.push(createHmac("sha256", searchKey).update(token).digest().subarray(0, 16).toString("hex"));
    if (hashes.length >= limit) break;
  }
  return hashes;
}

function simpleSemanticStem(token: string): string {
  for (const suffix of ["ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s"]) {
    if (token.length > suffix.length + 3 && token.endsWith(suffix)) {
      const stem = token.slice(0, -suffix.length);
      return suffix === "ies" || suffix === "ied" ? `${stem}y` : stem;
    }
  }
  return token;
}

function semanticFeatures(tokens: string[]): Array<{ name: string; weight: number }> {
  const features: Array<{ name: string; weight: number }> = [];
  const seen = new Set<string>();
  const append = (name: string, weight: number) => {
    if (!name || seen.has(name)) return;
    seen.add(name);
    features.push({ name, weight });
  };
  for (const token of tokens) {
    append(`token:${token}`, 2.4);
    const stem = simpleSemanticStem(token);
    if (stem !== token) append(`stem:${stem}`, 1.8);
    if (token.length >= 5) append(`prefix:${token.slice(0, 5)}`, 0.8);
  }
  for (let index = 0; index < tokens.length - 1; index += 1) {
    append(`bigram:${tokens[index]}_${tokens[index + 1]}`, 1.3);
  }
  return features;
}

function semanticHashes(text: string, vaultKey: Buffer, limit: number): string[] {
  const tokens = normalizedTokens(text);
  if (tokens.length === 0 || limit <= 0) return [];
  const searchKey = hkdfSha256(vaultKey, SEMANTIC_SEARCH_SALT, SEMANTIC_SEARCH_INFO, 32);
  const accumulator = Array.from({ length: 64 }, () => 0);
  const features = semanticFeatures(tokens);
  for (const feature of features) {
    const digest = createHmac("sha256", searchKey).update(feature.name).digest();
    const index = ((digest[0] << 8) | digest[1]) % accumulator.length;
    accumulator[index] += (digest[2] & 1) === 0 ? feature.weight : -feature.weight;
  }
  const hashes: string[] = [];
  const seen = new Set<string>();
  const appendBucket = (bucket: string) => {
    if (hashes.length >= limit) return;
    const hash = createHmac("sha256", searchKey).update(bucket).digest().subarray(0, 16).toString("hex");
    if (seen.has(hash)) return;
    seen.add(hash);
    hashes.push(hash);
  };
  for (let band = 0; band < 8; band += 1) {
    let value = 0;
    for (let bit = 0; bit < 8; bit += 1) {
      if (accumulator[band * 8 + bit] >= 0) value |= 1 << bit;
    }
    appendBucket(`simhash:v1:band:${band}:${value.toString(16).padStart(2, "0")}`);
  }
  for (const feature of features.slice(0, Math.max(0, limit - hashes.length))) {
    appendBucket(`feature:v1:${feature.name}`);
  }
  return hashes;
}

function stableJson(value: unknown): string {
  if (!value || typeof value !== "object" || Array.isArray(value)) return JSON.stringify(value);
  const record = value as Record<string, unknown>;
  return JSON.stringify(Object.fromEntries(Object.keys(record).sort().map((key) => [key, record[key]])));
}

function decryptRequired(value: unknown, field: string): string {
  const opened = decryptSealedText(value);
  if (opened === undefined) throw new ResumeCliError(`error: could not decrypt sealed resume field '${field}'`, 3);
  return opened;
}

function normalizeHarness(value: unknown): string {
  const raw = typeof value === "string" ? value.trim() : "";
  const slug = raw.toLowerCase().replace(/[^a-z0-9]+/gu, "_").replace(/^_+|_+$/gu, "");
  return ({
    claude: "claude_code",
    claudecode: "claude_code",
    claude_code: "claude_code",
    codex: "codex",
    cursor: "cursor",
    windsurf: "windsurf",
    goose: "goose"
  } as Record<string, string>)[slug] ?? slug;
}

function displayDate(value: unknown): string {
  if (typeof value !== "string" || !value) return "unknown date";
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return value;
  return date.toLocaleString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  });
}

function oneLine(value: string | undefined, fallback: string, max = 180): string {
  const text = (value ?? "").replace(/\s+/gu, " ").trim();
  if (!text) return fallback;
  return text.length > max ? `${text.slice(0, max - 3).trimEnd()}...` : text;
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/gu, "'\\''")}'`;
}

function renderHostedResumeCandidates(response: unknown, query: string, targetHarness?: string): RenderedResume {
  const record = response && typeof response === "object" ? response as Record<string, unknown> : {};
  const hits = Array.isArray(record.hits) ? record.hits as SearchHitRecord[] : [];
  const target = targetHarness ?? "claudeCode";
  if (hits.length === 0) {
    return {
      kind: "candidate_list",
      text: [
        `OBB Resume probable matches for: "${query}"\n`,
        "\nNo synced hosted memories matched this fuzzy search.\n",
        "Try more specific words, a project name, an agent name, or paste a session id.\n"
      ].join("")
    };
  }

  const lines = [
    `OBB Resume probable matches for: "${query}"`,
    "",
    "Pick one and run its Resume command.",
    ""
  ];
  hits.slice(0, 10).forEach((hit, index) => {
    const documentID = typeof hit.documentID === "string" ? hit.documentID : "";
    const sessionID = typeof hit.sessionID === "string" ? hit.sessionID : undefined;
    const sourceID = typeof hit.sourceID === "string" ? hit.sourceID : undefined;
    const resumeID = documentID || sessionID || sourceID || "";
    const title = oneLine(decryptSealedText(hit.sealedTitle), "Untitled session", 100);
    const snippet = oneLine(decryptSealedText(hit.sealedSnippet) ?? decryptSealedText(hit.sealedBodyPreview), "No decrypted preview available.");
    const provider = typeof hit.provider === "string" && hit.provider ? hit.provider : "unknown agent";
    const model = typeof hit.model === "string" && hit.model ? hit.model : "unknown model";
    const project = typeof hit.projectName === "string" && hit.projectName ? hit.projectName : "unknown project";
    const date = displayDate(hit.lastMessageAt ?? hit.startedAt);
    const score = typeof hit.score === "number" ? ` ${(hit.score * 100).toFixed(0)}%` : "";
    const kind = typeof hit.matchKind === "string" ? hit.matchKind : "match";
    lines.push(`${index + 1}. ${title}`);
    lines.push(`   ${date} | ${provider} | ${model} | ${project} | ${kind}${score}`);
    lines.push(`   ${snippet}`);
    if (resumeID) {
      lines.push(`   Resume: OBB Resume ${shellQuote(resumeID)} --as ${target}`);
      lines.push(`   ID: ${resumeID}`);
    }
    lines.push("");
  });
  return { kind: "candidate_list", text: lines.join("\n") };
}

function isSessionNotFound(response: unknown): boolean {
  const record = response && typeof response === "object" ? response as Record<string, unknown> : {};
  return record.kind === "error" && record.code === "session_not_found";
}

function modelArgs(targetHarness: string | undefined, targetModel: string | undefined): string[] {
  if (!targetModel) return [];
  if (targetHarness === "claude_code" || targetHarness === "codex") return ["--model", targetModel];
  return [];
}

export function renderHostedResumeResponse(response: unknown): RenderedResume {
  if (!response || typeof response !== "object") {
    throw new ResumeCliError("Hosted MCP resume returned an invalid response.", 1);
  }
  const record = response as Record<string, unknown>;
  if (record.kind === "native") {
    const argv = Array.isArray(record.argv) ? record.argv.map(String) : [];
    const cwd = typeof record.working_directory === "string" ? `# Run from: ${record.working_directory}\n` : "";
    return {
      kind: "native",
      text: `${cwd}${argv.join(" ")}`,
      targetArgv: argv,
      targetHarness: normalizeHarness(record.target_harness),
      workingDirectory: typeof record.working_directory === "string" ? record.working_directory : undefined
    };
  }
  if (record.kind === "ported" && typeof record.briefing_md === "string") {
    return {
      kind: "ported",
      text: record.briefing_md,
      pathPayload: record.briefing_md,
      targetHarness: normalizeHarness(record.target_harness),
      targetModel: typeof record.target_model === "string" ? record.target_model : undefined,
      targetArgv: Array.isArray(record.target_argv) ? record.target_argv.map(String) : undefined,
      workingDirectory: typeof record.working_directory === "string" ? record.working_directory : undefined
    };
  }
  if (record.kind === "error") {
    const code = typeof record.code === "string" ? record.code : "unknown";
    const recovery = typeof record.recovery === "string" ? record.recovery : "";
    return { kind: "error", text: `error: ${code}\n${recovery}` };
  }
  if (record.kind !== "ported_sealed") {
    throw new ResumeCliError(`Unsupported resume response kind '${String(record.kind)}'.`, 1);
  }

  const header = (record.header_plain && typeof record.header_plain === "object")
    ? record.header_plain as Record<string, unknown>
    : {};
  const sealed = (record.sealed && typeof record.sealed === "object")
    ? record.sealed as Record<string, unknown>
    : {};
  const trailChunks = Array.isArray(sealed.trail_chunks) ? sealed.trail_chunks : [];
  const bodyHashes = Array.isArray(record.body_hashes) ? record.body_hashes.map(String) : [];
  for (const [index, chunk] of trailChunks.entries()) {
    if (bodyHashes[index] && sha256(stableJson(chunk)) !== bodyHashes[index]) {
      throw new ResumeCliError(`error: sealed trail chunk ${index} failed integrity check`, 3);
    }
  }

  const title = decryptSealedText(sealed.summary_title) ?? "Encrypted session";
  const summary = decryptRequired(sealed.summary, "summary");
  const context = decryptRequired(sealed.context, "context");
  const handOff = decryptRequired(sealed.hand_off, "hand_off");
  const trail = trailChunks.map((chunk, index) => decryptRequired(chunk, `trail_chunks[${index}]`));
  const projectName = typeof header.project_name === "string" ? header.project_name : "-";
  const provider = typeof header.provider === "string" ? header.provider : "unknown";
  const model = typeof header.model === "string" ? header.model : "unknown";
  const started = typeof header.started_at === "string" ? header.started_at : "unknown";
  const ended = typeof header.last_message_at === "string" ? header.last_message_at : "unknown";
  const text = [
    `# BurnBar Resume: ${title}\n\n`,
    `**Project:** ${projectName}\n`,
    `**Source:** ${provider} / \`${model}\`\n`,
    `**Session:** ${started} -> ${ended}\n\n`,
    `## Summary\n${summary || "No generated summary is available."}\n\n`,
    `## Context\n${context || "No context block is available."}\n\n`,
    `## Conversation Trail\n> Showing ${trail.length} sealed chunk(s).\n\n${trail.join("\n\n")}\n\n`,
    `## Handoff\n${handOff || "No handoff was recorded."}\n`
  ].join("");
  return {
    kind: "ported_sealed",
    text,
    pathPayload: text,
    targetHarness: normalizeHarness(record.target_harness),
    targetModel: typeof record.target_model === "string" ? record.target_model : undefined
  };
}

async function copyToClipboard(text: string): Promise<void> {
  if (process.platform === "darwin") {
    const child = spawn("pbcopy", [], { stdio: ["pipe", "ignore", "ignore"] });
    child.stdin.end(text);
    await new Promise<void>((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code) => code === 0 ? resolve() : reject(new Error(`pbcopy exited ${code}`)));
    });
    return;
  }
  if (process.platform === "linux") {
    const child = spawn("xclip", ["-selection", "clipboard"], { stdio: ["pipe", "ignore", "ignore"] });
    child.stdin.end(text);
    await new Promise<void>((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code) => code === 0 ? resolve() : reject(new Error(`xclip exited ${code}`)));
    });
    return;
  }
  throw new ResumeCliError(JSON.stringify({
    kind: "error",
    code: "unsupported_platform",
    recovery: "--copy is currently supported on macOS and Linux."
  }), 2);
}

async function openTempMarkdown(text: string): Promise<string> {
  assertLocalResumeMarkdown(text);
  const dir = mkdtempSync(join(tmpdir(), "burnbar-resume-"));
  const path = join(dir, "resume.md");
  writeFileSync(path, text, { mode: 0o600 });
  chmodSync(path, 0o600);
  if (process.platform === "darwin") {
    await execFileAsync("open", [path]);
  } else if (process.platform === "linux") {
    await execFileAsync("xdg-open", [path]);
  } else {
    throw new ResumeCliError(JSON.stringify({
      kind: "error",
      code: "unsupported_platform",
      recovery: "--open is currently supported on macOS and Linux."
    }), 2);
  }
  return path;
}

function writeTempMarkdownSync(text: string): string {
  assertLocalResumeMarkdown(text);
  const dir = mkdtempSync(join(tmpdir(), "burnbar-resume-"));
  const path = join(dir, "resume.md");
  writeFileSync(path, text, { mode: 0o600 });
  chmodSync(path, 0o600);
  return path;
}

function assertLocalResumeMarkdown(text: string): void {
  const bytes = Buffer.byteLength(text, "utf8");
  if (bytes > MAX_LOCAL_RESUME_MARKDOWN_BYTES) {
    throw new ResumeCliError(JSON.stringify({
      kind: "error",
      code: "resume_payload_too_large",
      recovery: "Narrow the resume query or use --print for manual review."
    }), 2);
  }
}

function scheduleDelete(path: string | undefined, seconds = DEFAULT_CLEANUP_AFTER_SECONDS): void {
  if (!path) return;
  const timer = setTimeout(() => {
    import("node:fs").then(({ rmSync }) => {
      try {
        rmSync(path, { force: true });
      } catch {
        // Best-effort cleanup only.
      }
    }).catch(() => {});
  }, seconds * 1000);
  timer.unref();
}

export function buildResumeSpawnCommand(rendered: RenderedResume): ResumeSpawnCommand {
  if (rendered.kind === "native" && rendered.targetArgv?.length) {
    const [command, ...args] = rendered.targetArgv;
    return { command, args, cwd: rendered.workingDirectory };
  }

  const targetHarness = normalizeHarness(rendered.targetHarness) || "claude_code";
  const targetModel = rendered.targetModel;
  const model = modelArgs(targetHarness, targetModel);
  if (targetHarness === "claude_code") {
    return {
      command: "claude",
      args: [...model, "--append-system-prompt", "Use the OpenBurnBar Resume briefing as canonical handoff context.", rendered.text],
      cwd: rendered.workingDirectory
    };
  }
  if (targetHarness === "codex") {
    const args = [...model];
    if (rendered.workingDirectory) args.push("-C", rendered.workingDirectory);
    args.push(rendered.text);
    return { command: "codex", args, cwd: rendered.workingDirectory };
  }
  if (targetHarness === "cursor" || targetHarness === "windsurf") {
    const briefingPath = writeTempMarkdownSync(rendered.pathPayload ?? rendered.text);
    return {
      command: "open",
      args: ["-a", targetHarness === "cursor" ? "Cursor" : "Windsurf", rendered.workingDirectory ?? briefingPath],
      cwd: rendered.workingDirectory,
      briefingPath
    };
  }
  const briefingPath = writeTempMarkdownSync(rendered.pathPayload ?? rendered.text);
  return {
    command: "open",
    args: [rendered.workingDirectory ?? briefingPath],
    cwd: rendered.workingDirectory,
    briefingPath
  };
}

function spawnRenderedResume(rendered: RenderedResume): number {
  const command = buildResumeSpawnCommand(rendered);
  const child = spawn(command.command, command.args, {
    cwd: command.cwd,
    detached: true,
    stdio: "ignore"
  });
  child.unref();
  scheduleDelete(command.briefingPath);
  return child.pid ?? 0;
}

export async function resumeViaShim(options: ResumeViaShimOptions): Promise<void> {
  requireVaultKey();
  if (!options.sessionId && !options.query) {
    throw new ResumeCliError("error: pass a session id or --query text to resume.", 2);
  }
  const args: Record<string, unknown> = {
    target_harness: options.targetHarness,
    target_model: options.targetModel
  };
  if (options.sessionId) {
    args.session_id = options.sessionId;
  }
  if (options.query) {
    const vaultKey = readVaultKeyBytes();
    args.tokenHashes = tokenHashes(options.query, vaultKey, 10);
    args.semanticHashes = semanticHashes(options.query, vaultKey, 12);
    if (options.provider) args.provider = options.provider;
    if (options.projectName) args.projectName = options.projectName;
  }
  const fuzzyListFirst = options.query && (!options.sessionId || /\s/u.test(options.query));
  let rendered: RenderedResume;
  if (fuzzyListFirst) {
    const response = await callHostedTool("burnbar_search_conversations", {
      tokenHashes: args.tokenHashes,
      semanticHashes: args.semanticHashes,
      provider: options.provider,
      projectName: options.projectName,
      includeBodyPreview: true,
      limit: 10
    }, options.endpoint);
    rendered = renderHostedResumeCandidates(response, options.query ?? "", options.targetHarness);
  } else {
    const response = await callHostedTool("burnbar_resume_conversation", {
      session_id: options.sessionId,
      target_harness: options.targetHarness,
      target_model: options.targetModel
    }, options.endpoint);
    if (isSessionNotFound(response) && options.query) {
      const searchResponse = await callHostedTool("burnbar_search_conversations", {
        tokenHashes: args.tokenHashes,
        semanticHashes: args.semanticHashes,
        provider: options.provider,
        projectName: options.projectName,
        includeBodyPreview: true,
        limit: 10
      }, options.endpoint);
      rendered = renderHostedResumeCandidates(searchResponse, options.query, options.targetHarness);
    } else {
      rendered = renderHostedResumeResponse(response);
    }
  }
  const mode = options.mode ?? "print";
  if (mode === "copy") {
    await copyToClipboard(rendered.text);
    process.stderr.write(`Briefing copied to clipboard (approximately ${Math.max(1, Math.ceil(rendered.text.length / 4))} tokens).\n`);
    return;
  }
  if (mode === "open") {
    const path = await openTempMarkdown(rendered.pathPayload ?? rendered.text);
    process.stdout.write(`${path}\n`);
    return;
  }
  if (mode === "spawn") {
    const pid = spawnRenderedResume(rendered);
    process.stdout.write(JSON.stringify({
      kind: "spawned",
      pid,
      target_harness: rendered.targetHarness ?? "claude_code"
    }) + "\n");
    return;
  }
  process.stdout.write(`${rendered.text}\n`);
}

export async function runResumeCli(options: ResumeViaShimOptions): Promise<number> {
  try {
    await resumeViaShim(options);
    return 0;
  } catch (err) {
    if (err instanceof ResumeCliError) {
      process.stderr.write(`${err.message}\n`);
      return err.exitCode;
    }
    process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
    return 1;
  }
}
