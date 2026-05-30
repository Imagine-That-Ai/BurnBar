import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile, rm, chmod } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import os from "node:os";
import { fetchAntigravityQuota } from "../src/providers/antigravity.mjs";

test("fetchAntigravityQuota calculates rolling 5h requests and reset timestamp", async (t) => {
  const tempHome = await mkdtemp(join(tmpdir(), "obb-test-home-"));
  await chmod(tempHome, 0o700);

  const originalHomedir = os.homedir;
  os.homedir = () => tempHome;

  t.after(async () => {
    os.homedir = originalHomedir;
    await rm(tempHome, { recursive: true, force: true });
  });

  const geminiDir = join(tempHome, ".gemini", "antigravity-cli");
  await mkdir(geminiDir, { recursive: true });
  const historyPath = join(geminiDir, "history.jsonl");
  const settingsPath = join(geminiDir, "settings.json");

  const nowMs = Date.now();
  const hourInMs = 60 * 60 * 1000;

  // 1. When history file doesn't exist
  const unavailableResult = await fetchAntigravityQuota({ credential: "", accountID: "hosted" });
  assert.equal(unavailableResult.provider, "antigravity");
  assert.equal(unavailableResult.confidence, "unavailable");
  assert.equal(unavailableResult.buckets.length, 0);
  assert.match(unavailableResult.statusMessage, /not found/);

  // 2. When history file exists with mixed events and settings.json present
  const mockLines = [
    JSON.stringify({ timestamp: nowMs - 2 * hourInMs, display: "Req 1" }),
    JSON.stringify({ timestamp: nowMs - 5 * hourInMs, display: "Req 2 (edge of window)" }),
    JSON.stringify({ timestamp: nowMs - 6 * hourInMs, display: "Req 3 (too old)" }),
    "invalid json line",
    JSON.stringify({ timestamp: nowMs + 10 * hourInMs, display: "Req 4 (in future)" }),
  ];

  await writeFile(historyPath, mockLines.join("\n"), "utf8");
  await writeFile(settingsPath, JSON.stringify({ model: "Claude Opus 4.6 (Thinking)" }), "utf8");

  const result = await fetchAntigravityQuota({ credential: "", accountID: "hosted" });
  assert.equal(result.provider, "antigravity");
  assert.equal(result.confidence, "estimated");
  assert.equal(result.buckets.length, 7, "Should have 7 per-model buckets");
  assert.match(result.statusMessage, /Claude Opus 4.6/);

  // Find the active bucket
  const activeBucket = result.buckets.find((b) => b.name.includes("(Active)"));
  assert.ok(activeBucket, "Should have an active model bucket");
  assert.match(activeBucket.name, /Claude Opus 4.6 \(Thinking\) \(Active\)/);
  // Only 1 event within 5h window (2h ago). 5h ago is exactly the cutoff — excluded.
  assert.equal(activeBucket.used, 1);
  assert.equal(activeBucket.limit, 60);
  assert.equal(activeBucket.remaining, 59);
  assert.equal(activeBucket.window, "5h");
  assert.equal(activeBucket.meta.unit, "requests");

  // resetsAt should be earliest timestamp (nowMs - 2h) + 5 hours
  const expectedResetTime = nowMs - 2 * hourInMs + 5 * hourInMs;
  const expectedResetISO = new Date(expectedResetTime).toISOString();
  assert.equal(activeBucket.meta.resetsAt, expectedResetISO);

  // Inactive model should have 0 used and full headroom
  const flashBucket = result.buckets.find((b) => b.name === "Gemini 3.5 Flash (High)");
  assert.ok(flashBucket, "Should have a Gemini 3.5 Flash (High) bucket");
  assert.equal(flashBucket.used, 0);
  assert.equal(flashBucket.limit, 600);
  assert.equal(flashBucket.remaining, 600);
  assert.equal(flashBucket.meta.resetsAt, undefined, "Inactive model should have no resetsAt");

  // 3. When settings.json is missing, defaults to Claude Opus 4.6 (Thinking)
  await rm(settingsPath, { force: true });
  const defaultResult = await fetchAntigravityQuota({ credential: "", accountID: "hosted" });
  const defaultActive = defaultResult.buckets.find((b) => b.name.includes("(Active)"));
  assert.ok(defaultActive, "Should default to an active bucket");
  assert.match(defaultActive.name, /Claude Opus 4.6 \(Thinking\) \(Active\)/);
  assert.equal(defaultActive.used, 1);
  assert.equal(defaultActive.limit, 60);
});
