/**
 * R-L3 — `evaluateComputerUseBudget` must FAIL CLOSED (and stay observable)
 * when Remote Config is unreadable.
 *
 * The Computer Use budget gate pulls its caps from Firebase Remote Config.
 * Before this fix a Remote Config read failure (cold start, offline, permission
 * error) was swallowed by a bare `catch {}` and silently fell back to the
 * optimistic in-code defaults, so it evaluated as `normal` (fail-OPEN) with no
 * log or Sentry event. This proves the catch-path now (a) clamps to `hard_cap`
 * (kill-switch tier) regardless of projected spend, and (b) surfaces the outage
 * to Sentry — while a healthy Remote Config still evaluates `normal` on a
 * low-spend month.
 */

import { describe, expect, it, vi, beforeEach } from "vitest";

// In-memory Firestore double: rollups read (empty → zero spend) + status/metrics
// writes. The budget level under test is driven entirely by the tunings path.
const { firestoreMock, writes, FakeTimestamp } = vi.hoisted(() => {
  const writes = new Map<string, Record<string, unknown>>();

  class FakeTimestamp {
    constructor(public readonly ms: number) {}
    static now(): FakeTimestamp {
      return new FakeTimestamp(Date.now());
    }
    static fromDate(date: Date): FakeTimestamp {
      return new FakeTimestamp(date.getTime());
    }
    toMillis(): number {
      return this.ms;
    }
  }

  const docRef = (path: string) => ({
    path,
    async set(data: Record<string, unknown>) {
      writes.set(path, { ...(writes.get(path) ?? {}), ...data });
    },
  });

  const firestoreMock = {
    collection: (_path: string) => ({
      where() {
        return this;
      },
      async get() {
        return { docs: [] };
      },
    }),
    doc: (path: string) => docRef(path),
  };

  return { firestoreMock, writes, FakeTimestamp };
});

vi.mock("firebase-admin/firestore", () => ({ getFirestore: () => firestoreMock, Timestamp: FakeTimestamp }));

// Kill-switch sync publishes to Remote Config; stub so the test stays hermetic
// and we can assert the level it was handed.
const { syncKillSwitchMock } = vi.hoisted(() => ({ syncKillSwitchMock: vi.fn(async () => {}) }));
vi.mock("../computerUseRemoteConfig.js", () => ({ syncKillSwitchForBudgetLevel: syncKillSwitchMock }));

// Sentry is loaded via dynamic import on the failure path; mock it so we can
// assert the RC outage is actually captured (observable, not swallowed).
const { captureExceptionMock } = vi.hoisted(() => ({ captureExceptionMock: vi.fn() }));
vi.mock("../sentry.js", () => ({ captureException: captureExceptionMock, setSentryUser: vi.fn() }));

const { getTemplateMock } = vi.hoisted(() => ({ getTemplateMock: vi.fn() }));
vi.mock("firebase-admin/remote-config", () => ({ getRemoteConfig: () => ({ getTemplate: getTemplateMock }) }));

import { evaluateComputerUseBudgetOnce } from "../computerUseBudget.js";

describe("evaluateComputerUseBudget — R-L3 fail-closed on Remote Config failure", () => {
  beforeEach(() => {
    writes.clear();
    syncKillSwitchMock.mockClear();
    captureExceptionMock.mockClear();
    getTemplateMock.mockReset();
  });

  it("clamps to hard_cap and captures to Sentry when Remote Config throws (fail CLOSED, not normal)", async () => {
    getTemplateMock.mockRejectedValue(new Error("PERMISSION_DENIED reading Remote Config template"));

    const result = await evaluateComputerUseBudgetOnce(new Date("2026-06-12T00:00:00.000Z"));

    expect(result.level).toBe("hard_cap");
    // Kill-switch tier means the published envelope zeroes every allowance.
    expect(writes.get("ops/computer_use_budget_status/state/current")).toMatchObject({
      level: "hard_cap",
      activeActionsPerRun: 0,
      activeActionsPerDay: 0,
      activeSessionsPerDay: 0,
      perUserDailySpendCeilingUSD: 0,
    });
    // The gate must have been handed the conservative level.
    expect(syncKillSwitchMock).toHaveBeenCalledWith("hard_cap");
    // The outage must be observable — never swallowed silently.
    expect(captureExceptionMock).toHaveBeenCalled();
  });

  it("evaluates normal on a low-spend month when Remote Config loads cleanly", async () => {
    getTemplateMock.mockResolvedValue({ parameters: {} });

    const result = await evaluateComputerUseBudgetOnce(new Date("2026-06-12T00:00:00.000Z"));

    // Zero rollups → $0 projected → normal level (proves the fail-closed clamp
    // is scoped to the failure path, not the happy path).
    expect(result.level).toBe("normal");
    expect(syncKillSwitchMock).toHaveBeenCalledWith("normal");
    expect(captureExceptionMock).not.toHaveBeenCalled();
  });
});
