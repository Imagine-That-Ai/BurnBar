"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Flame } from "lucide-react";
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
      <header className="sticky top-0 z-40 border-b border-glass-line bg-ink-base/70 backdrop-blur-xl">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-token-4 px-token-4 py-token-3">
          <Link href="/" className="flex items-center gap-token-2">
            <Flame className="size-5 text-brass-core" />
            <span className="font-display text-content-bright">
              BurnBar <span className="text-content-mute">Console</span>
            </span>
          </Link>

          <nav className="hidden items-center gap-1 md:flex">
            {NAV.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "rounded-md px-token-3 py-token-2 text-sm transition-colors duration-150 ease-standard",
                  pathname === item.href
                    ? "bg-mercury-wash text-content-bright"
                    : "text-content-mute hover:text-content-base",
                )}
              >
                {item.label}
              </Link>
            ))}
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

      <main className="mx-auto max-w-6xl px-token-4 py-token-8">{children}</main>

      <footer className="border-t border-glass-line px-token-4 py-token-6 text-center text-xs text-content-dim">
        Your data, your keys. The server never sees your sealed content.
      </footer>
    </div>
  );
}
