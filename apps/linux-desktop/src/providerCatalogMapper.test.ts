import { describe, expect, it } from 'vitest';
import { mapProviderCatalog } from './tauriBridge.js';

describe('mapProviderCatalog', () => {
  it('merges catalog/config state and exposes only verified route eligibility', () => {
    const mapped = mapProviderCatalog({
      config: {
        snapshot: {
          routerMode: 'exactModelOnly',
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
      failover: { mode: 'exactModelOnly', eligible: true }
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
          routerMode: 'providerFamilyFailover',
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
});
