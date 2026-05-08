import { initializeApp } from "firebase-admin/app";
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { Redis } from "ioredis";
import { WebSocket, WebSocketServer } from "ws";
import { authenticateRequest } from "./auth.js";
import { loadRelayConfig } from "./config.js";
import { FirestoreEntitlementVerifier } from "./entitlements.js";
import { RelayHttpError, RelayLimitError } from "./errors.js";
import { logError, logEvent, logWarning, uidHash } from "./logging.js";
import { RedisRelayQuotaStore } from "./quota.js";
import { RedisRelayHub } from "./redisHub.js";
import { HermesRealtimeRelaySession } from "./relay.js";

initializeApp();

const config = loadRelayConfig();

function createRedisClient(role: string): Redis {
  const client = new Redis(config.redisURL, {
    enableReadyCheck: true,
    maxRetriesPerRequest: 3,
    lazyConnect: false,
  });
  client.on("error", (error) => {
    logError("redis_error", error, { role });
  });
  return client;
}

const publisher = createRedisClient("publisher");
const subscriber = createRedisClient("subscriber");
const relayHub = new RedisRelayHub(publisher, subscriber);
const quota = new RedisRelayQuotaStore(publisher, config.limits);
const entitlementVerifier = new FirestoreEntitlementVerifier({
  productIDs: config.hostedRelayProductIDs,
  cacheTTLSeconds: config.entitlementCacheTTLSeconds,
  negativeCacheTTLSeconds: config.entitlementNegativeCacheTTLSeconds,
});

const server = createServer(async (req, res) => {
  if (req.url === "/healthz" || req.url === "/readyz") {
    try {
      await relayHub.ping();
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, redis: true, maxFrameBytes: config.limits.maxFrameBytes }));
    } catch (error) {
      logError("readyz_failed", error);
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: false, redis: false }));
    }
    return;
  }
  res.writeHead(404);
  res.end("not found");
});

const wss = new WebSocketServer({ noServer: true, maxPayload: config.limits.maxFrameBytes });
const liveSockets = new WeakMap<WebSocket, { alive: boolean }>();

server.on("upgrade", async (req, socket, head) => {
  if (upgradePath(req) !== "/v1/hermes/ws") {
    socket.destroy();
    return;
  }
  let sessionID = "";
  let reservedUID = "";
  let reservedRole: "host" | "client" = "client";
  try {
    const auth = await authenticateRequest(req, {
      enforceAppCheck: config.enforceAppCheck,
      verifyRevokedIdTokens: config.verifyRevokedIdTokens,
      entitlementVerifier,
      allowedAppIDs: config.allowedAppIDs,
    });
    sessionID = randomUUID();
    reservedUID = auth.uid;
    reservedRole = auth.role;
    await quota.reserveSocket(auth.uid, auth.role, sessionID);
    wss.handleUpgrade(req, socket, head, (ws) => {
      liveSockets.set(ws, { alive: true });
      ws.on("pong", () => {
        liveSockets.set(ws, { alive: true });
      });
      const session = new HermesRealtimeRelaySession(ws, {
        uid: auth.uid,
        role: auth.role,
        sessionID,
        bus: relayHub,
        quota,
        maxFrameBytes: config.limits.maxFrameBytes,
      });
      session.start();
      wss.emit("connection", ws, req);
      logEvent("relay_socket_opened", {
        uid: uidHash(auth.uid),
        role: auth.role,
        entitlementSource: auth.entitlementSource,
      });
    });
  } catch (error) {
    if (sessionID) {
      // The upgrade may fail after reserving the quota slot.
      quota.releaseSocket(reservedUID, reservedRole, sessionID).catch(() => undefined);
    }
    const status = httpStatus(error);
    logWarning("relay_upgrade_denied", {
      status,
      code: error instanceof RelayHttpError || error instanceof RelayLimitError ? error.code : "upgrade_failed",
    });
    socket.write(`HTTP/1.1 ${status} ${statusText(status)}\r\nConnection: close\r\n\r\n`);
    socket.destroy();
  }
});

const heartbeatTimer = setInterval(() => {
  for (const ws of wss.clients) {
    const state = liveSockets.get(ws);
    if (state?.alive === false) {
      ws.terminate();
      continue;
    }
    liveSockets.set(ws, { alive: false });
    ws.ping();
  }
}, 30_000);
heartbeatTimer.unref();

server.listen(config.port, () => {
  logEvent("relay_listening", {
    port: config.port,
    maxFrameBytes: config.limits.maxFrameBytes,
  });
});

process.on("SIGTERM", () => {
  logEvent("relay_sigterm");
  clearInterval(heartbeatTimer);
  for (const ws of wss.clients) {
    ws.close(1001, "Hermes realtime relay is restarting.");
  }
  relayHub.disconnect()
    .catch((error) => logError("relay_disconnect_failed", error))
    .finally(() => server.close());
});

function upgradePath(req: { url?: string; headers: { host?: string | string[] } }): string {
  try {
    const host = Array.isArray(req.headers.host) ? req.headers.host[0] : req.headers.host;
    return new URL(req.url ?? "", `http://${host ?? "localhost"}`).pathname;
  } catch {
    return "";
  }
}

function httpStatus(error: unknown): number {
  if (error instanceof RelayHttpError) return error.statusCode;
  if (error instanceof RelayLimitError) return 429;
  return 401;
}

function statusText(status: number): string {
  switch (status) {
    case 400:
      return "Bad Request";
    case 401:
      return "Unauthorized";
    case 403:
      return "Forbidden";
    case 429:
      return "Too Many Requests";
    default:
      return "Unauthorized";
  }
}
