import { describe, expect, it } from "vitest";
import { createTrackSync, type TrackSyncHost } from "../src/scripts/roomTrackSync";

/** A deterministic host: manual clock, timer queue and a scriptable track position. */
function harness(count = 3) {
  let clock = 0;
  let position = 0;
  let nextId = 1;
  const timers = new Map<number, { at: number; callback: () => void }>();
  const selected: number[] = [];
  const scrolledTo: number[] = [];
  let checked = 0;

  const host: TrackSyncHost<number> = {
    count,
    position: () => position,
    scrollToIndex: (index) => scrolledTo.push(index),
    select: (index) => {
      selected.push(index);
      checked = index;
    },
    now: () => clock,
    setTimer: (callback, ms) => {
      const id = nextId++;
      timers.set(id, { at: clock + ms, callback });
      return id;
    },
    clearTimer: (id) => timers.delete(id)
  };

  /** Advance the clock, firing due timers in order. */
  function advance(ms: number) {
    const end = clock + ms;
    for (;;) {
      const due = [...timers.entries()]
        .filter(([, t]) => t.at <= end)
        .sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      timers.delete(due[0]);
      clock = due[1].at;
      due[1].callback();
    }
    clock = end;
  }

  return {
    host,
    selected,
    scrolledTo,
    checked: () => checked,
    advance,
    setPosition: (value: number) => (position = value)
  };
}

/** Animate the track from `from` to `to` panels, one scroll event per 16 ms frame. */
function animate(
  h: ReturnType<typeof harness>,
  sync: ReturnType<typeof createTrackSync>,
  from: number,
  to: number,
  frames = 20
) {
  for (let frame = 1; frame <= frames; frame++) {
    h.setPosition(from + ((to - from) * frame) / frames);
    sync.onScroll();
    h.advance(16);
  }
}

describe("room track sync", () => {
  it("never selects an intermediate panel while a chosen panel scrolls into view", () => {
    // The reported race: a smooth scroll 0 -> 1 passes positions that round to
    // 0, which used to re-check panel 0's radio mid-flight.
    const h = harness();
    const sync = createTrackSync(h.host);
    sync.choose(1);
    expect(h.scrolledTo).toEqual([1]);
    animate(h, sync, 0, 1);
    expect(h.selected).toEqual([]);
    sync.onScrollEnd();
    expect(h.selected).toEqual([1]);
  });

  it("honours a second choice made during the first animation", () => {
    const h = harness();
    const sync = createTrackSync(h.host);
    sync.choose(1);
    animate(h, sync, 0, 0.5, 10);
    sync.choose(2); // second key press mid-flight
    animate(h, sync, 0.5, 2, 20);
    h.advance(200);
    expect(h.selected).toEqual([2]);
    expect(h.scrolledTo).toEqual([1, 2]);
  });

  it("selects the panel a swipe settles on, once, after it settles", () => {
    const h = harness();
    const sync = createTrackSync(h.host);
    animate(h, sync, 0, 2);
    expect(h.selected).toEqual([]);
    h.advance(200); // no scrollend support: the quiet period settles it
    expect(h.selected).toEqual([2]);
  });

  it("lets a swipe that takes over a choice win once the choice window passes", () => {
    const h = harness();
    const sync = createTrackSync(h.host, { intentMs: 1000 });
    sync.choose(2);
    animate(h, sync, 0, 0.4, 5);
    animate(h, sync, 0.4, 1, 10); // the person grabs the track and lands on panel 1
    sync.onScrollEnd();
    expect(h.selected).toEqual([]); // still inside the choice window
    h.advance(1000);
    expect(h.selected).toEqual([1]);
    expect(h.checked()).toBe(1);
  });

  it("clamps out-of-range positions and choices", () => {
    const h = harness();
    const sync = createTrackSync(h.host);
    sync.choose(9);
    expect(h.scrolledTo).toEqual([2]);
    h.setPosition(-0.4);
    sync.onScroll();
    h.advance(1200);
    expect(h.selected).toEqual([0]);
  });
});
