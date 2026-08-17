"use client";

import { BarChart3 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAnalytics } from "@/lib/analytics/AnalyticsProvider";

/**
 * First-run, opt-in analytics consent banner for the console. Renders only when
 * consent is `unset` and the member has not dismissed it this session. Declining
 * — or never answering — keeps the console dark: the Amplitude chunk is never
 * fetched. Revisit via the settings toggle (AnalyticsSettingsToggle).
 *
 * Mounted once from AppShell. All `track` calls elsewhere are dropped until the
 * member clicks "Enable analytics", so nothing leaks before this decision.
 */
export function ConsentBanner() {
  const { showBanner, grant, decline } = useAnalytics();
  if (!showBanner) return null;

  return (
    <aside
      role="dialog"
      aria-modal="false"
      aria-label="Usage analytics consent"
      className="fixed inset-x-token-4 bottom-token-4 z-50 mx-auto max-w-2xl glass-pane p-token-4 shadow-[0_18px_48px_-24px_rgba(0,0,0,0.7)] backdrop-blur-md"
    >
      <div className="flex flex-col gap-token-3 sm:flex-row sm:flex-wrap sm:items-center sm:justify-between sm:gap-token-4">
        <div className="flex min-w-0 flex-1 items-start gap-token-3">
          <span
            className="mt-0.5 grid size-8 shrink-0 place-items-center border border-glass-line bg-mercury-wash text-[color:var(--accent-deep)]"
            aria-hidden
          >
            <BarChart3 className="size-4" />
          </span>
          <p className="min-w-0 text-sm leading-6 text-content-mute">
            <span className="font-medium text-content-bright">Privacy-first, opt-in analytics.</span>{" "}
            We&apos;d like to measure feature usage with privacy-preserving analytics (Amplitude) to
            improve the console. No personal data, no sealed content, no message bodies, no tracking
            until you choose to opt in.
          </p>
        </div>
        <div className="flex shrink-0 justify-end gap-token-2">
          <Button variant="ghost" size="sm" onClick={decline} data-analytics-decline>
            Not now
          </Button>
          <Button variant="primary" size="sm" onClick={grant} data-analytics-accept>
            Enable analytics
          </Button>
        </div>
      </div>
    </aside>
  );
}
