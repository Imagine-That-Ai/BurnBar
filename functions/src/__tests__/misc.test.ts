/**
 * `rebuildUsageRollups` force-gating (perf finding crosscut-001, callable side).
 *
 * The callable used to run the destructive full rebuild (`computeUserRollups`:
 * recursiveDelete of all counter collections + full usage-history rescan) on
 * EVERY stale-dashboard open. It now delegates to `refreshUserRollups` and
 * forwards `force` only when the client sent the literal boolean `true` — the
 * explicit repair entry point. The rebuild-vs-serve decision itself is covered
 * in rollupRebuildSkip.test.ts; these tests pin the callable's contract:
 *  - routine refreshes (no `force`, or any non-`true` value) pass force:false;
 *  - `force: true` passes through verbatim;
 *  - the success log records whether counters were rebuilt;
 *  - auth gating and error propagation are unchanged.
 *
 * Drives the REAL handlers through `.run(request)` with the rollup engine,
 * Firestore handle, and auth checks replaced by typed fakes.
 */

import { describe, expect, it, beforeEach, vi } from "vitest";

const { refreshUserRollupsMock, seedDemoMock, enforceMock, logInfoMock, logErrorMock, dbStub } = vi.hoisted(() => ({
  refreshUserRollupsMock: vi.fn(),
  seedDemoMock: vi.fn(),
  enforceMock: vi.fn(),
  logInfoMock: vi.fn(),
  logErrorMock: vi.fn(),
  // Identity marker: the callables must pass the shared admin Firestore handle
  // through unchanged; nothing in these tests dereferences it.
  dbStub: { __marker: "admin-db-stub" },
}));

vi.mock("../adminRuntime.js", () => ({ db: dbStub }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: enforceMock }));
vi.mock("../config.js", () => ({ getConfig: () => ({ enforceAppCheck: false }) }));
vi.mock("../rollups.js", () => ({ refreshUserRollups: refreshUserRollupsMock }));
vi.mock("../demoSeed.js", () => ({ seedAndroidDemoAccount: seedDemoMock }));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: logInfoMock, logError: logErrorMock };
});

import { rebuildUsageRollups, seedAndroidDemoAccount } from "../callables/misc.js";

const UID = "user-rollups-1";
const COMPUTED_AT = "2026-06-10T12:00:00.000Z";

// `null` is the unauthenticated sentinel: an explicit `undefined` argument
// would re-trigger the `= UID` default parameter and silently authenticate.
function req(data: Record<string, unknown>, uid: string | null = UID) {
  return {
    auth: uid === null ? undefined : { uid },
    data,
    rawRequest: { headers: {} },
  };
}

/**
 * Single typed seam for driving the real callables through `.run(request)`.
 * Funnelling every invocation through this helper keeps the unavoidable
 * mock-request widening to exactly one cast instead of one per call site.
 */
function invokeCallable<TRes = unknown>(
  callable: unknown,
  data: Record<string, unknown>,
  uid: string | null = UID,
): Promise<TRes> {
  const runnable = callable as { run: (request: unknown) => Promise<TRes> };
  return runnable.run(req(data, uid));
}

beforeEach(() => {
  vi.clearAllMocks();
  refreshUserRollupsMock.mockResolvedValue({
    rollups: { all_time: { computedAt: COMPUTED_AT } },
    rebuiltCounters: false,
  });
  seedDemoMock.mockResolvedValue({ seeded: true });
});

describe("rebuildUsageRollups force gating", () => {
  it("routine refresh (no force) requests force:false and returns the recomputed window set", async () => {
    const res = await invokeCallable<{ success: boolean; computedAt: string; windows: readonly string[] }>(
      rebuildUsageRollups,
      {},
    );

    expect(refreshUserRollupsMock).toHaveBeenCalledTimes(1);
    expect(refreshUserRollupsMock).toHaveBeenCalledWith(dbStub, UID, { force: false });
    expect(res).toEqual({
      success: true,
      computedAt: COMPUTED_AT,
      windows: ["today", "7d", "30d", "90d", "all_time"],
    });
  });

  it("force:true passes through verbatim — the explicit repair path stays reachable", async () => {
    refreshUserRollupsMock.mockResolvedValue({
      rollups: { all_time: { computedAt: COMPUTED_AT } },
      rebuiltCounters: true,
    });

    const res = await invokeCallable<{ success: boolean }>(rebuildUsageRollups, { force: true });

    expect(refreshUserRollupsMock).toHaveBeenCalledWith(dbStub, UID, { force: true });
    expect(res.success).toBe(true);
    expect(logInfoMock).toHaveBeenCalledWith(
      expect.objectContaining({ message: "rebuild_usage_rollups_succeeded", counters_rebuilt: true }),
    );
  });

  it("only the literal boolean true forces a rebuild — truthy look-alikes stay routine", async () => {
    for (const hostileForce of ["true", 1, {}, []]) {
      refreshUserRollupsMock.mockClear();
      await invokeCallable(rebuildUsageRollups, { force: hostileForce });
      expect(refreshUserRollupsMock).toHaveBeenCalledWith(dbStub, UID, { force: false });
    }
  });

  it("logs whether counters were rebuilt on the routine path", async () => {
    await invokeCallable(rebuildUsageRollups, {});

    expect(logInfoMock).toHaveBeenCalledWith(
      expect.objectContaining({
        message: "rebuild_usage_rollups_succeeded",
        computed_at: COMPUTED_AT,
        counters_rebuilt: false,
      }),
    );
  });

  it("rejects unauthenticated requests before touching the rollup engine", async () => {
    await expect(invokeCallable(rebuildUsageRollups, {}, null)).rejects.toThrow(/unauthenticated/);
    expect(refreshUserRollupsMock).not.toHaveBeenCalled();
  });

  it("enforces auth + App Check for the caller's own uid", async () => {
    await invokeCallable(rebuildUsageRollups, {});

    expect(enforceMock).toHaveBeenCalledWith(expect.objectContaining({ auth: { uid: UID } }), UID);
  });

  it("propagates refresh failures and records the structured error log", async () => {
    refreshUserRollupsMock.mockRejectedValue(new Error("counter rebuild exploded"));

    await expect(invokeCallable(rebuildUsageRollups, {})).rejects.toThrow("counter rebuild exploded");
    expect(logErrorMock).toHaveBeenCalledWith(
      expect.objectContaining({ message: "rebuild_usage_rollups_failed", detail: expect.stringContaining("exploded") }),
    );
  });
});

describe("seedAndroidDemoAccount", () => {
  it("delegates to the demo seeder with the shared db handle and the caller's uid", async () => {
    const res = await invokeCallable<{ seeded: boolean }>(seedAndroidDemoAccount, {});

    expect(seedDemoMock).toHaveBeenCalledWith(dbStub, UID);
    expect(res).toEqual({ seeded: true });
  });

  it("rejects unauthenticated requests without seeding anything", async () => {
    await expect(invokeCallable(seedAndroidDemoAccount, {}, null)).rejects.toThrow(/Sign in before loading demo data/);
    expect(seedDemoMock).not.toHaveBeenCalled();
  });
});
