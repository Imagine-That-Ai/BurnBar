/**
 * @fileoverview Memory Power-Up pack catalog.
 *
 * Packs are prepaid token wallets, not entitlements. They never unlock a
 * membership tier. Product IDs are the commercial contract; list prices in
 * this file are documentation + anti-typo floors, never charged by clients.
 */

import { getConfig } from "../config.js";

export const MEMORY_PACK_IDS = ["text_1m", "text_5m", "vision_1m"] as const;
export type MemoryPackId = (typeof MEMORY_PACK_IDS)[number];
export type MemoryLane = "text" | "multimodal";
export type MemoryPackSource = "stripe" | "app_store" | "google_play";

export const MEMORY_PACK_SCHEMA_VERSION = 1;
export const MEMORY_PACK_TTL_MS = 365 * 24 * 60 * 60 * 1000;

export interface MemoryPackDefinition {
  packId: MemoryPackId;
  lane: MemoryLane;
  tokens: number;
  /** Documented USD cents. Clients must show StoreKit / Play / Stripe localized prices. */
  listPriceMinor: number;
  /** Server refuses a Stripe grant below this amount_total (anti-typo). */
  minChargeMinor: number;
  appleProductID: string;
  playProductID: string;
  stripeLookupKey: string;
  title: string;
  cadence: string;
  requiresVisionEntitlement: boolean;
}

export const DEFAULT_MEMORY_PACKS: Record<MemoryPackId, MemoryPackDefinition> = {
  text_1m: {
    packId: "text_1m",
    lane: "text",
    tokens: 1_000_000,
    listPriceMinor: 299,
    minChargeMinor: 200,
    appleProductID: "com.openburnbar.memory.boost.text.1m",
    playProductID: "com.openburnbar.memory.boost.text.1m",
    stripeLookupKey: "memory_boost_text_1m",
    title: "1M text tokens",
    cadence: "Prepaid · expires in 12 months",
    requiresVisionEntitlement: false,
  },
  text_5m: {
    packId: "text_5m",
    lane: "text",
    tokens: 5_000_000,
    listPriceMinor: 999,
    minChargeMinor: 700,
    appleProductID: "com.openburnbar.memory.boost.text.5m",
    playProductID: "com.openburnbar.memory.boost.text.5m",
    stripeLookupKey: "memory_boost_text_5m",
    title: "5M text tokens",
    cadence: "Prepaid · expires in 12 months",
    requiresVisionEntitlement: false,
  },
  vision_1m: {
    packId: "vision_1m",
    lane: "multimodal",
    tokens: 1_000_000,
    listPriceMinor: 699,
    minChargeMinor: 500,
    appleProductID: "com.openburnbar.memory.boost.vision.1m",
    playProductID: "com.openburnbar.memory.boost.vision.1m",
    stripeLookupKey: "memory_boost_vision_1m",
    title: "1M vision tokens",
    cadence: "Cloud Pro or Ultra · expires in 12 months",
    requiresVisionEntitlement: true,
  },
};

export function isMemoryPackId(value: unknown): value is MemoryPackId {
  return value === "text_1m" || value === "text_5m" || value === "vision_1m";
}

export function isMemoryLane(value: unknown): value is MemoryLane {
  return value === "text" || value === "multimodal";
}

export function defaultMemoryPack(packId: MemoryPackId): MemoryPackDefinition {
  return DEFAULT_MEMORY_PACKS[packId];
}

export interface MemoryPackRuntimeIds {
  appleProductID: string;
  playProductID: string;
  stripePriceID: string;
}

export function memoryPackRuntimeIds(packId: MemoryPackId): MemoryPackRuntimeIds {
  const cfg = getConfig();
  switch (packId) {
    case "text_1m":
      return {
        appleProductID: cfg.memoryBoostText1mProductID,
        playProductID: cfg.googlePlayMemoryBoostText1mProductID,
        stripePriceID: cfg.stripeMemoryBoostText1mPriceID,
      };
    case "text_5m":
      return {
        appleProductID: cfg.memoryBoostText5mProductID,
        playProductID: cfg.googlePlayMemoryBoostText5mProductID,
        stripePriceID: cfg.stripeMemoryBoostText5mPriceID,
      };
    case "vision_1m":
      return {
        appleProductID: cfg.memoryBoostVision1mProductID,
        playProductID: cfg.googlePlayMemoryBoostVision1mProductID,
        stripePriceID: cfg.stripeMemoryBoostVision1mPriceID,
      };
  }
}

export function memoryPackFromAppleProductID(productID: string): MemoryPackId | undefined {
  const cfg = getConfig();
  if (productID === cfg.memoryBoostText1mProductID || productID === DEFAULT_MEMORY_PACKS.text_1m.appleProductID) {
    return "text_1m";
  }
  if (productID === cfg.memoryBoostText5mProductID || productID === DEFAULT_MEMORY_PACKS.text_5m.appleProductID) {
    return "text_5m";
  }
  if (productID === cfg.memoryBoostVision1mProductID || productID === DEFAULT_MEMORY_PACKS.vision_1m.appleProductID) {
    return "vision_1m";
  }
  return undefined;
}

export function memoryPackFromPlayProductID(productID: string): MemoryPackId | undefined {
  const cfg = getConfig();
  if (
    productID === cfg.googlePlayMemoryBoostText1mProductID ||
    productID === DEFAULT_MEMORY_PACKS.text_1m.playProductID
  ) {
    return "text_1m";
  }
  if (
    productID === cfg.googlePlayMemoryBoostText5mProductID ||
    productID === DEFAULT_MEMORY_PACKS.text_5m.playProductID
  ) {
    return "text_5m";
  }
  if (
    productID === cfg.googlePlayMemoryBoostVision1mProductID ||
    productID === DEFAULT_MEMORY_PACKS.vision_1m.playProductID
  ) {
    return "vision_1m";
  }
  return undefined;
}

export function memoryPackFromStripePriceID(priceID: string): MemoryPackId | undefined {
  if (!priceID) return undefined;
  const cfg = getConfig();
  if (priceID === cfg.stripeMemoryBoostText1mPriceID) return "text_1m";
  if (priceID === cfg.stripeMemoryBoostText5mPriceID) return "text_5m";
  if (priceID === cfg.stripeMemoryBoostVision1mPriceID) return "vision_1m";
  return undefined;
}

export function isMemoryPackProductID(productID: string): boolean {
  return memoryPackFromAppleProductID(productID) !== undefined || memoryPackFromPlayProductID(productID) !== undefined;
}
