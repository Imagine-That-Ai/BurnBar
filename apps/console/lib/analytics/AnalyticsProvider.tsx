"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { usePathname } from "next/navigation";
import { useAuth } from "@/lib/useAuth";
import {
  analyticsConsent,
  boot,
  declineConsent,
  grantConsent,
  identifyUser,
  revokeConsent,
  routeKeyForPath,
  trackEvent,
  EVENT,
  type AnalyticsEventName,
  type AnalyticsProps,
} from "@/lib/analytics";
import type { ConsentState } from "@/lib/analytics/consent";

interface AnalyticsContextValue {
  /** Tri-state consent, reactive so the banner + settings toggle re-render. */
  consent: ConsentState;
  /** Whether the first-run prompt should be visible (unset and not dismissed). */
  showBanner: boolean;
  grant: () => void;
  decline: () => void;
  revoke: () => void;
  /** Reopen the first-run prompt from a settings control. */
  openConsentPrompt: () => void;
  /** Dismiss the banner without recording a decision (it returns next session). */
  dismissBanner: () => void;
  /** Record a taxonomy event. Dropped unless consent is granted + a key exists. */
  track: (event: AnalyticsEventName, props?: AnalyticsProps) => void;
}

const AnalyticsContext = createContext<AnalyticsContextValue | null>(null);

/**
 * Client provider that boots console analytics, instruments route changes and
 * authenticated identity, and exposes a consent-gated `track` to the tree.
 * Mounted high in the app (app/providers.tsx). All tracking is dropped until the
 * member opts in, so mounting it everywhere leaks nothing pre-consent.
 */
export function AnalyticsProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const pathname = usePathname();

  // Mirror the persisted consent into React state so UI reacts to changes.
  const [consent, setConsent] = useState<ConsentState>("unset");
  const [bannerDismissed, setBannerDismissed] = useState(false);
  const lastRouteKey = useRef<string | null>(null);
  const booted = useRef(false);
  const identityRequest = useRef(0);
  // Read the current path without making the boot effect depend on it (the boot
  // must run exactly once; later path changes are handled by the nav effect).
  const pathnameRef = useRef(pathname);
  pathnameRef.current = pathname;

  // Boot once on mount: resume a consented session (page view + session start).
  useEffect(() => {
    if (booted.current) return;
    booted.current = true;
    boot();
    setConsent(analyticsConsent.state);
    lastRouteKey.current = routeKeyForPath(pathnameRef.current);
  }, []);

  // Identify / clear the signed-in member (hashed uid only; gated downstream).
  useEffect(() => {
    const request = ++identityRequest.current;
    void identifyUser(user?.uid, () => request === identityRequest.current);
  }, [user?.uid]);

  // Track in-app navigation as nav.route.changed (bounded route keys, no raw URL).
  useEffect(() => {
    const next = routeKeyForPath(pathname);
    const prev = lastRouteKey.current;
    if (prev === null) {
      lastRouteKey.current = next;
      return;
    }
    if (prev === next) return;
    lastRouteKey.current = next;
    trackEvent(EVENT.navRouteChanged, { from_route: prev, to_route: next });
    trackEvent(EVENT.screenViewed, { is_first_view: false });
  }, [pathname]);

  const grant = useCallback(() => {
    grantConsent();
    setConsent(analyticsConsent.state);
    setBannerDismissed(true);
  }, []);

  const decline = useCallback(() => {
    declineConsent();
    setConsent(analyticsConsent.state);
    setBannerDismissed(true);
  }, []);

  const revoke = useCallback(() => {
    revokeConsent();
    setConsent(analyticsConsent.state);
  }, []);

  const openConsentPrompt = useCallback(() => setBannerDismissed(false), []);
  const dismissBanner = useCallback(() => setBannerDismissed(true), []);

  const track = useCallback(
    (event: AnalyticsEventName, props?: AnalyticsProps) => trackEvent(event, props),
    [],
  );

  const showBanner = consent === "unset" && !bannerDismissed;

  const value = useMemo<AnalyticsContextValue>(
    () => ({
      consent,
      showBanner,
      grant,
      decline,
      revoke,
      openConsentPrompt,
      dismissBanner,
      track,
    }),
    [consent, showBanner, grant, decline, revoke, openConsentPrompt, dismissBanner, track],
  );

  return <AnalyticsContext.Provider value={value}>{children}</AnalyticsContext.Provider>;
}

/**
 * Consent-gated analytics for components. Safe to call anywhere under the
 * provider; if the provider is somehow absent, `track` is a no-op so a missing
 * provider never throws into a user flow.
 */
export function useAnalytics(): AnalyticsContextValue {
  const ctx = useContext(AnalyticsContext);
  if (ctx) return ctx;
  return {
    consent: "unset",
    showBanner: false,
    grant: () => {},
    decline: () => {},
    revoke: () => {},
    openConsentPrompt: () => {},
    dismissBanner: () => {},
    track: () => {},
  };
}
