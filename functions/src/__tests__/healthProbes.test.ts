/**
 * Contract tests for the Stream D health-probe hardening (functions/src/health.ts).
 *
 *   - Liveness can never report DOWN-by-throttle: healthLive answers 200 under
 *     a simulated monitor burst even when the product rate limiter rejects,
 *     and never consults the limiter or Firestore at all.
 *   - Readiness/combined probes gate on { firestore, firestoreTransaction,
 *     domainCore } and stay honest about partial degradation.
 *   - 429s from the still-limited probes carry Retry-After ("retry", not DOWN).
 *   - The K_SERVICE/K_REVISION runtime coordinates stay public by recorded
 *     decision (the post-deploy gate requires them); served verbatim.
 */

import { EventEmitter } from "node:events";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../domainCoreBuildProfile.js", () => ({
  domainCoreDeploymentIdentity: vi.fn(),
}));

vi.mock("../domainCorePricing.js", () => ({
  loadedDomainCorePricingIdentity: vi.fn(),
  DomainCorePricingError: class DomainCorePricingError extends Error {},
}));

vi.mock("../sentry.js", () => ({
  sentryStatus: () => ({ enabled: false, environment: "test" }),
}));

vi.mock("../logging.js", () => ({
  logInfo: vi.fn(),
  logError: vi.fn(),
  logWarn: vi.fn(),
  wrapRequestHandler: (_name: string, handler: (req: unknown, res: unknown) => unknown) => handler,
}));

vi.mock("../callables/publicRateLimit.js", () => ({
  checkPublicHttpEndpointRateLimit: vi.fn(),
  clientIpFromHttpRequest: () => "127.0.0.1",
  isPublicRateLimitExceeded: (err: unknown) =>
    typeof err === "object" && err !== null && Reflect.get(err, "code") === "resource-exhausted",
}));

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: vi.fn(),
}));

import { domainCoreDeploymentIdentity } from "../domainCoreBuildProfile.js";
import { loadedDomainCorePricingIdentity } from "../domainCorePricing.js";
import { checkPublicHttpEndpointRateLimit } from "../callables/publicRateLimit.js";
import { getFirestore } from "firebase-admin/firestore";
import type { Firestore } from "firebase-admin/firestore";

const mockDeploymentIdentity = vi.mocked(domainCoreDeploymentIdentity);
const mockLoadedCore = vi.mocked(loadedDomainCorePricingIdentity);
const mockRateLimit = vi.mocked(checkPublicHttpEndpointRateLimit);
const mockGetFirestore = vi.mocked(getFirestore);

const LOADED_CORE = {
  version: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
  wasmSha256: "c".repeat(64),
};

function deploymentIdentity(pricingMode: "legacy" | "shadow" | "rust") {
  return { profile: "test", candidateIdentity: null, pricingMode };
}

// ---------------------------------------------------------------------------
// Firestore double — controllable per test (ok / blocked / split-brain).
// ---------------------------------------------------------------------------

function fakeFirestore(
  options: { read?: () => Promise<unknown>; transaction?: (fn: (tx: unknown) => Promise<void>) => Promise<void> } = {},
): Firestore {
  const read = options.read ?? (async () => ({ exists: false }));
  const transaction =
    options.transaction ??
    (async (fn: (tx: unknown) => Promise<void>) => {
      await fn({ get: async () => ({ exists: false }) });
    });
  return {
    collection: () => ({ doc: () => ({ get: read }) }),
    runTransaction: transaction,
  } as unknown as Firestore;
}

function mockFirestoreHealthy(): void {
  mockGetFirestore.mockReturnValue(fakeFirestore());
}

function mockFirestoreBlocked(): void {
  const failure = async (): Promise<never> => {
    throw new Error("Firestore unavailable");
  };
  mockGetFirestore.mockReturnValue(fakeFirestore({ read: failure, transaction: failure }));
}

// ---------------------------------------------------------------------------
// Express/Node response double — mirrors healthManifest.test.ts.
// ---------------------------------------------------------------------------

class FakeRes extends EventEmitter {
  _status = 0;
  _body: unknown = undefined;
  private _headers: Record<string, string> = {};

  status(code: number): this {
    this._status = code;
    return this;
  }

  json(body: unknown): void {
    this._body = body;
    this.emit("finish");
  }

