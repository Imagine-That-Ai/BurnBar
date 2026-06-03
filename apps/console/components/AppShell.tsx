"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAuth } from "@/lib/useAuth";
import { Button } from "@/components/ui/button";
import { PanicButton } from "@/components/PanicButton";
import { cn } from "@/lib/utils";

const NAV = [
  { href: "/", label: "Basin" },
  { href: "/inventory", label: "Inventory" },
  { href: "/pensieve", label: "Pensieve" },
  { href: "/escrow", label: "Trust" },
  { href: "/settings", label: "Settings" },
];

export function AppShell({ children }: { children: React.ReactNode }) {
  const { user, signOut } = useAuth();
  const pathname = usePathname();

  return (
    <div className="min-h-dvh">
      <header className="rule-double sticky top-0 z-40 bg-[color:var(--color-ink-void)]/90 backdrop-blur-sm">
        <div className="border-b border-glass-line">
          <div className="mx-auto flex max-w-5xl items-center justify-between px-token-6 py-1.5">
            <span className="folio">Private — not indexed</span>
            <span className="folio">Your data · your keys</span>
          </div>
        </div>

        <div className="mx-auto flex max-w-5xl items-center justify-between gap-token-4 px-token-6 py-token-3">
          <Link href="/" className="flex items-baseline gap-token-2">
            <span
              className="size-2 translate-y-[-1px] rounded-[2px]"
              style={{ background: "var(--accent)" }}
              aria-hidden
            />
            <span className="nameplate text-lg text-content-bright">
              BurnBar <span className="text-base font-normal text-content-mute">Console</span>
            </span>
          </Link>

          <nav className="hidden items-center gap-token-6 md:flex">
            {NAV.map((item, i) => {
              const active = pathname === item.href;
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className={cn(
                    "relative flex items-baseline gap-1.5 py-1 text-sm transition-colors duration-150",
                    active
                      ? "text-content-bright"
                      : "text-content-mute hover:text-content-bright",
                  )}
                >
                  <span className="font-mono text-[0.62rem] text-content-dim">
                    {String(i + 1).padStart(2, "0")}
                  </span>
                  {item.label}
                  {active && (
                    <span
                      className="absolute inset-x-0 -bottom-px h-px"
                      style={{ background: "var(--accent)" }}
                      aria-hidden
                    />
                  )}
                </Link>
              );
            })}
          </nav>

          <div className="flex items-center gap-token-2">
            {user && <PanicButton />}
            {user && (
              <Button variant="ghost" size="sm" onClick={() => signOut()}>
                Sign out
              </Button>
            )}
          </div>
        </div>

        <nav className="flex items-center gap-token-4 overflow-x-auto border-t border-glass-line px-token-6 py-token-2 md:hidden">
          {NAV.map((item) => {
            const active = pathname === item.href;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "folio whitespace-nowrap",
                  active && "text-[color:var(--accent-deep)]",
                )}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>
      </header>

      <main className="mx-auto max-w-5xl px-token-6 py-token-12">{children}</main>

      <footer className="mx-auto max-w-5xl px-token-6 pb-token-8">
        <hr className="rule mb-token-4" />
        <p className="font-mono text-xs tracking-[0.04em] text-content-dim">
          Your data, your keys. The server never sees your sealed content.
        </p>
      </footer>
    </div>
  );
}
