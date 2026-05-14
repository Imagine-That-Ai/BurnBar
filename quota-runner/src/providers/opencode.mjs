import { access } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { percentBucket, valueBucket, runProcess, stripAnsi } from "./shared.mjs";

const DEFAULT_OPENCODE_GO_LIMITS = {
  fiveHour: 12,
  weekly: 30,
  monthly: 60,
};

export async function fetchOpenCodeQuota({ credential, accountID }) {
  if (credential.trim()) {
    throw new Error(
      "OpenCode hosted credential refresh is not supported because OpenCode does not expose a public account quota API; configure a self-hosted runner with local OpenCode authentication."
    );
  }

  return fetchOpenCodeQuotaFromCLI({
    accountID,
    env: process.env,
    sourceId: "self-hosted-runner",
  });
}

async function fetchOpenCodeQuotaFromCLI({ accountID, env, sourceId }) {
  const [fiveHourCost, oneDay, sevenDay, thirtyDay] = await Promise.all([
    readOpenCodeFiveHourCost(env),
    runOpenCodeStats(env, 1),
    runOpenCodeStats(env, 7),
    runOpenCodeStats(env, 30),
  ]);
  const buckets = parseOpenCodeQuotaWindows(
    { fiveHourCost, oneDay, sevenDay, thirtyDay },
    openCodeGoLimits(env)
  );
  if (buckets.length === 0) {
    throw new Error("opencode stats output did not contain usable cost or quota buckets");
  }
  return {
    provider: "opencode",
    sourceKind: "provider",
    sourceId,
    fetchedAt: new Date().toISOString(),
    source: "OpenCode stats",
    confidence: fiveHourCost == null ? "medium" : "high",
    managementURL: "https://opencode.ai/docs/go/",
    statusMessage: fiveHourCost == null
      ? `OpenCode quota estimated from local CLI stats for ${accountID}; hosted account quota is not available from a public OpenCode API.`
      : `OpenCode quota uses exact local 5-hour spend from OpenCode SQLite plus CLI stats for 7-day and monthly plan pressure for ${accountID}.`,
    buckets,
  };
}

async function runOpenCodeStats(env, days) {
  const result = await runProcess("opencode", ["stats", "--days", String(days), "--models", "10"], {
    env: {
      ...env,
      TERM: "xterm-256color",
      NO_COLOR: "1",
    },
    timeoutMs: 45_000,
  });
  return `${result.stdout}\n${result.stderr}`;
}

export function parseOpenCodeQuotaWindows(transcripts, limits = DEFAULT_OPENCODE_GO_LIMITS) {
  const fiveHourCost = finiteNumberOrNull(transcripts.fiveHourCost);
  const oneDay = parseStatsTotalCost(transcripts.oneDay ?? "");
  const sevenDay = parseStatsTotalCost(transcripts.sevenDay ?? "");
  const thirtyDay = parseStatsTotalCost(transcripts.thirtyDay ?? "");
  const buckets = [];

  if (fiveHourCost != null) {
    buckets.push(valueBucket({
      name: "OpenCode 5-hour limit",
      used: fiveHourCost,
      limit: limits.fiveHour,
      window: "5h",
      source: "opencode-sqlite",
      unit: "credits",
    }));
  } else if (oneDay != null) {
    buckets.push(valueBucket({
      name: "OpenCode 5-hour limit (24h fallback)",
      used: oneDay,
      limit: limits.fiveHour,
      window: "5h",
      source: "opencode-stats-24h-fallback",
      unit: "credits",
      isEstimated: true,
    }));
  }

  if (sevenDay != null) {
    buckets.push(valueBucket({
      name: "OpenCode 7-day limit",
      used: sevenDay,
      limit: limits.weekly,
      window: "7d",
      source: "opencode-stats",
      unit: "credits",
      isEstimated: true,
    }));
  }

  if (thirtyDay != null) {
    buckets.push(valueBucket({
      name: "OpenCode monthly limit",
      used: thirtyDay,
      limit: limits.monthly,
      window: "monthly",
      source: "opencode-stats",
      unit: "credits",
      isEstimated: true,
    }));
  }

  return buckets.filter((bucket) => bucket.limit > 0);
}

export function parseOpenCodeQuota(transcript, options = {}) {
  const text = stripAnsi(transcript)
    .replace(/\n{2,}/g, "\n")
    .replace(/[ \t]+/g, " ");
  const buckets = [];
  buckets.push(...parsePercentWindows(text));
  const monthly = parseMonthlyCredits(text, options.monthlyCreditLimit ?? options.limits?.monthly);
  if (monthly) buckets.push(monthly);
  return buckets;
}