  send(body?: unknown): void {
    if (body !== undefined) this._body = body;
    this.emit("finish");
  }

  end(): void {
    this.emit("finish");
  }

  set(name: string, value: string): void {
    this._headers[name.toLowerCase()] = value;
  }

  setHeader(name: string, value: string): void {
    this._headers[name.toLowerCase()] = value;
  }

  getHeader(name: string): string | undefined {
    return this._headers[name.toLowerCase()];
  }
}

function makeReq(path = "/"): Record<string, unknown> {
  return {
    method: "GET",
    path,
    url: path,
    body: undefined,
    query: {},
    headers: {},
    socket: { remoteAddress: "127.0.0.1" },
    get(): undefined {
      return undefined;
    },
  };
}

async function loadHealth(): Promise<typeof import("../health.js")> {
  return await import("../health.js");
}

async function driveHandler(handler: unknown, path = "/"): Promise<FakeRes> {
  const res = new FakeRes();
  const callable = typeof handler === "function" ? handler : Reflect.get(Object(handler), "run");
  if (typeof callable !== "function") {
    throw new Error("Expected HTTP handler to be callable");
  }
  await callable(makeReq(path), res);
  return res;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function field(body: unknown, key: string): unknown {
  if (!isRecord(body)) throw new Error(`response body is not an object (reading "${key}")`);
  return Reflect.get(body, key);
}

function resourceExhaustedError(): Error {
  return Object.assign(new Error("Too many requests. Try again later."), {
    code: "resource-exhausted",
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("health probes — liveness can never throttle as DOWN", () => {
  beforeEach(() => {
    vi.resetModules();
    mockDeploymentIdentity.mockReset();
    mockLoadedCore.mockReset();
    mockRateLimit.mockReset();
    mockGetFirestore.mockReset();
    mockDeploymentIdentity.mockReturnValue(deploymentIdentity("shadow"));
    mockLoadedCore.mockReturnValue(LOADED_CORE);
    mockRateLimit.mockResolvedValue(undefined);
    mockFirestoreHealthy();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("answers every request in a monitor burst with 200 even when the limiter rejects", async () => {
    mockRateLimit.mockRejectedValue(resourceExhaustedError());
    const { healthLive } = await loadHealth();

    // 70 rapid probes — past the old 60/min liveness ceiling.
    for (let i = 0; i < 70; i++) {
      const res = await driveHandler(healthLive, "/healthLive");
      expect(res._status).toBe(200);
      expect(field(res._body, "status")).toBe("alive");
    }
    // Liveness never consults the limiter at all: no 429 path exists.
    expect(mockRateLimit).not.toHaveBeenCalled();
  });

  it("stays 200 when Firestore is unreachable (no Firestore I/O on the liveness path)", async () => {
    mockGetFirestore.mockImplementation(() => {
      throw new Error("Firestore unavailable");
    });
    const { healthLive } = await loadHealth();

    const res = await driveHandler(healthLive, "/healthLive");
    expect(res._status).toBe(200);
    expect(field(res._body, "status")).toBe("alive");
    expect(mockGetFirestore).not.toHaveBeenCalled();
  });

  it("readiness reports all checks ok when reads and transactions work", async () => {
    const { healthReady } = await loadHealth();

    const res = await driveHandler(healthReady, "/healthReady");
    expect(res._status).toBe(200);
    expect(field(res._body, "status")).toBe("ready");
    expect(field(res._body, "checks")).toEqual({
      firestore: "ok",
      firestoreTransaction: "ok",
      domainCore: "loaded",
    });
  });

  it("readiness returns 503 with honest checks when Firestore is blocked", async () => {
    mockFirestoreBlocked();
    const { healthReady } = await loadHealth();

    const res = await driveHandler(healthReady, "/healthReady");
    expect(res._status).toBe(503);
    expect(field(res._body, "status")).toBe("degraded");
    expect(field(res._body, "checks")).toEqual({
      firestore: "error",
      firestoreTransaction: "error",
      domainCore: "loaded",
    });
    expect(field(res._body, "error")).toBe("Firestore connectivity check failed");
  });

  it("readiness returns 503 when plain reads work but transactions fail", async () => {
    mockGetFirestore.mockReturnValue(
      fakeFirestore({
        transaction: async () => {
          throw new Error("transaction rejected");
        },
      }),
    );
    const { healthReady } = await loadHealth();

    const res = await driveHandler(healthReady, "/healthReady");
    expect(res._status).toBe(503);
    expect(field(res._body, "checks")).toEqual({
      firestore: "ok",
      firestoreTransaction: "error",
      domainCore: "loaded",
    });
  });

  it("readiness 429 carries Retry-After so monitors back off instead of flapping", async () => {
    mockRateLimit.mockRejectedValueOnce(resourceExhaustedError());
    const { healthReady } = await loadHealth();

    const res = await driveHandler(healthReady, "/healthReady");
    expect(res._status).toBe(429);
    expect(res._body).toEqual({ error: "too_many_requests" });
    expect(res.getHeader("Retry-After")).toBe("60");
  });

  it("readiness gates on a missing domain core only in rust pricing mode", async () => {
    mockLoadedCore.mockImplementation(() => {
      throw new Error("WASM unavailable");
    });

    // Production serving mode: missing core means broken pricing → 503.
    mockDeploymentIdentity.mockReturnValue(deploymentIdentity("rust"));
    const rustHealth = await loadHealth();
    const rustRes = await driveHandler(rustHealth.healthReady, "/healthReady");
    expect(rustRes._status).toBe(503);
    expect(field(rustRes._body, "checks")).toMatchObject({ domainCore: "unavailable" });

    // Fallback modes serve via TypeScript: missing core is informational → 200.
    vi.resetModules();
    mockDeploymentIdentity.mockReturnValue(deploymentIdentity("shadow"));
    const shadowHealth = await loadHealth();
    const shadowRes = await driveHandler(shadowHealth.healthReady, "/healthReady");
    expect(shadowRes._status).toBe(200);
    expect(field(shadowRes._body, "checks")).toMatchObject({ domainCore: "unavailable" });
  });

  it("combined check 429s with Retry-After and 503s honestly when Firestore is blocked", async () => {
    const { healthCheck } = await loadHealth();

    mockRateLimit.mockRejectedValueOnce(resourceExhaustedError());
    const throttled = await driveHandler(healthCheck, "/healthCheck");
    expect(throttled._status).toBe(429);
    expect(throttled.getHeader("Retry-After")).toBe("60");

    mockRateLimit.mockResolvedValue(undefined);
    mockFirestoreBlocked();
    const blocked = await driveHandler(healthCheck, "/healthCheck");
    expect(blocked._status).toBe(503);
    expect(field(blocked._body, "status")).toBe("degraded");
    expect(field(blocked._body, "checks")).toEqual({
      firestore: "error",
      firestoreTransaction: "error",
      domainCore: "loaded",
    });
    expect(typeof field(blocked._body, "uptime_ms")).toBe("number");
  });

  it("combined check reports all checks ok plus uptime when healthy", async () => {
    const { healthCheck } = await loadHealth();

    const res = await driveHandler(healthCheck, "/healthCheck");
    expect(res._status).toBe(200);
    expect(field(res._body, "status")).toBe("ok");
    expect(field(res._body, "checks")).toEqual({
      firestore: "ok",
      firestoreTransaction: "ok",
      domainCore: "loaded",
    });
    expect(typeof field(res._body, "uptime_ms")).toBe("number");
  });

  it("serves K_SERVICE/K_REVISION runtime coordinates verbatim (recorded keep-decision)", async () => {
    // The post-deploy gate requires non-empty runtime coordinates to prove the
    // probed instance is the just-deployed revision; the values are
    // low-sensitivity (service name is derivable from the public URL, revision
    // is an opaque Cloud Run suffix), so they stay public. This test pins the
    // decision: coordinates present in env must be served verbatim.
    vi.stubEnv("K_SERVICE", "openburnbar-functions");
    vi.stubEnv("K_REVISION", "openburnbar-functions-00042");
    vi.stubEnv("K_CONFIGURATION", "openburnbar-functions");
    vi.stubEnv("FUNCTION_TARGET", "healthLive");
    const { healthLive } = await loadHealth();

    const res = await driveHandler(healthLive, "/healthLive");
    expect(res._status).toBe(200);
    const domainCore = field(res._body, "domainCore");
    expect(field(domainCore, "runtime")).toEqual({
      service: "openburnbar-functions",
      revision: "openburnbar-functions-00042",
      configuration: "openburnbar-functions",
      functionTarget: "healthLive",
    });
  });
});
