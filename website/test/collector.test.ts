import { describe, it, expect } from "vitest";
import { FirstPartyCollectorTransport } from "../src/lib/analytics/collectorTransport";
import { Analytics } from "../src/lib/analytics/recorder";
import { ConsentStore, type ConsentStorage } from "../src/lib/analytics/consent";
import { EVENT } from "../src/lib/analytics/events";
import { attributionFromSearch } from "../src/lib/analytics/attribution";
import {
  handleCollectorPost,
  AMPLITUDE_HTTP_V2_US,
  isAllowedCollectorOrigin
} from "../../workers/analytics-collector/src/handler";
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
      superProperties: () => ({ product: "burnbar", platform: "web" })
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
      superProperties: () => ({ product: "burnbar", platform: "web" })
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
      superProperties: () => ({ product: "burnbar", platform: "web", app_version: "1.0.40" })
    });

    analytics.track(EVENT.pageViewed, { surface: "home" });
    await new Promise((r) => setTimeout(r, 0));

    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe("https://collect.burnbar.test/v1");
    expect(calls[0]?.url).not.toContain("amplitude.com");
    const payload = calls[0]?.body as {
      consent: boolean;
      events: { name: string; props: Record<string, string> }[];
    };
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
      }
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
      }
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
        events: [
          { name: "page.viewed", props: { product: "burnbar", surface: "web" }, device_id: "d1" }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830583" },
      async (url, init) => {
        fetches.push({ url, body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response(JSON.stringify({ code: 200, events_ingested: 1 }), { status: 200 });
      }
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
    expect(result.body.project_id).toBe(830583);
    expect(fetches[0]?.url).toBe(AMPLITUDE_HTTP_V2_US);
    expect(fetches[0]?.body.api_key).toBe("secret-key");
    const events = fetches[0]?.body.events as {
      event_properties: { amplitude_project_id: string };
    }[];
    expect(events[0]?.event_properties.amplitude_project_id).toBe("830583");
  });

  it("rejects malformed project id suffixes instead of parseInt coercion", async () => {
    for (const malformed of ["830583-prod", "830583.5"]) {
      const fetches: string[] = [];
      const result = await handleCollectorPost(
        { consent: true, events: [{ name: "page.viewed" }] },
        { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: malformed },
        async (url) => {
          fetches.push(url);
          return new Response("{}", { status: 200 });
        }
      );
      expect(result.status, `project ${malformed} must be rejected`).toBe(409);
      expect(result.body.reason).toBe("project_rejected");
      expect(fetches).toHaveLength(0);
    }
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
        }
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
      }
    );
    expect(result.status).toBe(204);
    expect(fetches).toHaveLength(0);
  });

  it("forwards arena events that the marketing site already emits", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    const result = await handleCollectorPost(
      {
        consent: true,
        events: [{ name: "arena.vote.recorded", props: { variant: "neural", choice: "a" } }]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push({ body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response("{}", { status: 200 });
      }
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
    const events = fetches[0]?.body.events as { event_type: string }[];
    expect(events[0]?.event_type).toBe("arena.vote.recorded");
  });

  it("allows production and staging hosting origins", () => {
    expect(isAllowedCollectorOrigin("https://burnbar.ai")).toBe(true);
    expect(isAllowedCollectorOrigin("https://www.burnbar.ai")).toBe(true);
    expect(isAllowedCollectorOrigin("https://burnbar.web.app")).toBe(true);
    expect(isAllowedCollectorOrigin("https://burnbar.firebaseapp.com")).toBe(true);
    expect(isAllowedCollectorOrigin("https://burnbar-staging.web.app")).toBe(true);
    expect(isAllowedCollectorOrigin("https://burnbar-staging.firebaseapp.com")).toBe(true);
    expect(isAllowedCollectorOrigin("http://127.0.0.1:4321")).toBe(true);
    expect(isAllowedCollectorOrigin("https://evil.example")).toBe(false);
  });

  it("forwards from a staging origin", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed" }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
      "https://burnbar-staging.web.app"
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
    expect(fetches).toHaveLength(1);
  });

  it("rejects a disallowed origin and does not call Amplitude", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed" }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
      "https://evil.example"
    );
    expect(result.status).toBe(403);
    expect(result.body.reason).toBe("origin_rejected");
    expect(fetches).toHaveLength(0);
  });

  it("rejects a null body without throwing", async () => {
    const result = await handleCollectorPost(
      null,
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async () => new Response("{}", { status: 200 })
    );
    expect(result.status).toBe(400);
    expect(result.body.reason).toBe("invalid_body");
  });

  it("does not throw when device_id is a number", async () => {
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed", device_id: 12 as unknown as string }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async () => new Response("{}", { status: 200 })
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
  });

  it("rejects oversized event batches", async () => {
    const events = Array.from({ length: 21 }, (_, i) => ({
      name: "page.viewed",
      insert_id: `n${i}`
    }));
    const result = await handleCollectorPost(
      { consent: true, events },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async () => new Response("{}", { status: 200 })
    );
    expect(result.status).toBe(413);
    expect(result.body.reason).toBe("batch_too_large");
  });

  it("strips raw email fields before forwarding", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "email.captured",
            props: { email: "a@b.com", captured: true, product: "burnbar" }
          }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push({ body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response("{}", { status: 200 });
      }
    );
    const events = fetches[0]?.body.events as { event_properties: Record<string, unknown> }[];
    expect(events[0]?.event_properties.email).toBeUndefined();
    expect(events[0]?.event_properties.captured).toBe(true);
  });
});

describe("attribution", () => {
  it("keeps only the bounded attribution keys", () => {
    const props = attributionFromSearch(
      "?utm_source=x&utm_campaign=spring&click_id=abc&slate_id=s1&post_id=p9&email=no@no.com&path=/secret"
    );
    expect(props.utm_source).toBe("x");
    expect(props.utm_campaign).toBe("spring");
    expect(props.click_id).toBe("abc");
    expect(props.slate_id).toBe("s1");
    expect(props.post_id).toBe("p9");
    expect(props.email).toBeUndefined();
    expect(props.path).toBeUndefined();
  });

  it("drops attribution values that look like personal data", () => {
    const props = attributionFromSearch("?utm_campaign=a@b.com&utm_source=x");
    expect(props.utm_campaign).toBeUndefined();
    expect(props.utm_source).toBe("x");
  });

  it("drops free-text names and phone-shaped query values", () => {
    const props = attributionFromSearch(
      "?utm_term=Alice+Smith+14155551212&utm_campaign=spring-sale&utm_content=14155551212&utm_medium=1415-555-1212&utm_source=Alice-14155551212"
    );
    expect(props.utm_term).toBeUndefined();
    expect(props.utm_content).toBeUndefined();
    expect(props.utm_medium).toBeUndefined();
    expect(props.utm_source).toBeUndefined();
    expect(props.utm_campaign).toBe("spring-sale");
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

  it("download CTAs emit target_platform, never overriding platform", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const download = readFileSync(join(here, "../src/pages/download.astro"), "utf8");
    const header = readFileSync(join(here, "../src/components/Header.astro"), "utf8");
    expect(download).not.toContain("data-analytics-prop-platform=");
    expect(header).not.toContain("data-analytics-prop-platform=");
    expect(download).toContain("data-analytics-prop-target-platform=");
    expect(header).toContain("data-analytics-prop-target-platform=");
  });
});
