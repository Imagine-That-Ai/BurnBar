import { beforeEach, describe, expect, it } from "vitest";

import { ConsentStore, type ConsentStorage } from "../lib/analytics/consent";
import { Analytics, type AnalyticsTransport, type AnalyticsProps } from "../lib/analytics/recorder";
import { EVENT, eventCategory } from "../lib/analytics/events";

/** In-memory storage standing in for localStorage. */
function fakeStorage(initial: Record<string, string> = {}): ConsentStorage {
  const m = new Map<string, string>(Object.entries(initial));
  return {
    getItem: (k) => m.get(k) ?? null,
    setItem: (k, v) => void m.set(k, v),
  };
}

interface Recorded {
  name: string;
  category: string;
  props: AnalyticsProps;
}

/**
 * Fake transport injected in place of the Amplitude SDK. Records calls and
 * proves the SDK is never even "started" while the gate is closed.
 */
class FakeTransport implements AnalyticsTransport {
  started = false;
  startCount = 0;
  stopCount = 0;
  userId: string | undefined = undefined;
  setUserIdCalls: Array<string | undefined> = [];
  events: Recorded[] = [];

  get isStarted(): boolean {
    return this.started;
  }
  start(apiKey: string): void {
    expect(apiKey.length).toBeGreaterThan(0); // recorder must never start with an empty key
    this.started = true;
    this.startCount += 1;
  }
  track(name: string, category: string, props: AnalyticsProps): void {
    if (!this.started) throw new Error("track() before start() — gate leak");
    this.events.push({ name, category, props });
  }
  setUserId(id: string | undefined): void {
    this.userId = id;
    this.setUserIdCalls.push(id);
  }
  stop(): void {
    this.started = false;
    this.stopCount += 1;
  }
}

const SUPER: AnalyticsProps = { platform: "console", app_version: "console", surface: "console" };

function makeAnalytics(opts: {
  initialConsent?: string;
  apiKey?: string;
}): { analytics: Analytics; consent: ConsentStore; transport: FakeTransport } {
  const storage = fakeStorage(
    opts.initialConsent ? { "burnbar-console-analytics-consent": opts.initialConsent } : {},
  );
  const consent = new ConsentStore(storage);
  const transport = new FakeTransport();
  const analytics = new Analytics({
    consent,
    transport,
    apiKey: opts.apiKey ?? "test-key",
    superProperties: () => ({ ...SUPER }),
  });
  return { analytics, consent, transport };
}

