import { describe, expect, it } from 'vitest';
import { matchesSubsequence, routeMatchRank, routeMatchesQuery } from './commandPaletteMatch.js';

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
describe('routeMatchRank', () => {
  it('ranks exact label above description mention', () => {
    // Typing "Memory" must select the Memory route, not Projects
    // ("Workspace projects and code memory scope.").
    expect(routeMatchRank('Memory', 'Recall boundaries and audit.', 'Memory')).toBeLessThan(
      routeMatchRank('Projects', 'Workspace projects and code memory scope.', 'Memory')
    );
  });

  it('ranks label prefix above label substring above description', () => {
    expect(routeMatchRank('Insights', '', 'ins')).toBe(1);
    expect(routeMatchRank('Insights', '', 'sight')).toBe(2);
    expect(routeMatchRank('Overview', 'insights live here', 'sight')).toBe(3);
  });

  it('treats an empty query as neutral', () => {
    expect(routeMatchRank('Overview', 'desc', '')).toBe(routeMatchRank('Memory', 'desc', ''));
  });
});
