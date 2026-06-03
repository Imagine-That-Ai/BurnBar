"use client";

import Link from "next/link";
import { PrivacyPosture } from "@/components/basin/Basin";
import { useAuth } from "@/lib/useAuth";
import { useDomainUsage, usageById } from "@/lib/useDomainUsage";
import { DATA_DOMAINS, type DataDomain } from "@/lib/domains";
import { formatBytes, formatCount } from "@/lib/utils";

type Tier = DataDomain["encryptionTier"];

const TIER_DOT: Record<Tier, string> = {
  end_to_end: "var(--tier-e2e-dot)",
  zero_access: "var(--tier-zero-dot)",
  server_readable: "var(--tier-srv-dot)",
};
const TIER_LABEL: Record<Tier, string> = {
  end_to_end: "End-to-end",
  zero_access: "Zero-access",
  server_readable: "Server-readable",
};

export default function HomePage() {
  const { user } = useAuth();
  const { data } = useDomainUsage();
  const byId = usageById(data);

  const totals = (data?.domains ?? []).reduce(
    (acc, d) => ({ count: acc.count + d.count, bytes: acc.bytes + d.bytes }),
    { count: 0, bytes: 0 },
  );

  return (
    <div className="space-y-token-12">
      <section className="max-w-3xl space-y-token-6 pt-token-4">
        <p className="eyebrow eyebrow--accent">{user?.email ?? "Your private console"}</p>
        <h1 className="text-[clamp(2.5rem,6.5vw,4.5rem)] font-semibold leading-[1.01] tracking-[-0.03em] text-content-bright">
          Everything we keep for you —{" "}
          <span className="text-content-mute">and exactly who can read it.</span>
        </h1>
        <p className="epigraph text-xl">“A basin that remembers, and never reads.”</p>

        <div className="flex flex-wrap items-center gap-x-token-6 gap-y-token-3 pt-token-2">
          <Figure value={formatCount(totals.count)} label="memories" />
          <Sep />
          <Figure value={String(DATA_DOMAINS.length)} label="domains" />
          <Sep />
          <Figure value={formatBytes(totals.bytes)} label="sealed" />
        </div>

        <div className="flex flex-wrap gap-token-3 pt-token-2">
          <Link
            href="/inventory"
            className="btn-quiet btn-accent inline-flex h-11 items-center px-token-6 text-sm"
          >
            Open the Transparency Inventory →
          </Link>
          <Link
            href="/escrow"
            className="btn-quiet btn-outline inline-flex h-11 items-center px-token-6 text-sm"
          >
            Trust this browser
          </Link>
        </div>
      </section>

      <hr className="rule" />

      <section>
        <PrivacyPosture usage={data} />
      </section>

      <hr className="rule" />

      <section className="space-y-token-2">
        <div className="flex items-baseline justify-between">
          <h2 className="text-2xl font-semibold tracking-[-0.02em] text-content-bright">
            The whole footprint
          </h2>
          <Link
            href="/inventory"
            className="link-underline font-mono text-xs uppercase tracking-[0.18em]"
          >
            Manage →
          </Link>
        </div>

        <div className="border-t border-glass-line">
          {DATA_DOMAINS.map((d) => {
            const u = byId[d.id] ?? { count: 0, bytes: 0 };
            return (
              <Link
                key={d.id}
                href="/inventory"
                className="ledger-row grid-cols-[1fr_auto] sm:grid-cols-[minmax(0,17rem)_1fr_auto]"
              >
                <div className="flex min-w-0 items-center gap-token-3">
                  <span
                    className="tier-dot"
                    style={{ background: TIER_DOT[d.encryptionTier] }}
                    aria-hidden
                  />
                  <span className="truncate font-display text-base font-medium text-content-bright">
                    {d.title}
                  </span>
                </div>
                <p className="hidden truncate text-sm text-content-mute sm:block">{d.summary}</p>
                <div className="flex items-center gap-token-6 font-mono text-xs">
                  <span className="hidden tabular-nums text-content-dim sm:inline">
                    {TIER_LABEL[d.encryptionTier]}
                  </span>
                  <span className="tabular-nums text-content-base">
                    {u.count ? formatCount(u.count) : "—"}
                  </span>
                </div>
              </Link>
            );
          })}
        </div>
      </section>
    </div>
  );
}

function Figure({ value, label }: { value: string; label: string }) {
  return (
    <span className="inline-flex items-baseline gap-2">
      <span className="font-mono text-2xl font-medium tabular-nums text-content-bright">
        {value}
      </span>
      <span className="text-sm text-content-mute">{label}</span>
    </span>
  );
}

function Sep() {
  return <span className="hidden h-5 w-px bg-glass-line sm:inline-block" aria-hidden />;
}
