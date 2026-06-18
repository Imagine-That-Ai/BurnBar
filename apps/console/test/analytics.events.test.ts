import { describe, expect, it } from "vitest";

import { EVENT, eventCategory, type AnalyticsEventName } from "../lib/analytics/events";

const EVENT_NAME_RE = /^[a-z0-9]+(\.[a-z0-9_]+)+$/;

/** Tier 1 names are shared verbatim across every platform — pin them exactly. */
const TIER1_VERBATIM: Record<string, string> = {
  appSessionStarted: "app.session.started",
  screenViewed: "screen.viewed",
  navRouteChanged: "nav.route.changed",
  authSignInCompleted: "auth.sign_in.completed",
  authSignUpCompleted: "auth.sign_up.completed",
  authSignedOut: "auth.signed_out",
  settingsChanged: "settings.changed",
  errorHandled: "error.handled",
  consentAnalyticsGranted: "consent.analytics.granted",
};

describe("event registry", () => {
  it("every wire name matches the canonical casing scheme", () => {
    for (const name of Object.values(EVENT)) {
      expect(name, name).toMatch(EVENT_NAME_RE);
    }
  });

  it("Tier 1 names are byte-identical to the shared taxonomy", () => {
    for (const [key, wire] of Object.entries(TIER1_VERBATIM)) {
      expect(EVENT[key as keyof typeof EVENT]).toBe(wire);
    }
  });

  it("Tier 2 console events use surface.object.action under the console surfaces", () => {
    const tier2 = [
      EVENT.inventoryDomainExported,
      EVENT.inventoryDomainDeleted,
      EVENT.pensieveRepoConnected,
      EVENT.pensieveRepoDisconnected,
      EVENT.pensieveResyncRequested,
      EVENT.escrowDeviceRegistered,
      EVENT.escrowDeviceTrusted,
      EVENT.escrowDeviceFailed,
      EVENT.passkeyEnrollmentCompleted,
      EVENT.accountAccessRevoked,
    ];
    for (const name of tier2) {
      expect(name, name).toMatch(EVENT_NAME_RE);
      expect(name.split(".")).toHaveLength(3); // surface.object.action
    }
  });

  it("maps each event to exactly one of the five categories", () => {
    const allowed = new Set(["lifecycle", "screen_view", "primary_action", "conversion_auth", "error"]);
    for (const name of Object.values(EVENT)) {
      expect(allowed.has(eventCategory(name as AnalyticsEventName))).toBe(true);
    }
  });

  it("assigns the documented categories for the spine + conversions + errors", () => {
    expect(eventCategory(EVENT.consentAnalyticsGranted)).toBe("lifecycle");
    expect(eventCategory(EVENT.appSessionStarted)).toBe("lifecycle");
    expect(eventCategory(EVENT.authSignedOut)).toBe("lifecycle");
    expect(eventCategory(EVENT.screenViewed)).toBe("screen_view");
    expect(eventCategory(EVENT.navRouteChanged)).toBe("screen_view");
    expect(eventCategory(EVENT.authSignInCompleted)).toBe("conversion_auth");
    expect(eventCategory(EVENT.escrowDeviceTrusted)).toBe("conversion_auth");
    expect(eventCategory(EVENT.passkeyEnrollmentCompleted)).toBe("conversion_auth");
    expect(eventCategory(EVENT.errorHandled)).toBe("error");
    expect(eventCategory(EVENT.escrowDeviceFailed)).toBe("error");
    expect(eventCategory(EVENT.inventoryDomainExported)).toBe("primary_action");
  });

  it("has no duplicate wire names", () => {
    const names = Object.values(EVENT);
    expect(new Set(names).size).toBe(names.length);
  });
});
