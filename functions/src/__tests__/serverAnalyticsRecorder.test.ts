/**
 * The backend analytics consent contract — the server mirror of the macOS and
 * website recorder tests. Asserts THE invariant: a conversion is dropped unless
 * the propagated consent is `granted` AND a non-empty key is configured, the
 * transport is never even started before opt-in (PROVABLE darkness), name +
 * category + props are correct after grant, the stream is silent for
 * declined/unset/revoked, and `insert_id` gives idempotent dedup.
 *
 * The transport seam is a fake — no network is touched. A spy fetch additionally
 * proves the real HTTP transport makes ZERO requests until started.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it, beforeEach, vi } from "vitest";

import { ConsentSignal } from "../analytics/consent.js";
import { EVENT } from "../analytics/events.js";
import { ServerAnalytics, type AnalyticsEnvelope, type ServerAnalyticsTransport } from "../analytics/recorder.js";
import { AmplitudeHttpTransport } from "../analytics/amplitudeTransport.js";

vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logError: vi.fn(), logInfo: vi.fn(), logWarn: vi.fn() };
});

/** Records start/stop/track without any network — the injected transport seam. */
class FakeTransport implements ServerAnalyticsTransport {
  startCalls = 0;
  stopCalls = 0;
  sent: AnalyticsEnvelope[] = [];
  private _started = false;

  get isStarted(): boolean {
    return this._started;
  }
  start(apiKey: string): void {
    if (this._started || apiKey.length === 0) return;
    this.startCalls += 1;
    this._started = true;
  }
  async track(event: AnalyticsEnvelope): Promise<void> {
    if (!this._started) return;
    this.sent.push(event);
  }
  stop(): void {
    this.stopCalls += 1;
    this._started = false;
  }
}

const KEY = "amp-test-key";
const DEVICE = "device-abc-123";

function build(transport: FakeTransport, key = KEY, overrides: { now?: () => number; insertId?: () => string } = {}) {
  return new ServerAnalytics({
    transport,
    apiKey: key,
    superProperties: () => ({ platform: "backend", app_version: "test-build" }),
    now: overrides.now ?? (() => 1_700_000_000_000),
    insertId: overrides.insertId ?? (() => "rand-insert"),
  });
}

const granted = () => new ConsentSignal("granted");
const declined = () => new ConsentSignal("declined");
const unset = () => new ConsentSignal(undefined);

describe("ServerAnalytics — pre-consent darkness (PROVABLE)", () => {
  let transport: FakeTransport;
  let analytics: ServerAnalytics;
  beforeEach(() => {
    transport = new FakeTransport();
    analytics = build(transport);
  });

  it("default unset → transport NEVER started, nothing sent", async () => {
    const ok = await analytics.track(EVENT.subscriptionEntitlementGranted, unset(), { deviceId: DEVICE });
    expect(ok).toBe(false);
    expect(transport.startCalls).toBe(0); // <- the SDK seam is never constructed/started
    expect(transport.isStarted).toBe(false);
    expect(transport.sent).toHaveLength(0);
  });

  it("declined is identical to unset → dark, transport never started", async () => {
    const ok = await analytics.track(EVENT.subscriptionEntitlementGranted, declined(), { deviceId: DEVICE });
    expect(ok).toBe(false);
    expect(transport.startCalls).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });

  it("granted but NO key → dark (key gate), transport never started", async () => {
    const noKey = build(transport, "");
    const ok = await noKey.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE });
    expect(ok).toBe(false);
    expect(transport.startCalls).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });

  it("granted + key but NO device id → dark (anonymous id mandatory)", async () => {
    const ok = await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: "" });
    expect(ok).toBe(false);
    expect(transport.startCalls).toBe(0);
    expect(transport.sent).toHaveLength(0);
  });
});

