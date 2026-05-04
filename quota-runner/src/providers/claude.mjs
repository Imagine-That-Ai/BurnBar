import { percentBucket, runProcess, stripAnsi } from "./shared.mjs";

export async function fetchClaudeQuota({ credential, accountID }) {
  if (credential.trim().length > 0) {
    throw new Error("Claude Code hosted credential refresh is not supported; configure a self-hosted runner with local Claude authentication.");
  }

  const env = {
    ...process.env,
    TERM: "xterm-256color",
    NO_COLOR: "1",
  };
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
