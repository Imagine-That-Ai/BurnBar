/**
 * Characterization test pinning the CURRENT observable behavior of
 * `searchEncryptedConversationIndex` (target of the U8 complexity/max-lines refactor that
 * relocated the search/scoring machinery into `encryptedSearchQuery.ts`).
 *
 * Pins two representative inputs at the callable trust boundary, driven through `.run(request)`:
 *   1. Unauthenticated request -> throws HttpsError("unauthenticated", "Sign in before searching
 *      session logs.") before any entitlement / Firestore access.
 *   2. Authenticated request with empty token + semantic hashes -> short-circuits to { hits: [] }
 *      AFTER the entitlement gate but WITHOUT touching the cloud_search_chunks collection.
 *
 * The refactor is a verbatim relocation; identical inputs MUST keep producing identical return
 * values and identical thrown HttpsError codes/messages.
 */
import { describe, expect, it, vi } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));

// Spy so the short-circuit assertion can prove no chunk collection read occurs.
const collectionSpy = vi.fn(() => {
  throw new Error("db.collection must not be called on the empty-hashes short-circuit");
});
vi.mock("../adminRuntime.js", () => ({
  db: {
    collection: collectionSpy,
    doc: vi.fn(() => ({
      get: vi.fn(async () => ({ exists: false, data: () => ({}) })),
    })),
  },
}));

// Keep every validation helper real; neutralize only the entitlement gate (a Firestore read).
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarProEntitlement: vi.fn(async () => undefined),
  };
});

type Runnable = { run: (request: unknown) => Promise<unknown> };

function hasCallableRun(candidate: unknown): candidate is Runnable {
  if (candidate === null || (typeof candidate !== "object" && typeof candidate !== "function")) {
    return false;
  }
  return Reflect.get(candidate, "run") instanceof Function;
}

function asRunnable(candidate: unknown): Runnable {
  // firebase-functions v2 `onCall(...)` returns a CallableFunction, which is a *function* value
  // that also carries a `.run(request)` method (`CallableFunction extends HttpsFunction`). Guarding
  // on `typeof candidate === "object"` alone would reject it (a function is `"function"`), so accept
  // both shapes and require `run` to be callable — matching the repo's other callable-runner seams.
  if (!hasCallableRun(candidate)) {
    throw new Error("callable target is missing run()");
  }
  return { run: (request: unknown) => candidate.run(request) };
}

function callableRequest(uid: string | undefined, data: Record<string, unknown>): unknown {
  return {
    auth: uid ? { uid, token: {} } : undefined,
    app: { appId: "openburnbar-test" },
    rawRequest: { headers: {} },
    data,
  };
}

describe("searchEncryptedConversationIndex characterization (U8 split)", () => {
  it("rejects an unauthenticated request before any Firestore access", async () => {
    const mod = await import("../callables/encryptedSearch.js");
    const target = asRunnable(mod.searchEncryptedConversationIndex);

    let thrown: unknown;
    try {
      await target.run(callableRequest(undefined, { tokenHashes: [], semanticHashes: [] }));
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeTruthy();
    expect(thrown).toBeInstanceOf(Error);
    if (!(thrown instanceof Error)) throw new Error("expected HttpsError-compatible Error");
    expect(Reflect.get(thrown, "code")).toBe("unauthenticated");
    expect(thrown.message).toBe("Sign in before searching session logs.");
    expect(collectionSpy).not.toHaveBeenCalled();
  });

  it("short-circuits to an empty hit list when no token or semantic hashes are supplied", async () => {
    const mod = await import("../callables/encryptedSearch.js");
    const target = asRunnable(mod.searchEncryptedConversationIndex);

    const result = await target.run(
      callableRequest("alice-char-uid", {
        tokenHashes: [],
        semanticHashes: [],
        limit: 25,
        provider: "openai",
      }),
    );

    expect(result).toEqual({ hits: [] });
    // The short-circuit returns before any cloud_search_chunks collection read.
    expect(collectionSpy).not.toHaveBeenCalled();
  });
});
