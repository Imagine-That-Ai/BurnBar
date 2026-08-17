"use client";

import * as React from "react";
import * as DialogPrimitive from "@radix-ui/react-dialog";
import { useRouter } from "next/navigation";
import { LogOut, Palette, Search } from "lucide-react";

import { useAuth } from "@/lib/useAuth";
import { THEMES, useTheme, type ThemeId } from "@/lib/useTheme";
import { cn } from "@/lib/utils";
import {
  filterPaletteEntries,
  groupPaletteEntries,
  navPaletteEntries,
  type PaletteEntry,
} from "./navModel";

/**
 * ⌘K command palette — every destination, every theme, and Sign out, one
 * fuzzy keystroke away. Execution is keyed off PaletteEntry.id: a route href
 * navigates, `theme:<id>` reskins the console, `action:sign-out` signs out.
 */
export function CommandPalette({
  open,
  onClose,
}: {
  open: boolean;
  onClose: () => void;
}) {
  const router = useRouter();
  const { signOut } = useAuth();
  const { theme, setTheme } = useTheme();
  const [query, setQuery] = React.useState("");
  const [selected, setSelected] = React.useState(0);
  const listRef = React.useRef<HTMLDivElement>(null);

  const entries = React.useMemo<PaletteEntry[]>(() => {
    const themeEntries: PaletteEntry[] = THEMES.map((t) => ({
      id: `theme:${t.id}`,
      label: `Theme: ${t.label}`,
      group: "Appearance",
      hint: t.id === theme ? "current" : t.scheme,
      icon: Palette,
      keywords: ["theme", "appearance", "color", t.id, t.scheme],
    }));
    return [
      ...navPaletteEntries(),
      ...themeEntries,
      {
        id: "action:sign-out",
        label: "Sign out",
        group: "Account",
        icon: LogOut,
        keywords: ["logout", "log out", "exit", "leave"],
      },
    ];
  }, [theme]);

  const filtered = React.useMemo(() => filterPaletteEntries(entries, query), [entries, query]);
  const sections = React.useMemo(() => groupPaletteEntries(filtered), [filtered]);

  // Fresh state each time the palette opens.
  React.useEffect(() => {
    if (open) {
      setQuery("");
      setSelected(0);
    }
  }, [open]);

  // Clamp the selection when filtering shrinks the list.
  React.useEffect(() => {
    setSelected((i) => Math.min(i, Math.max(0, filtered.length - 1)));
  }, [filtered.length]);

  const run = React.useCallback(
    (entry: PaletteEntry) => {
      onClose();
      if (entry.id.startsWith("theme:")) {
        setTheme(entry.id.slice("theme:".length) as ThemeId);
      } else if (entry.id === "action:sign-out") {
        void signOut();
      } else {
        router.push(entry.id);
      }
    },
    [onClose, router, setTheme, signOut],
  );

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (filtered.length === 0) return;
      const delta = e.key === "ArrowDown" ? 1 : -1;
      const next = (selected + delta + filtered.length) % filtered.length;
      setSelected(next);
      listRef.current
        ?.querySelector(`[data-index="${next}"]`)
        ?.scrollIntoView({ block: "nearest" });
    } else if (e.key === "Enter") {
      e.preventDefault();
      const entry = filtered[selected];
      if (entry) run(entry);
    }
  };

  let flatIndex = -1;

  return (
    <DialogPrimitive.Root open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="fixed inset-0 z-50 bg-black/40 backdrop-blur-sm data-[state=open]:animate-in data-[state=open]:fade-in-0" />
        <DialogPrimitive.Content
          aria-label="Command palette"
          className="glass-pane glass-pane--elevated fixed left-1/2 top-[14vh] z-50 w-[calc(100vw-2rem)] max-w-xl -translate-x-1/2 overflow-hidden p-0 data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:zoom-in-95"
          onKeyDown={onKeyDown}
        >
          <DialogPrimitive.Title className="sr-only">Command palette</DialogPrimitive.Title>
          <DialogPrimitive.Description className="sr-only">
            Jump to a destination, switch theme, or sign out.
          </DialogPrimitive.Description>

          <div className="flex items-center gap-2.5 border-b border-glass-line px-4 py-3">
            <Search size={15} aria-hidden className="shrink-0 text-content-dim" />
            <input
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setSelected(0);
              }}
              placeholder="Jump to a page, theme, or action…"
              aria-label="Search destinations and actions"
              className="w-full bg-transparent text-sm text-content-bright outline-none placeholder:text-content-dim"
            />
            <kbd className="folio shrink-0 rounded border border-glass-line px-1.5 py-0.5">esc</kbd>
          </div>

          <div ref={listRef} role="listbox" aria-label="Results" className="max-h-[50vh] overflow-y-auto py-1.5">
            {filtered.length === 0 ? (
              <p className="px-4 py-6 text-center text-sm text-content-dim">
                No matches — try a destination, theme, or action.
              </p>
            ) : (
              sections.map(([group, rows]) => (
                <div key={group}>
                  <p className="eyebrow px-4 pb-1 pt-2.5 text-[0.62rem]">{group}</p>
                  {rows.map((entry) => {
                    flatIndex += 1;
                    const index = flatIndex;
                    const Icon = entry.icon;
                    return (
                      <button
                        key={entry.id}
                        type="button"
                        role="option"
                        aria-selected={index === selected}
                        data-index={index}
                        onMouseEnter={() => setSelected(index)}
                        onClick={() => run(entry)}
                        className={cn(
                          "flex w-full items-center gap-2.5 px-4 py-2 text-left text-[13.5px] transition-colors duration-100",
                          index === selected
                            ? "bg-[color:var(--accent-wash)] text-content-bright"
                            : "text-content-mute",
                        )}
                      >
                        {Icon && (
                          <Icon
                            size={15}
                            strokeWidth={1.8}
                            aria-hidden
                            className={index === selected ? "text-[color:var(--accent)]" : "opacity-70"}
                          />
                        )}
                        <span className="flex-1">{entry.label}</span>
                        {entry.hint && <span className="font-mono text-[10px] text-content-dim">{entry.hint}</span>}
                      </button>
                    );
                  })}
                </div>
              ))
            )}
          </div>

          <div className="flex gap-4 border-t border-glass-line px-4 py-2.5">
            <span className="folio">↑↓ navigate</span>
            <span className="folio">↵ open</span>
            <span className="folio">esc close</span>
          </div>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
