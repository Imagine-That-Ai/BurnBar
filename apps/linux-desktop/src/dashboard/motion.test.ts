import { describe, expect, it } from 'vitest';
import { MOTION_FALLBACK, staggerDelayMs } from './motion.js';

describe('motion vocabulary', () => {
  it('staggers with the shared step and cap', () => {
    expect(staggerDelayMs(0, false)).toBe(0);
    expect(staggerDelayMs(1, false)).toBe(MOTION_FALLBACK.staggerStepMs);
    expect(staggerDelayMs(20, false)).toBe(MOTION_FALLBACK.staggerCapMs);
  });

  it('collapses stagger to simultaneous under reduced motion', () => {
    expect(staggerDelayMs(4, true)).toBe(0);
  });
});
