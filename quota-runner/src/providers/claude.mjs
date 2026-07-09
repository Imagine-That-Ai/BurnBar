import { percentBucket, runProcess, stripAnsi, valueBucket } from "./shared.mjs";

export async function fetchClaudeQuota({ credential, accountID }) {
  const baseEnv = {
    ...process.env,
    TERM: "xterm-256color",
    NO_COLOR: "1",
  };

  if (credential.trim().length > 0) {
    // Hosted runner: write the credential (a base64-encoded or raw JSON
    // auth bundle) to a temp CLAUDE_CONFIG_DIR so `claude /usage` can
    // pick it up. Mirrors the Codex hosted-credential pattern.
    const { withTempDir } = await import("./shared.mjs");
    return withTempDir("obb-claude", async (claudeConfigDir) => {
      const { mkdir, writeFile } = await import("node:fs/promises");
      const { join } = await import("node:path");
      const decoded = decodeCredential(credential);
      await mkdir(claudeConfigDir, { recursive: true, mode: 0o700 });
      if (typeof decoded === "object" && decoded !== null) {
        await writeFile(join(claudeConfigDir, "credentials.json"), JSON.stringify(decoded), { mode: 0o600 });
      }
      const env = { ...baseEnv, CLAUDE_CONFIG_DIR: claudeConfigDir };
      const buckets = await fetchClaudeUsageBuckets(env);
      if (buckets.length === 0) {
        throw new Error("claude usage output did not contain quota buckets (hosted credential mode)");
      }
      return {
        provider: "claude-code",
        sourceKind: "provider",
        sourceId: "hosted-runner",
        fetchedAt: new Date().toISOString(),
        source: "Claude Code /usage",
        confidence: "high",
        managementURL: "https://claude.ai/settings/billing",
        statusMessage: `Claude Code quota fetched on demand for ${accountID}.`,
        buckets,
      };
    });
  }

  // Self-hosted runner: use local Claude authentication
  const env = baseEnv;
  const buckets = await fetchClaudeUsageBuckets(env);
  if (buckets.length === 0) {
    throw new Error("claude usage output did not contain quota buckets");
  }
  return {
    provider: "claude-code",
    sourceKind: "provider",
    sourceId: "self-hosted-runner",
    fetchedAt: new Date().toISOString(),
    source: "Claude Code /usage",
    confidence: "high",
    managementURL: "https://claude.ai/settings/billing",
    statusMessage: `Claude Code quota fetched on demand for ${accountID}.`,
    buckets,
  };
}

function decodeCredential(credential) {
  const trimmed = credential.trim();
  if (trimmed.startsWith("{")) {
    try { return JSON.parse(trimmed); } catch { /* fall through */ }
  }
  try {
    const decoded = Buffer.from(trimmed, "base64").toString("utf8");
    return JSON.parse(decoded);
  } catch {
    return trimmed;
  }
}

async function fetchClaudeUsageBuckets(env) {
  try {
    const jsonResult = await runProcess("claude", ["/usage", "--json"], {
      env,
      timeoutMs: 45_000,
    });
    const buckets = parseClaudeUsage(jsonResult.stdout);
    if (buckets.length > 0) {
      return buckets;
    }
  } catch {
    // Older Claude Code builds do not support `/usage --json`; fall through to
    // the terminal transcript path instead of turning a capability probe into a hard failure.
  }

  const transcript = await runClaudeUsageTranscript(env);
  return parseClaudeUsage(transcript);
}

async function runClaudeUsageTranscript(env) {
  try {
    const result = await runProcess("script", ["-q", "-c", "claude /usage", "/dev/null"], {
      env,
      timeoutMs: 45_000,
    });
    return result.stdout;
  } catch {
    const result = await runProcess("claude", ["/usage"], {
      env,
      timeoutMs: 45_000,
    });
    return result.stdout;
  }
}

export function parseClaudeUsage(transcript) {
  const jsonBuckets = parseClaudeUsageJSON(transcript);
  if (jsonBuckets.length > 0) {
    return jsonBuckets;
  }

  const text = stripAnsi(transcript)
    .replace(/\n{2,}/g, "\n")
    .replace(/[ \t]+/g, " ");
  const labels = [
    ["Current session", "5h"],
    ["Current week (all models)", "weekly"],
    ["Current week (Sonnet only)", "weekly-sonnet"],
    ["Current week (Opus only)", "weekly-opus"],
  ];
  const buckets = [];
  for (const [label, window] of labels) {
    const start = text.indexOf(label);
    if (start < 0) continue;
    const section = text.slice(start, start + 260);
    const match = section.match(/(\d{1,3})%\s*used/i);
    if (!match) continue;
    const reset = section.match(/Resets\s+([^\n]+)/i)?.[1]?.trim();
    buckets.push(percentBucket({
      name: label,
      usedPercent: Number(match[1]),
      window,
      resetsAt: reset,
      source: "claude-usage",
    }));
  }
  return buckets;
}

