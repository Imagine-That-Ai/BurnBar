import { describe, it, expect } from "vitest";
import { FirstPartyCollectorTransport } from "../src/lib/analytics/collectorTransport";
import { Analytics } from "../src/lib/analytics/recorder";
import { ConsentStore, type ConsentStorage } from "../src/lib/analytics/consent";
import { EVENT } from "../src/lib/analytics/events";
import {
  ATTRIBUTION_STORAGE_KEY,
  attributionFromSearch,
  clearStoredAttribution,
  resolveAttribution,
  type AttributionStorage
} from "../src/lib/analytics/attribution";
import { rememberAttribution } from "../src/lib/analytics/index";
import {
  handleCollectorPost,
  AMPLITUDE_HTTP_V2_US,
  isAllowedCollectorOrigin,
  createMemoryRateLimiter,
  rejectOversizedCollectorBody,
  declaredCollectorBodyTooLarge,
  readBoundedCollectorBody,
  MAX_COLLECTOR_BODY_BYTES,
  MAX_EVENT_TIME_SKEW_MS,
  sanitizeCollectorEventTime
} from "../../workers/analytics-collector/src/handler";
import collectorWorker from "../../workers/analytics-collector/src/index";
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
        events: [
          {
            name: "arena.vote.recorded",
            props: { variant: "neural", choice: "a", rubric: "none", surface: "other" }
          }
        ]
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

  it("binds staging origins to Dev and production origins to prod", () => {
    expect(isAllowedCollectorOrigin("https://burnbar-staging.web.app", 830583)).toBe(false);
    expect(isAllowedCollectorOrigin("https://burnbar-staging.firebaseapp.com", 830583)).toBe(false);
    expect(isAllowedCollectorOrigin("http://127.0.0.1:4321", 830583)).toBe(false);
    expect(isAllowedCollectorOrigin("https://burnbar.ai", 830581)).toBe(false);
    expect(isAllowedCollectorOrigin("https://burnbar.web.app", 830581)).toBe(false);
    expect(isAllowedCollectorOrigin("https://burnbar.ai", 830583)).toBe(true);
    expect(isAllowedCollectorOrigin("https://burnbar-staging.web.app", 830581)).toBe(true);
    expect(isAllowedCollectorOrigin("http://127.0.0.1:4321", 830581)).toBe(true);
  });

  it("rejects a staging origin against the production project", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed" }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830583" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
      "https://burnbar-staging.web.app"
    );
    expect(result.status).toBe(403);
    expect(result.body.reason).toBe("origin_rejected");
    expect(fetches).toHaveLength(0);
  });

  it("rejects a production origin against the Dev project", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed" }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
      "https://burnbar.ai"
    );
    expect(result.status).toBe(403);
    expect(result.body.reason).toBe("origin_rejected");
    expect(fetches).toHaveLength(0);
  });

  it("forwards from a staging origin", async () => {
    const fetches: string[] = [];
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed", props: { surface: "home" } }] },
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
      {
        consent: true,
        events: [
          { name: "page.viewed", device_id: 12 as unknown as string, props: { surface: "home" } }
        ]
      },
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

  it("drops phone-shaped attribution and free-text props before forwarding", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "page.viewed",
            props: {
              product: "burnbar",
              surface: "home",
              utm_campaign: "Alice-14155551212",
              utm_source: "spring-sale",
              note: "hello world",
              target_platform: "macos"
            }
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
    expect(events[0]?.event_properties.utm_campaign).toBeUndefined();
    expect(events[0]?.event_properties.note).toBeUndefined();
    expect(events[0]?.event_properties.utm_source).toBe("spring-sale");
    expect(events[0]?.event_properties.surface).toBe("home");
    expect(events[0]?.event_properties.target_platform).toBeUndefined();
    expect(events[0]?.event_properties.product).toBe("burnbar");
  });

  it("strips raw email fields before forwarding", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "email.captured",
            props: { email: "a@b.com", captured: true, product: "burnbar", surface: "other" }
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

  it("sanitizes event.category before forwarding event_category", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "page.viewed",
            category: "alice@example.com",
            props: { product: "burnbar", surface: "home" }
          },
          {
            name: "app.opened",
            category: "lifecycle",
            props: { product: "burnbar", surface: "home" }
          }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push({ body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response("{}", { status: 200 });
      }
    );
    const events = fetches[0]?.body.events as {
      event_type: string;
      event_properties: Record<string, unknown>;
    }[];
    const emailed = events.find((event) => event.event_type === "page.viewed");
    const lifecycle = events.find((event) => event.event_type === "app.opened");
    expect(emailed?.event_properties.event_category).toBe("screen_view");
    expect(lifecycle?.event_properties.event_category).toBe("lifecycle");
    expect(lifecycle?.event_properties.amplitude_project_id).toBe("830581");
  });

  it("drops unknown property keys instead of treating a missing enum as unrestricted", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "page.viewed",
            props: {
              product: "burnbar",
              surface: "home",
              prompt: "secret",
              api_key: "sk-secret"
            }
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
    expect(events[0]?.event_properties.prompt).toBeUndefined();
    expect(events[0]?.event_properties.api_key).toBeUndefined();
    expect(events[0]?.event_properties.surface).toBe("home");
    expect(events[0]?.event_properties.product).toBe("burnbar");
  });

  it("replaces email, phone, and oversize identifiers with anonymous fallbacks", async () => {
    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "page.viewed",
            device_id: "alice@example.com",
            insert_id: "14155551212",
            props: { product: "burnbar", surface: "home" }
          },
          {
            name: "page.viewed",
            device_id: "alice@example.com",
            insert_id: "14155551212",
            props: { product: "burnbar", surface: "home" }
          },
          {
            name: "page.viewed",
            device_id: "550e8400-e29b-41d4-a716-446655440000",
            insert_id: "obb-ok-1",
            props: { product: "burnbar", surface: "home" }
          }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push({ body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response("{}", { status: 200 });
      }
    );
    const events = fetches[0]?.body.events as { device_id: string; insert_id: string }[];
    expect(events[0]?.device_id).toMatch(/^anon-/);
    expect(events[0]?.device_id).not.toBe("anonymous");
    expect(events[0]?.device_id).not.toBe("alice@example.com");
    expect(events[1]?.device_id).toMatch(/^anon-/);
    expect(events[1]?.device_id).not.toBe(events[0]?.device_id);
    expect(events[0]?.insert_id).toMatch(/^obb-/);
    expect(events[0]?.insert_id).not.toBe("14155551212");
    expect(events[2]?.device_id).toBe("550e8400-e29b-41d4-a716-446655440000");
    expect(events[2]?.insert_id).toBe("obb-ok-1");
  });

  it("returns a structured 502 when Amplitude fetch rejects", async () => {
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed", props: { surface: "home" } }] },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async () => {
        throw new Error("dns failed");
      }
    );
    expect(result.status).toBe(502);
    expect(result.body.reason).toBe("amplitude_http_error");
    expect(result.forwarded).toBe(0);
    expect(result.amplitudeUrl).toBe(AMPLITUDE_HTTP_V2_US);
  });

  it("returns 429 when the rate limiter rejects the client key", async () => {
    const fetches: string[] = [];
    const limiter = { limit: async () => ({ success: false }) };
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed" }] },
      {
        AMPLITUDE_API_KEY: "secret-key",
        AMPLITUDE_PROJECT_ID: "830581",
        COLLECTOR_RATE_LIMIT: limiter
      },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      },
      "https://burnbar.ai",
      "203.0.113.9"
    );
    expect(result.status).toBe(429);
    expect(result.body.reason).toBe("rate_limited");
    expect(result.forwarded).toBe(0);
    expect(fetches).toHaveLength(0);
  });

  it("forwards when the rate limiter allows the client key", async () => {
    const limiter = createMemoryRateLimiter(2, 60_000);
    const result = await handleCollectorPost(
      { consent: true, events: [{ name: "page.viewed", props: { surface: "home" } }] },
      {
        AMPLITUDE_API_KEY: "secret-key",
        AMPLITUDE_PROJECT_ID: "830581",
        COLLECTOR_RATE_LIMIT: limiter
      },
      async () => new Response("{}", { status: 200 }),
      "https://burnbar-staging.web.app",
      "203.0.113.9"
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
  });

  it("rejects an oversized collector body before JSON parse", () => {
    const oversized = "x".repeat(MAX_COLLECTOR_BODY_BYTES + 1);
    const result = rejectOversizedCollectorBody(oversized);
    expect(result?.status).toBe(413);
    expect(result?.body.reason).toBe("body_too_large");
    expect(rejectOversizedCollectorBody('{"consent":true}')).toBeNull();
  });

  it("drops email.captured unless captured is true", async () => {
    const fetches: string[] = [];
    const dropped = await handleCollectorPost(
      {
        consent: true,
        events: [
          { name: "email.captured", props: { captured: false, product: "burnbar", surface: "other" } }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      }
    );
    expect(dropped.status).toBe(204);
    expect(dropped.body.reason).toBe("no_allowed_events");
    expect(fetches).toHaveLength(0);

    const kept = await handleCollectorPost(
      {
        consent: true,
        events: [
          { name: "email.captured", props: { captured: true, product: "burnbar", surface: "other" } }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      }
    );
    expect(kept.status).toBe(200);
    expect(kept.forwarded).toBe(1);
    expect(fetches).toHaveLength(1);
  });

  it("rejects native funnel events and requires a website surface on website funnel events", async () => {
    const fetches: { events?: { event_type: string }[] }[] = [];
    const dropped = await handleCollectorPost(
      {
        consent: true,
        events: [
          { name: "install.started", props: { surface: "macos", product: "burnbar" } },
          { name: "nav.route.changed", props: { surface: "home" } },
          { name: "app.opened", props: { surface: "ios", product: "burnbar" } },
          { name: "page.viewed", props: { product: "burnbar" } },
          { name: "download.clicked", props: { product: "burnbar" } }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push({ events: [] });
        return new Response("{}", { status: 200 });
      }
    );
    expect(dropped.status).toBe(204);
    expect(dropped.body.reason).toBe("no_allowed_events");
    expect(fetches).toHaveLength(0);

    const kept = await handleCollectorPost(
      {
        consent: true,
        events: [
          { name: "app.opened", props: { surface: "home", product: "burnbar" } },
          { name: "page.viewed", props: { surface: "pricing", product: "burnbar" } },
          { name: "download.clicked", props: { surface: "download", product: "burnbar" } }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push(JSON.parse(String(init?.body ?? "{}")));
        return new Response("{}", { status: 200 });
      }
    );
    expect(kept.status).toBe(200);
    expect(kept.forwarded).toBe(3);
    const types = (fetches[0]?.events ?? []).map((event) => event.event_type);
    expect(types).toEqual(["app.opened", "page.viewed", "download.clicked"]);
  });

  it("drops allowlisted product events that miss required properties", async () => {
    const fetches: string[] = [];
    const dropped = await handleCollectorPost(
      {
        consent: true,
        events: [
          { name: "arena.vote.recorded", props: { variant: "neural" } },
          { name: "auth.sign_in.completed", props: { product: "burnbar" } },
          { name: "download.cta.clicked", props: { surface: "home" } },
          { name: "pricing.cta.clicked", props: { surface: "pricing" } },
          { name: "nav.external.clicked", props: { surface: "home" } },
          { name: "consent.analytics.granted", props: { surface: "home" } },
          { name: "error.handled", props: { surface: "home" } },
          { name: "app.session.started", props: { surface: "home" } },
          { name: "screen.viewed", props: { surface: "home" } },
          { name: "pricing.cta.clicked", props: { plan: "cloud" } },
          { name: "email.captured", props: { captured: true } }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (url) => {
        fetches.push(url);
        return new Response("{}", { status: 200 });
      }
    );
    expect(dropped.status).toBe(204);
    expect(dropped.body.reason).toBe("no_allowed_events");
    expect(fetches).toHaveLength(0);
  });

  it("forwards arena votes and auth completions only with required properties", async () => {
    const fetches: { events?: { event_type: string; event_properties: Record<string, string> }[] }[] =
      [];
    const result = await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "arena.vote.recorded",
            props: { variant: "neural", choice: "a", rubric: "none", surface: "other" }
          },
          {
            name: "auth.sign_in.completed",
            props: { method: "google", outcome: "success", surface: "other" }
          },
          { name: "pricing.plan.viewed", props: { surface: "pricing" } },
          { name: "download.cta.clicked", props: { placement: "header", surface: "home" } },
          { name: "pricing.cta.clicked", props: { plan: "cloud", surface: "pricing" } },
          { name: "nav.external.clicked", props: { destination: "github", surface: "home" } },
          {
            name: "consent.analytics.granted",
            props: { consent_version: "1", surface: "home" }
          },
          {
            name: "error.handled",
            props: { error_category: "auth", surface: "home" }
          }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push(JSON.parse(String(init?.body ?? "{}")));
        return new Response("{}", { status: 200 });
      }
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(8);
    const events = fetches[0]?.events ?? [];
    expect(events.map((event) => event.event_type)).toEqual([
      "arena.vote.recorded",
      "auth.sign_in.completed",
      "pricing.plan.viewed",
      "download.cta.clicked",
      "pricing.cta.clicked",
      "nav.external.clicked",
      "consent.analytics.granted",
      "error.handled"
    ]);
    expect(events[0]?.event_properties).toMatchObject({
      variant: "neural",
      choice: "a",
      rubric: "none"
    });
    expect(events[1]?.event_properties).toMatchObject({ method: "google", outcome: "success" });
    expect(events[3]?.event_properties).toMatchObject({ placement: "header" });
    expect(events[4]?.event_properties).toMatchObject({ plan: "cloud" });
    expect(events[5]?.event_properties).toMatchObject({ destination: "github" });
    expect(events[6]?.event_properties).toMatchObject({
      consent_version: "1",
      platform: "web"
    });
    expect(events[7]?.event_properties).toMatchObject({
      error_category: "auth",
      surface: "home"
    });
    expect(events[0]?.event_properties.event_category).toBe("primary_action");
    expect(events[6]?.event_properties.platform).toBe("web");
  });

  it("requires is_first_launch and cold_start on app.session.started", async () => {
    const fetches: { events?: { event_type: string; event_properties: Record<string, unknown> }[] }[] =
      [];
    const kept = await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "app.session.started",
            props: { surface: "home", is_first_launch: true, cold_start: true }
          }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push(JSON.parse(String(init?.body ?? "{}")));
        return new Response("{}", { status: 200 });
      }
    );
    expect(kept.status).toBe(200);
    expect(kept.forwarded).toBe(1);
    expect(fetches[0]?.events?.[0]?.event_properties).toMatchObject({
      surface: "home",
      is_first_launch: true,
      cold_start: true,
      platform: "web"
    });
  });

  it("requires is_first_view on screen.viewed", async () => {
    const fetches: { events?: { event_type: string; event_properties: Record<string, unknown> }[] }[] =
      [];
    const kept = await handleCollectorPost(
      {
        consent: true,
        events: [{ name: "screen.viewed", props: { surface: "home", is_first_view: true } }]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push(JSON.parse(String(init?.body ?? "{}")));
        return new Response("{}", { status: 200 });
      }
    );
    expect(kept.status).toBe(200);
    expect(kept.forwarded).toBe(1);
    expect(fetches[0]?.events?.[0]?.event_properties).toMatchObject({
      surface: "home",
      is_first_view: true,
      platform: "web"
    });
  });

  it("strips properties and categories outside each event's schema", async () => {
    const fetches: { events?: { event_type: string; event_properties: Record<string, unknown> }[] }[] =
      [];
    const result = await handleCollectorPost(
      {
        consent: true,
        events: [
          {
            name: "arena.vote.recorded",
            category: "error",
            props: {
              variant: "neural",
              choice: "a",
              rubric: "none",
              plan: "ultra",
              surface: "other"
            }
          }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push(JSON.parse(String(init?.body ?? "{}")));
        return new Response("{}", { status: 200 });
      }
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
    const props = fetches[0]?.events?.[0]?.event_properties ?? {};
    expect(props.variant).toBe("neural");
    expect(props.choice).toBe("a");
    expect(props.rubric).toBe("none");
    expect(props.plan).toBeUndefined();
    expect(props.event_category).toBe("primary_action");
  });

  it("still allows page.viewed with the website page-surface enum", async () => {
    const result = await handleCollectorPost(
      {
        consent: true,
        events: [{ name: "page.viewed", props: { surface: "web", product: "burnbar" } }]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async () => new Response("{}", { status: 200 })
    );
    expect(result.status).toBe(200);
    expect(result.forwarded).toBe(1);
  });

  it("stamps the Worker receipt time for unusable client timestamps", async () => {
    const now = Date.now();
    expect(sanitizeCollectorEventTime(Number.POSITIVE_INFINITY, now)).toBe(now);
    expect(sanitizeCollectorEventTime(Number.NaN, now)).toBe(now);
    expect(sanitizeCollectorEventTime(-1, now)).toBe(now);
    expect(sanitizeCollectorEventTime(now + MAX_EVENT_TIME_SKEW_MS + 1, now)).toBe(now);
    expect(sanitizeCollectorEventTime(now - 1_000, now)).toBe(now - 1_000);

    const fetches: { body: Record<string, unknown> }[] = [];
    await handleCollectorPost(
      {
        consent: true,
        events: [
          { name: "page.viewed", time_ms: Number.POSITIVE_INFINITY, props: { surface: "home" } }
        ]
      },
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830581" },
      async (_url, init) => {
        fetches.push({ body: JSON.parse(String(init?.body ?? "{}")) });
        return new Response("{}", { status: 200 });
      }
    );
    const events = fetches[0]?.body.events as { time: number }[];
    expect(Number.isFinite(events[0]?.time)).toBe(true);
    expect(JSON.stringify(fetches[0]?.body)).not.toContain("null");
  });

  it("rejects a declared Content-Length over the collector cap", () => {
    expect(declaredCollectorBodyTooLarge(String(MAX_COLLECTOR_BODY_BYTES + 1))).toBe(true);
    expect(declaredCollectorBodyTooLarge(String(MAX_COLLECTOR_BODY_BYTES))).toBe(false);
    expect(declaredCollectorBodyTooLarge(null)).toBe(false);
  });

  it("cancels a streaming body once it exceeds the collector cap", async () => {
    const oversized = new Request("https://collect.burnbar.ai/v1", {
      method: "POST",
      body: "x".repeat(MAX_COLLECTOR_BODY_BYTES + 1)
    });
    expect(await readBoundedCollectorBody(oversized)).toBeNull();
    const ok = new Request("https://collect.burnbar.ai/v1", {
      method: "POST",
      body: JSON.stringify({ consent: true, events: [] })
    });
    expect(await readBoundedCollectorBody(ok)).toContain("consent");
  });
});

describe("collector worker fetch — rate limit and body order", () => {
  it("rate-limits before buffering the body", async () => {
    let limited = false;
    const here = dirname(fileURLToPath(import.meta.url));
    const worker = readFileSync(
      join(here, "../../workers/analytics-collector/src/index.ts"),
      "utf8"
    );
    const originGate = worker.indexOf("if (!isAllowedCollectorOrigin(origin, projectId))");
    const rateLimit = worker.indexOf("const verdict = await applyCollectorRateLimit");
    const contentLength = worker.indexOf(
      'if (declaredCollectorBodyTooLarge(request.headers.get("content-length")))'
    );
    const bodyRead = worker.indexOf("const raw = await readBoundedCollectorBody(request)");
    expect(originGate).toBeGreaterThan(-1);
    expect(rateLimit).toBeGreaterThan(-1);
    expect(contentLength).toBeGreaterThan(-1);
    expect(bodyRead).toBeGreaterThan(-1);
    expect(originGate).toBeLessThan(rateLimit);
    expect(rateLimit).toBeLessThan(contentLength);
    expect(contentLength).toBeLessThan(bodyRead);
    const response = await collectorWorker.fetch(
      new Request("https://collect.burnbar.ai/v1", {
        method: "POST",
        headers: { "cf-connecting-ip": "203.0.113.9", origin: "https://burnbar.ai" },
        body: '{"consent":true}'
      }),
      {
        AMPLITUDE_API_KEY: "secret-key",
        AMPLITUDE_PROJECT_ID: "830583",
        COLLECTOR_RATE_LIMIT: {
          async limit() {
            limited = true;
            return { success: false };
          }
        }
      }
    );
    expect(limited).toBe(true);
    expect(response.status).toBe(429);
  });

  it("rejects a foreign origin before charging the rate limiter", async () => {
    let limited = false;
    const response = await collectorWorker.fetch(
      new Request("https://collect.burnbar.ai/v1", {
        method: "POST",
        headers: {
          "cf-connecting-ip": "203.0.113.9",
          origin: "https://evil.example",
          "content-type": "text/plain"
        },
        body: '{"consent":true}'
      }),
      {
        AMPLITUDE_API_KEY: "secret-key",
        AMPLITUDE_PROJECT_ID: "830583",
        COLLECTOR_RATE_LIMIT: {
          async limit() {
            limited = true;
            return { success: false };
          }
        }
      }
    );
    expect(limited).toBe(false);
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ reason: "origin_rejected" });
  });

  it("reuses one isolate-local limiter when the binding is absent", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const worker = readFileSync(
      join(here, "../../workers/analytics-collector/src/index.ts"),
      "utf8"
    );
    expect(
      worker.indexOf("const fallbackCollectorRateLimit = createMemoryRateLimiter()")
    ).toBeGreaterThan(-1);
    expect(worker.indexOf("const fallbackCollectorRateLimit")).toBeLessThan(
      worker.indexOf("export default")
    );
    expect(worker).toContain("env.COLLECTOR_RATE_LIMIT ?? fallbackCollectorRateLimit");
    expect(worker).not.toMatch(/fetch\([\s\S]*createMemoryRateLimiter\(\)/);
  });

  it("rejects a trustworthy oversized Content-Length without reading the body", async () => {
    const response = await collectorWorker.fetch(
      new Request("https://collect.burnbar.ai/v1", {
        method: "POST",
        headers: {
          "content-length": String(MAX_COLLECTOR_BODY_BYTES + 1),
          origin: "https://burnbar.ai"
        },
        body: "x".repeat(MAX_COLLECTOR_BODY_BYTES + 1)
      }),
      { AMPLITUDE_API_KEY: "secret-key", AMPLITUDE_PROJECT_ID: "830583" }
    );
    expect(response.status).toBe(413);
    const payload = (await response.json()) as { reason?: string };
    expect(payload.reason).toBe("body_too_large");
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

  it("retains bounded attribution across empty internal navigation", () => {
    const storage = attributionMemory();
    const landed = resolveAttribution("?utm_campaign=spring-sale&click_id=abc", storage);
    expect(landed.utm_campaign).toBe("spring-sale");
    expect(landed.click_id).toBe("abc");
    const nextPage = resolveAttribution("", storage);
    expect(nextPage.utm_campaign).toBe("spring-sale");
    expect(nextPage.click_id).toBe("abc");
    expect(storage.getItem(ATTRIBUTION_STORAGE_KEY)).toContain("spring-sale");
  });

  it("does not persist rejected personal-data values for later pages", () => {
    const storage = attributionMemory();
    const landed = resolveAttribution("?utm_campaign=a@b.com", storage);
    expect(landed.utm_campaign).toBeUndefined();
    expect(resolveAttribution("", storage).utm_campaign).toBeUndefined();
  });

  it("clears a stored campaign when the next URL has rejected attribution keys", () => {
    const storage = attributionMemory();
    resolveAttribution("?utm_campaign=spring-sale", storage);
    const rejected = resolveAttribution("?utm_campaign=a@b.com", storage);
    expect(rejected).toEqual({});
    expect(resolveAttribution("", storage)).toEqual({});
  });

  it("replaces the stored bag when a later landing carries a new campaign", () => {
    const storage = attributionMemory();
    resolveAttribution("?utm_campaign=spring-sale", storage);
    const next = resolveAttribution("?utm_campaign=summer-sale", storage);
    expect(next.utm_campaign).toBe("summer-sale");
    expect(resolveAttribution("", storage).utm_campaign).toBe("summer-sale");
  });

  it("clears the stored bag on revoke", () => {
    const storage = attributionMemory();
    resolveAttribution("?utm_campaign=spring-sale", storage);
    clearStoredAttribution(storage);
    expect(resolveAttribution("", storage)).toEqual({});
  });

  it("does not persist campaign params after consent is declined", () => {
    const storage = attributionMemory();
    const declined = { hasDecided: true, isGranted: false };
    expect(rememberAttribution("?utm_campaign=spring-sale", storage, declined)).toEqual({});
    expect(storage.getItem(ATTRIBUTION_STORAGE_KEY)).toBeNull();
    expect(rememberAttribution("", storage, declined)).toEqual({});
  });

  it("still persists campaign params before a consent decision", () => {
    const storage = attributionMemory();
    const unset = { hasDecided: false, isGranted: false };
    const landed = rememberAttribution("?utm_campaign=spring-sale", storage, unset);
    expect(landed.utm_campaign).toBe("spring-sale");
    expect(storage.getItem(ATTRIBUTION_STORAGE_KEY)).toContain("spring-sale");
    clearStoredAttribution(storage);
    const afterDecline = rememberAttribution("?utm_campaign=summer-sale", storage, {
      hasDecided: true,
      isGranted: false
    });
    expect(afterDecline).toEqual({});
    expect(storage.getItem(ATTRIBUTION_STORAGE_KEY)).toBeNull();
  });

  it("ConsentBanner captures attribution before the consent decision branch", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const banner = readFileSync(join(here, "../src/components/ConsentBanner.astro"), "utf8");
    const rememberIdx = banner.indexOf("rememberAttribution()");
    const decidedIdx = banner.indexOf("if (analyticsConsent.hasDecided)");
    expect(rememberIdx).toBeGreaterThan(-1);
    expect(decidedIdx).toBeGreaterThan(-1);
    expect(rememberIdx).toBeLessThan(decidedIdx);
  });
});

function attributionMemory(): AttributionStorage {
  const m = new Map<string, string>();
  return {
    getItem: (k) => m.get(k) ?? null,
    setItem: (k, v) => void m.set(k, v),
    removeItem: (k) => void m.delete(k)
  };
}

describe("website bundle never embeds an Amplitude API key", () => {
  it("index.ts reads a collector URL, not PUBLIC_AMPLITUDE_API_KEY", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const source = readFileSync(join(here, "../src/lib/analytics/index.ts"), "utf8");
    expect(source).toContain("PUBLIC_ANALYTICS_COLLECTOR_URL");
    expect(source).not.toContain("PUBLIC_AMPLITUDE_API_KEY");
    expect(source).toContain("FirstPartyCollectorTransport");
    expect(source).toContain("rememberAttribution");
    expect(source).toContain("isReviewedCollectorOrigin");
    expect(source).toContain("resolveCollectorLane");
    expect(source).toContain("PUBLIC_ANALYTICS_COLLECTOR_LANE");
    expect(source).toContain("claimSessionSpine");
    expect(source).toContain("sessionStartProps");
    expect(source).toContain("screenViewedProps");
    expect(source).toContain("flushPendingEmailCapture");
    expect(source).toContain("is_first_launch");
    expect(source).toContain("cold_start");
    expect(source).toContain("is_first_view");
    expect(source).toContain("analytics.canSend");
    expect(source).toMatch(
      /export function declineConsent\(\)[\s\S]*clearSessionSpine\(sessionSpineStorage\(\)\)/
    );
    expect(source).toMatch(
      /export function revokeConsent\(\)[\s\S]*clearSessionSpine\(sessionSpineStorage\(\)\)/
    );
    expect(source).not.toMatch(/AmplitudeTransport/);
  });

  it("wires email.captured on credential success, not restored auth sessions", () => {
    const here = dirname(fileURLToPath(import.meta.url));
    const subscribe = readFileSync(join(here, "../src/pages/subscribe.astro"), "utf8");
    const link = readFileSync(join(here, "../src/pages/link.astro"), "utf8");
    const connect = readFileSync(join(here, "../src/pages/hermes/connect.astro"), "utf8");
    const arena = readFileSync(join(here, "../src/scripts/bench-arena.ts"), "utf8");
    for (const source of [subscribe, link, connect, arena]) {
      expect(source).toContain("trackEmailCapturedIfNewAccount");
      expect(source).toContain("signInWithPopup");
    }
    expect(subscribe).toContain("getRedirectResult");
    expect(arena).toContain("getRedirectResult");
    const authListener = subscribe.slice(subscribe.lastIndexOf("onAuthStateChanged(auth"));
    expect(authListener).not.toContain("trackEmailCapturedIfNewAccount");
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
