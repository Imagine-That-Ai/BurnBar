import { spawn } from "node:child_process";
import { rm, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";

export function percentBucket({ name, usedPercent, window, resetsAt, source, isEstimated = false }) {
  const used = clampPercent(usedPercent);
  return {
    name,
    used,
    limit: 100,
    remaining: Math.max(0, 100 - used),
    window,
    meta: {
      unit: "percent",
      ...(resetsAt ? { resetsAt: String(resetsAt) } : {}),
      ...(source ? { source } : {}),
      ...(isEstimated ? { isEstimated: true } : {}),
    },
  };
}

export function valueBucket({
  name,
  used,
  limit,
  remaining,
  window,
  resetsAt,
  source,
  unit = "credits",
  isEstimated = false,
}) {
  const normalizedUsed = finiteNumber(used, 0);
  const normalizedLimit = finiteNumber(limit, 0);
  const normalizedRemaining = remaining == null
    ? Math.max(0, normalizedLimit - normalizedUsed)
    : finiteNumber(remaining, 0);
  return {
    name,
    used: normalizedUsed,
    limit: normalizedLimit,
    remaining: normalizedRemaining,
    window,
    meta: {
      unit,
      ...(resetsAt ? { resetsAt: String(resetsAt) } : {}),
      ...(source ? { source } : {}),
      ...(isEstimated ? { isEstimated: true } : {}),
    },
  };
}

export function clampPercent(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(100, Math.round(n)));
}

export function stripAnsi(input) {
  return String(input)
    .replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\)|[PX^_][^\x1B]*(?:\x1B\\))/g, "")
    .replace(/\r/g, "\n");
}

export async function withTempDir(prefix, fn) {
  const dir = join(tmpdir(), `${prefix}-${randomUUID()}`);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  try {
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export async function writeCodexAuth(codexHome, credential) {
  const json = normalizeJSONCredential(credential);
  await mkdir(codexHome, { recursive: true, mode: 0o700 });
  await writeFile(join(codexHome, "auth.json"), json, { mode: 0o600 });
}

export async function writeOpenCodeAuth(home, credential) {
  const json = normalizeJSONCredential(credential);
  const dataDir = join(home, ".local", "share", "opencode");
  await mkdir(dataDir, { recursive: true, mode: 0o700 });
  await writeFile(join(dataDir, "auth.json"), json, { mode: 0o600 });
}

export function normalizeJSONCredential(credential) {
  const trimmed = credential.trim();
  if (trimmed.startsWith("{")) {
    JSON.parse(trimmed);
    return trimmed;
  }
  const decoded = Buffer.from(trimmed, "base64").toString("utf8");
  JSON.parse(decoded);
  return decoded;
}

function finiteNumber(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

export function runProcess(command, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? 30_000;
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: options.env || process.env,
      cwd: options.cwd || process.cwd(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${command} timed out`));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0 || stdout) {
        resolve({ stdout, stderr, code });
      } else {
        reject(new Error(`${command} exited ${code}`));
      }
    });
  });
}
