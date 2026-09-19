// @vitest-environment jsdom
/**
 * Paging-loop contract for useProfileEvents: a full server page with ZERO
 * client matches is a gap, not exhaustion — the hook must continue on raw
 * server truth (serverHasMore), not the post-filter event count.
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

vi.mock("firebase/firestore", () => ({}));

vi.mock("@/lib/firebaseClient", () => ({
  db: () => ({}),
}));

vi.mock("@/lib/useAuth", () => {
  // Stable identity across renders — mirrors the real AuthProvider's
  // useMemo'd value. A fresh literal per call would retrigger the hook's
  // user-keyed effects every render (infinite loop).
  const stable = { user: { uid: "probe" }, loading: false };
  return { useAuth: () => stable };
});

const fetchMock = vi.fn();
vi.mock("../lib/profile/profileEvents", () => ({
  PROFILE_EVENTS_PAGE_SIZE: 100,
  PROFILE_EVENTS_AGGREGATE_CAP: 2_000,
  fetchProfileEventPage: (...args: unknown[]) => fetchMock(...args),
}));

// Imported after the mocks above (hoisted by vitest regardless).
import { useProfileEvents } from "../lib/profile/useProfileEvents";

let container: HTMLDivElement | null = null;
let root: Root | null = null;
let seen: { count: number; loading: boolean } = { count: -1, loading: true };

afterEach(() => {
  if (root && container) {
    act(() => root!.unmount());
    container.remove();
  }
  container = null;
  root = null;
  fetchMock.mockReset();
});

function renderHook() {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  const Probe = () => {
    const r = useProfileEvents(
      { providers: ["claude-code"], models: [], devices: [], harnesses: [], accounts: [] },
      { fromDay: "2026-08-01", toDay: "2026-08-16" },
      true,
    );
    seen = { count: r.events.length, loading: r.loading };
    return null;
  };
  act(() => {
    root!.render(<Probe />);
  });
}

describe("useProfileEvents auto-paging", () => {
  it("pages past a zero-match page on raw server truth", async () => {
    const match = {
      id: "late-match",
      provider: "x",
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      reasoningTokens: 0,
      totalTokens: 10,
      costUsd: 0,
      startedAt: "2026-08-02T00:00:00.000Z",
      hourUtc: 0,
      durationSeconds: null,
    };
    fetchMock
      .mockResolvedValueOnce({
        page: { events: [], cursor: { c: 1 }, serverHasMore: true, rawCount: 100 },
        error: null,
      })
      .mockResolvedValueOnce({
        page: { events: [match], cursor: null, serverHasMore: false, rawCount: 1 },
        error: null,
      });
    renderHook();
    // Flush the full promise chain (fetch → setState → loop → fetch):
    // poll until the late match lands or the deadline hits.
    const deadline = Date.now() + 4_000;
    while (seen.count !== 1 && Date.now() < deadline) {
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 25));
      });
    }
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(seen.count).toBe(1);
    expect(seen.loading).toBe(false);
  });

  it("stops at the raw aggregate cap", async () => {
    fetchMock.mockResolvedValue({
      page: {
        events: [],
        cursor: { c: 1 },
        serverHasMore: true,
        rawCount: 100,
      },
      error: null,
    });
    renderHook();
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 200));
    });
    // 2,000 raw docs / 100 per page = 20 fetches, then the cap stops it.
    expect(fetchMock.mock.calls.length).toBeLessThanOrEqual(21);
    expect(seen.count).toBe(0);
  });
});