function parseClaudeUsageJSON(input) {
  const raw = String(input).trim();
  if (!raw.startsWith("{") && !raw.startsWith("[")) return [];
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }

  const candidates = collectUsageCandidates(parsed);
  const buckets = [];
  const seen = new Set();
  for (const candidate of candidates) {
    const bucket = bucketFromJSONCandidate(candidate);
    if (!bucket) continue;
    const key = `${bucket.name}|${bucket.window}|${bucket.limit}|${bucket.used}`;
    if (seen.has(key)) continue;
    seen.add(key);
    buckets.push(bucket);
  }
  return buckets;
}

function collectUsageCandidates(value, depth = 0) {
  if (depth > 5 || value == null) return [];
  if (Array.isArray(value)) {
    return value.flatMap((item) => collectUsageCandidates(item, depth + 1));
  }
  if (typeof value !== "object") return [];

  const record = value;
  const direct =
    numberFromAny(record.used) !== undefined ||
    numberFromAny(record.usage) !== undefined ||
    numberFromAny(record.usedPercent) !== undefined ||
    numberFromAny(record.used_percent) !== undefined ||
    numberFromAny(record.percentUsed) !== undefined ||
    numberFromAny(record.percent_used) !== undefined;
  const nested = Object.entries(record)
    .filter(([key]) => !["meta", "metadata"].includes(key))
    .flatMap(([, child]) => collectUsageCandidates(child, depth + 1));
  return direct ? [record, ...nested] : nested;
}

function bucketFromJSONCandidate(record) {
  const name = stringFromAny(record.name) ?? stringFromAny(record.label) ?? stringFromAny(record.title);
  if (!name) return undefined;
  const window = windowFromJSONCandidate(record, name);
  const resetsAt =
    stringFromAny(record.resetsAt) ??
    stringFromAny(record.resetAt) ??
    stringFromAny(record.resets_at) ??
    stringFromAny(record.reset_at) ??
    stringFromAny(record.renewalAt) ??
    stringFromAny(record.renewal_at);
  const percent =
    numberFromAny(record.usedPercent) ??
    numberFromAny(record.used_percent) ??
    numberFromAny(record.percentUsed) ??
    numberFromAny(record.percent_used);
  if (percent !== undefined) {
    return percentBucket({
      name,
      usedPercent: percent,
      window,
      resetsAt,
      source: "claude-usage-json",
    });
  }

  const used = numberFromAny(record.used) ?? numberFromAny(record.usage);
  const limit = numberFromAny(record.limit) ?? numberFromAny(record.total);
  const remaining = numberFromAny(record.remaining);
  if (used === undefined && limit === undefined && remaining === undefined) {
    return undefined;
  }
  const inferredLimit = limit ?? (used !== undefined && remaining !== undefined ? used + remaining : undefined);
  if (inferredLimit === undefined || inferredLimit <= 0) {
    return undefined;
  }
  const inferredUsed = used ?? Math.max(0, inferredLimit - (remaining ?? 0));
  return valueBucket({
    name,
    used: inferredUsed,
    limit: inferredLimit,
    remaining,
    window,
    resetsAt,
    source: "claude-usage-json",
    unit: stringFromAny(record.unit) ?? "quota",
  });
}

function windowFromJSONCandidate(record, name) {
  const explicit =
    stringFromAny(record.window) ??
    stringFromAny(record.period) ??
    stringFromAny(record.interval) ??
    stringFromAny(record.timeframe);
  if (explicit) return explicit;
  const normalized = name.toLowerCase();
  if (normalized.includes("session")) return "5h";
  if (normalized.includes("sonnet")) return "weekly-sonnet";
  if (normalized.includes("opus")) return "weekly-opus";
  if (normalized.includes("week")) return "weekly";
  return "custom";
}

function numberFromAny(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().replace(/%$/, "");
  if (!normalized) return undefined;
  const n = Number(normalized);
  return Number.isFinite(n) ? n : undefined;
}

function stringFromAny(value) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}
