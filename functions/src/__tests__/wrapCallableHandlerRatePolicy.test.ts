/**
 * wrapCallableHandler central rate-policy enforcement.
 *
 * The wrapper resolves each callable's policy from CALLABLE_RATE_POLICIES at
 * definition time; a `limited` policy runs checkCallablePolicyRateLimit before
 * the handler and rejects unauthenticated calls, while exempt /
 * handler-enforced policies add no central bookkeeping.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ALICE_UID, pathKeyedFirestore } from "./bola/callableBolaHarness.js";

const mocks = vi.hoisted(() => ({
  store: new Map<string, Record<string, unknown>>(),
  captureException: vi.fn(),
  setSentryUser: vi.fn(),
}));

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(mocks.store),
  };
});

vi.mock("../../../packages/functions-shared/src/adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));

vi.mock("../../../packages/functions-shared/src/sentry.js", () => ({
  captureException: mocks.captureException,
  setSentryUser: mocks.setSentryUser,
}));

vi.mock("../../../packages/functions-shared/src/accountErasureBarrier.js", () => ({
  assertAccountErasureAllowsCallable: vi.fn(async () => undefined),
}));

import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { wrapCallableHandler } from "../../../packages/functions-shared/src/logging.js";

const BOB_UID = "bob-wrapper-uid";

function requestFor(uid?: string, data: Record<string, unknown> = {}): CallableRequest<Record<string, unknown>> {
  return {
    auth: uid ? { uid, token: Object.create(null), rawToken: "test-token" } : undefined,
    data,
    rawRequest: Object.assign(Object.create(null), { headers: {} }),
    acceptsStreaming: false,
  };
}

function rateLimitDocPaths(store: Map<string, Record<string, unknown>>): string[] {
  return [...store.keys()].filter((p) => p.startsWith("public_rate_limits/"));
}

describe("wrapCallableHandler rate-policy enforcement", () => {
  beforeEach(() => {
    mocks.store.clear();
    vi.clearAllMocks();
  });
  afterEach(() => vi.useRealTimers());

  it("throws at definition time when the callable has no declared policy", () => {
    expect(() => wrapCallableHandler("totallyUnregisteredCallableName", async () => ({}))).toThrow(
      /No callable rate policy declared for "totallyUnregisteredCallableName"/,
    );
  });

  it("rejects unauthenticated callers of a limited callable", async () => {
    const handler = vi.fn(async () => ({ ok: true }));
    const wrapped = wrapCallableHandler("deleteDomainData", handler);
    await expect(wrapped(requestFor(undefined))).rejects.toMatchObject({ code: "unauthenticated" });
    expect(handler).not.toHaveBeenCalled();
    expect(rateLimitDocPaths(mocks.store)).toEqual([]);
  });

  it("enforces the burst window before the handler runs", async () => {
    // submitBugReport's declared limits: 3 per 600 s / 10 per day.
    const handler = vi.fn(async () => ({ ok: true }));
    const wrapped = wrapCallableHandler("submitBugReport", handler);
    for (let i = 0; i < 3; i += 1) {
      await expect(wrapped(requestFor(ALICE_UID))).resolves.toEqual({ ok: true });
    }
    await expect(wrapped(requestFor(ALICE_UID))).rejects.toMatchObject({ code: "resource-exhausted" });
    expect(handler).toHaveBeenCalledTimes(3);
  });

  it("enforces the sustained window after the burst window resets", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-01T00:00:00Z"));
    const handler = vi.fn(async () => ({ ok: true }));
    const wrapped = wrapCallableHandler("submitBugReport", handler);
    for (let window = 0; window < 3; window += 1) {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        await wrapped(requestFor(ALICE_UID));
      }
      vi.advanceTimersByTime(601_000);
    }
    // 9 calls so far; the 10th is allowed by the daily cap, the 11th rejects —
    // the burst window would have allowed both.
    await expect(wrapped(requestFor(ALICE_UID))).resolves.toEqual({ ok: true });
    await expect(wrapped(requestFor(ALICE_UID))).rejects.toMatchObject({ code: "resource-exhausted" });
    expect(handler).toHaveBeenCalledTimes(10);
  });

  it("isolates limits per uid", async () => {
    const handler = vi.fn(async () => ({ ok: true }));
    const wrapped = wrapCallableHandler("submitBugReport", handler);
    for (let i = 0; i < 3; i += 1) {
      await wrapped(requestFor(ALICE_UID));
    }
    await expect(wrapped(requestFor(ALICE_UID))).rejects.toMatchObject({ code: "resource-exhausted" });
    await expect(wrapped(requestFor(BOB_UID))).resolves.toEqual({ ok: true });
  });

  it("does not send rate-limit rejections to Sentry captureException", async () => {
    const handler = vi.fn(async () => ({ ok: true }));
    const wrapped = wrapCallableHandler("submitBugReport", handler);
    for (let i = 0; i < 3; i += 1) {
      await wrapped(requestFor(ALICE_UID));
    }
    mocks.captureException.mockClear();
    await expect(wrapped(requestFor(ALICE_UID))).rejects.toMatchObject({ code: "resource-exhausted" });
    expect(mocks.captureException).not.toHaveBeenCalled();
  });

  it("still captures handler errors to Sentry", async () => {
    const failure = new HttpsError("internal", "handler exploded");
    const wrapped = wrapCallableHandler("deleteDomainData", async () => {
      throw failure;
    });
    await expect(wrapped(requestFor(ALICE_UID))).rejects.toThrow("handler exploded");
    expect(mocks.captureException).toHaveBeenCalledWith(
      failure,
      expect.objectContaining({ callable: "deleteDomainData" }),
    );
  });

  it("writes no public_rate_limits docs for exempt callables", async () => {
    const handler = vi.fn(async () => ({ ok: true }));
    const wrapped = wrapCallableHandler("getAuditLog", handler); // exempt read-only
    await expect(wrapped(requestFor(ALICE_UID))).resolves.toEqual({ ok: true });
    await expect(wrapped(requestFor(undefined))).resolves.toEqual({ ok: true });
    expect(rateLimitDocPaths(mocks.store)).toEqual([]);
  });

  it("writes no public_rate_limits docs for handler-enforced callables", async () => {
    const handler = vi.fn(async () => ({ ok: true }));
    const wrapped = wrapCallableHandler("arenaVote", handler); // handler-enforced
    await expect(wrapped(requestFor(ALICE_UID))).resolves.toEqual({ ok: true });
    expect(rateLimitDocPaths(mocks.store)).toEqual([]);
  });
});
