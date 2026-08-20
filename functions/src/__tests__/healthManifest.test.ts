/**
 * Contract tests for functions/src/health.ts — runtime artifact manifest and
 * production identity honesty.
 *
 * The health endpoints embed a `domainCore` object in every JSON response. The
 * post-deploy health gate (scripts/ci/post-deploy-health-gate.sh) compares the
 * served `artifactManifest.sha256`, `loadedCore`, `profile`, `candidateIdentity`,
 * and `pricingMode` against the expected release identity. A fabricated or
 * null-masked identity would let an unverifiable deployment pass the gate.
 *
 * These tests prove:
 *   - Importing health.ts succeeds even when no runtime artifact manifest exists.
 *   - A valid manifest produces a real SHA-256 (not a placeholder).
 *   - A missing manifest yields artifactManifest: null (not a fabricated digest).
 *   - An unavailable WASM yields loadedCore: null (not a fabricated identity).
 *   - A missing deployment identity yields no fabricated profile/candidateIdentity/pricingMode.
 *   - A partial (malformed) deployment identity is served honestly — present
 *     fields pass through, absent fields are not fabricated.
 *   - healthReady and healthCheck carry the same honest identity as healthLive.
 *
 * Pre-fix: readFileSync and loadedDomainCorePricingIdentity at module top-level
 * throw when the manifest or WASM are absent, crashing the import. Post-fix: the
 * reads are guarded and absence is reported as null.
 */
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// ---------------------------------------------------------------------------
// Module mocks: control the domain-core identity functions without loading the
// real WASM or the candidate receipt parser. The health module's manifest read
// (readFileSync) and crypto hash (createHash) stay real — not mocked — so file
// presence/absence and byte-level hashing are exercised end-to-end.
// ---------------------------------------------------------------------------

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
}));

vi.mock("../callables/publicRateLimit.js", () => ({
  checkPublicHttpEndpointRateLimit: vi.fn(),
  clientIpFromHttpRequest: () => "127.0.0.1",
  isPublicRateLimitExceeded: (err: unknown) =>
    typeof err === "object" && err !== null && Reflect.get(err, "code") === "resource-exhausted",
}));

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({
      doc: () => ({
        get: async () => ({ exists: false, data: () => undefined }),
      }),
    }),
  }),
}));

import { domainCoreDeploymentIdentity } from "../domainCoreBuildProfile.js";
import { loadedDomainCorePricingIdentity } from "../domainCorePricing.js";

const mockDeploymentIdentity = vi.mocked(domainCoreDeploymentIdentity);
const mockLoadedCore = vi.mocked(loadedDomainCorePricingIdentity);

// ---------------------------------------------------------------------------
// Manifest file management — the real readFileSync/createHash are used so
// file presence/absence and byte-level hashing are exercised end-to-end.
// Under vitest, __dirname in health.ts resolves to functions/src, so the
// manifest file must live at functions/src/domain-core-runtime-artifact-manifest.json.
// ---------------------------------------------------------------------------

const MANIFEST_PATH = resolve(__dirname, "..", "domain-core-runtime-artifact-manifest.json");
const MANIFEST_FILE_NAME = "domain-core-runtime-artifact-manifest.json";

const VALID_MANIFEST = JSON.stringify({
  schemaVersion: 1,
  manifestKind: "domain-core-runtime-artifact",
  consumer: "functions",
  profile: "public-production",
  candidate: {
    candidateCommit: "a".repeat(40),
    coreVersion: "0.3.0",
    abiVersion: 3,
    sourceSha256: "b".repeat(64),
  },
  files: [],
});

const VALID_DEPLOYMENT_IDENTITY = {
  profile: "public-production",
  candidateIdentity: {
    candidateCommit: "a".repeat(40),
    coreVersion: "0.3.0-beta.1+build.7",
    abiVersion: 3,
    sourceSha256: "b".repeat(64),
  },
  pricingMode: "rust" as const,
};

const VALID_LOADED_CORE = {
  version: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
  wasmSha256: "c".repeat(64),
};

function writeManifest(content: string = VALID_MANIFEST): void {
  writeFileSync(MANIFEST_PATH, content, "utf-8");
}

function removeManifest(): void {
  if (existsSync(MANIFEST_PATH)) rmSync(MANIFEST_PATH);
}

