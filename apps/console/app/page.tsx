"use client";

import Link from "next/link";
import { CheckCircle2 } from "lucide-react";
import type { CSSProperties } from "react";
import { PasskeyEnrollmentActions } from "@/components/account/PasskeyEnrollment";
import { PrivacyPosture } from "@/components/basin/Basin";
import { isFirstRunAccount, usageTotals } from "@/lib/accountStatus";
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
// AA-legible tier ink used for the badge text + border/background tint on paper.
const TIER_INK: Record<Tier, string> = {
  end_to_end: "var(--color-tier-end-to-end)",
  zero_access: "var(--color-tier-zero-access)",
  server_readable: "var(--color-tier-server-readable)",
};
const TIER_LABEL: Record<Tier, string> = {
  end_to_end: "End-to-end",
  zero_access: "Zero-access",
  server_readable: "Server-readable",
};

// Shared grid template so the column header and every row stay aligned.
const LEDGER_COLS =
  "grid-cols-[2.25rem_1fr_auto] sm:grid-cols-[2.25rem_minmax(9rem,13rem)_minmax(0,1fr)_9rem_3rem]";

const delay = (ms: number) => ({ "--d": `${ms}ms` }) as CSSProperties;

export default function HomePage() {
  const { user } = useAuth();
  const { data } = useDomainUsage();
  const byId = usageById(data);
  const firstRun = isFirstRunAccount(data);

  const totals = usageTotals(data);

  return (
    <div className="space-y-token-8">
      {/* ── masthead folio ─────────────────────────────────────────────── */}
      <div className="reveal flex items-baseline justify-between" style={delay(0)}>
        <span className="folio" style={{ color: "var(--accent-deep)" }}>
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

      {firstRun && (
        <AccountReadyPanel
          email={user?.email ?? "this signed-in identity"}
        />
      )}

      <hr className="rule-double" />

      {/* ── posture spine ──────────────────────────────────────────────── */}
      <section className="reveal" style={delay(120)}>
        <PrivacyPosture usage={data} />
      </section>

      <hr className="rule-double" />

      {/* ── the numbered ledger ────────────────────────────────────────── */}
      <section>
        <div className="reveal mb-token-3 flex items-baseline justify-between" style={delay(60)}>
          <h2 className="text-2xl font-semibold tracking-[-0.02em] text-content-bright">
            The whole footprint
          </h2>
          <Link href="/inventory" className="link-underline folio">
            Manage →
          </Link>
        </div>

        {/* column header — names each track so the table reads top-down */}
        <div className={`ledger-head reveal ${LEDGER_COLS}`} style={delay(90)}>
          <span className="folio">#</span>
          <span className="folio">Category</span>
          <span className="hidden folio sm:block">What&apos;s inside</span>
          <span className="hidden folio sm:block">Access</span>
          <span className="folio text-right">Items</span>
        </div>

        <div className="border-t border-glass-line">
          {DATA_DOMAINS.map((d, i) => {
            const u = byId[d.id] ?? { count: 0, bytes: 0 };
            return (
              <Link
                key={d.id}
                href="/inventory"
                className={`ledger-row group reveal items-start ${LEDGER_COLS}`}
                style={delay(120 + i * 35)}
              >
                <span className="index-num pt-0.5 text-sm group-hover:text-[color:var(--accent-deep)]">
                  {String(i + 1).padStart(2, "0")}
                </span>
                <div className="flex min-w-0 items-start gap-token-2">
                  <span
                    className="tier-dot mt-[0.5rem] sm:hidden"
                    style={{ background: TIER_DOT[d.encryptionTier] }}
                    aria-hidden
                  />
                  <span className="line-clamp-2 font-display text-base font-medium leading-snug text-content-bright">
                    {d.title}
                  </span>
                </div>
                <p className="hidden line-clamp-2 text-sm leading-snug text-content-mute sm:block">
                  {d.summary}
                </p>
                <div className="hidden sm:flex">
                  <TierBadge tier={d.encryptionTier} />
                </div>
                <span className="pt-0.5 text-right font-mono text-xs tabular-nums text-content-base">
                  {u.count ? formatCount(u.count) : "—"}
                </span>
              </Link>
            );
          })}
        </div>
      </section>
    </div>
  );
}

function AccountReadyPanel({
  email,
}: {
  email: string;
}) {
  return (
    <section
      className="reveal grid gap-token-4 border-y border-glass-line bg-mercury-wash px-token-4 py-token-5 md:grid-cols-[1fr_auto]"
      style={delay(360)}
      aria-labelledby="account-ready-heading"
    >
      <div className="max-w-2xl">
        <div className="mb-token-2 inline-flex items-center gap-token-2 text-sm text-[color:var(--accent-deep)]">
          <CheckCircle2 className="size-4" aria-hidden />
          <span className="smallcaps text-xs">Account ready</span>
        </div>
        <h2 id="account-ready-heading" className="text-2xl tracking-[-0.02em]">
          No Mac data has landed for this sign-in yet.
        </h2>
        <p className="mt-token-2 text-sm leading-6 text-content-mute">
          Signed in as <span className="font-mono text-content-base">{email}</span>. Once the Mac
          app publishes Cloud Sync data for this same Apple or Google sign-in, the ledger below will
          fill automatically.
        </p>
      </div>

      <PasskeyEnrollmentActions
        className="md:min-w-52"
        buttonClassName="h-11 px-token-5 text-sm"
        secondaryAction={
          <Link href="/escrow" className="btn-quiet btn-outline h-11 px-token-5 text-sm">
            Trust this browser
          </Link>
        }
      />
    </section>
  );
}

function TierBadge({ tier }: { tier: Tier }) {
  return (
    <span
      className="tier-badge"
      style={
        {
          "--tier-ink": TIER_INK[tier],
          "--tier-dot": TIER_DOT[tier],
        } as CSSProperties
      }
    >
      <span className="tier-badge__dot" aria-hidden />
      {TIER_LABEL[tier]}
    </span>
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
