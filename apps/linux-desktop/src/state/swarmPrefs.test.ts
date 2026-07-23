// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  DEFAULT_SWARM_PREFERENCES,
  persistSwarmPreferences,
  readSwarmPreferences,
  SWARM_PREFS_CHANGED_EVENT,
  SWARM_PREFS_KEY,
  SWARM_SPEED_MAX,
  SWARM_SPEED_MIN
} from './swarmPrefs.js';

describe('swarm preference contract', () => {
  beforeEach(() => localStorage.clear());
  afterEach(() => localStorage.clear());

  it('defaults to the cinematic macOS dashboard pace with sparkles off', () => {
    expect(readSwarmPreferences()).toEqual(DEFAULT_SWARM_PREFERENCES);
  });

  it('clamps unsafe speed values and publishes a typed change event', () => {
    const listener = vi.fn();
    window.addEventListener(SWARM_PREFS_CHANGED_EVENT, listener);
    const next = persistSwarmPreferences({ speed: 99, sparkles: true });
    expect(next).toMatchObject({ speed: SWARM_SPEED_MAX, sparkles: true });
    expect(next.constellationMode).toBe(false);
    expect(next.providerGlyphs.length).toBeGreaterThan(0);
    expect(next.excludeBrandShapes).toBe(true);
    expect(JSON.parse(localStorage.getItem(SWARM_PREFS_KEY) ?? '{}')).toEqual(next);
    expect(readSwarmPreferences()).toEqual(next);
    expect(listener).toHaveBeenCalledTimes(1);

    persistSwarmPreferences({ speed: -1, sparkles: false });
    expect(readSwarmPreferences().speed).toBe(SWARM_SPEED_MIN);
    window.removeEventListener(SWARM_PREFS_CHANGED_EVENT, listener);
  });

  it('persists the Constellation style preset independently from manual swarm controls', () => {
    const next = persistSwarmPreferences({
      ...DEFAULT_SWARM_PREFERENCES,
      constellationMode: true,
      speed: 1.8,
      sparkles: false,
      allowsClickCycle: true
    });

    expect(next).toMatchObject({
      constellationMode: true,
      speed: 1.8,
      sparkles: false,
      allowsClickCycle: true
    });
    expect(readSwarmPreferences()).toEqual(next);
  });
});
