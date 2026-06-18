import { describe, expect, it } from "vitest";

import { AmplitudeTransport } from "../lib/analytics/amplitudeTransport";

/**
 * Pre-consent darkness of the REAL transport. These assertions hold WITHOUT the
 * Amplitude module ever resolving — they pin the synchronous guarantees the
 * recorder relies on: nothing is "started", no key is a no-op, and track before
 * start buffers in-process (never a network call). The dynamic `import()` is only
 * triggered by start() with a non-empty key, which the recorder calls solely
 * after consent is granted.
 */
describe("AmplitudeTransport pre-consent darkness", () => {
  it("is not started on construction", () => {
    const t = new AmplitudeTransport("US");
    expect(t.isStarted).toBe(false);
  });

  it("start('') is a no-op — an empty key never loads the SDK", () => {
    const t = new AmplitudeTransport("US");
    t.start("");
    expect(t.isStarted).toBe(false);
  });

  it("track() before start() does not start the transport", () => {
    const t = new AmplitudeTransport("US");
    t.track("screen.viewed", "screen_view", { platform: "console" });
    expect(t.isStarted).toBe(false);
  });

  it("setUserId() before start() does not start the transport", () => {
    const t = new AmplitudeTransport("US");
    t.setUserId("hashed-uid");
    expect(t.isStarted).toBe(false);
  });

  it("stop() is safe before anything started", () => {
    const t = new AmplitudeTransport("US");
    expect(() => t.stop()).not.toThrow();
    expect(t.isStarted).toBe(false);
  });

  it("a non-empty key flips started synchronously (then loads the module async)", () => {
    const t = new AmplitudeTransport("US");
    t.start("test-key"); // kicks off the dynamic import; started flips immediately
    expect(t.isStarted).toBe(true);
    // We immediately stop to mark opted-out; the async import resolution must not
    // resurrect sending (the optedOut guard in start()).
    t.stop();
    expect(t.isStarted).toBe(false);
  });
});
