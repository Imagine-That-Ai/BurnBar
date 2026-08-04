import { describe, expect, it } from 'vitest';
import { petAtlasFrameRect, resolvePetAtlasState } from './petAtlasRuntime.js';
import type { PetAtlasDefinition } from './petCatalog.js';

const atlas: PetAtlasDefinition = {
  image: 'goose/spritesheet.webp',
  grid: { cols: 8, rows: 9 },
  cell: { w: 192, h: 208 },
  anchor: { x: 96, y: 196 },
  defaultState: 'idle',
  states: {
    idle: { row: 0, frames: 8, fps: 8, loop: true, hero: false },
    waddle: { row: 1, frames: 8, fps: 9, loop: true, hero: false },
    cheer: { row: 6, frames: 8, fps: 11, loop: false, hero: false }
  }
};

describe('pet atlas runtime', () => {
  it('maps logical movement to the pet-specific atlas row and clamps frames', () => {
    expect(resolvePetAtlasState(atlas, 'wander').name).toBe('waddle');
    expect(petAtlasFrameRect(atlas, 'wander', 99)).toEqual({ x: 1344, y: 208, width: 192, height: 208 });
  });

  it('falls back to idle for an unknown logical state', () => {
    expect(resolvePetAtlasState(atlas, 'unknown').name).toBe('idle');
  });
});
