import { describe, expect, it } from 'vitest';
import { resolveCacheHitRateTier } from './cacheHitTier.js';

describe('cacheHitTier', () => {
  it('maps percentage bands to macOS-aligned tiers', () => {
    expect(resolveCacheHitRateTier(72).id).toBe('strong');
    expect(resolveCacheHitRateTier(45).id).toBe('healthy');
    expect(resolveCacheHitRateTier(12).id).toBe('warming');
    expect(resolveCacheHitRateTier(2).id).toBe('cold');
    expect(resolveCacheHitRateTier(0).formattedValue).toBe('0%');
    expect(resolveCacheHitRateTier(null).id).toBe('noSignal');
  });
});