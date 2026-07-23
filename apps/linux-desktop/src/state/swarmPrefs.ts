/** Local swarm controls mirrored from macOS SwarmWallpaperViewModel. */
import {
  normalizeSwarmProviderGlyphs,
  SWARM_PROVIDER_GLYPH_IDS,
  type SwarmProviderGlyphId
} from '@openburnbar/gl-engine/engine/kernels/swarmCatalog';

export const SWARM_PREFS_KEY = 'openburnbar.linux.swarm.v1';
export const SWARM_PREFS_CHANGED_EVENT = 'openburnbar:swarm-preferences-changed';
export const SWARM_SPEED_MIN = 0.35;
export const SWARM_SPEED_MAX = 2.5;
export const SWARM_SPEED_DEFAULT = 0.6;

export type SwarmPreferences = {
  speed: number;
  sparkles: boolean;
  providerGlyphs: SwarmProviderGlyphId[];
  excludeBrandShapes: boolean;
  autoCycleShapes: boolean;
  allowsClickCycle: boolean;
};

export const DEFAULT_SWARM_PREFERENCES: SwarmPreferences = {
  speed: SWARM_SPEED_DEFAULT,
  sparkles: false,
  providerGlyphs: [...SWARM_PROVIDER_GLYPH_IDS],
  // Linux historically used the provider-only dashboard cycle. Keep that
  // default while exposing the macOS brand-shape switch to users.
  excludeBrandShapes: true,
  autoCycleShapes: true,
  allowsClickCycle: false
};

function clampSwarmSpeed(value: number): number {
  if (!Number.isFinite(value)) return SWARM_SPEED_DEFAULT;
  return Math.min(SWARM_SPEED_MAX, Math.max(SWARM_SPEED_MIN, value));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

export function readSwarmPreferences(): SwarmPreferences {
  try {
    const raw = localStorage.getItem(SWARM_PREFS_KEY);
    if (!raw) return DEFAULT_SWARM_PREFERENCES;
    const parsed: unknown = JSON.parse(raw);
    if (!isRecord(parsed)) return DEFAULT_SWARM_PREFERENCES;
    return {
      speed: clampSwarmSpeed(Number(parsed.speed)),
      sparkles: parsed.sparkles === true,
      providerGlyphs: normalizeSwarmProviderGlyphs(
        Array.isArray(parsed.providerGlyphs)
          ? parsed.providerGlyphs.filter((value): value is string => typeof value === 'string')
          : undefined
      ),
      excludeBrandShapes: parsed.excludeBrandShapes !== false,
      autoCycleShapes: parsed.autoCycleShapes !== false,
      allowsClickCycle: parsed.allowsClickCycle === true
    };
  } catch {
    return DEFAULT_SWARM_PREFERENCES;
  }
}

export function persistSwarmPreferences(next: Partial<SwarmPreferences>): SwarmPreferences {
  const normalized = {
    speed: clampSwarmSpeed(next.speed ?? SWARM_SPEED_DEFAULT),
    sparkles: next.sparkles === true,
    providerGlyphs: normalizeSwarmProviderGlyphs(next.providerGlyphs),
    excludeBrandShapes: next.excludeBrandShapes !== false,
    autoCycleShapes: next.autoCycleShapes !== false,
    allowsClickCycle: next.allowsClickCycle === true
  };
  try {
    localStorage.setItem(SWARM_PREFS_KEY, JSON.stringify(normalized));
  } catch {
    // Convenience preference; the in-memory renderer still receives it.
  }
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new CustomEvent<SwarmPreferences>(SWARM_PREFS_CHANGED_EVENT, { detail: normalized }));
  }
  return normalized;
}
