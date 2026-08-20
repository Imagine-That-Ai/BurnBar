import { describe, expect, it } from 'vitest';
import {
  normalizeSwarmProviderGlyphs,
  SWARM_PROVIDER_GLYPH_IDS,
  SWARM_PROVIDER_GLYPH_OPTIONS
} from '@openburnbar/gl-engine/engine/kernels/swarmCatalog';
import { buildDashboardCycle } from '@openburnbar/gl-engine/engine/kernels/swarmEmberKernel';

describe('swarm provider glyph catalog', () => {
  it('keeps the settings order stable and rejects stale IDs', () => {
    expect(SWARM_PROVIDER_GLYPH_OPTIONS).toHaveLength(34);
    expect(SWARM_PROVIDER_GLYPH_OPTIONS.map(({ id }) => id)).toEqual([...SWARM_PROVIDER_GLYPH_IDS]);
    expect(normalizeSwarmProviderGlyphs(['windsurf', 'unknown', 'windsurf', 'codex'])).toEqual([
      'codex',
      'windsurf'
    ]);
  });

  it('distinguishes an explicit empty selection from an omitted selection', () => {
    expect(normalizeSwarmProviderGlyphs([])).toEqual([]);
    expect(normalizeSwarmProviderGlyphs(undefined)).toEqual([...SWARM_PROVIDER_GLYPH_IDS]);
  });

  it('builds the same provider-only and brand-inclusive cycle modes as macOS', () => {
    expect(buildDashboardCycle(['codex'], true, true)).toHaveLength(2);
    expect(buildDashboardCycle([], true, true)).toEqual(['swarm']);
    expect(buildDashboardCycle([], false, true)).toEqual([
      'swarm',
      'shapeDollar',
      'swarm',
      'shapeCode',
      'swarm',
      'shapeBurnBarLogo',
      'swarm',
      'shapeRings',
      'swarm',
      'shapeRouterFlow'
    ]);
    expect(buildDashboardCycle(['codex'], false, false)).toEqual(['swarm']);
  });
});
