import { describe, expect, it } from 'vitest';
import { matchesSubsequence, routeMatchesQuery } from './commandPaletteMatch.js';

describe('commandPaletteMatch', () => {
  it('matches subsequence like macOS palette', () => {
    expect(matchesSubsequence('ov', 'overview')).toBe(true);
    expect(matchesSubsequence('xyz', 'overview')).toBe(false);
  });

  it('filters routes by label and description', () => {
    expect(routeMatchesQuery('Overview', 'Local peer health', 'peer')).toBe(true);
    expect(routeMatchesQuery('Overview', 'Local peer health', 'zzz')).toBe(false);
  });
});