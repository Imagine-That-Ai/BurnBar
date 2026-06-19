"use client";

import { BarChart3 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAnalytics } from "@/lib/analytics/AnalyticsProvider";

/**
 * Revisitable analytics consent control for the settings page. Reflects the
 * persisted tri-state and lets the member opt in or out at any time. Opting out
 * after opting in revokes immediately — the SDK is torn down and nothing is
 * flushed. There is no "revoked" event (that would be a send after revoke).
 */
export function AnalyticsSettingsToggle() {
  const { consent, grant, revoke } = useAnalytics();
  const enabled = consent === "granted";

  const status = enabled ? "Enabled" : consent === "declined" ? "Off" : "Not set";
  const detail = enabled
    ? "Privacy-preserving usage analytics are on. We measure feature usage with bucketed counts and outcomes — never sealed content, message bodies, or personal data."
    : "Analytics are off. Turn them on to help improve the console with privacy-preserving, bucketed usage data. You can turn them back off here at any time.";

  return (
    <div className="grid gap-token-4 border-t border-glass-line py-token-4 first:border-t-0 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
      <div className="flex min-w-0 items-start gap-token-3">
        <span
          className="mt-0.5 grid size-8 shrink-0 place-items-center border border-glass-line bg-mercury-wash text-[color:var(--accent-deep)]"
          aria-hidden
        >
          <BarChart3 className="size-4" />
        </span>
        <div className="min-w-0">
          <p className="text-sm font-medium text-content-bright">Usage analytics</p>
          <p className="mt-1 text-sm leading-6 text-content-mute">{detail}</p>
        </div>
      </div>
      <div className="flex items-center gap-token-3 justify-self-start md:justify-self-end">
        <span className="font-mono text-xs uppercase tracking-[0.12em] text-content-dim">
          {status}
        </span>
        {enabled ? (
          <Button variant="secondary" size="sm" onClick={revoke}>
            Turn off
          </Button>
        ) : (
          <Button variant="secondary" size="sm" onClick={grant}>
            Turn on
          </Button>
        )}
      </div>
    </div>
  );
}
