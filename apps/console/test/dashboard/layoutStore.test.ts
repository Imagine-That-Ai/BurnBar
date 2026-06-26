import { describe, expect, it } from "vitest";

import {
  DASHBOARD_STORAGE_KEY,
  LAYOUT_SCHEMA_VERSION,
  loadDashboardState,
  resetDashboardState,
  sanitizeState,
  saveDashboardState,
  type DashboardState,
  type SanitizeContext,
  type StorageLike,
} from "@/components/dashboard/layoutStore";

function memoryStorage(): StorageLike & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return {
    map,
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => void map.set(k, v),
    removeItem: (k) => void map.delete(k),
  };
}

const FALLBACK: DashboardState = {
  version: LAYOUT_SCHEMA_VERSION,
  items: [{ cardId: "burn", rect: { x: 0, y: 0, w: 4, h: 3 } }],
  appearance: { kernelId: "liquidGlass", frost: 0.5 },
};

const CTX: SanitizeContext = {
  validCardIds: new Set(["burn", "tokens", "cache"]),
  validKernelIds: new Set(["liquidGlass", "aurora"]),
  fallback: FALLBACK,
};

describe("sanitizeState", () => {
  it("drops unknown card ids and clamps rects", () => {
    const out = sanitizeState(
      {
        items: [
          { cardId: "burn", rect: { x: 99, y: 0, w: 99, h: 1 } },
          { cardId: "not-a-card", rect: { x: 0, y: 0, w: 3, h: 2 } },
        ],
        appearance: { kernelId: "aurora", frost: 0.2 },
      },
      CTX,
    );
    expect(out.items.map((i) => i.cardId)).toEqual(["burn"]);
    const rect = out.items[0]!.rect;
    expect(rect.x + rect.w).toBeLessThanOrEqual(12);
    expect(out.appearance.kernelId).toBe("aurora");
    expect(out.appearance.frost).toBe(0.2);
  });

  it("dedupes a card that appears twice", () => {
    const out = sanitizeState(
      {
        items: [
          { cardId: "burn", rect: { x: 0, y: 0, w: 4, h: 3 } },
          { cardId: "burn", rect: { x: 1, y: 1, w: 4, h: 3 } },
        ],
        appearance: { kernelId: "liquidGlass", frost: 0.5 },
      },
      CTX,
    );
    expect(out.items).toHaveLength(1);
  });

  it("falls back to default items when nothing valid survives", () => {
    const out = sanitizeState({ items: [{ cardId: "bogus" }], appearance: {} }, CTX);
    expect(out.items).toEqual(FALLBACK.items);
  });

  it("clamps frost and rejects unknown kernel ids", () => {
    const out = sanitizeState(
      { items: FALLBACK.items, appearance: { kernelId: "nope", frost: 5 } },
      CTX,
    );
    expect(out.appearance.kernelId).toBe(FALLBACK.appearance.kernelId);
    expect(out.appearance.frost).toBe(1);
  });

  it("returns fallback for non-object input", () => {
    expect(sanitizeState(null, CTX)).toBe(FALLBACK);
    expect(sanitizeState("garbage", CTX)).toBe(FALLBACK);
  });

  it("always stamps the current schema version", () => {
    const out = sanitizeState({ version: 0, items: FALLBACK.items, appearance: {} }, CTX);
    expect(out.version).toBe(LAYOUT_SCHEMA_VERSION);
  });
});

describe("persistence round trip", () => {
  it("saves and loads a state", () => {
    const storage = memoryStorage();
    const state: DashboardState = {
      version: LAYOUT_SCHEMA_VERSION,
      items: [{ cardId: "tokens", rect: { x: 0, y: 0, w: 3, h: 2 } }],
      appearance: { kernelId: "aurora", frost: 0.8 },
    };
    saveDashboardState(storage, state);
    const loaded = loadDashboardState(storage, CTX);
    expect(loaded.items.map((i) => i.cardId)).toEqual(["tokens"]);
    expect(loaded.appearance.kernelId).toBe("aurora");
    expect(loaded.appearance.frost).toBe(0.8);
  });

  it("returns fallback when storage is null (SSR)", () => {
    expect(loadDashboardState(null, CTX)).toBe(FALLBACK);
  });

  it("returns fallback on corrupt JSON", () => {
    const storage = memoryStorage();
    storage.map.set(DASHBOARD_STORAGE_KEY, "{not json");
    expect(loadDashboardState(storage, CTX)).toBe(FALLBACK);
  });

  it("reset clears the key", () => {
    const storage = memoryStorage();
    saveDashboardState(storage, FALLBACK);
    resetDashboardState(storage);
    expect(storage.map.has(DASHBOARD_STORAGE_KEY)).toBe(false);
  });
});
