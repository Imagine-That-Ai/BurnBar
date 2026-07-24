import { describe, expect, it } from 'vitest';
import { mapProviderCatalog } from './tauriBridge.js';
import { decodeQuotaDate } from './tauriBridgeCoreDecoders.js';

describe('mapProviderCatalog', () => {
  it('merges catalog/config state and exposes only verified route eligibility', () => {
    const mapped = mapProviderCatalog({
      config: {
        snapshot: {
          routerMode: 'same_model_failover',
          providers: [{
            providerID: 'openai',
            isEnabled: true,
            quotaSourceKind: 'officialAPI',
            quotaConfidence: 'exact',
            accountStorage: 'cloud',
            planTier: 'TEAM',
            preferredModelIDs: ['gpt-5.5'],
            credentialSlots: [{ slotID: 'team', label: 'Team', isEnabled: true, status: 'ready' }]
          }]
        }
      },
      catalog: {
        providers: [{
          id: 'openai',
          displayName: 'OpenAI',
          capabilities: ['routing', 'accounting'],
          models: [{ id: 'gpt-5.5', displayName: 'GPT-5.5', aliases: [], capabilities: ['reasoning'] }]
        }]
      }
    });

    expect(mapped).toHaveLength(1);
    expect(mapped[0]).toMatchObject({
      id: 'openai',
      label: 'OpenAI',
      accountLabel: 'Team',
      health: 'healthy',
      provenance: 'daemon-catalog+daemon-config',
      catalogAvailable: true,
      failover: { mode: 'same_model_failover', eligible: true }
    });
    expect(mapped[0]).toMatchObject({
      quotaSourceKind: 'officialAPI',
      quotaConfidence: 'high',
      accountStorage: 'cloud',
      planTierBadge: 'TEAM'
    });
    expect(mapped[0]?.credentialSlots).toEqual([
      expect.objectContaining({ slotID: 'team', label: 'Team', status: 'ready' })
    ]);
    expect(mapped[0]?.models?.[0]).toMatchObject({
      id: 'gpt-5.5',
      label: 'GPT-5.5',
      enabled: true,
      provenance: 'daemon-catalog'
    });
  });

  it('maps the daemon.catalog response wrapper emitted by the Linux bridge', () => {
    const mapped = mapProviderCatalog({
      config: {
        snapshot: {
          routerMode: 'provider_family_failover',
          providers: [{
            providerID: 'anthropic',
            isEnabled: true,
            credentialSlots: [{ slotID: 'oauth', label: 'Claude OAuth', isEnabled: true, status: 'connected' }]
          }]
        }
      },
      catalog: {
        catalog: {
          providers: [{
            id: 'anthropic',
            displayName: 'Anthropic',
            capabilities: ['routing'],
            models: [{ id: 'claude-sonnet-4', displayName: 'Claude Sonnet 4', aliases: ['sonnet'], capabilities: ['reasoning'] }]
          }]
        }
      },
      catalogAvailable: true
    });

    expect(mapped[0]).toMatchObject({
      id: 'anthropic',
      health: 'healthy',
      catalogAvailable: true,
      provenance: 'daemon-catalog+daemon-config'
    });
    expect(mapped[0]?.models?.[0]).toMatchObject({
      id: 'claude-sonnet-4',
      aliases: ['sonnet'],
      enabled: true,
      provenance: 'daemon-catalog'
    });
  });

  it('keeps unconfigured catalog rows visible but fail-closed', () => {
    const mapped = mapProviderCatalog({
      catalog: { providers: [{ id: 'anthropic', displayName: 'Anthropic', models: [{ id: 'claude-sonnet-4' }] }] },
      catalogAvailable: true
    });
    expect(mapped[0]).toMatchObject({
      id: 'anthropic',
      accountLabel: 'Catalog only',
      health: 'unknown',
      failover: { eligible: false }
    });
    expect(mapped[0]?.models?.[0]?.enabled).toBe(false);
  });

  it('drops malformed rows and never fabricates ids, labels, or credential material', () => {
    const mapped = mapProviderCatalog({
      snapshot: {
        providers: [
          { providerID: '', label: 'forged', credentialSlots: [{ apiKey: 'sk-secret', status: 'ready' }] },
          { providerID: 'openai', isEnabled: false, credentialSlots: [{ label: 'Disabled', status: 'ready', apiKey: 'sk-secret' }] }
        ]
      }
    });
    expect(mapped).toHaveLength(1);
    expect(mapped[0]).toMatchObject({ id: 'openai', label: 'openai', health: 'unavailable' });
    expect(JSON.stringify(mapped)).not.toContain('sk-secret');
    expect(JSON.stringify(mapped)).not.toContain('Provider 1');
  });

  it('uses the preferred enabled slot as the quota account label and keeps slot metadata redacted', () => {
    const mapped = mapProviderCatalog({
      snapshot: {
        providers: [{
          providerID: 'anthropic',
          isEnabled: true,
          preferredCredentialSlotID: 'backup',
          credentialSlots: [
            { slotID: 'team', label: 'Team', isEnabled: true, status: 'ready', apiKey: 'sk-team' },
            { slotID: 'backup', label: 'Backup', isEnabled: true, status: 'ready', apiKey: 'sk-backup' }
          ]
        }]
      }
    });
    expect(mapped[0]).toMatchObject({ accountLabel: 'Backup', preferredCredentialSlotID: 'backup' });
    expect(mapped[0]?.credentialSlots?.map((slot) => slot.slotID)).toEqual(['team', 'backup']);
    expect(JSON.stringify(mapped)).not.toContain('sk-team');
    expect(JSON.stringify(mapped)).not.toContain('sk-backup');
  });

  it('preserves daemon quota provenance aliases without trusting unknown values', () => {
    const mapped = mapProviderCatalog({
      snapshot: {
        providers: [
          {
            providerID: 'claude-code',
            quotaSourceKind: 'local-session',
            quotaConfidence: 'estimated',
            quotaSource: 'ParserRegistry'
          },
          {
            providerID: 'openai',
            quotaSourceKind: 'made-up-source',
            quotaConfidence: 'made-up-confidence'
          }
        ]
      }
    });

    expect(mapped.find((provider) => provider.id === 'claude-code')).toMatchObject({
      quotaSourceKind: 'localSession',
      quotaConfidence: 'medium',
      quotaSource: 'ParserRegistry'
    });
    expect(mapped.find((provider) => provider.id === 'openai')).not.toHaveProperty('quotaSourceKind');
    expect(mapped.find((provider) => provider.id === 'openai')).not.toHaveProperty('quotaConfidence');
  });

  it('maps real daemon quota snapshots with canonical identity and stale provenance', () => {
    const swift = (iso: string) => Date.parse(iso) / 1000 - 978_307_200;
    const mapped = mapProviderCatalog({
      config: { snapshot: { routerMode: 'same_model_failover', providers: [{ providerID: 'anthropic', isEnabled: true, credentialSlots: [] }] } },
      catalog: { providers: [{ id: 'anthropic', models: [] }] },
      quota: { snapshots: [{
        providerID: 'anthropic', sourceKind: 'provider', sourceId: 'daemon.quota.signals:signal-1',
        source: 'Provider response headers', confidence: 'stale', fetchedAt: swift('2026-07-20T10:00:00Z'),
        updatedAt: swift('2026-07-20T10:00:00Z'), buckets: [{ key: 'traffic-rate-limit', label: 'Provider rate limit',
          usedValue: 30, limitValue: 100, remainingValue: 70, resetsAt: swift('2026-07-20T11:00:00Z') }]
      }] }
    });

    expect(mapped[0]).toMatchObject({
      canonicalProviderID: 'claude', providerAliases: ['anthropic', 'claude-code'], quotaStale: true,
      quotaSourceKind: 'provider', quotaSourceID: 'daemon.quota.signals:signal-1',
      quotaSource: 'Provider response headers', quotaConfidence: 'stale',
      quotaFetchedAt: '2026-07-20T10:00:00.000Z', quotaUpdatedAt: '2026-07-20T10:00:00.000Z',
      quotaBuckets: [{ id: 'traffic-rate-limit', usedPct: 30, resetsAt: '2026-07-20T11:00:00.000Z', state: 'ok' }],
      failover: { mode: 'same_model_failover', eligible: false }
    });
  });

  it('decodes bounded Swift Foundation quota dates and rejects invalid epochs', () => {
    const now = Date.parse('2026-07-20T12:00:00Z');
    expect(decodeQuotaDate(Date.parse('2026-07-20T10:00:00Z') / 1000 - 978_307_200, now)).toBe('2026-07-20T10:00:00.000Z');
    expect(decodeQuotaDate('2026-07-20T11:00:00Z', now)).toBe('2026-07-20T11:00:00.000Z');
    expect(decodeQuotaDate(Number.POSITIVE_INFINITY, now)).toBeUndefined();
    expect(decodeQuotaDate(-978_307_201, now)).toBeUndefined();
    expect(decodeQuotaDate(now / 1000 - 978_307_200 + 60 * 60 * 24 * 366 * 20, now)).toBeUndefined();
    expect(decodeQuotaDate('not-a-date', now)).toBeUndefined();
  });

  it('keeps a quota-only provider row and derives exhaustion from the exact Swift bucket shape', () => {
    const mapped = mapProviderCatalog({ quota: { snapshots: [{
      id: 'linux-header-openai-provider', provider: 'openai', providerID: { rawValue: 'openai' },
      sourceKind: 'provider', sourceId: 'daemon.quota.signals:signal-2', fetchedAt: '2026-07-20T10:00:00Z',
      source: 'Provider response headers', confidence: 'high', buckets: [{ key: 'traffic-rate-limit',
        label: 'Provider rate limit', windowKind: 'custom', usedValue: 100, limitValue: 100,
        remainingValue: 0, usedPercent: 100, resetsAt: null, unit: 'requests', isEstimated: false,
        name: 'traffic-rate-limit', used: 100, limit: 100, remaining: 0, window: 'custom', meta: {} }],
      schemaVersion: 2, updatedAt: '2026-07-20T10:00:00Z'
    }] } });
    expect(mapped).toHaveLength(1);
    expect(mapped[0]).toMatchObject({ id: 'openai', quotaBuckets: [{ id: 'traffic-rate-limit', usedPct: 100, state: 'exhausted' }] });
  });

  it('drops unknown quota values instead of fabricating zero-percent buckets', () => {
    const mapped = mapProviderCatalog({
      snapshot: { providers: [{ providerID: 'openai', isEnabled: true }] },
      quota: { snapshots: [{ providerID: 'openai', sourceKind: 'future-source', confidence: 'future-confidence',
        buckets: [{ key: 'unknown', label: 'Unknown' }] }] }
    });
    expect(mapped[0]?.quotaBuckets).toEqual([]);
    expect(mapped[0]).not.toHaveProperty('quotaSourceKind');
    expect(mapped[0]).not.toHaveProperty('quotaConfidence');
  });
});
