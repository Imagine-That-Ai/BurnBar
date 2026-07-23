/** Local swarm controls mirrored from macOS SwarmWallpaperViewModel. */
export const SWARM_PREFS_KEY = 'openburnbar.linux.swarm.v1';
export const SWARM_PREFS_CHANGED_EVENT = 'openburnbar:swarm-preferences-changed';
export const SWARM_SPEED_MIN = 0.35;
export const SWARM_SPEED_MAX = 2.5;
export const SWARM_SPEED_DEFAULT = 0.6;

export type SwarmPreferences = {
  speed: number;
  sparkles: boolean;
};

export const DEFAULT_SWARM_PREFERENCES: SwarmPreferences = {
  speed: SWARM_SPEED_DEFAULT,
  sparkles: false
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
      sparkles: parsed.sparkles === true
    };
  } catch {
    return DEFAULT_SWARM_PREFERENCES;
  }
}

export function persistSwarmPreferences(next: SwarmPreferences): SwarmPreferences {
  const normalized = {
    speed: clampSwarmSpeed(next.speed),
    sparkles: next.sparkles === true
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
