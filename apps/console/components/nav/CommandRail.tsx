"use client";

import * as React from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Menu, Search, X } from "lucide-react";

import { useAuth } from "@/lib/useAuth";
import { Button } from "@/components/ui/button";
import { PanicButton } from "@/components/PanicButton";
import { ThemeMenu } from "@/components/ThemeMenu";
import { cn } from "@/lib/utils";
import { isNavActive, NAV_GROUPS } from "./navModel";

/**
 * The Command Rail — the console's one navigation surface. A slim left rail
 * on desktop (md+), a slim top bar + slide-over drawer with the SAME content
 * on mobile. Destinations group by intent (Observe · Vault · System); Panic
 * is quarantined at the bottom, visibly outside the navigation's weight class.
 */
export function CommandRail({ onOpenPalette }: { onOpenPalette: () => void }) {
  const [drawerOpen, setDrawerOpen] = React.useState(false);

  // Escape closes the drawer; lock body scroll while it is open.
  React.useEffect(() => {
    if (!drawerOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setDrawerOpen(false);
    };
    document.addEventListener("keydown", onKey);
    document.documentElement.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.documentElement.style.overflow = "";
    };
  }, [drawerOpen]);

  return (
    <>
      {/* Desktop rail */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-60 flex-col border-r border-glass-line bg-[color:var(--color-ink-void)]/80 backdrop-blur-md md:flex">
        <RailBody onOpenPalette={onOpenPalette} />
      </aside>

      {/* Mobile top bar — brand + the only two controls that matter */}
      <div className="sticky top-0 z-40 border-b border-glass-line bg-[color:var(--color-ink-void)]/85 backdrop-blur-md md:hidden">
        <div className="flex items-center justify-between px-token-4 py-2">
          <Brand />
          <button
            type="button"
            onClick={() => setDrawerOpen(true)}
            aria-label="Open navigation"
            aria-expanded={drawerOpen}
            className="rounded-md p-1.5 text-content-mute transition-colors hover:bg-mercury-wash hover:text-content-bright"
          >
            <Menu size={18} aria-hidden />
          </button>
        </div>
      </div>

      {/* Mobile drawer — the same rail, sliding over. z-[60]: sits above the
          z-50 ConsentBanner, which follows the rail in DOM order. */}
      {drawerOpen && (
        <div className="fixed inset-0 z-[60] md:hidden">
          <div
            className="absolute inset-0 bg-black/50 backdrop-blur-sm"
            onClick={() => setDrawerOpen(false)}
            aria-hidden
          />
          <aside
            role="dialog"
            aria-modal="true"
            aria-label="Navigation"
            className="animate-in slide-in-from-left absolute inset-y-0 left-0 flex w-72 max-w-[85vw] flex-col border-r border-glass-line-bright bg-[color:var(--color-ink-void)]/95 backdrop-blur-xl duration-200"
          >
            <div className="absolute right-2 top-2.5">
              <button
                type="button"
                onClick={() => setDrawerOpen(false)}
                aria-label="Close navigation"
                className="rounded-md p-1.5 text-content-mute transition-colors hover:bg-mercury-wash hover:text-content-bright"
              >
                <X size={18} aria-hidden />
              </button>
            </div>
            <RailBody onOpenPalette={onOpenPalette} onNavigate={() => setDrawerOpen(false)} />
          </aside>
        </div>
      )}
    </>
  );
}

function Brand() {
  return (
    <Link href="/" className="flex items-center gap-2.5 px-1">
      {/* The flame mark is full-colour, so it reads on every theme — no tile,
          no hairline, just the mark itself carrying the rail header. */}
      <img src="/brand/burnbar-logo-mark.png" alt="" className="size-8 shrink-0 object-contain" />
      <span className="nameplate text-[15px] text-content-bright">
        BurnBar <span className="text-[13px] font-normal text-content-mute">Console</span>
      </span>
    </Link>
  );
}

