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

  it('explains preferred account routing and quota-drain fallback', () => {
    const entries = buildSubscriptionEntries([{
      id: 'anthropic',
      label: 'Anthropic',
      accountLabel: 'Team',
      preferredCredentialSlotID: 'team',
      credentialSlots: [
        { slotID: 'team', label: 'Team', isEnabled: true, status: 'ready', lastQuotaRemainingPercent: 72 },
        { slotID: 'backup', label: 'Backup', isEnabled: true, status: 'ready', lastQuotaRemainingPercent: 95 }
      ],
      quotaBuckets: [{ id: 'five-hour', label: '5h', usedPct: 28, state: 'ok' }]
    }]);
    expect(entries[0]?.routing).toMatchObject({ mode: 'preferred', activeSlotLabel: 'Team', eligibleSlotCount: 2, slotCount: 2 });
    expect(entries[0]?.routing.detail).toMatch(/drain to another eligible account/);
  });

  it('falls back to automatic routing when the preferred slot is exhausted', () => {
    const entries = buildSubscriptionEntries([{
      id: 'openai',
      label: 'OpenAI',
      accountLabel: 'Primary',
      preferredCredentialSlotID: 'primary',
      credentialSlots: [
        { slotID: 'primary', label: 'Primary', isEnabled: true, status: 'ready', lastQuotaRemainingPercent: 0 },
        { slotID: 'backup', label: 'Backup', isEnabled: true, status: 'ready', lastQuotaRemainingPercent: 80 }
      ],
      quotaBuckets: [{ id: 'requests', label: 'Requests', usedPct: 20, state: 'ok' }]
    }]);
    expect(entries[0]?.routing).toMatchObject({ mode: 'automatic', preferredSlotLabel: 'Primary', eligibleSlotCount: 1 });
    expect(entries[0]?.routing.detail).toMatch(/Preferred account Primary is unavailable/);
  });
});
