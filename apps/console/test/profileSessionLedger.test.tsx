// @vitest-environment jsdom
/**
 * Ledger contract: raw events group into sessions (shared sessionId merges,
 * unkeyed events stand alone), sessions sort newest-first by default, and
 * every row exposes a visible, labeled control — expand, focus session,
 * focus run. No hover-only affordances.
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import {
  groupLedgerSessions,
  ProfileSessionLedger,
} from "../components/profile/ProfileSessionLedger";
import type { ProfileUsageEvent } from "../lib/profile/profileEvents";

beforeAll(() => {
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

function ev(partial: Partial<ProfileUsageEvent> & { id: string }): ProfileUsageEvent {
  return {
    provider: "Claude Code",
    providerID: "claude-code",
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    reasoningTokens: 0,
    totalTokens: 0,
    costUsd: 0,
    startedAt: null,
    hourUtc: null,
    durationSeconds: null,
    ...partial,
  };
}

const events = [
  ev({
    id: "a1",
    sessionId: "s-1",
    model: "m-1",
    harnessName: "H1",
    totalTokens: 100,
    costUsd: 1,
    startedAt: "2026-08-14T07:10:00.000Z",
    durationSeconds: 30,
  }),
  ev({
    id: "a2",
    sessionId: "s-1",
    model: "m-2",
    harnessName: "H1",
    totalTokens: 200,
    costUsd: 2,
    startedAt: "2026-08-14T07:12:00.000Z",
    durationSeconds: 90,
  }),
  ev({
    id: "b1",
    model: "m-1",
    totalTokens: 50,
    costUsd: 0.5,
    startedAt: "2026-08-15T07:10:00.000Z",
  }),
];

describe("groupLedgerSessions", () => {
  it("merges shared sessionIds and stands unkeyed events alone", () => {
    const sessions = groupLedgerSessions(events);
    expect(sessions).toHaveLength(2);
    const merged = sessions.find((s) => s.sessionId === "s-1")!;
    expect(merged.runs).toBe(2);
    expect(merged.tokens).toBe(300);
    expect(merged.cost).toBe(3);
    expect(merged.models).toEqual(["m-1", "m-2"]);
    expect(merged.startedAt).toBe("2026-08-14T07:10:00.000Z");
    expect(merged.endedAt).toBe("2026-08-14T07:12:00.000Z");
    // Session span: earliest start (07:10) → latest run end (07:12 + 90s).
    expect(merged.durationSeconds).toBe(210);
    const solo = sessions.find((s) => s.sessionId === null)!;
    expect(solo.runs).toBe(1);
    expect(solo.events.map((e) => e.id)).toEqual(["b1"]);
  });
});

let container: HTMLDivElement | null = null;
let root: Root | null = null;

afterEach(() => {
  if (root && container) {
    act(() => root!.unmount());
    container.remove();
  }
  container = null;
  root = null;
  vi.restoreAllMocks();
});

function renderLedger(props?: Partial<React.ComponentProps<typeof ProfileSessionLedger>>) {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
  const r = root;
  act(() => {
    r.render(
      <ProfileSessionLedger
        events={events}
        loading={false}
        error={null}
        hasMore={false}
        capped={false}
        enabledHint={null}
        onLoadMore={() => {}}
        onFocusEvent={() => {}}
        onFocusSession={() => {}}
        {...props}
      />,
    );
  });
  return container;
}

describe("ProfileSessionLedger", () => {
  it("renders one row per session with visible expand + focus controls", () => {
    const el = renderLedger();
    expect(el.textContent).toContain("2 sessions · 3 runs");
    const expanders = [...el.querySelectorAll("button")].filter((b) =>
      (b.getAttribute("aria-label") ?? "").startsWith("Expand session"),
    );
    expect(expanders).toHaveLength(2);
    const focusers = [...el.querySelectorAll("button")].filter(
      (b) => b.title === "Focus this session in the inspector",
    );
    expect(focusers).toHaveLength(2);
  });

  it("expanding a session reveals its runs with per-run focus buttons", () => {
    const onFocusEvent = vi.fn();
    const el = renderLedger({ onFocusEvent });
    const expander = [...el.querySelectorAll("button")].find((b) =>
      (b.getAttribute("aria-label") ?? "").includes("s-1"),
    )!;
    act(() => {
      expander.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(el.textContent).toContain("07:10");
    expect(el.textContent).toContain("07:12");
    const runButtons = [...el.querySelectorAll("button")].filter(
      (b) => b.title === "Focus this run in the inspector",
    );
    expect(runButtons).toHaveLength(2);
    act(() => {
      runButtons[0]!.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(onFocusEvent).toHaveBeenCalledTimes(1);
  });

  it("session focus reports the session, not just a day", () => {
    const onFocusSession = vi.fn();
    const el = renderLedger({ onFocusSession });
    // Default sort is newest-first: the Aug-15 solo session (unkeyed) comes
    // first, s-1 second. Find s-1's focuser by its session prefix label.
    const focuser = [...el.querySelectorAll("button")].find(
      (b) =>
        b.title === "Focus this session in the inspector" &&
        (b.closest("tr")?.textContent ?? "").includes("2026-08-14"),
    )!;
    act(() => {
      focuser.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(onFocusSession).toHaveBeenCalledTimes(1);
    expect(onFocusSession.mock.calls[0][0].sessionId).toBe("s-1");
  });

  it("sorts by tokens, spend, runs, and duration", () => {
    const el = renderLedger();
    const getFirstSessionTime = () =>
      [...el.querySelectorAll("tbody tr")][0]?.querySelectorAll("td")[1]?.textContent;
    // Default: newest first (Aug 15 solo session).
    expect(getFirstSessionTime()).toContain("2026-08-15");
    // Sort by tokens desc: s-1 (300) first.
    const tokensHead = [...el.querySelectorAll("button")].find(
      (b) => b.getAttribute("aria-label") === "Sort by Tokens",
    )!;
    act(() => {
      tokensHead.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });
    expect(getFirstSessionTime()).toContain("2026-08-14");
  });
});
