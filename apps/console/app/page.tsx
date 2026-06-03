"use client";

import Link from "next/link";
import type { CSSProperties } from "react";
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

const delay = (ms: number) => ({ "--d": `${ms}ms` }) as CSSProperties;

export default function HomePage() {
  const { user } = useAuth();
  const { data } = useDomainUsage();
  const byId = usageById(data);

  const totals = (data?.domains ?? []).reduce(
    (acc, d) => ({ count: acc.count + d.count, bytes: acc.bytes + d.bytes }),
    { count: 0, bytes: 0 },
  );

  return (
    <div className="space-y-token-8">
      {/* ── masthead folio ─────────────────────────────────────────────── */}
      <div className="reveal flex items-baseline justify-between" style={delay(0)}>
        <span className="folio" style={{ color: "var(--accent)" }}>
          The Private Ledger
        </span>
        <span className="folio">{user?.email ?? "Not indexed"}</span>
      </div>
      <hr className="rule-double" />

      {/* ── hero ───────────────────────────────────────────────────────── */}
      <section className="grid gap-token-8 pt-token-4 lg:grid-cols-[1.55fr_1fr]">
        <div className="space-y-token-6">
          <h1
            className="reveal text-[clamp(2.6rem,7vw,5.25rem)] font-semibold leading-[0.98] tracking-[-0.035em] text-content-bright"
            style={delay(80)}
          >
            Everything we keep
            <br />
            for you —{" "}
            <span className="text-content-mute">and exactly who can read it.</span>
          </h1>

          <blockquote
            className="reveal border-l-2 pl-token-4 epigraph text-xl"
            style={{ ...delay(180), borderColor: "var(--accent)" }}
          >
            “A basin that remembers, and never reads.”
          </blockquote>

          <div className="reveal flex flex-wrap gap-token-3 pt-token-2" style={delay(320)}>
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
        </div>

        {/* figures — the broadsheet's running totals */}
        <div className="reveal grid grid-cols-3 self-end lg:grid-cols-1" style={delay(240)}>
          <Figure value={formatCount(totals.count)} label="memories held" first />
          <Figure value={String(DATA_DOMAINS.length)} label="data domains" />
          <Figure value={formatBytes(totals.bytes)} label="sealed on device" />
        </div>
      </section>

      <hr className="rule-double" />

      {/* ── posture spine ──────────────────────────────────────────────── */}
      <section className="reveal" style={delay(120)}>
        <PrivacyPosture usage={data} />
      </section>

      <hr className="rule-double" />

      {/* ── the numbered ledger ────────────────────────────────────────── */}
      <section>
        <div className="reveal mb-token-2 flex items-baseline justify-between" style={delay(60)}>
          <h2 className="text-2xl font-semibold tracking-[-0.02em] text-content-bright">
            The whole footprint
          </h2>
          <Link href="/inventory" className="link-underline folio">
            Manage →
          </Link>
        </div>

        <div className="border-t border-glass-line">
          {DATA_DOMAINS.map((d, i) => {
            const u = byId[d.id] ?? { count: 0, bytes: 0 };
            return (
              <Link
                key={d.id}
                href="/inventory"
                className="ledger-row group reveal grid-cols-[auto_1fr_auto] sm:grid-cols-[2.5rem_minmax(0,15rem)_1fr_auto]"
                style={delay(120 + i * 35)}
              >
                <span className="index-num text-sm group-hover:text-[color:var(--accent)]">
                  {String(i + 1).padStart(2, "0")}
                </span>
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
                <div className="flex items-center gap-token-6">
                  <span className="hidden smallcaps text-xs text-content-dim sm:inline">
                    {TIER_LABEL[d.encryptionTier]}
                  </span>
                  <span className="font-mono text-xs tabular-nums text-content-base">
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

function Figure({ value, label, first }: { value: string; label: string; first?: boolean }) {
  return (
    <div
      className={
        "px-token-4 py-token-2 first:pl-0 lg:border-l-0 lg:py-token-3 " +
        (first ? "" : "border-l border-glass-line lg:border-t lg:border-l-0")
      }
    >
      <div className="font-mono text-[clamp(1.6rem,3vw,2.4rem)] font-medium leading-none tabular-nums text-content-bright">
        {value}
      </div>
      <div className="mt-1.5 folio">{label}</div>
    </div>
  );
}