describe("ServerAnalytics — after grant", () => {
  let transport: FakeTransport;
  let analytics: ServerAnalytics;
  beforeEach(() => {
    transport = new FakeTransport();
    analytics = build(transport);
  });

  it("lazily starts the transport on the FIRST permitted track, exactly once", async () => {
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE });
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE, dedupeKey: "k2" });
    expect(transport.startCalls).toBe(1); // started once, not per-call
    expect(transport.sent).toHaveLength(2);
  });

  it("sends the correct wire name, category, super-properties, and event props", async () => {
    const ok = await analytics.track(
      EVENT.subscriptionEntitlementGranted,
      granted(),
      { deviceId: DEVICE },
      {
        entitlement_family: "burnbar_pro",
        outcome: "success",
      },
    );
    expect(ok).toBe(true);
    const e = transport.sent[0];
    expect(e.name).toBe("subscription.entitlement.granted");
    expect(e.category).toBe("conversion_auth");
    expect(e.props).toMatchObject({
      platform: "backend",
      app_version: "test-build",
      entitlement_family: "burnbar_pro",
      outcome: "success",
    });
    expect(e.deviceId).toBe(DEVICE);
  });

  it("sets user_id only when provided (authenticated action)", async () => {
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE, userId: "uid-1" });
    await analytics.track(EVENT.errorHandled, granted(), { deviceId: DEVICE, dedupeKey: "k2" });
    expect(transport.sent[0].userId).toBe("uid-1");
    expect(transport.sent[1].userId).toBeUndefined();
  });

  it("uses the caller dedupeKey as insert_id (7-day dedup); mints a random one otherwise", async () => {
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE, dedupeKey: "evt-77" });
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE });
    expect(transport.sent[0].insertId).toBe("evt-77");
    expect(transport.sent[1].insertId).toBe("rand-insert");
  });

  it("carries the caller-supplied event time, else falls back to now()", async () => {
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), {
      deviceId: DEVICE,
      timeMs: 123,
      dedupeKey: "a",
    });
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE, dedupeKey: "b" });
    expect(transport.sent[0].timeMs).toBe(123);
    expect(transport.sent[1].timeMs).toBe(1_700_000_000_000);
  });

  it("stays silent again the moment consent flips back to declined (revoke = declined)", async () => {
    await analytics.track(EVENT.subscriptionEntitlementGranted, granted(), { deviceId: DEVICE, dedupeKey: "a" });
    expect(transport.sent).toHaveLength(1);
    const ok = await analytics.track(EVENT.subscriptionEntitlementGranted, declined(), { deviceId: DEVICE });
    expect(ok).toBe(false);
    expect(transport.sent).toHaveLength(1); // no new send after revoke
  });
});

describe("AmplitudeHttpTransport — real transport is dark until started, never throws", () => {
  it("track() before start() makes ZERO fetch calls", async () => {
    const fetchSpy = vi.fn();
    const t = new AmplitudeHttpTransport("US", fetchSpy as never);
    await t.track({
      name: "subscription.entitlement.granted",
      category: "conversion_auth",
      props: { platform: "backend" },
      deviceId: DEVICE,
      insertId: "x",
      timeMs: 1,
    });
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(t.isStarted).toBe(false);
  });

  it("after start() it POSTs the V2 batch with api_key, insert_id, device_id, event_category, and NO ip/geo", async () => {
    const fetchSpy = vi.fn().mockResolvedValue({ ok: true, status: 200 } as Response);
    const t = new AmplitudeHttpTransport("US", fetchSpy as never);
    t.start(KEY);
    await t.track({
      name: "subscription.entitlement.granted",
      category: "conversion_auth",
      props: { platform: "backend", entitlement_family: "burnbar_pro" },
      deviceId: DEVICE,
      userId: "uid-1",
      insertId: "evt-77",
      timeMs: 1_700_000_000_000,
    });
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0];
    expect(url).toBe("https://api2.amplitude.com/2/httpapi");
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body.api_key).toBe(KEY);
    expect(body.events).toHaveLength(1);
    const ev = body.events[0];
    expect(ev.event_type).toBe("subscription.entitlement.granted");
    expect(ev.device_id).toBe(DEVICE);
    expect(ev.user_id).toBe("uid-1");
    expect(ev.insert_id).toBe("evt-77");
    expect(ev.event_properties.event_category).toBe("conversion_auth");
    // anti-fingerprinting: no geo/ip fields are ever populated.
    expect(ev.ip).toBeUndefined();
    expect(ev.location_lat).toBeUndefined();
    expect(ev.location_lng).toBeUndefined();
    expect(ev.city).toBeUndefined();
    expect(ev.dma).toBeUndefined();
  });

  it("a non-2xx response is swallowed (analytics never fails the conversion path)", async () => {
    const fetchSpy = vi.fn().mockResolvedValue({ ok: false, status: 500 } as Response);
    const t = new AmplitudeHttpTransport("EU", fetchSpy as never);
    t.start(KEY);
    await expect(
      t.track({ name: "error.handled", category: "error", props: {}, deviceId: DEVICE, insertId: "x", timeMs: 1 }),
    ).resolves.toBeUndefined();
    expect(fetchSpy.mock.calls[0][0]).toBe("https://api.eu.amplitude.com/2/httpapi");
  });

  it("a thrown fetch is swallowed too", async () => {
    const fetchSpy = vi.fn().mockRejectedValue(new Error("network down"));
    const t = new AmplitudeHttpTransport("US", fetchSpy as never);
    t.start(KEY);
    await expect(
      t.track({ name: "error.handled", category: "error", props: {}, deviceId: DEVICE, insertId: "x", timeMs: 1 }),
    ).resolves.toBeUndefined();
  });
});

