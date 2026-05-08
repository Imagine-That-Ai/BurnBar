import { spawn } from "node:child_process";
import { withTempDir, writeCodexAuth, percentBucket } from "./shared.mjs";

export async function fetchCodexQuota({ credential, accountID }) {
  if (!credential.trim()) {
    const result = await readRateLimits(process.env.CODEX_HOME);
    return {
      provider: "codex",
      sourceKind: "provider",
      sourceId: "self-hosted-runner",
      fetchedAt: new Date().toISOString(),
      source: "Codex app-server account/rateLimits/read",
      confidence: "high",
      managementURL: "https://chatgpt.com/codex/settings/usage",
      statusMessage: `Codex quota fetched on demand for ${accountID}.`,
      buckets: codexBuckets(result),
    };
  }

  return withTempDir("obb-codex", async (codexHome) => {
    await writeCodexAuth(codexHome, credential);
    const result = await readRateLimits(codexHome);
    const buckets = codexBuckets(result);
    return {
      provider: "codex",
      sourceKind: "provider",
      sourceId: "hosted-runner",
      fetchedAt: new Date().toISOString(),
      source: "Codex app-server account/rateLimits/read",
      confidence: "high",
      managementURL: "https://chatgpt.com/codex/settings/usage",
      statusMessage: `Codex quota fetched on demand for ${accountID}.`,
      buckets,
    };
  });
}

function readRateLimits(codexHome) {
  return new Promise((resolve, reject) => {
    const child = spawn("codex", ["app-server", "--listen", "stdio://"], {
      env: codexHome ? { ...process.env, CODEX_HOME: codexHome } : process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buffer = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("codex app-server timed out"));
    }, 30_000);
    const send = (msg) => child.stdin.write(`${JSON.stringify(msg)}\n`);
    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg.id === 1) {
          send({ id: 2, method: "account/rateLimits/read" });
        } else if (msg.id === 2) {
          clearTimeout(timer);
          child.kill();
          if (msg.error) reject(new Error("codex rate limit read failed"));
          else resolve(msg.result);
        }
      }
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("spawn", () => {
      send({
        id: 1,
        method: "initialize",
        params: {
          clientInfo: {
            name: "openburnbar-quota-runner",
            title: "OpenBurnBar Quota Runner",
            version: "0.1.0",
          },
          capabilities: { experimentalApi: true },
        },
      });
    });
  });
}

function codexBuckets(result) {
  const byLimit = result?.rateLimitsByLimitId && typeof result.rateLimitsByLimitId === "object"
    ? Object.entries(result.rateLimitsByLimitId)
    : [["codex", result?.rateLimits]].filter(([, value]) => value);
  const buckets = [];
  for (const [limitId, snapshot] of byLimit) {
    if (!snapshot || typeof snapshot !== "object") continue;
    const label = snapshot.limitName || limitId;
    if (snapshot.primary) {
      buckets.push(percentBucket({
        name: `${label} 5h`,
        usedPercent: snapshot.primary.usedPercent,
        window: "5h",
        resetsAt: epochToISO(snapshot.primary.resetsAt),
        source: "codex-app-server",
      }));
    }
    if (snapshot.secondary) {
      buckets.push(percentBucket({
        name: `${label} weekly`,
        usedPercent: snapshot.secondary.usedPercent,
        window: "weekly",
        resetsAt: epochToISO(snapshot.secondary.resetsAt),
        source: "codex-app-server",
      }));
    }
  }
  return buckets;
}

function epochToISO(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? new Date(n * 1000).toISOString() : undefined;
}
