import { describe, it, expect } from "vitest";
import {
  DEVICE_ID_KEY,
  FirstPartyCollectorTransport,
  persistentAnonymousId
} from "../src/lib/analytics/collectorTransport";

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

  it("does not persist a device id until start() after consent", () => {
    const storage = new Map<string, string>();
    const store = {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => void storage.set(key, value)
    };
    const transport = new FirstPartyCollectorTransport(
      undefined,
      async () => new Response("{}", { status: 200 }),
      store
    );
    expect(storage.get(DEVICE_ID_KEY)).toBeUndefined();
    transport.start("https://collect.burnbar.test/v1");
    expect(storage.get(DEVICE_ID_KEY)).toBeTruthy();
  });

  it("clears the persisted device id on stop so a later grant is not linkable", () => {
    const storage = new Map<string, string>();
    const store = {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => void storage.set(key, value),
      removeItem: (key: string) => void storage.delete(key)
    };
    const first = new FirstPartyCollectorTransport(
      undefined,
      async () => new Response("{}", { status: 200 }),
      store
    );
    first.start("https://collect.burnbar.test/v1");
    const beforeRevoke = storage.get(DEVICE_ID_KEY);
    expect(beforeRevoke).toBeTruthy();
    first.stop();
    expect(storage.get(DEVICE_ID_KEY)).toBeUndefined();

    const second = new FirstPartyCollectorTransport(
      undefined,
      async () => new Response("{}", { status: 200 }),
      store
    );
    second.start("https://collect.burnbar.test/v1");
    const afterGrant = storage.get(DEVICE_ID_KEY);
    expect(afterGrant).toBeTruthy();
    expect(afterGrant).not.toBe(beforeRevoke);
  });

  it("reuses a persisted anonymous device id across constructions", () => {
    const storage = new Map<string, string>();
    const store = {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => void storage.set(key, value)
    };
    const first = persistentAnonymousId(store, () => "stable-device-1");
    const second = persistentAnonymousId(store, () => "should-not-run");
    expect(first).toBe("stable-device-1");
    expect(second).toBe("stable-device-1");
    expect(storage.get(DEVICE_ID_KEY)).toBe("stable-device-1");
  });
});
