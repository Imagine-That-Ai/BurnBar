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
];

export function AppShell({ children }: { children: React.ReactNode }) {
  const { user, signOut } = useAuth();
  const pathname = usePathname();

  return (
    <div className="min-h-dvh">
      <header className="sticky top-0 z-40 border-b border-glass-line bg-[color:var(--color-ink-void)]/85 backdrop-blur-sm">
        <div className="mx-auto flex max-w-5xl items-center justify-between gap-token-4 px-token-6 py-token-4">
          <Link href="/" className="group flex items-center gap-token-2">
            <span
              className="size-2 rounded-[2px]"
              style={{ background: "var(--accent)" }}
              aria-hidden
            />
            <span className="font-display text-[0.95rem] font-semibold tracking-[-0.02em] text-content-bright">
              BurnBar <span className="font-normal text-content-mute">Console</span>
            </span>
          </Link>

          <nav className="hidden items-center gap-token-6 md:flex">
            {NAV.map((item) => {
              const active = pathname === item.href;
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className={cn(
                    "relative py-1 text-sm transition-colors duration-150",
                    active
                      ? "text-content-bright"
                      : "text-content-mute hover:text-content-bright",
                  )}
                >
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
