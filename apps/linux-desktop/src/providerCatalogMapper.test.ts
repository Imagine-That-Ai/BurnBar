import { describe, expect, it } from 'vitest';
import { mapProviderCatalog } from './tauriBridge.js';

describe('mapProviderCatalog', () => {
  it('merges canonical daemon catalog models with config health and failover state', () => {
    const mapped = mapProviderCatalog({
      config: {
        snapshot: {
          routerMode: 'exactModelOnly',
          providers: [
            {
              providerID: 'openai',
              isEnabled: true,
              preferredModelIDs: ['gpt-5.5'],
              disabledAdvertisedModelIDs: [],
              credentialSlots: [{ slotID: 'team', label: 'Team', isEnabled: true, status: 'ready' }]
            }
          ]
        }
      },
      catalog: {
        catalog: {
          providers: [
            {
              id: 'openai',
              displayName: 'OpenAI',
              capabilities: ['routing', 'accounting'],
              models: [
                {
                  id: 'gpt-5.5',
                  displayName: 'GPT-5.5',
                  aliases: [],
                  capabilityClassID: 'openai:reasoning'
                }
              ]
            }
          ]
        }
      },
      catalogAvailable: true
    });

    expect(mapped).toHaveLength(1);
    expect(mapped[0]).toMatchObject({
      id: 'openai',
      label: 'OpenAI',
      health: 'healthy',
      provenance: 'daemon catalog + local config',
      catalogAvailable: true,
      failover: { mode: 'exactModelOnly', eligible: true }
    });
    expect(mapped[0]?.models[0]).toMatchObject({
      id: 'gpt-5.5',
      label: 'GPT-5.5',
      enabled: true,
      health: 'healthy',
      provenance: 'daemon-catalog'
    });
    expect(mapped[0]?.capabilities).toEqual(['routing', 'accounting']);
  });

  it('keeps legacy config-only rows usable when enabled flags are absent', () => {
    const mapped = mapProviderCatalog({
      snapshot: {
        providers: [
          {
            providerId: 'anthropic',
            preferredModelIDs: ['claude-sonnet-4-6'],
            credentialSlots: [{ label: 'Local session', status: 'ready' }]
          }
        ]
      },
      catalogAvailable: false,
      catalogError: 'The daemon model catalog is unavailable; retry to refresh.'
    });

    expect(mapped[0]).toMatchObject({
      id: 'anthropic',
      health: 'healthy',
      failover: { eligible: true },
      catalogAvailable: false
    });
    expect(mapped[0]?.models[0]).toMatchObject({
      id: 'claude-sonnet-4-6',
      enabled: true,
      health: 'healthy',
      provenance: 'configured-model'
    });
  });

  it('never copies credential material into the typed catalog rows', () => {
    const mapped = mapProviderCatalog({
      config: {
        snapshot: {
          providers: [
            {
              providerID: 'openai',
              isEnabled: true,
              credentialSlots: [{ label: 'Personal', apiKey: 'sk-secret-not-for-ui', status: 'ready' }]
            }
          ]
        }
      },
      catalogAvailable: false
    });

    expect(JSON.stringify(mapped)).not.toContain('sk-secret-not-for-ui');
  });
});
