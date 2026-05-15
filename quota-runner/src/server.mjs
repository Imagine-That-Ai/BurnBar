import http from "node:http";
import { fetchClaudeQuota } from "./providers/claude.mjs";
import { fetchCodexQuota } from "./providers/codex.mjs";
import { fetchOpenCodeQuota } from "./providers/opencode.mjs";
import { fetchKimiQuota } from "./providers/kimi.mjs";

const MAX_BODY_BYTES = 128 * 1024;

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      size += Buffer.byteLength(chunk);
      if (size > MAX_BODY_BYTES) {
        reject(Object.assign(new Error("request too large"), { status: 413 }));
        req.destroy();
        return;
      }
      body += chunk;
    });
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(Object.assign(new Error("invalid JSON body"), { status: 400 }));
      }
    });
    req.on("error", reject);
  });
}

function writeJSON(res, status, data) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(data));
}

function requireAuth(req) {
  const expected = (process.env.RUNNER_SHARED_SECRET || "").trim();
  if (!expected) return;
  const got = String(req.headers.authorization || "").trim();
  if (got !== `Bearer ${expected}`) {
    throw Object.assign(new Error("unauthorized"), { status: 401 });
  }
}

async function route(req, res) {
  if (req.method === "GET" && (req.url === "/healthz" || req.url === "/readyz")) {
    writeJSON(res, 200, { ok: true });
    return;
  }
  if (req.method !== "POST" || req.url !== "/v1/quota/refresh") {
    writeJSON(res, 404, { error: "not found" });
    return;
  }

  requireAuth(req);
  const body = await readJSON(req);
  const provider = String(body.provider || "");
  const accountID = String(body.accountID || "hosted");
  const credential = typeof body.credential === "string" ? body.credential : "";

  if (provider === "codex") {
    writeJSON(res, 200, {
      snapshot: await fetchCodexQuota({ credential, accountID }),
    });
    return;
  }

  if (provider === "claude-code") {
    writeJSON(res, 200, {
      snapshot: await fetchClaudeQuota({ credential, accountID }),
    });
    return;
  }

  if (provider === "opencode") {
    writeJSON(res, 200, {
      snapshot: await fetchOpenCodeQuota({ credential, accountID }),
    });
    return;
  }

  if (provider === "kimi") {
    writeJSON(res, 200, {
      snapshot: await fetchKimiQuota({ credential, accountID }),
    });
    return;
  }

  throw Object.assign(new Error(`unsupported provider ${provider}`), { status: 400 });
}

const server = http.createServer((req, res) => {
  route(req, res).catch((err) => {
    const status = Number.isInteger(err.status) ? err.status : 500;
    writeJSON(res, status, {
      error: status >= 500 ? "quota runner failed" : err.message,
    });
  });
});

const host = process.env.RUNNER_HOST ||
  (process.env.RUNNER_SHARED_SECRET ? "0.0.0.0" : "127.0.0.1");
server.listen(Number(process.env.PORT || 8080), host);
