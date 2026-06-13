/**
 * RR-9 — `evaluateMediaBudget` must FAIL CLOSED when Remote Config is
 * unreadable.
 *
 * The hosted-relay budget gate pulls its caps from Firebase Remote Config.
 * Before this fix a Remote Config read failure (cold start, offline,
 * permission error) silently fell back to the optimistic in-code defaults and
 * therefore evaluated as `normal` (fail-OPEN), letting unbounded n0 spend
 * through. This proves the catch-path now clamps to `hard_cap` (kill-switch
 * tier) regardless of projected spend, while a healthy Remote Config still
 * evaluates `normal` on a low-spend month.
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
        return { docs: [] as unknown[] };
      },
    }),
    doc: (path: string) => docRef(path),
  };

  return { firestoreMock, writes, FakeTimestamp };
});

vi.mock("firebase-admin/firestore", () => ({ getFirestore: () => firestoreMock, Timestamp: FakeTimestamp }));

// Kill-switch sync writes to Remote Config; stub so the test stays hermetic and
// we can assert the level it was handed.
const { syncKillSwitchMock } = vi.hoisted(() => ({ syncKillSwitchMock: vi.fn(async () => {}) }));
vi.mock("../mediaRemoteConfig.js", () => ({ syncKillSwitchForMediaBudgetLevel: syncKillSwitchMock }));

const { getTemplateMock } = vi.hoisted(() => ({ getTemplateMock: vi.fn() }));
vi.mock("firebase-admin/remote-config", () => ({ getRemoteConfig: () => ({ getTemplate: getTemplateMock }) }));

import { evaluateBudget } from "../mediaBudget.js";

describe("evaluateMediaBudget — RR-9 fail-closed on Remote Config failure", () => {
  beforeEach(() => {
    writes.clear();
    syncKillSwitchMock.mockClear();
    getTemplateMock.mockReset();
  });

  it("clamps to hard_cap when Remote Config throws (fail CLOSED, not normal)", async () => {
    getTemplateMock.mockRejectedValue(new Error("PERMISSION_DENIED reading Remote Config template"));

    const status = await evaluateBudget(new Date("2026-06-12T00:00:00.000Z"));

    expect(status.level).toBe("hard_cap");
    // Kill-switch tier means the envelope zeroes every media allowance.
    expect(status.activeEnvelope).toMatchObject({
      screenShareDailyMinutes: 0,
      videoCallDailyMinutes: 0,
      fileTransferDailyGBIn: 0,
      fileTransferDailyGBOut: 0,
    });
    // The gate must have been handed the conservative level.
    expect(syncKillSwitchMock).toHaveBeenCalledWith("hard_cap");
  });

  it("evaluates normal on a low-spend month when Remote Config loads cleanly", async () => {
    getTemplateMock.mockResolvedValue({ parameters: {} });

    const status = await evaluateBudget(new Date("2026-06-12T00:00:00.000Z"));

    // Zero rollups → $0 projected → normal envelope (proves the fail-closed
    // clamp is scoped to the failure path, not the happy path).
    expect(status.level).toBe("normal");
    expect(syncKillSwitchMock).toHaveBeenCalledWith("normal");
  });
});
