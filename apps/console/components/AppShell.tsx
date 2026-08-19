"use client";

import * as React from "react";
import { usePathname } from "next/navigation";
import { GlobalBackdrop } from "@/components/GlobalBackdrop";
import { ConsentBanner } from "@/components/analytics/ConsentBanner";
import { CommandRail } from "@/components/nav/CommandRail";
import { CommandPalette } from "@/components/nav/CommandPalette";
import { cn } from "@/lib/utils";

/**
 * Shell layout: the Command Rail owns navigation (left rail on desktop,
 * top bar + drawer on mobile); ⌘K / Ctrl+K toggles the CommandPalette from
 * anywhere. The Studio dashboard stays full-bleed; every other route keeps
 * the left-aligned reading column, shifted right of the rail on desktop.
 */
export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const [paletteOpen, setPaletteOpen] = React.useState(false);

  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((v) => !v);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="min-h-dvh">
      <GlobalBackdrop />
      <CommandRail onOpenPalette={() => setPaletteOpen(true)} />

      <div className="flex min-h-dvh flex-col md:pl-60">
        <main
          className={cn(
            "w-full flex-1",
            // The Studio dashboard is a full-bleed glass surface; every other
            // route keeps a left-aligned reading column (console convention —
            // Linear/Vercel/Codex — not a centered editorial page).
            pathname === "/dashboard"
              ? "max-w-none px-token-6 py-token-6"
              : "max-w-5xl px-token-6 py-token-12 md:px-token-12 2xl:max-w-6xl",
          )}
        >
          {children}
        </main>

        <footer className="w-full max-w-5xl px-token-6 pb-token-8 md:px-token-12 2xl:max-w-6xl">
          <hr className="rule mb-token-4" />
          <p className="font-mono text-xs tracking-[0.04em] text-content-dim">
            Your data, your keys. The server never sees your sealed content.
          </p>
        </footer>
      </div>

      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} />
      <ConsentBanner />
    </div>
  );
}
