"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { BadgeCheck, KeyRound, Mail, ShieldCheck, Smartphone } from "lucide-react";
import { PasskeyEnrollmentActions } from "@/components/account/PasskeyEnrollment";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/lib/useAuth";
import { cn } from "@/lib/utils";

export default function SettingsPage() {
  const { user } = useAuth();
  const providers = user?.providerData.map((provider) => providerLabel(provider.providerId)) ?? [];
  const primaryProvider = providers[0] ?? "Provider-linked";

  return (
    <div className="mx-auto max-w-4xl space-y-token-8">
      <header className="grid gap-token-6 border-b border-glass-line pb-token-6 md:grid-cols-[1fr_auto] md:items-end">
        <div>
          <p className="eyebrow eyebrow--accent">Account settings</p>
          <h1 className="mt-token-2 font-display text-[clamp(2.3rem,5vw,4.4rem)] leading-none tracking-[-0.035em] text-content-bright">
            Sign-in
            <br />
            and device trust
          </h1>
        </div>
        <div className="max-w-sm md:text-right">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-content-dim">
            Signed in as
          </p>
          <p className="mt-token-2 break-all font-mono text-sm text-content-bright">
            {user?.email ?? "Signed-in member"}
          </p>
        </div>
      </header>

      <section aria-labelledby="identity-heading" className="space-y-token-3">
        <div className="flex items-baseline justify-between gap-token-4">
          <h2 id="identity-heading" className="font-display text-2xl text-content-bright">
            Identity
          </h2>
          <span className="folio">Firebase Auth</span>
        </div>

        <div className="border-y border-glass-line">
          <SettingLedgerRow
            icon={<Mail className="size-4" aria-hidden />}
            label="Account email"
            detail={user?.email ?? "Signed-in member"}
            value="Active"
            emphasis
          />
          <SettingLedgerRow
            icon={<BadgeCheck className="size-4" aria-hidden />}
            label="Primary provider"
            detail={primaryProvider}
            value="Verified"
          />
        </div>
      </section>

      <section aria-labelledby="methods-heading" className="space-y-token-3">
        <div className="flex items-baseline justify-between gap-token-4">
          <h2 id="methods-heading" className="font-display text-2xl text-content-bright">
            Sign-in methods
          </h2>
          <span className="folio">Add after fallback sign-in</span>
        </div>

        <div className="border-y border-glass-line">
          <SettingLedgerRow
            icon={<ShieldCheck className="size-4" aria-hidden />}
            label={`${primaryProvider} fallback`}
            detail="Keeps this account reachable if passkey sign-in is unavailable."
            value="Enabled"
          />
          <div className="grid gap-token-4 border-t border-glass-line py-token-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
            <div className="flex min-w-0 items-start gap-token-3">
              <LedgerIcon>
                <KeyRound className="size-4" aria-hidden />
              </LedgerIcon>
              <div className="min-w-0">
                <p className="text-sm font-medium text-content-bright">Passkey sign-in</p>
                <p className="mt-1 text-sm leading-6 text-content-mute">
                  Create a synced passkey for this account, then sign in from the passkey button.
                </p>
              </div>
            </div>
            <PasskeyEnrollmentActions
              className="md:w-56"
              buttonClassName="h-10 px-token-4 text-sm"
            />
          </div>
          <SettingLedgerRow
            icon={<Smartphone className="size-4" aria-hidden />}
            label="Browser trust"
            detail="Allow this browser to unwrap sealed content after native-device approval."
            value="Optional"
            action={
              <Button asChild variant="secondary" size="sm">
                <Link href="/escrow">Trust browser</Link>
              </Button>
            }
          />
        </div>
      </section>
    </div>
  );
}

function SettingLedgerRow({
  icon,
  label,
  detail,
  value,
  action,
  emphasis = false,
}: {
  icon: ReactNode;
  label: string;
  detail: string;
  value: string;
  action?: ReactNode;
  emphasis?: boolean;
}) {
  return (
    <div className="grid gap-token-4 border-t border-glass-line py-token-4 first:border-t-0 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
      <div className="flex min-w-0 items-start gap-token-3">
        <LedgerIcon>{icon}</LedgerIcon>
        <div className="min-w-0">
          <p className="text-sm font-medium text-content-bright">{label}</p>
          <p
            className={cn(
              "mt-1 leading-6",
              emphasis
                ? "break-all font-mono text-sm text-content-bright"
                : "text-sm text-content-mute",
            )}
          >
            {detail}
          </p>
        </div>
      </div>
      <div className="flex items-center gap-token-3 justify-self-start md:justify-self-end">
        <span className="font-mono text-xs uppercase tracking-[0.12em] text-content-dim">
          {value}
        </span>
        {action}
      </div>
    </div>
  );
}

function LedgerIcon({ children }: { children: ReactNode }) {
  return (
    <span className="mt-0.5 grid size-8 shrink-0 place-items-center border border-glass-line bg-mercury-wash text-[color:var(--accent)]">
      {children}
    </span>
  );
}

function providerLabel(providerId: string): string {
  switch (providerId) {
    case "apple.com":
      return "Apple";
    case "google.com":
      return "Google";
    case "password":
      return "Email";
    default:
      return providerId;
  }
}
