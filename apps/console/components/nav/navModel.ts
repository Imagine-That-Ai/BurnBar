import type { LucideIcon } from "lucide-react";
import {
  Boxes,
  Brain,
  FlaskConical,
  Home,
  KeyRound,
  LayoutDashboard,
  Settings2,
  UserRound,
} from "lucide-react";

/**
 * The console's destination model — one source of truth for the CommandRail
 * and the ⌘K CommandPalette. Destinations are grouped by INTENT, not by the
 * order routes happen to exist: Observe is where you look, Vault is where
 * your data and keys live, System is configuration. Add a route here and it
 * appears in both surfaces.
 */
export interface NavItem {
  href: string;
  label: string;
  icon: LucideIcon;
  /** Extra ⌘K search terms beyond the label. */
  keywords: string[];
}

export interface NavGroup {
  id: string;
  label: string;
  items: NavItem[];
}

export const NAV_GROUPS: NavGroup[] = [
  {
    id: "observe",
    label: "Observe",
    items: [
      { href: "/profile", label: "Profile", icon: UserRound, keywords: ["usage", "stats", "tokens", "me"] },
      { href: "/", label: "Basin", icon: Home, keywords: ["home", "overview", "landing"] },
      { href: "/dashboard", label: "Studio", icon: LayoutDashboard, keywords: ["dashboard", "canvas", "glass"] },
    ],
  },
  {
    id: "vault",
    label: "Vault",
    items: [
      { href: "/inventory", label: "Inventory", icon: Boxes, keywords: ["data", "footprint", "files"] },
      { href: "/pensieve", label: "Pensieve", icon: Brain, keywords: ["memory", "memories", "recall"] },
      { href: "/escrow", label: "Trust", icon: KeyRound, keywords: ["escrow", "keys", "devices", "recovery"] },
    ],
  },
  {
    id: "system",
    label: "System",
    items: [
      { href: "/experimental", label: "Experimental", icon: FlaskConical, keywords: ["labs", "beta", "flags"] },
      { href: "/settings", label: "Settings", icon: Settings2, keywords: ["preferences", "config", "options"] },
    ],
  },
];

/** Every console route is a single top-level segment, so exact match is exact. */
export function isNavActive(pathname: string, href: string): boolean {
  return pathname === href;
}

/**
 * One row in the ⌘K palette. `id` names the action: a route href for
 * destinations, `theme:<id>` for theme picks, `action:<name>` for verbs.
 * The palette component owns execution; this stays pure so it is testable.
 */
export interface PaletteEntry {
  id: string;
  label: string;
  /** Section heading the row renders under. */
  group: string;
  /** Right-aligned hint (href, current value, …). */
  hint?: string;
  icon?: LucideIcon;
  keywords: string[];
}

export function navPaletteEntries(): PaletteEntry[] {
  return NAV_GROUPS.flatMap((group) =>
    group.items.map((item) => ({
      id: item.href,
      label: item.label,
      group: group.label,
      hint: item.href,
      icon: item.icon,
      keywords: item.keywords,
    })),
  );
}

function matchScore(entry: PaletteEntry, query: string): number | null {
  const label = entry.label.toLowerCase();
  if (label.startsWith(query)) return 0;
  if (label.includes(query)) return 1;
  for (const kw of entry.keywords) {
    if (kw.startsWith(query)) return 2;
    if (kw.includes(query)) return 3;
  }
  return null;
}

/**
 * Substring filter with simple ranking: label prefix > label substring >
 * keyword prefix > keyword substring. Stable within a score — group order
 * survives, so results read in the same Observe → Vault → System rhythm.
 */
export function filterPaletteEntries(entries: PaletteEntry[], query: string): PaletteEntry[] {
  const q = query.trim().toLowerCase();
  if (!q) return entries;
  return entries
    .map((entry, index) => ({ entry, index, score: matchScore(entry, q) }))
    .filter((r): r is { entry: PaletteEntry; index: number; score: number } => r.score !== null)
    .sort((a, b) => a.score - b.score || a.index - b.index)
    .map((r) => r.entry);
}

/** Group filtered entries back into sections, preserving first-seen order. */
export function groupPaletteEntries(entries: PaletteEntry[]): [string, PaletteEntry[]][] {
  const groups: [string, PaletteEntry[]][] = [];
  for (const entry of entries) {
    const existing = groups.find(([label]) => label === entry.group);
    if (existing) existing[1].push(entry);
    else groups.push([entry.group, [entry]]);
  }
  return groups;
}
