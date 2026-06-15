/**
 * Characterization test pinning the CURRENT observable behavior of the Hermes
 * Gateway functions targeted by the U4 complexity/max-lines refactor:
 *   - requiredHttpIdentifier / adoptedGatewayDocId (id-contract helpers used by
 *     handleAttachmentFinalize + handleAttachmentInit)
 *   - assertSafeAttachmentContentType / legacyAttachmentContentTypeAllowed (the
 *     content-type guard reached from handleAttachmentInit/Finalize)
 *   - dispatchHermesGatewayRequest method guards for the refactored route
 *     handlers (handleDeviceStart, handleRuntimeStatus, handleAttachmentFinalize)
 *     — the wrong-method early return runs before any Firestore access, so it
 *     pins the 405 short-circuit without seeding a grant.
 *
 * These are pure relocations under refactor; identical inputs MUST keep producing
 * identical return values and identical thrown HttpsError codes/messages.
 */
import { describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));
// adminRuntime.ts runs for real here (the barrel pulls it in via shared.ts), so
// the firebase-admin singletons it builds at import time must be mocked: it calls
// initializeApp(), getFirestore().settings(), and getAuth(). Without getFirestore /
// getAuth the module crashes at load and every case below fails before assertions.
vi.mock("firebase-admin/app", () => ({ initializeApp: vi.fn() }));
vi.mock("firebase-admin/auth", () => ({ getAuth: () => ({}) }));
vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({ settings: vi.fn() }),
  FieldValue: { delete: () => ({ __delete: true }) },
  Timestamp: {
    now: () => ({ __ts: true, toMillis: () => Date.now() }),
    fromMillis: (ms: number) => ({ __ts: true, toMillis: () => ms }),
  },
}));
vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({ bucket: () => ({ file: () => ({}) }) }),
}));

interface CapturedResponse {
  status?: number;
  body?: unknown;
}

function makeRes(): { res: unknown; captured: CapturedResponse } {
  const captured: CapturedResponse = {};
  const res = {
    status(code: number) {
      captured.status = code;
      return res;
    },
    json(body: unknown) {
      captured.body = body;
    },
    send(body?: unknown) {
      captured.body = body;
    },
    set() {
      /* no-op */
    },
  };
  return { res, captured };
}

function makeReq(method: string, path: string): unknown {
  return {
    method,
    path,
    url: path,
    body: {},
    headers: {},
    query: {},
    socket: { remoteAddress: "127.0.0.1" },
    get: () => undefined,
  };
}

describe("hermesGateway refactor characterization — id-contract helpers", () => {
  it("requiredHttpIdentifier accepts a canonical id and throws on bad input", async () => {
    const { requiredHttpIdentifier } = await import("../callables/hermesGateway.js");
    // Representative input #1: a valid id passes through trimmed.
    expect(requiredHttpIdentifier("att_abc.123:x-y", "attachmentId")).toBe("att_abc.123:x-y");
    // Representative input #2: an out-of-charset id throws the structured 400.
    expect(() => requiredHttpIdentifier("bad id!", "attachmentId")).toThrowError();
    try {
      requiredHttpIdentifier("bad id!", "attachmentId");
      throw new Error("expected throw");
    } catch (err) {
      expect((err as { status?: number }).status).toBe(400);
      expect((err as { error?: string }).error).toBe("invalid_attachmentId");
    }
  });

  it("adoptedGatewayDocId adopts a canonical client id but mints a fallback otherwise", async () => {
    const { adoptedGatewayDocId } = await import("../callables/hermesGateway.js");
    // Representative input #1: a valid client id is adopted verbatim.
    expect(adoptedGatewayDocId("att_ok-1", () => "FALLBACK")).toBe("att_ok-1");
    // Representative input #2: an over-charset id falls back to the minted token.
    expect(adoptedGatewayDocId("has space", () => "FALLBACK")).toBe("FALLBACK");
    // Absent id also falls back.
    expect(adoptedGatewayDocId(undefined, () => "FALLBACK")).toBe("FALLBACK");
  });
});

describe("hermesGateway refactor characterization — content-type guard", () => {
  it("legacyAttachmentContentTypeAllowed mirrors the allowlist", async () => {
    const { legacyAttachmentContentTypeAllowed } = await import("../callables/hermesGateway.js");
    // Representative input #1: a known-inert type is allowed.
    expect(legacyAttachmentContentTypeAllowed("image/png")).toBe(true);
    expect(legacyAttachmentContentTypeAllowed("application/pdf; charset=utf-8")).toBe(true);
    // Representative input #2: an unknown/dangerous type is rejected.
    expect(legacyAttachmentContentTypeAllowed("text/html")).toBe(false);
    expect(legacyAttachmentContentTypeAllowed("image/svg+xml")).toBe(false);
  });

  it("assertSafeAttachmentContentType throws the structured 400 on an unsafe type", async () => {
    const { assertSafeAttachmentContentType } = await import("../callables/hermesGateway.js");
    expect(() => assertSafeAttachmentContentType("image/png")).not.toThrow();
    try {
      assertSafeAttachmentContentType("text/html");
      throw new Error("expected throw");
    } catch (err) {
      expect((err as { status?: number }).status).toBe(400);
      expect((err as { error?: string }).error).toBe("unsafe_content_type");
    }
  });
});

describe("hermesGateway refactor characterization — route method guards", () => {
  it("handleDeviceStart returns 405 on a non-POST request (pre-DB short-circuit)", async () => {
    const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
    const { res, captured } = makeRes();
    await dispatchHermesGatewayRequest(makeReq("GET", "/device/start") as never, res as never);
    expect(captured.status).toBe(405);
    expect((captured.body as { error?: string }).error).toBe("method_not_allowed");
  });

  it("handleRuntimeStatus returns 405 on a non-POST request", async () => {
    const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
    const { res, captured } = makeRes();
    await dispatchHermesGatewayRequest(makeReq("GET", "/runtime") as never, res as never);
    expect(captured.status).toBe(405);
    expect((captured.body as { error?: string }).error).toBe("method_not_allowed");
  });

  it("handleAttachmentFinalize returns 405 on a non-POST request", async () => {
    const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
    const { res, captured } = makeRes();
    await dispatchHermesGatewayRequest(makeReq("GET", "/attachments/finalize") as never, res as never);
    expect(captured.status).toBe(405);
    expect((captured.body as { error?: string }).error).toBe("method_not_allowed");
  });

  it("an OPTIONS preflight short-circuits with 204", async () => {
    const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
    const { res, captured } = makeRes();
    await dispatchHermesGatewayRequest(makeReq("OPTIONS", "/runtime") as never, res as never);
    expect(captured.status).toBe(204);
  });
});
