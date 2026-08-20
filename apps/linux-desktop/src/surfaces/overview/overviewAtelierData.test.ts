import { describe, expect, it } from 'vitest';
import { fixtureUsageInsights, fixtureUsageSummary } from '../../daemonFixture.js';
import {
  ATELIER_FIXTURE_PROVIDER_ROWS,
  buildSpendCurveModel,
  formatProviderCost,
  providerRowsFromInsights
} from './overviewAtelierData.js';

describe('overviewAtelierData', () => {
  it('fixture provider rows match Atelier screenshot spend labels', () => {
    expect(ATELIER_FIXTURE_PROVIDER_ROWS[0].label).toBe('MiMo');
    expect(formatProviderCost(252.43)).toBe('$252.43');
    expect(formatProviderCost(0.00004)).toMatch(/\$0\.0000/);
  });

  it('providerRowsFromInsights uses fixture rail in fixture mode', () => {
    const rows = providerRowsFromInsights([], 0, true);
    expect(rows).toHaveLength(10);
    expect(rows[0].costUsd).toBe(252.43);
  });

  it('never lets the screenshot rail reach a live Home', () => {
    const rows = providerRowsFromInsights([], 680.94, false);
    expect(rows).toEqual([]);
    expect(rows.map((row) => row.label)).not.toContain('MiMo');
  });

  it('buildSpendCurveModel produces stacked bands and legend in fixture mode', () => {
    const model = buildSpendCurveModel(fixtureUsageInsights(), fixtureUsageSummary(), true);
    expect(model.isEmpty).toBe(false);
    expect(model.bands.length).toBeGreaterThan(0);
    expect(model.legend.map((l) => l.label)).toContain('Codex');
    expect(model.yMax).toBeGreaterThanOrEqual(15000);
  });

  it('buildSpendCurveModel is empty without weekly data', () => {
    const model = buildSpendCurveModel(
      { weekly: [], providerMix: [], modelMix: [], cacheHitRatePct: 0 },
      fixtureUsageSummary(),
      false
    );
    expect(model.isEmpty).toBe(true);
  });
});