function RailBody({
  onOpenPalette,
  onNavigate,
}: {
  onOpenPalette: () => void;
  onNavigate?: () => void;
}) {
  const pathname = usePathname();
  const { user, signOut } = useAuth();
  const [avatarFailed, setAvatarFailed] = React.useState(false);

  return (
    <>
      <div className="px-3 pb-3 pt-4">
        <Brand />
      </div>

      <div className="px-3 pb-3">
        <button
          type="button"
          onClick={onOpenPalette}
          className="flex w-full items-center gap-2 rounded-md border border-glass-line px-2.5 py-1.5 text-xs text-content-dim transition-colors hover:border-glass-line-bright hover:text-content-bright"
        >
          <Search size={13} aria-hidden />
          Jump to…
          <kbd className="ml-auto rounded border border-glass-line px-1 py-px font-mono text-[10px]">⌘K</kbd>
        </button>
      </div>

      <nav aria-label="Console" className="flex-1 space-y-5 overflow-y-auto px-3 py-1">
        {NAV_GROUPS.map((group) => (
          <div key={group.id}>
            <p className="eyebrow px-2.5 pb-1.5 text-[0.62rem]">{group.label}</p>
            <ul className="space-y-0.5">
              {group.items.map((item) => {
                const active = isNavActive(pathname, item.href);
                const Icon = item.icon;
                return (
                  <li key={item.href}>
                    <Link
                      href={item.href}
                      onClick={onNavigate}
                      aria-current={active ? "page" : undefined}
                      className={cn(
                        "relative flex items-center gap-2.5 rounded-md px-2.5 py-1.5 text-[13.5px] transition-colors duration-150",
                        active
                          ? "bg-[color:var(--accent-wash)] text-content-bright"
                          : "text-content-mute hover:bg-mercury-wash hover:text-content-bright",
                      )}
                    >
                      {active && (
                        <span
                          aria-hidden
                          className="absolute bottom-[7px] left-0 top-[7px] w-[2.5px] rounded-full"
                          style={{ background: "var(--accent)" }}
                        />
                      )}
                      <Icon
                        size={15}
                        strokeWidth={1.8}
                        aria-hidden
                        className={active ? "text-[color:var(--accent)]" : "opacity-70"}
                      />
                      {item.label}
                    </Link>
                  </li>
                );
              })}
            </ul>
          </div>
        ))}
      </nav>

      <div className="border-t border-glass-line px-3 py-3">
        {user && (
          <Link
            href="/profile"
            onClick={onNavigate}
            className="mb-2 flex items-center gap-2.5 rounded-md px-1.5 py-1.5 transition-colors hover:bg-mercury-wash"
          >
            {user.photoURL && !avatarFailed ? (
              <img
                src={user.photoURL}
                alt=""
                referrerPolicy="no-referrer"
                onError={() => setAvatarFailed(true)}
                className="size-[26px] shrink-0 rounded-full"
              />
            ) : (
              <span
                aria-hidden
                className="grid size-[26px] shrink-0 place-items-center rounded-full bg-[color:var(--accent-wash)] font-mono text-[11px] text-[color:var(--accent)]"
              >
                {(user.displayName ?? user.email ?? "M").charAt(0).toUpperCase()}
              </span>
            )}
            <span className="min-w-0">
              <span className="block truncate text-[13px] font-medium text-content-bright">
                {user.displayName ?? "Member"}
              </span>
              <span className="block truncate font-mono text-[10.5px] text-content-dim">
                {user.email}
              </span>
            </span>
          </Link>
        )}
        <div className="flex items-center justify-between gap-1.5">
          <ThemeMenu direction="up" />
          {user && (
            <Button variant="ghost" size="sm" onClick={() => signOut()}>
              Sign out
            </Button>
          )}
        </div>
        {user && (
          <div className="pt-2 [&_button]:w-full [&_button]:justify-center">
            <PanicButton />
          </div>
        )}
      </div>
    </>
  );
}
