import { describe, it, expect } from "vitest";
import { FirstPartyCollectorTransport } from "../src/lib/analytics/collectorTransport";

describe("FirstPartyCollectorTransport", () => {
  it("start() with an empty URL stays dark", () => {
    const calls: string[] = [];
    const transport = new FirstPartyCollectorTransport("d", async (input) => {
      calls.push(String(input));
      return new Response("{}", { status: 200 });
    });
    transport.start("");
    transport.track("page.viewed", "screen_view", { product: "burnbar" });
    expect(transport.isStarted).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it("stop() silences further tracks", async () => {
    const calls: string[] = [];
    const transport = new FirstPartyCollectorTransport("d", async (input) => {
      calls.push(String(input));
      return new Response("{}", { status: 200 });
    });
    transport.start("https://collect.burnbar.test/v1");
    transport.track("page.viewed", "screen_view", { product: "burnbar" });
    await new Promise((r) => setTimeout(r, 0));
    expect(calls).toHaveLength(1);
    transport.stop();
    transport.track("cta.clicked", "conversion_auth", { product: "burnbar" });
    await new Promise((r) => setTimeout(r, 0));
    expect(calls).toHaveLength(1);
  });
});
