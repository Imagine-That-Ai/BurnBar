/**
 * @fileoverview Remote Config overlay for Memory Power-Up floors and token sizes.
 *
 * Product IDs stay in Functions config. RC may only tighten floors or hide a
 * pack. Token sizes are not overridable — a bad overlay must not inflate COGS.
 */

import { getRemoteConfig } from "firebase-admin/remote-config";

import { errorMessage, isRecord } from "../guards.js";
import { logWarn } from "../logging.js";
import { remoteConfigStringValue } from "../remoteConfigGuards.js";
import {
  DEFAULT_MEMORY_PACKS,
  MEMORY_PACK_IDS,
  isMemoryPackId,
  type MemoryPackDefinition,
  type MemoryPackId,
} from "./catalog.js";

interface MemoryPackCatalogSnapshot {
  packs: Record<MemoryPackId, MemoryPackDefinition>;
}

function integerOverride(raw: unknown): number | undefined {
  if (typeof raw !== "number" || !Number.isInteger(raw) || raw <= 0) return undefined;
  return raw;
}

function overlayPack(base: MemoryPackDefinition, overlay: unknown): MemoryPackDefinition {
  if (!isRecord(overlay)) return base;
  const minChargeMinor = integerOverride(overlay.minChargeMinor) ?? base.minChargeMinor;
  const hidden = overlay.hidden === true;
  return {
    ...base,
    minChargeMinor: Math.max(minChargeMinor, base.minChargeMinor),
    title: hidden ? "" : base.title,
  };
}

export function normalizeMemoryPackCatalog(raw: unknown): MemoryPackCatalogSnapshot {
  const packs: Record<MemoryPackId, MemoryPackDefinition> = {
    text_1m: DEFAULT_MEMORY_PACKS.text_1m,
    text_5m: DEFAULT_MEMORY_PACKS.text_5m,
    vision_1m: DEFAULT_MEMORY_PACKS.vision_1m,
  };
  if (!isRecord(raw)) return { packs };
  for (const packId of MEMORY_PACK_IDS) {
    packs[packId] = overlayPack(packs[packId], raw[packId]);
  }
  return { packs };
}

export async function loadMemoryPackCatalog(): Promise<MemoryPackCatalogSnapshot> {
  try {
    const template = await getRemoteConfig().getTemplate();
    const raw = remoteConfigStringValue(template.parameters?.memory_pack_catalog?.defaultValue);
    if (!raw) return normalizeMemoryPackCatalog(undefined);
    return normalizeMemoryPackCatalog(JSON.parse(raw));
  } catch (err) {
    logWarn({
      event: "memory_pack.remote_config_unavailable",
      error: errorMessage(err),
    });
    return normalizeMemoryPackCatalog(undefined);
  }
}

export function isMemoryPackOffered(pack: MemoryPackDefinition): boolean {
  return pack.title.length > 0;
}

export function listedMemoryPacks(
  catalog: MemoryPackCatalogSnapshot,
  visionEligible: boolean,
): MemoryPackDefinition[] {
  return MEMORY_PACK_IDS.map((id) => catalog.packs[id]).filter((pack) => {
    if (!isMemoryPackOffered(pack)) return false;
    if (pack.requiresVisionEntitlement && !visionEligible) return false;
    return isMemoryPackId(pack.packId);
  });
}