function sha256Hex(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

// ---------------------------------------------------------------------------
// Express/Node response double — sufficient for the firebase-functions
// onRequest wrapper (emits "finish" on json/send/end so the wrapper resolves).
// Mirrors the harness in routerRundownEndpoint.test.ts.
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

function makeReq(path = "/healthLive"): Record<string, unknown> {
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

// Dynamic import is required here: each test exercises the module-load boundary
// (manifest file presence/absence changes what happens at import time), so the
// module must be re-imported fresh after vi.resetModules() per test case.
async function loadHealth(): Promise<typeof import("../health.js")> {
  return await import("../health.js");
}

async function driveHandler(
  handler: unknown,
  req: Record<string, unknown> = makeReq(),
): Promise<FakeRes> {
  const res = new FakeRes();
  const callable = typeof handler === "function" ? handler : Reflect.get(Object(handler), "run");
  if (typeof callable !== "function") {
    throw new Error("Expected HTTP handler to be callable");
  }
  await callable(req, res);
  return res;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function domainCoreFromBody(body: unknown): Record<string, unknown> | undefined {
  if (!isRecord(body)) return undefined;
  const dc = Reflect.get(body, "domainCore");
  if (!isRecord(dc)) return undefined;
  return dc;
}

// Safe field accessor — replaces non-null assertions after expect(dc).toBeDefined().
// Throws if dc is unexpectedly absent so the test fails loudly rather than
// silently passing on a structural mismatch.
function dcField(dc: Record<string, unknown> | undefined, key: string): unknown {
  if (dc === undefined) throw new Error(`domainCore is undefined accessing "${key}"`);
  return Reflect.get(dc, key);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("health endpoint runtime artifact manifest and production identity", () => {
  beforeEach(() => {
    vi.resetModules();
    mockDeploymentIdentity.mockReset();
    mockLoadedCore.mockReset();
    removeManifest();
  });

  afterEach(() => {
    removeManifest();
  });

  // ---- Import boundary: no manifest, no WASM, no deployment identity ----

  it("imports the module without a runtime artifact manifest", async () => {
    mockDeploymentIdentity.mockReturnValue(undefined);
    mockLoadedCore.mockImplementation(() => {
      throw new Error("WASM unavailable");
    });

    // Pre-fix: readFileSync at module top-level throws ENOENT.
    // Post-fix: import succeeds; absence is reported as null.
    const health = await loadHealth();
    expect(health).toBeTypeOf("object");
    expect(typeof health.healthLive).toBe("function");
    expect(typeof health.healthReady).toBe("function");
    expect(typeof health.healthCheck).toBe("function");
  });

  // ---- Valid manifest → real sha256 ----

  it("serves a real artifact manifest sha256 when a valid manifest is present", async () => {
    writeManifest();
    const expectedSha = sha256Hex(readFileSync(MANIFEST_PATH));

    mockDeploymentIdentity.mockReturnValue(VALID_DEPLOYMENT_IDENTITY);
    mockLoadedCore.mockReturnValue(VALID_LOADED_CORE);

    const { healthLive } = await loadHealth();
    const res = await driveHandler(healthLive);
    const dc = domainCoreFromBody(res._body);

    expect(res._status).toBe(200);
    expect(dc).toBeDefined();
    expect(dcField(dc, "artifactManifest")).toEqual({
      fileName: MANIFEST_FILE_NAME,
      sha256: expectedSha,
    });
    // Negative control: the sha is a real 64-hex digest, not a placeholder.
    const manifest = dcField(dc, "artifactManifest");
    const sha = isRecord(manifest) ? Reflect.get(manifest, "sha256") : undefined;
    expect(sha).toEqual(expect.stringMatching(/^[0-9a-f]{64}$/u));
  });

  // ---- Missing manifest → null, not fabricated ----

  it("does not fabricate artifactManifest when the manifest file is missing", async () => {
    mockDeploymentIdentity.mockReturnValue(VALID_DEPLOYMENT_IDENTITY);
    mockLoadedCore.mockReturnValue(VALID_LOADED_CORE);

    const { healthLive } = await loadHealth();
    const res = await driveHandler(healthLive);
    const dc = domainCoreFromBody(res._body);

    expect(res._status).toBe(200);
    expect(dc).toBeDefined();
    // Null, not a fabricated digest.
    expect(dcField(dc, "artifactManifest")).toBeNull();
  });

  // ---- WASM unavailable → null, not fabricated ----

  it("does not fabricate loadedCore when the WASM is unavailable", async () => {
    writeManifest();
    mockDeploymentIdentity.mockReturnValue(VALID_DEPLOYMENT_IDENTITY);
    mockLoadedCore.mockImplementation(() => {
      throw new Error("WASM unavailable");
    });

    const { healthLive } = await loadHealth();
    const res = await driveHandler(healthLive);
    const dc = domainCoreFromBody(res._body);

    expect(res._status).toBe(200);
    expect(dc).toBeDefined();
    // Null, not a fabricated identity.
    expect(dcField(dc, "loadedCore")).toBeNull();
  });

  // ---- Missing deployment identity → no fabricated profile/identity/pricingMode ----

  it("does not fabricate production identity when domainCoreDeploymentIdentity is undefined", async () => {
    writeManifest();
    mockDeploymentIdentity.mockReturnValue(undefined);
    mockLoadedCore.mockReturnValue(VALID_LOADED_CORE);

    const { healthLive } = await loadHealth();
    const res = await driveHandler(healthLive);
    const dc = domainCoreFromBody(res._body);

    expect(res._status).toBe(200);
    expect(dc).toBeDefined();
    // No fabricated profile, candidateIdentity, or pricingMode.
    expect(dcField(dc, "profile")).toBeUndefined();
    expect(dcField(dc, "candidateIdentity")).toBeUndefined();
    expect(dcField(dc, "pricingMode")).toBeUndefined();
  });

  // ---- Partial (malformed) deployment identity → served honestly ----

  it("serves a partial deployment identity honestly without fabricating missing fields", async () => {
    writeManifest();
    // A malformed receipt that parses to a partial identity — profile present
    // but candidateIdentity and pricingMode absent.
    // JSON.parse returns `any`, so the partial object bypasses the type system
    // without an unsafe cast — the test proves the health endpoint serves it
    // honestly without fabricating the missing candidateIdentity/pricingMode
    // fields.
    mockDeploymentIdentity.mockReturnValue(
      JSON.parse('{"profile":"public-production"}'),
    );
    mockLoadedCore.mockReturnValue(VALID_LOADED_CORE);

    const { healthLive } = await loadHealth();
    const res = await driveHandler(healthLive);
    const dc = domainCoreFromBody(res._body);

    expect(res._status).toBe(200);
    expect(dc).toBeDefined();
    // Present field passes through honestly.
    expect(dcField(dc, "profile")).toBe("public-production");
    // Absent fields are not fabricated — the health gate will fail on the
    // mismatch, which is the correct fail-closed behavior.
    expect(dcField(dc, "candidateIdentity")).toBeUndefined();
    expect(dcField(dc, "pricingMode")).toBeUndefined();
  });

  // ---- healthReady carries the same honest identity ----

  it("healthReady carries honest domain-core identity when manifest and WASM are absent", async () => {
    mockDeploymentIdentity.mockReturnValue(undefined);
    mockLoadedCore.mockImplementation(() => {
      throw new Error("WASM unavailable");
    });

    const { healthReady } = await loadHealth();
    const res = await driveHandler(healthReady, makeReq("/healthReady"));
    const dc = domainCoreFromBody(res._body);

    // healthReady returns 200 (Firestore ok) or 503 (degraded) — either way
    // the domainCore identity must be honest.
    expect([200, 503]).toContain(res._status);
    expect(dc).toBeDefined();
    expect(dcField(dc, "artifactManifest")).toBeNull();
    expect(dcField(dc, "loadedCore")).toBeNull();
    expect(dcField(dc, "profile")).toBeUndefined();
    expect(dcField(dc, "candidateIdentity")).toBeUndefined();
    expect(dcField(dc, "pricingMode")).toBeUndefined();
  });

  // ---- healthCheck carries the same honest identity ----

  it("healthCheck carries honest domain-core identity when manifest and WASM are absent", async () => {
    mockDeploymentIdentity.mockReturnValue(undefined);
    mockLoadedCore.mockImplementation(() => {
      throw new Error("WASM unavailable");
    });

    const { healthCheck } = await loadHealth();
    const res = await driveHandler(healthCheck, makeReq("/healthCheck"));
    const dc = domainCoreFromBody(res._body);

    expect([200, 503]).toContain(res._status);
    expect(dc).toBeDefined();
    expect(dcField(dc, "artifactManifest")).toBeNull();
    expect(dcField(dc, "loadedCore")).toBeNull();
  });

  // ---- Full valid identity is served correctly (positive control) ----

  it("serves the complete valid domain-core identity when all artifacts are present", async () => {
    writeManifest();
    const expectedSha = sha256Hex(readFileSync(MANIFEST_PATH));

    mockDeploymentIdentity.mockReturnValue(VALID_DEPLOYMENT_IDENTITY);
    mockLoadedCore.mockReturnValue(VALID_LOADED_CORE);

    const { healthLive } = await loadHealth();
    const res = await driveHandler(healthLive);
    const dc = domainCoreFromBody(res._body);

    expect(res._status).toBe(200);
    expect(dc).toEqual({
      ...VALID_DEPLOYMENT_IDENTITY,
      loadedCore: VALID_LOADED_CORE,
      artifactManifest: {
        fileName: MANIFEST_FILE_NAME,
        sha256: expectedSha,
      },
      runtime: {
        service: null,
        revision: null,
        configuration: null,
        functionTarget: null,
      },
    });
  });
});