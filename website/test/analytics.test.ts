import { describe, it, expect } from "vitest";
import { ConsentStore, type ConsentStorage } from "../src/lib/analytics/consent";
import { Analytics, type AnalyticsTransport } from "../src/lib/analytics/recorder";
import { EVENT } from "../src/lib/analytics/events";
import { eventsToEmit } from "../src/lib/analytics/funnelAlias";
import {
  authCaptureSourceFromProviderId,
  clearSessionSpine,
  hasRecordedEmailCapture,
  isFreshAuthAccount,
  markEmailCaptured,
  shouldEmitSessionSpine,
  trackEmailCapturedIfNewAccount
} from "../src/lib/analytics/index";
import { bucketCount, bucketDurationMs, bucketDurationSeconds } from "../src/lib/analytics/buckets";

/** In-memory Storage seam — vitest's node env has no localStorage. */
function makeStorage(): ConsentStorage {
  const m = new Map<string, string>();
  return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => void m.set(k, v) };
}

/** Records every transport call so tests can assert on the wire contract. */
class FakeTransport implements AnalyticsTransport {
  started = false;
  startCount = 0;
  stopCount = 0;
  sent: { name: string; category: string; props: Record<string, string | boolean> }[] = [];
  get isStarted() {
    return this.started;
  }
  start() {
    this.started = true;
    this.startCount++;
  }
  track(name: string, category: string, props: Record<string, string | boolean>) {
    this.sent.push({ name, category, props });
  }
  stop() {
    this.started = false;
    this.stopCount++;
  }
}

function make(granted: boolean, collectorUrl = "https://collect.example.test/v1") {
  const consent = new ConsentStore(makeStorage());
  if (granted) consent.grant();
  const transport = new FakeTransport();
  const analytics = new Analytics({
    consent,
    transport,
    collectorUrl,
    superProperties: () => ({ platform: "website", app_version: "1.0.0" })
  });
  return { analytics, transport, consent };
}

describe("ConsentStore", () => {
  it("defaults to unset — dark", () => {
    const c = new ConsentStore(makeStorage());
    expect(c.state).toBe("unset");
    expect(c.isGranted).toBe(false);
    expect(c.hasDecided).toBe(false);
  });

  it("treats unset and declined identically (both dark)", () => {
    const c = new ConsentStore(makeStorage());
    expect(c.isGranted).toBe(false);
    c.decline();
    expect(c.state).toBe("declined");
    expect(c.isGranted).toBe(false);
    expect(c.hasDecided).toBe(true);
  });

  it("grant/revoke persist across instances", () => {
    const s = makeStorage();
    const c = new ConsentStore(s);
    c.grant();
    expect(c.isGranted).toBe(true);
    expect(new ConsentStore(s).isGranted).toBe(true);
    c.revoke();
    expect(c.state).toBe("declined");
    expect(new ConsentStore(s).isGranted).toBe(false);
  });
});

describe("Analytics recorder — consent contract", () => {
  it("sends nothing and never starts before consent", () => {
    const { analytics, transport } = make(false);
    analytics.track(EVENT.downloadCtaClicked, { platform: "macos" });
    expect(transport.sent).toHaveLength(0);
    expect(transport.isStarted).toBe(false);
    expect(transport.startCount).toBe(0);
  });

  it("after grant, emits name + category + super-props", () => {
    const { analytics, transport } = make(true);
    analytics.track(EVENT.downloadCtaClicked, { platform: "macos", placement: "hero" });
    expect(transport.sent).toHaveLength(1);
    const e = transport.sent[0];
    expect(e.name).toBe("download.cta.clicked");
    expect(e.category).toBe("conversion_auth");
    expect(e.props.platform).toBe("macos");
    expect(e.props.placement).toBe("hero");
    expect(e.props.app_version).toBe("1.0.0");
  });

  it("consentDidChange→granted starts the transport and emits consent.granted exactly once", () => {
    const { analytics, transport, consent } = make(false);
    consent.grant();
    analytics.consentDidChange();
    expect(transport.isStarted).toBe(true);
    expect(transport.sent.filter((e) => e.name === "consent.analytics.granted")).toHaveLength(1);
    analytics.consentDidChange();
    expect(transport.sent.filter((e) => e.name === "consent.analytics.granted")).toHaveLength(1);
  });

  it("revoke stops the transport and silences further tracks", () => {
    const { analytics, transport, consent } = make(true);
    analytics.track(EVENT.screenViewed, { surface: "home" });
    expect(transport.sent).toHaveLength(1);
    consent.revoke();
    analytics.consentDidChange();
    expect(transport.isStarted).toBe(false);
    expect(transport.stopCount).toBe(1);
    const n = transport.sent.length;
    analytics.track(EVENT.screenViewed, { surface: "home" });
    expect(transport.sent).toHaveLength(n);
  });

  it("stays dark with no collector URL even when consent is granted", () => {
    const { analytics, transport } = make(true, "");
    analytics.track(EVENT.screenViewed, { surface: "home" });
    expect(transport.isStarted).toBe(false);
    expect(transport.sent).toHaveLength(0);
  });

  it("lazily starts the transport on the first track after grant", () => {
    const { analytics, transport } = make(true);
    expect(transport.isStarted).toBe(false);
    analytics.track(EVENT.appSessionStarted);
    expect(transport.isStarted).toBe(true);
  });

  it("startIfConsented resumes a consented session without re-emitting grant", () => {
    const { analytics, transport } = make(true);
    analytics.startIfConsented();
    expect(transport.isStarted).toBe(true);
    expect(transport.sent).toHaveLength(0);
  });

  it("startIfConsented stays dark when not consented", () => {
    const { analytics, transport } = make(false);
    analytics.startIfConsented();
    expect(transport.isStarted).toBe(false);
  });
});

