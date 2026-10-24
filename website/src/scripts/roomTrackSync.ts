/**
 * Keeps the Afar control-room swipe track and its radio group in agreement.
 *
 * The portrait composition renders every environment panel in a horizontal
 * scroll-snap track, and the radios below it choose which panel is in view.
 * Two rules prevent the track from overwriting the person's choice:
 *
 * 1. Scrolling never selects mid-flight. The track's position only selects a
 *    radio once scrolling settles (`scrollend`, or `settleMs` without a scroll
 *    event where `scrollend` is unsupported). A smooth scroll from panel 0 to
 *    panel 1 therefore can no longer flash panel 0's radio back on when an
 *    intermediate position rounds down.
 * 2. A choice owns the track until it arrives. After `choose(i)` the track
 *    settling anywhere other than `i` is ignored for `intentMs`, so a quick
 *    second key press or a tap during the animation is honoured. If the person
 *    takes over with a swipe and the track rests elsewhere past that window,
 *    their swipe wins.
 *
 * The host supplies the DOM and the clock, so the logic is testable without a
 * browser.
 */
export interface TrackSyncHost<Timer> {
  /** Number of panels (and radios). */
  readonly count: number;
  /** Current position in panels: scrollLeft / panel width. */
  position(): number;
  /** Scroll the track to a panel. */
  scrollToIndex(index: number): void;
  /** Mark a radio checked without dispatching a change event. */
  select(index: number): void;
  now(): number;
  setTimer(callback: () => void, ms: number): Timer;
  clearTimer(timer: Timer): void;
}

export interface TrackSyncOptions {
  /** Quiet period that counts as "settled" when `scrollend` is unavailable. */
  settleMs?: number;
  /** How long a choice owns the track before a resting swipe position wins. */
  intentMs?: number;
}

export interface TrackSync {
  /** The person chose panel `index` (radio change): scroll there and protect it. */
  choose(index: number): void;
  /** A `scroll` event fired on the track. */
  onScroll(): void;
  /** A `scrollend` event fired on the track. */
  onScrollEnd(): void;
}

export function createTrackSync<Timer>(
  host: TrackSyncHost<Timer>,
  { settleMs = 120, intentMs = 1000 }: TrackSyncOptions = {}
): TrackSync {
  let target: number | null = null;
  let deadline = 0;
  let timer: Timer | null = null;

  const clamp = (index: number) => Math.min(Math.max(index, 0), host.count - 1);

  function schedule(ms: number) {
    if (timer !== null) host.clearTimer(timer);
    timer = host.setTimer(settle, ms);
  }

  function settle() {
    if (timer !== null) host.clearTimer(timer);
    timer = null;
    const index = clamp(Math.round(host.position()));
    if (target !== null && index !== target) {
      const remaining = deadline - host.now();
      if (remaining > 0) {
        // Still travelling to the chosen panel, or briefly interrupted:
        // look again once the choice's window has passed.
        schedule(remaining);
        return;
      }
    }
    target = null;
    host.select(index);
  }

  return {
    choose(index) {
      target = clamp(index);
      deadline = host.now() + intentMs;
      host.scrollToIndex(target);
    },
    onScroll() {
      schedule(settleMs);
    },
    onScrollEnd() {
      settle();
    }
  };
}
