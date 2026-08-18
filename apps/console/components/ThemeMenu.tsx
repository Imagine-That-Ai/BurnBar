"use client";

import * as React from "react";
import { Check, ChevronDown, Palette } from "lucide-react";

import { THEMES, useTheme } from "@/lib/useTheme";
import { cn } from "@/lib/utils";

/**
 * Header theme switcher: a button showing the current theme, opening a popover
 * of all themes (preview chip + name). Picking one reskins the whole console
 * instantly and persists. Closes on outside-click or Escape.
 *
 * `direction="up"` flips the popover above the trigger and left-aligns it —
 * required in the Command Rail footer, where a downward popover opens past the
 * viewport's bottom edge and becomes unreachable.
 */
export function ThemeMenu({ direction = "down" }: { direction?: "up" | "down" }) {
  const { theme, setTheme } = useTheme();
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);
  const current = THEMES.find((t) => t.id === theme) ?? THEMES[0];

  React.useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={`Theme: ${current.label}`}
        className="flex items-center gap-1.5 rounded-pill py-1 pl-1.5 pr-2 text-xs font-medium text-content-mute transition-colors hover:text-content-bright"
        style={{ border: "1px solid var(--color-glass-line)" }}
      >
        <Palette size={14} aria-hidden />
        <ChipPreview colors={current.preview} />
        <span className="hidden sm:inline">{current.label}</span>
        <ChevronDown size={13} aria-hidden className={open ? "rotate-180 transition-transform" : "transition-transform"} />
      </button>

      {open && (
        <div
          role="menu"
          aria-label="Themes"
          className={cn(
            "glass-pane glass-pane--elevated absolute z-50 w-52 p-1.5",
            direction === "up" ? "bottom-full left-0 mb-2" : "right-0 mt-2",
          )}
        >
          <p className="eyebrow px-2 pb-1 pt-1.5">Theme</p>
          {THEMES.map((t) => {
            const active = t.id === theme;
            return (
              <button
                key={t.id}
                type="button"
                role="menuitemradio"
                aria-checked={active}
                onClick={() => {
                  setTheme(t.id);
                  setOpen(false);
                }}
                className="flex w-full items-center gap-token-2 rounded-md px-2 py-1.5 text-left text-sm text-content-base transition-colors hover:bg-mercury-wash"
              >
                <ChipPreview colors={t.preview} />
                <span className="flex-1">{t.label}</span>
                {active && <Check size={14} aria-hidden className="text-[color:var(--accent-deep)]" />}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

/** Two-tone preview: a surface swatch with an accent corner. */
function ChipPreview({ colors }: { colors: readonly [string, string] | readonly string[] }) {
  const [surface, accent] = colors;
  return (
    <span
      aria-hidden
      className="relative inline-block size-4 shrink-0 overflow-hidden rounded-[5px]"
      style={{ background: surface, boxShadow: "inset 0 0 0 1px rgba(128,128,128,0.35)" }}
    >
      <span
        className="absolute bottom-0 right-0 size-2.5 rounded-tl-[4px]"
        style={{ background: accent }}
      />
    </span>
  );
}
