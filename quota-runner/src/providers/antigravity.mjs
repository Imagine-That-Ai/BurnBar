import { readFile } from "node:fs/promises";
import { join } from "node:path";
import os from "node:os";
import { valueBucket } from "./shared.mjs";

/**
 * Antigravity model tiers and their estimated 5-hour window caps.
 * Antigravity uses a credit-based quota system; these caps are
 * community-estimated, not official Google numbers.
 *
 * Quota windows refresh every 5 hours (Pro/Ultra).
 * See: https://blog.google/feed/new-antigravity-rate-limits-pro-ultra-subsribers/
 */
const MODEL_TIERS = [
  { name: "Gemini 3.5 Flash (High)", windowCap: 600 },
  { name: "Gemini 3.5 Flash (Medium)", windowCap: 900 },
  { name: "Gemini 3.1 Pro (High)", windowCap: 150 },
  { name: "Gemini 3.1 Pro (Low)", windowCap: 300 },
  { name: "Claude Sonnet 4.6 (Thinking)", windowCap: 120 },
  { name: "Claude Opus 4.6 (Thinking)", windowCap: 60 },
  { name: "GPT-OSS 120B (Medium)", windowCap: 240 },
];

const DEFAULT_MODEL = "Claude Opus 4.6 (Thinking)";

/** 5-hour quota window in milliseconds. */
const QUOTA_WINDOW_MS = 5 * 60 * 60 * 1000;

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

    // --- Parse history events in rolling 5h quota window ---
    let data;
    try {
      data = await readFile(historyPath, "utf8");
    } catch (error) {
      if (error?.code === "ENOENT") {
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
      throw error;
    }
    const lines = data.split(/\r?\n/);
    const cutoff = now.getTime() - QUOTA_WINDOW_MS;

    const eventsInWindow = [];

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const event = JSON.parse(trimmed);
        if (typeof event.timestamp === "number") {
          if (event.timestamp >= cutoff && event.timestamp <= now.getTime()) {
            eventsInWindow.push(event);
          }
        }
      } catch {
        // Skip invalid JSON lines
      }
    }

    const usedCount = eventsInWindow.length;

    // --- Compute resetsAt from earliest event in the window ---
    let resetsAt = null;
    if (eventsInWindow.length > 0) {
      const sortedTimestamps = eventsInWindow
        .map((e) => e.timestamp)
        .sort((a, b) => a - b);
      resetsAt = new Date(
        sortedTimestamps[0] + QUOTA_WINDOW_MS
      ).toISOString();
    }

    // --- Build per-model buckets ---
    const buckets = MODEL_TIERS.map((tier) => {
      const isActive =
        tier.name.toLowerCase() === activeModelName.toLowerCase();
      const used = isActive ? usedCount : 0;
      const limit = tier.windowCap;
      const remaining = Math.max(0, limit - used);

      return valueBucket({
        name: isActive ? `${tier.name} (Active)` : tier.name,
        used,
        limit,
        remaining,
        window: "5h",
        resetsAt: isActive ? resetsAt : null,
        source: "antigravity-history",
        unit: "requests",
        isEstimated: true,
      });
    });

    return {
      provider: "antigravity",
      sourceKind: "provider",
      sourceId: credential.trim() ? "hosted-runner" : "self-hosted-runner",
      fetchedAt: now.toISOString(),
      source: "Antigravity CLI history",
      confidence: "estimated",
      managementURL: null,
      statusMessage: `Antigravity 5h rolling quota — active model: ${activeModelName}. Caps are community-estimated.`,
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
