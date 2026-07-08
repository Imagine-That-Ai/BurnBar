import { describe, expect, it } from 'vitest';
import { fixtureProviderCatalog } from '../../daemonFixture.js';
import {
  aggregateSummary,
  buildInactiveSlots,
  buildSubscriptionEntries,
  filterByProvider,
  headlineText,
  sortEntries
} from './quotaModel.js';

describe('quotaModel', () => {
  it('builds subscription entries from fixture catalog', () => {
    const entries = buildSubscriptionEntries(fixtureProviderCatalog());
    expect(entries.length).toBeGreaterThanOrEqual(4);
    expect(entries.some((e) => e.providerId === 'anthropic')).toBe(true);
    expect(entries.find((e) => e.providerId === 'openai')?.pressure).toBe(1);
  });

  it('aggregates near-edge counts from pressure', () => {
    const entries = buildSubscriptionEntries(fixtureProviderCatalog());
    const summary = aggregateSummary(entries.filter((e) => !e.isInactive));
    expect(summary.activeCount).toBeGreaterThan(0);
    expect(summary.nearEdgeCount).toBeGreaterThanOrEqual(1);
    expect(headlineText(summary, null)).toMatch(/near the edge|tracked/);
  });

  it('sorts by urgency descending pressure', () => {
    const entries = buildSubscriptionEntries(fixtureProviderCatalog());
    const sorted = sortEntries(entries, 'urgency');
    expect(sorted[0].pressure).toBeGreaterThanOrEqual(sorted[sorted.length - 1].pressure);
  });

  it('filters entries by focused provider', () => {
    const entries = buildSubscriptionEntries(fixtureProviderCatalog());
    const focused = filterByProvider(entries, 'anthropic');
    expect(focused.every((e) => e.providerId === 'anthropic')).toBe(true);
  });

  it('marks missing-credential providers as inactive', () => {
    const entries = buildSubscriptionEntries(fixtureProviderCatalog());
    const google = entries.find((e) => e.providerId === 'google');
    expect(google).toBeDefined();
    expect(google?.isInactive).toBe(true);
  });

  it('keeps inactive catalog providers out of glyph-only setup slots', () => {
    const catalog = fixtureProviderCatalog();
    const slots = buildInactiveSlots(catalog);
    const ids = slots.map((s) => s.providerId);
    expect(ids).not.toContain('google');
    expect(new Set(ids).size).toBe(ids.length);
  });
});