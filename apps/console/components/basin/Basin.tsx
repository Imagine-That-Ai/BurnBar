"use client";

import { DATA_DOMAINS, type DataDomain } from "@/lib/domains";
import { usageById } from "@/lib/useDomainUsage";
import type { DataDomainUsageResponse } from "@/lib/api";

/**
 * Privacy posture — the member's data footprint as an editorial hairline bar,
 * segmented by encryption tier and read top-to-bottom like a ledger. No canvas,
 * no ornament: how much of what we hold sits at each tier, in plain language.
 */

type Tier = DataDomain["encryptionTier"];

const TIER_ORDER: Tier[] = ["end_to_end", "zero_access", "server_readable"];

const TIER_META: Record<Tier, { label: string; note: string; ink: string; dot: string }> = {
  end_to_end: {
    label: "End-to-end",
    note: "Sealed on your devices. We never see the contents or the key.",
    ink: "var(--color-tier-end-to-end)",
    dot: "var(--tier-e2e-dot)",
  },
  zero_access: {
    label: "Zero-access",
    note: "Encrypted at rest under a key only your trusted devices hold.",
    ink: "var(--color-tier-zero-access)",
    dot: "var(--tier-zero-dot)",
  },
  server_readable: {
    label: "Server-readable",
    note: "Operational metadata we can read — telemetry, billing, the device mirror.",
    ink: "var(--color-tier-server-readable)",
    dot: "var(--tier-srv-dot)",
  },
};

export function PrivacyPosture({ usage }: { usage: DataDomainUsageResponse | null }) {
  const byId = usageById(usage);

  // Weight each tier by how many domains sit there, nudged by real footprint so
  // a heavy tier reads heavier once you have data. Domain count keeps the bar
  // honest and populated even before anything syncs.
  const weights: Record<Tier, number> = { end_to_end: 0, zero_access: 0, server_readable: 0 };
  for (const d of DATA_DOMAINS) {
    const u = byId[d.id] ?? { count: 0, bytes: 0 };
    weights[d.encryptionTier] += 1 + Math.log1p(u.count + u.bytes / (64 * 1024)) * 0.6;
  }
  const total = TIER_ORDER.reduce((s, t) => s + weights[t], 0) || 1;
  const domainCount: Record<Tier, number> = { end_to_end: 0, zero_access: 0, server_readable: 0 };
  for (const d of DATA_DOMAINS) domainCount[d.encryptionTier] += 1;

  return (
    <div>
      <div className="flex items-baseline justify-between gap-token-4">
        <p className="eyebrow">Your data, by who can read it</p>
        <p className="font-mono text-xs tabular-nums text-content-dim">
          {DATA_DOMAINS.length} domains
        </p>
      </div>

      <div
        className="mt-token-4 flex h-2.5 w-full overflow-hidden rounded-full"
        role="img"
        aria-label="Share of your data domains at each encryption tier."
      >
        {TIER_ORDER.map((t, i) => (
          <div
            key={t}
            className="h-full"
            style={{
              width: `${(weights[t] / total) * 100}%`,
              background: TIER_META[t].ink,
              marginLeft: i === 0 ? 0 : 2,
              borderRadius: 2,
            }}
          />
        ))}
      </div>

      <div className="mt-token-6 grid gap-token-6 sm:grid-cols-3">
        {TIER_ORDER.map((t) => {
          const m = TIER_META[t];
          return (
            <div key={t}>
              <div className="flex items-center gap-token-2">
                <span className="tier-dot" style={{ background: m.dot }} aria-hidden />
                <span className="font-display text-sm font-semibold text-content-bright">
                  {m.label}
                </span>
                <span className="font-mono text-xs tabular-nums text-content-dim">
                  {domainCount[t]}
                </span>
              </div>
              <p className="mt-1.5 text-sm leading-snug text-content-mute">{m.note}</p>
            </div>
          );
        })}
      </div>
    </div>
  );
}