describe("event taxonomy hygiene", () => {
  it("every registered backend event matches the canonical name scheme", async () => {
    const names = Object.values(EVENT);
    for (const n of names) expect(n).toMatch(/^[a-z0-9]+(\.[a-z0-9_]+)+$/);
  });
});

/**
 * Governance guard (the CI gate the verifier asked for): every backend EVENT
 * wire-name MUST be REGISTERED in the canonical taxonomy doc. The doc is the
 * single source of truth — an off-taxonomy backend name (renamed/typo/drift)
 * fails this test before it can ship. Registered-but-unwired names (e.g.
 * `auth.account.deleted`, `error.handled`) still appear in the doc, so they
 * pass: registration is what's checked, not call-site coverage.
 */
describe("backend event registry ↔ canonical taxonomy doc", () => {
  // src/__tests__/ → worktree-root docs/analytics/event-taxonomy.md (vitest runs
  // the TS source in place, so __dirname is functions/src/__tests__; `../../..`
  // is the repo root, the same anchor the other doc-reading tests here use).
  const TAXONOMY_PATH = resolve(__dirname, "../../../docs/analytics/event-taxonomy.md");

  /** Wire names registered in the doc: inline-code `surface.object.action`
   *  tokens — backtick-wrapped, lowercase dotted, ≥1 dot. Property tokens
   *  (`is_first_launch:bool`) carry no dot and are excluded; any extra non-event
   *  dotted token only makes the set a superset, never a false failure. */
  function registeredTaxonomyNames(): Set<string> {
    const doc = readFileSync(TAXONOMY_PATH, "utf8");
    const set = new Set<string>();
    for (const m of doc.matchAll(/`([a-z0-9]+(?:\.[a-z0-9_]+)+)`/g)) set.add(m[1]);
    return set;
  }

  it("the doc parses to a non-empty registry (regex is actually matching)", () => {
    const registered = registeredTaxonomyNames();
    expect(registered.size).toBeGreaterThan(0);
    // Anchor on names we KNOW are in the doc, so a broken regex can't vacuously pass.
    expect(registered.has("subscription.entitlement.granted")).toBe(true);
    expect(registered.has("auth.account.deleted")).toBe(true);
  });

  it("EVERY backend EVENT wire-name is registered in the taxonomy doc", () => {
    const registered = registeredTaxonomyNames();
    const offTaxonomy = Object.values(EVENT).filter((name) => !registered.has(name));
    // Empty array ⇒ no backend event drifts from the doc. The message names the
    // culprits so a future drift fails loudly with the exact missing wire name.
    expect(offTaxonomy).toEqual([]);
  });

  it("an off-taxonomy name FAILS the membership check (guard has teeth)", () => {
    const registered = registeredTaxonomyNames();
    // A deliberately unregistered name must be rejected — proves the assertion
    // above isn't a no-op that would green-light an invented event.
    expect(registered.has("backend.totally.invented_event")).toBe(false);
  });
});
