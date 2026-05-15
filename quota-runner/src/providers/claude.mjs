import { percentBucket, runProcess, stripAnsi } from "./shared.mjs";

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
      const transcript = await runClaudeUsage(env);
      const buckets = parseClaudeUsage(transcript);
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
  const transcript = await runClaudeUsage(env);
  const buckets = parseClaudeUsage(transcript);
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

async function runClaudeUsage(env) {
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
