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
    expect(mapped[0]?.models?.[0]).toMatchObject({
      id: 'gpt-5.5',
      label: 'GPT-5.5',
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
});