describe("Analytics consent contract", () => {
  describe("dark before opt-in (unset)", () => {
    let env: ReturnType<typeof makeAnalytics>;
    beforeEach(() => {
      env = makeAnalytics({}); // default unset
    });

    it("never starts the transport on track() while unset", () => {
      env.analytics.track(EVENT.screenViewed, { is_first_view: true });
      expect(env.transport.isStarted).toBe(false);
      expect(env.transport.startCount).toBe(0);
      expect(env.transport.events).toHaveLength(0);
    });

    it("startIfConsented() stays dark when unset", () => {
      env.analytics.startIfConsented();
      expect(env.transport.isStarted).toBe(false);
      expect(env.transport.startCount).toBe(0);
    });

    it("does not forward a user id while unset (no user_id before opt-in)", () => {
      env.analytics.setUserId("hashed-uid");
      expect(env.transport.setUserIdCalls).toHaveLength(0);
      expect(env.transport.isStarted).toBe(false);
    });
  });

  describe("declined is identical to unset (both dark)", () => {
    it("never starts and never sends after a decline", () => {
      const { analytics, consent, transport } = makeAnalytics({});
      consent.decline();
      analytics.consentDidChange();
      analytics.track(EVENT.screenViewed);
      analytics.startIfConsented();
      expect(transport.startCount).toBe(0);
      expect(transport.events).toHaveLength(0);
      expect(consent.isGranted).toBe(false);
    });
  });

  describe("on grant", () => {
    it("starts the transport and emits EXACTLY ONE consent.analytics.granted", () => {
      const { analytics, consent, transport } = makeAnalytics({});
      consent.grant();
      analytics.consentDidChange();

      expect(transport.startCount).toBe(1);
      const grants = transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted);
      expect(grants).toHaveLength(1);
      expect(grants[0].category).toBe("lifecycle");
      expect(grants[0].props.consent_version).toBe("1");
      // super-properties are stamped on every event
      expect(grants[0].props.platform).toBe("console");
    });

    it("does not re-emit grant if consentDidChange fires twice", () => {
      const { analytics, consent, transport } = makeAnalytics({});
      consent.grant();
      analytics.consentDidChange();
      analytics.consentDidChange();
      expect(transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted)).toHaveLength(
        1,
      );
    });

    it("emits subsequent events with the correct name + category + merged props", () => {
      const { analytics, consent, transport } = makeAnalytics({});
      consent.grant();
      analytics.consentDidChange();
      analytics.track(EVENT.inventoryDomainExported, {
        encryption_tier: "end_to_end",
        outcome: "success",
      });

      const ev = transport.events.find((e) => e.name === EVENT.inventoryDomainExported);
      expect(ev).toBeTruthy();
      expect(ev!.category).toBe(eventCategory(EVENT.inventoryDomainExported));
      expect(ev!.category).toBe("primary_action");
      expect(ev!.props).toMatchObject({
        platform: "console",
        encryption_tier: "end_to_end",
        outcome: "success",
      });
    });
  });

  describe("resume of an already-consented session", () => {
    it("starts WITHOUT re-emitting grant", () => {
      const { analytics, transport } = makeAnalytics({ initialConsent: "granted" });
      analytics.startIfConsented();
      expect(transport.startCount).toBe(1);
      expect(transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted)).toHaveLength(
        0,
      );
    });

    it("forwards a previously-set user id once resumed", () => {
      const { analytics, transport } = makeAnalytics({ initialConsent: "granted" });
      analytics.setUserId("hashed-uid"); // granted, so this reaches the transport immediately
      expect(transport.setUserIdCalls).toContain("hashed-uid");
    });
  });

  describe("on revoke (granted -> declined)", () => {
    it("stops the transport, flushes nothing, emits no revoked event", () => {
      const { analytics, consent, transport } = makeAnalytics({ initialConsent: "granted" });
      analytics.startIfConsented();
      const sentBefore = transport.events.length;

      consent.revoke();
      analytics.consentDidChange();

      expect(transport.stopCount).toBe(1);
      expect(transport.isStarted).toBe(false);
      // no new event was emitted by the revoke
      expect(transport.events.length).toBe(sentBefore);
      // revoke lands in declined, never back to unset
      expect(consent.state).toBe("declined");
    });

    it("is silent on track() after revoke", () => {
      const { analytics, consent, transport } = makeAnalytics({ initialConsent: "granted" });
      analytics.startIfConsented();
      consent.revoke();
      analytics.consentDidChange();

      const before = transport.events.length;
      analytics.track(EVENT.screenViewed);
      expect(transport.events.length).toBe(before);
    });

    it("re-grant after revoke emits grant again (announce flag re-armed)", () => {
      const { analytics, consent, transport } = makeAnalytics({ initialConsent: "granted" });
      analytics.startIfConsented();
      consent.revoke();
      analytics.consentDidChange();
      consent.grant();
      analytics.consentDidChange();
      expect(transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted)).toHaveLength(
        1,
      );
    });
  });

  describe("no key -> dark even when granted", () => {
    it("never starts or sends when the API key is empty", () => {
      const { analytics, consent, transport } = makeAnalytics({ apiKey: "" });
      consent.grant();
      analytics.consentDidChange();
      analytics.startIfConsented();
      analytics.track(EVENT.screenViewed);
      expect(transport.startCount).toBe(0);
      expect(transport.events).toHaveLength(0);
    });
  });
});

describe("ConsentStore tri-state", () => {
  it("defaults to unset and reports the right gates", () => {
    const c = new ConsentStore(fakeStorage());
    expect(c.state).toBe("unset");
    expect(c.isGranted).toBe(false);
    expect(c.hasDecided).toBe(false);
  });

  it("revoke() persists declined, not unset", () => {
    const storage = fakeStorage();
    const c = new ConsentStore(storage);
    c.grant();
    expect(c.isGranted).toBe(true);
    c.revoke();
    expect(c.state).toBe("declined");
    expect(c.hasDecided).toBe(true);
    // a fresh store over the same storage still reads declined
    expect(new ConsentStore(storage).state).toBe("declined");
  });

  it("treats unrecognized persisted values as unset", () => {
    expect(new ConsentStore(fakeStorage({ "burnbar-console-analytics-consent": "yes" })).state).toBe(
      "unset",
    );
  });
});
