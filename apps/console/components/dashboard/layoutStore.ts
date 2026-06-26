/**
 * Versioned persistence for the dashboard: which cards are placed, their grid
 * rects, and the appearance (kernel + frost). Stored as one JSON document in
 * localStorage.
 *
 * Everything is defensive: untrusted stored JSON is sanitized against the set
 * of currently-valid card/kernel ids and clamped to the grid, so a stale or
 * tampered payload can never crash the dashboard — it degrades to the
 * fallback. The storage handle is injected (StorageLike) so this is unit-
 * testable and safe to call when localStorage is unavailable (SSR, private
 * mode, blocked cookies).
 */

import { clampRect, type GridRect } from "./gridMath";

export const DASHBOARD_STORAGE_KEY = "burnbar.console.dashboard.v1";
export const LAYOUT_SCHEMA_VERSION = 1;

export interface DashboardLayoutItem {
  cardId: string;
  rect: GridRect;
}

export interface DashboardAppearance {
  kernelId: string;
  /** 0 (full frost) .. 1 (clear). */
  frost: number;
}

export interface DashboardState {
  version: number;
  items: DashboardLayoutItem[];
  appearance: DashboardAppearance;
}

export interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export interface SanitizeContext {
  validCardIds: ReadonlySet<string>;
  validKernelIds: ReadonlySet<string>;
  fallback: DashboardState;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function clampFrost(value: unknown, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(1, Math.max(0, value));
}

function sanitizeRect(value: unknown): GridRect | null {
  if (!isRecord(value)) return null;
  const { x, y, w, h } = value;
  if (
    typeof x !== "number" ||
    typeof y !== "number" ||
    typeof w !== "number" ||
    typeof h !== "number" ||
    ![x, y, w, h].every(Number.isFinite)
  ) {
    return null;
  }
  return clampRect({ x, y, w, h });
}

function sanitizeItems(
  value: unknown,
  validCardIds: ReadonlySet<string>,
): DashboardLayoutItem[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const items: DashboardLayoutItem[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) continue;
    const cardId = entry.cardId;
    if (typeof cardId !== "string" || !validCardIds.has(cardId)) continue;
    if (seen.has(cardId)) continue; // a card appears at most once on the grid
    const rect = sanitizeRect(entry.rect);
    if (!rect) continue;
    seen.add(cardId);
    items.push({ cardId, rect });
  }
  return items;
}

/** Coerce arbitrary parsed JSON into a valid DashboardState. */
export function sanitizeState(raw: unknown, ctx: SanitizeContext): DashboardState {
  if (!isRecord(raw)) return ctx.fallback;

  const items = sanitizeItems(raw.items, ctx.validCardIds);

  const appearanceRaw = isRecord(raw.appearance) ? raw.appearance : {};
  const kernelId =
    typeof appearanceRaw.kernelId === "string" &&
    ctx.validKernelIds.has(appearanceRaw.kernelId)
      ? appearanceRaw.kernelId
      : ctx.fallback.appearance.kernelId;
  const frost = clampFrost(appearanceRaw.frost, ctx.fallback.appearance.frost);

  // If nothing valid survived, fall back to the default layout rather than an
  // empty dashboard (an all-invalid payload is treated as "no saved state").
  if (items.length === 0) {
    return {
      version: LAYOUT_SCHEMA_VERSION,
      items: ctx.fallback.items,
      appearance: { kernelId, frost },
    };
  }

  return {
    version: LAYOUT_SCHEMA_VERSION,
    items,
    appearance: { kernelId, frost },
  };
}

export function loadDashboardState(
  storage: StorageLike | null,
  ctx: SanitizeContext,
): DashboardState {
  if (!storage) return ctx.fallback;
  let raw: string | null;
  try {
    raw = storage.getItem(DASHBOARD_STORAGE_KEY);
  } catch {
    return ctx.fallback;
  }
  if (!raw) return ctx.fallback;
  try {
    return sanitizeState(JSON.parse(raw), ctx);
  } catch {
    return ctx.fallback;
  }
}

export function saveDashboardState(
  storage: StorageLike | null,
  state: DashboardState,
): void {
  if (!storage) return;
  try {
    storage.setItem(
      DASHBOARD_STORAGE_KEY,
      JSON.stringify({ ...state, version: LAYOUT_SCHEMA_VERSION }),
    );
  } catch {
    // Quota / private-mode failures are non-fatal — the live layout still works.
  }
}

export function resetDashboardState(storage: StorageLike | null): void {
  if (!storage) return;
  try {
    storage.removeItem(DASHBOARD_STORAGE_KEY);
  } catch {
    // ignore
  }
}

/** localStorage if usable, else null (SSR / blocked / private mode). */
export function safeLocalStorage(): StorageLike | null {
  try {
    if (typeof window === "undefined" || !window.localStorage) return null;
    return window.localStorage;
  } catch {
    return null;
  }
}
