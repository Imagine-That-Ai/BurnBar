import { describe, expect, it } from 'vitest';
import { resolveSkinPalette } from './resolveSkinPalette.js';

describe('resolveSkinPalette', () => {
  it('maps editorial skin to brass ember accents', () => {
    const p = resolveSkinPalette('editorial');
    expect(p.accents[0]).toEqual([250, 107, 6]);
    expect(p.accents[1]).toEqual([253, 196, 44]);
    expect(p.theme).toBe('dark');
  });

  it('maps aurora skin to teal/cyan accents', () => {
    const p = resolveSkinPalette('aurora');
    expect(p.accents[0]).toEqual([60, 214, 192]);
    expect(p.accents[1]).toEqual([110, 231, 255]);
    expect(p.theme).toBe('dark');
  });
});