describe("buckets match the macOS labels verbatim", () => {
  it("count boundaries", () => {
    expect(bucketCount(0)).toBe("0");
    expect(bucketCount(1)).toBe("1");
    expect(bucketCount(3)).toBe("2-5");
    expect(bucketCount(50)).toBe("21-100");
    expect(bucketCount(1000)).toBe(">500");
  });

  it("durationMs boundaries", () => {
    expect(bucketDurationMs(50)).toBe("<100ms");
    expect(bucketDurationMs(2000)).toBe("1-3s");
    expect(bucketDurationMs(99999)).toBe(">30s");
  });

  it("durationSeconds boundaries", () => {
    expect(bucketDurationSeconds(2)).toBe("<5s");
    expect(bucketDurationSeconds(90)).toBe("30s-2m");
    expect(bucketDurationSeconds(9999)).toBe(">60m");
  });
});

describe("CMO funnel aliases", () => {
  it("pairs product events with taxonomy-legal funnel names", () => {
    expect(eventsToEmit(EVENT.screenViewed)).toEqual([EVENT.screenViewed, EVENT.pageViewed]);
    expect(eventsToEmit(EVENT.appSessionStarted)).toEqual([
      EVENT.appSessionStarted,
      EVENT.appOpened
    ]);
    expect(eventsToEmit(EVENT.downloadCtaClicked)).toEqual([EVENT.downloadCtaClicked]);
    expect(eventsToEmit(EVENT.downloadClicked)).toEqual([
      EVENT.downloadClicked,
      EVENT.downloadCtaClicked
    ]);
    expect(eventsToEmit(EVENT.pricingCtaClicked)).toEqual([
      EVENT.pricingCtaClicked,
      EVENT.ctaClicked
    ]);
    expect(eventsToEmit(EVENT.errorHandled)).toEqual([EVENT.errorHandled]);
  });

  it("does not emit aliases when the recorder is dark", () => {
    const { analytics, transport } = make(false);
    for (const name of eventsToEmit(EVENT.downloadCtaClicked)) {
      analytics.track(name, { placement: "header" });
    }
    expect(transport.sent).toHaveLength(0);
    expect(transport.isStarted).toBe(false);
  });
});

describe("session spine when storage is blocked", () => {
  it("emits once per tab when sessionStorage works", () => {
    const storage = new Map<string, string>();
    const store = {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => void storage.set(key, value)
    };
    expect(shouldEmitSessionSpine(store)).toBe(true);
    expect(shouldEmitSessionSpine(store)).toBe(false);
  });

  it("emits the spine when getItem or setItem throws", () => {
    expect(
      shouldEmitSessionSpine({
        getItem: () => {
          throw new Error("blocked");
        },
        setItem: () => undefined
      })
    ).toBe(true);
    expect(
      shouldEmitSessionSpine({
        getItem: () => null,
        setItem: () => {
          throw new Error("quota");
        }
      })
    ).toBe(true);
  });

  it("clears the session marker so a later grant in the same tab emits again", () => {
    const storage = new Map<string, string>();
    const store = {
      getItem: (key: string) => storage.get(key) ?? null,
      setItem: (key: string, value: string) => void storage.set(key, value),
      removeItem: (key: string) => void storage.delete(key)
    };
    expect(shouldEmitSessionSpine(store)).toBe(true);
    expect(shouldEmitSessionSpine(store)).toBe(false);
    clearSessionSpine(store);
    expect(shouldEmitSessionSpine(store)).toBe(true);
  });
});

describe("fresh auth account capture", () => {
  it("accepts only parsed creation and last-sign-in times within 60s", () => {
    const created = "2026-08-28T12:00:00.000Z";
    const fresh = "2026-08-28T12:00:30.000Z";
    const stale = "2026-08-28T12:05:00.000Z";
    expect(isFreshAuthAccount({ metadata: { creationTime: created, lastSignInTime: fresh } })).toBe(
      true
    );
    expect(isFreshAuthAccount({ metadata: { creationTime: created, lastSignInTime: stale } })).toBe(
      false
    );
    expect(isFreshAuthAccount({ metadata: { creationTime: created } })).toBe(false);
    expect(isFreshAuthAccount(null)).toBe(false);
  });

  it("maps Firebase provider ids to bounded capture sources", () => {
    expect(authCaptureSourceFromProviderId("google.com")).toBe("google");
    expect(authCaptureSourceFromProviderId("apple.com")).toBe("apple");
    expect(authCaptureSourceFromProviderId("github.com")).toBe("github");
    expect(authCaptureSourceFromProviderId("facebook.com")).toBe("facebook");
    expect(authCaptureSourceFromProviderId("twitter.com")).toBe("unknown");
  });

  it("records at most one email.captured per browser after a fresh account", () => {
    const storage = makeStorage();
    const created = "2026-08-28T12:00:00.000Z";
    const user = {
      metadata: { creationTime: created, lastSignInTime: "2026-08-28T12:00:20.000Z" }
    };
    expect(hasRecordedEmailCapture(storage)).toBe(false);
    trackEmailCapturedIfNewAccount(user, "google", storage);
    expect(hasRecordedEmailCapture(storage)).toBe(true);
    markEmailCaptured(storage);
    trackEmailCapturedIfNewAccount(
      { metadata: { creationTime: created, lastSignInTime: "2026-08-28T12:00:40.000Z" } },
      "apple",
      storage
    );
    expect(hasRecordedEmailCapture(storage)).toBe(true);
  });
});
