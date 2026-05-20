import { readFile, access } from "node:fs/promises";
import { join } from "node:path";
import os from "node:os";
import { valueBucket } from "./shared.mjs";

/**
 * Antigravity model tiers and their rolling 24-hour daily caps.
 * Order determines display order in the quota UI.
 */
const MODEL_TIERS = [
  { name: "Gemini 3.5 Flash (High)", dailyCap: 1000 },
  { name: "Gemini 3.5 Flash (Medium)", dailyCap: 1500 },
  { name: "Gemini 3.1 Pro (High)", dailyCap: 250 },
  { name: "Gemini 3.1 Pro (Low)", dailyCap: 500 },
  { name: "Claude Sonnet 4.6 (Thinking)", dailyCap: 200 },
  { name: "Claude Opus 4.6 (Thinking)", dailyCap: 100 },
  { name: "GPT-OSS 120B (Medium)", dailyCap: 400 },
];

const DEFAULT_MODEL = "Claude Opus 4.6 (Thinking)";

/** Snake-case a model name for use as a bucket key. */
function modelKey(name) {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

export async function fetchAntigravityQuota({ credential, accountID }) {
  const homeDir = os.homedir();
  const cliDir = join(homeDir, ".gemini/antigravity-cli");
  const historyPath = join(cliDir, "history.jsonl");
  const settingsPath = join(cliDir, "settings.json");
  const now = new Date();

  try {
    await access(historyPath);
  } catch {
    return {
      provider: "antigravity",
      sourceKind: "unavailable",
      sourceId: credential.trim() ? "hosted-runner" : "self-hosted-runner",
      fetchedAt: now.toISOString(),
      source: "Antigravity CLI history",
      confidence: "unavailable",
      managementURL: null,
      statusMessage:
        "Antigravity history log not found at ~/.gemini/antigravity-cli/history.jsonl",
      buckets: [],
    };
  }

  try {
    // --- Read active model from settings.json ---
    let activeModelName = DEFAULT_MODEL;
    try {
      const settingsRaw = await readFile(settingsPath, "utf8");
      const settings = JSON.parse(settingsRaw);
      if (typeof settings.model === "string" && settings.model.trim()) {
        activeModelName = settings.model.trim();
      }
    } catch {
      // settings.json missing or malformed — keep default
    }

    // --- Parse history events in rolling 24h window ---
    const data = await readFile(historyPath, "utf8");
    const lines = data.split(/\r?\n/);
    const cutoff = now.getTime() - 24 * 60 * 60 * 1000;

    const eventsIn24h = [];

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const event = JSON.parse(trimmed);
        if (typeof event.timestamp === "number") {
          if (event.timestamp >= cutoff && event.timestamp <= now.getTime()) {
            eventsIn24h.push(event);
          }
        }
      } catch {
        // Skip invalid JSON lines
      }
    }

    const usedCount = eventsIn24h.length;

    // --- Compute resetsAt from earliest event in the window ---
    let resetsAt = null;
    if (eventsIn24h.length > 0) {
      const sortedTimestamps = eventsIn24h
        .map((e) => e.timestamp)
        .sort((a, b) => a - b);
      resetsAt = new Date(
        sortedTimestamps[0] + 24 * 60 * 60 * 1000
      ).toISOString();
    }

    // --- Build per-model buckets ---
    const buckets = MODEL_TIERS.map((tier) => {
      const isActive =
        tier.name.toLowerCase() === activeModelName.toLowerCase();
      const used = isActive ? usedCount : 0;
      const limit = tier.dailyCap;
      const remaining = Math.max(0, limit - used);

      return valueBucket({
        name: isActive ? `${tier.name} (Active)` : tier.name,
        used,
        limit,
        remaining,
        window: "24h",
        resetsAt: isActive ? resetsAt : null,
        source: "antigravity-history",
        unit: "requests",
      });
    });

    return {
      provider: "antigravity",
      sourceKind: "provider",
      sourceId: credential.trim() ? "hosted-runner" : "self-hosted-runner",
      fetchedAt: now.toISOString(),
      source: "Antigravity CLI history",
      confidence: "exact",
      managementURL: null,
      statusMessage: `Antigravity quota calculated — active model: ${activeModelName}`,
      buckets,
    };
  } catch (err) {
    return {
      provider: "antigravity",
      sourceKind: "unavailable",
      sourceId: credential.trim() ? "hosted-runner" : "self-hosted-runner",
      fetchedAt: now.toISOString(),
      source: "Antigravity CLI history",
      confidence: "unavailable",
      managementURL: null,
      statusMessage: `Error reading Antigravity history: ${err.message}`,
      buckets: [],
    };
  }
}