function parsePercentWindows(text) {
  const windows = [
    { label: "OpenCode 5-hour window", window: "5h", patterns: [/\b5[- ]?h(?:our)?\b/i, /\bfive[- ]hour\b/i] },
    { label: "OpenCode 7-day window", window: "7d", patterns: [/\b7[- ]?d(?:ay)?\b/i, /\bweekly\b/i, /\bweek\b/i] },
  ];
  const buckets = [];
  for (const candidate of windows) {
    const index = firstPatternIndex(text, candidate.patterns);
    if (index < 0) continue;
    const section = text.slice(index, index + 320);
    const usedPercent = percentUsed(section);
    if (usedPercent == null) continue;
    buckets.push(percentBucket({
      name: candidate.label,
      usedPercent,
      window: candidate.window,
      resetsAt: resetHint(section),
      source: "opencode-quota",
    }));
  }
  return buckets;
}

function parseMonthlyCredits(text, configuredLimit) {
  const monthlyIndex = firstPatternIndex(text, [/\bmonthly\b/i, /\bcredit/i, /\bcost\b/i]);
  if (monthlyIndex < 0) return undefined;
  const section = text.slice(Math.max(0, monthlyIndex - 120), monthlyIndex + 420);
  const usedAndLimit = section.match(/\$?\s*([0-9]+(?:\.[0-9]+)?)\s*(?:\/|of)\s*\$?\s*([0-9]+(?:\.[0-9]+)?)/i);
  if (usedAndLimit) {
    const used = Number(usedAndLimit[1]);
    const limit = Number(usedAndLimit[2]);
    if (Number.isFinite(used) && Number.isFinite(limit) && limit > 0) {
      return valueBucket({
        name: "OpenCode monthly credits",
        used,
        limit,
        window: "monthly",
        resetsAt: resetHint(section),
        source: "opencode-quota",
        unit: "credits",
      });
    }
  }

  const used = parseStatsTotalCost(section);
  const limit = Number(configuredLimit);
  if (Number.isFinite(used) && Number.isFinite(limit) && limit > 0) {
    return valueBucket({
      name: "OpenCode monthly credits",
      used,
      limit,
      window: "monthly",
      resetsAt: resetHint(section),
      source: "opencode-stats",
      unit: "credits",
      isEstimated: true,
    });
  }
  return undefined;
}

function parseStatsTotalCost(transcript) {
  const text = stripAnsi(transcript).replace(/[ \t]+/g, " ");
  const total = text.match(/\bTotal\s+Cost\b[^$]*\$\s*([0-9]+(?:\.[0-9]+)?)/i);
  if (total) return Number(total[1]);
  const costs = [...text.matchAll(/\$\s*([0-9]+(?:\.[0-9]+)?)/g)]
    .map((match) => Number(match[1]))
    .filter(Number.isFinite);
  return costs.length ? costs[0] : undefined;
}

async function readOpenCodeFiveHourCost(env) {
  const dbPath = openCodeDatabasePath(env);
  try {
    await access(dbPath);
  } catch {
    return undefined;
  }

  const sql = [
    "SELECT COALESCE(SUM(json_extract(data, '$.cost')), 0)",
    "FROM message",
    "WHERE json_extract(data, '$.role') = 'assistant'",
    "AND time_created >= (CAST(strftime('%s','now') AS INTEGER) * 1000 - 5 * 60 * 60 * 1000);",
  ].join(" ");

  try {
    const result = await runProcess("sqlite3", [dbPath, sql], {
      env,
      timeoutMs: 10_000,
    });
    return finiteNumberOrNull(result.stdout.trim());
  } catch {
    return undefined;
  }
}

function openCodeDatabasePath(env) {
  if (env.OPENCODE_DB_PATH?.trim()) {
    return env.OPENCODE_DB_PATH.trim();
  }
  if (env.OPENCODE_DATA_HOME?.trim()) {
    return join(env.OPENCODE_DATA_HOME.trim(), "opencode.db");
  }
  const xdgDataHome = env.XDG_DATA_HOME?.trim() || join(env.HOME || homedir(), ".local", "share");
  return join(xdgDataHome, "opencode", "opencode.db");
}

function finiteNumberOrNull(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

function percentUsed(section) {
  const used = section.match(/([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used/i);
  if (used) return Number(used[1]);
  const remaining = section.match(/([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(?:left|remaining)/i);
  if (remaining) return 100 - Number(remaining[1]);
  return undefined;
}

function resetHint(section) {
  return section.match(/resets?\s+(?:at|on|in)?\s*([^.;,\n]+)/i)?.[1]?.trim();
}

function firstPatternIndex(text, patterns) {
  let best = -1;
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (!match || match.index == null) continue;
    if (best < 0 || match.index < best) best = match.index;
  }
  return best;
}

function openCodeGoLimits(env) {
  return {
    fiveHour: positiveNumber(env.OPENCODE_GO_5H_LIMIT, DEFAULT_OPENCODE_GO_LIMITS.fiveHour),
    weekly: positiveNumber(env.OPENCODE_GO_WEEKLY_LIMIT, DEFAULT_OPENCODE_GO_LIMITS.weekly),
    monthly: positiveNumber(env.OPENCODE_GO_MONTHLY_LIMIT, DEFAULT_OPENCODE_GO_LIMITS.monthly),
  };
}

function positiveNumber(value, fallback) {
  const n = Number(value ?? "");
  return Number.isFinite(n) && n > 0 ? n : fallback;
}
