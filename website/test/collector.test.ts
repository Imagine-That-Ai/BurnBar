import { describe, it, expect } from "vitest";
import { FirstPartyCollectorTransport } from "../src/lib/analytics/collectorTransport";
import { Analytics } from "../src/lib/analytics/recorder";
import { ConsentStore, type ConsentStorage } from "../src/lib/analytics/consent";
import { EVENT } from "../src/lib/analytics/events";
import { attributionFromSearch } from "../src/lib/analytics/attribution";
import { handleCollectorPost, AMPLITUDE_HTTP_V2_US } from "../../workers/analytics-collector/src/handler";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

function memoryStorage(): ConsentStorage {
  const m = new Map<string, string>();
  return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => void m.set(k, v) };
}

describe("first-party collector — consent gate", () => {
  it("does not POST when consent is unset, even with a collector URL", () => {
    const calls: { url: string; body: string }[] = [];
    const transport = new FirstPartyCollectorTransport("dev-1", async (input, init) => {
      calls.push({ url: String(input), body: String(init?.body ?? "") });
      return new Response("{}", { status: 200 });
    });
    const consent = new ConsentStore(memoryStorage());
    const analytics = new Analytics({
      consent,
      transport,
      collectorUrl: "https://collect.burnbar.test/v1",
      superProperties: () => ({ product: "burnbar", platform: "web" }),
    });

    analytics.track(EVENT.pageViewed, { surface: "home" });
    expect(calls).toHaveLength(0);
    expect(transport.isStarted).toBe(false);
  });

  it("does not POST when consent is declined", () => {
    const calls: { url: string }[] = [];
    const transport = new FirstPartyCollectorTransport("dev-1", async (input) => {
      calls.push({ url: String(input) });
      return new Response("{}", { status: 200 });
    });
    const consent = new ConsentStore(memoryStorage());
    consent.decline();
    const analytics = new Analytics({
      consent,
      transport,
      collectorUrl: "https://collect.burnbar.test/v1",
      superProperties: () => ({ product: "burnbar", platform: "web" }),
    });

    analytics.track(EVENT.pageViewed, { surface: "home" });
    expect(calls).toHaveLength(0);
    expect(transport.isStarted).toBe(false);
  });

  it("POSTs only to the collector URL after consent — never Amplitude", async () => {
    const calls: { url: string; body: unknown }[] = [];
    const transport = new FirstPartyCollectorTransport("dev-1", async (input, init) => {
      calls.push({ url: String(input), body: JSON.parse(String(init?.body ?? "{}")) });
      return new Response("{}", { status: 200 });
    });
    const consent = new ConsentStore(memoryStorage());
    consent.grant();
    const analytics = new Analytics({
      consent,
      transport,
      collectorUrl: "https://collect.burnbar.test/v1",
      superProperties: () => ({ product: "burnbar", platform: "web", app_version: "1.0.40" }),
    });

    analytics.track(EVENT.pageViewed, { surface: "home" });
    await new Promise((r) => setTimeout(r, 0));

    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe("https://collect.burnbar.test/v1");
    expect(calls[0]?.url).not.toContain("amplitude.com");
    const payload = calls[0]?.body as { consent: boolean; events: { name: string; props: Record<string, string> }[] };
    expect(payload.consent).toBe(true);
    expect(payload.events[0]?.name).toBe("page.viewed");
    expect(JSON.stringify(payload)).not.toMatch(/api[_-]?key/i);
    expect(JSON.stringify(payload)).not.toContain("830583");
  });
});

describe("collector worker — consent and project routing", () => {
  it("forwards nothing when consent is missing", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { events: [{ name: "page.viewed" }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830583" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
    );
    expect(result.status).toBe(204);
    expect(result.forwarded).toBe(0);
    expect(fetches).toHaveLength(0);
  });

  it("forwards nothing when the Amplitude key is absent (collector stays dark)", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed" }] },
      { AMPLITUDE_PROJECT_ID: "830583" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
    );
    expect(result.status).toBe(204);
    expect(result.body.reason).toBe("collector_dark");
    expect(fetches).toHaveLength(0);
  });

  it("forwards a consented funnel event to Amplitude HTTP V2 for project 830583", async () => {
    const fetches: { url: string; body: Record<string, unknown> }[] = [];
    const result = await handleCollectorPost(
      {
        consent: true,
        events: [{ name: "page.viewed", props: { product: "burnbar", surface: "web" }, device_id: "d1" }],
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830583" },
      async (url, init) => {
        fetches.push({ url, body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response(JSON.stringify({ code: 200, events_ingested: 1 }), { status: 200 });
      },
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
    expect(result.body.project_id).toBe(830583);
    expect(fetches[0]?.url).toBe(AMPLITUDE_HTTP_V2_US);
    expect(fetches[0]?.body.api_key).toBe("secret-key");
    const events = fetches[0]?.body.events as { event_properties: { amplitude_project_id: string } }[];
    expect(events[0]?.event_properties.amplitude_project_id).toBe("830583");
  });

  it("rejects CubeLove and Hormiga project ids and does not call Amplitude", async () => {
    for (const forbidden of ["852537", "703455", "799824"]) {
      const fetches: string[] = [];
      const result = await handleCollectorPost(
        { consent: true, events: [{ name: "page.viewed" }] },
        { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: forbidden },
        async (url) => {
          fetches.push(url);
          return new Response("{}", { status: 200 });
        },
      );
      expect(result.status, `project ${forbidden} must be rejected`).toBe(409);
      expect(result.body.reason).toBe("project_rejected");
      expect(fetches).toHaveLength(0);
    }
  });

  it("drops unknown event names and never forwards them", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "totally.bogus.event" }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
    );
    expect(result.status).toBe(204);
    expect(fetches).toHaveLength(0);
  });

  it("strips raw email fields before forwarding", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [{ name: "email.captured", props: { email: "a@b.com", captured: true, product: "burnbar" } }],
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push({ body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response("{}", { status: 200 });
      },
    );
    const events = fetches[0]?.body.events as { event_properties: Record<string, unknown> }[];
    expect(events[0]?.event_properties.email).toBeUndefined();
    expect(events[0]?.event_properties.captured).toBe(true);
  });
});

describe("attribution", () => {
  it("keeps only the bounded attribution keys", () => {
    const props = attributionFromSearch(
      "?utm_source=x&utm_campaign=spring&click_id=abc&slate_id=s1&post_id=p9&email=no@no.com&path=/secret",
    );
    expect(props.utm_source).toBe("x");
    expect(props.utm_campaign).toBe("spring");
    expect(props.click_id).toBe("abc");
    expect(props.slate_id).toBe("s1");
    expect(props.post_id).toBe("p9");
    expect(props.email).toBeUndefined();
    expect(props.path).toBeUndefined();
  });
});

describe("website bundle never embeds an Amplitude API key", () => {
  it("index.ts reads a collector URL, not PUBLIC_AMPLITUDE_API_KEY", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const source = readFileSync(join(here, "../src/lib/analytics/index.ts"), "utf8");
    expect(source).toContain("PUBLIC_ANALYTICS_COLLECTOR_URL");
    expect(source).not.toContain("PUBLIC_AMPLITUDE_API_KEY");
    expect(source).toContain("FirstPartyCollectorTransport");
    expect(source).not.toMatch(/AmplitudeTransport/);
  });
});
