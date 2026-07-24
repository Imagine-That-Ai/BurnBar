import { describe, expect, it } from 'vitest';
import type { ConfigSnapshot } from '../../tauriBridge.js';
import {
  chatModelOptions,
  chatThinkingLevels,
  defaultChatModelSelection,
  selectionForModelOption,
  selectionForThinkingLevel
} from './chatOptions.js';

const config: ConfigSnapshot = {
  paths: { supportDir: '/tmp', socketPath: '/tmp/sock', configDir: '/tmp/cfg', providerLogPaths: [] },
  secretServiceStatus: 'ready',
  telemetryEnabled: false,
  privacyOptIn: false,
  providers: [
    {
      providerID: 'anthropic',
      isEnabled: true,
      baseURL: 'https://api.anthropic.com',
      preferredModelIDs: ['claude-opus', 'claude-sonnet'],
      disabledAdvertisedModelIDs: ['claude-sonnet'],
      credentialSlots: [],
      modelVariants: [
        {
          variantID: 'claude-opus-xhigh',
          label: 'XHigh',
          baseModelID: 'claude-opus',
          thinkingLevel: 'xhigh'
        },
        {
          variantID: 'claude-opus-high',
          label: 'High',
          baseModelID: 'claude-opus',
          thinkingLevel: 'high'
        }
      ],
      modelAliases: [
        {
          aliasID: 'anthropic/primary',
          baseModelID: 'claude-opus',
          displayName: 'Primary route',
          hidesBaseModel: false
        }
      ],
      modelDisplayOverrides: [{ modelID: 'claude-opus', displayName: 'Claude Opus' }],
      customModels: [{ modelID: 'claude-preview', displayName: 'Preview' }]
    }
  ]
};

describe('chat model options', () => {
  it('uses preferred, custom, and alias models while filtering disabled ids', () => {
    const options = chatModelOptions(config, 'claude', 'fallback');
    expect(options.map((option) => option.id)).toEqual([
      'claude-opus',
      'claude-preview',
      'anthropic/primary'
    ]);
    expect(options[0]?.label).toBe('Claude Opus');
    expect(chatThinkingLevels(options, 'claude-opus', 'claude-opus')).toEqual(['high', 'xhigh']);
  });

  it('selects a declared thinking variant and rejects unavailable levels', () => {
    const options = chatModelOptions(config, 'claude', 'fallback');
    expect(selectionForModelOption(options, 'claude-opus')).toEqual({
      modelID: 'claude-opus',
      modelOptionID: 'claude-opus',
      thinkingLevel: 'default'
    });
    expect(selectionForThinkingLevel(options, 'claude-opus', 'claude-opus', 'xhigh')).toEqual({
      modelID: 'claude-opus-xhigh',
      modelOptionID: 'claude-opus',
      thinkingLevel: 'xhigh'
    });
    expect(selectionForThinkingLevel(options, 'claude-opus', 'claude-opus', 'max')).toBeNull();
  });

  it('resets to the first valid model when backend changes or config has no provider', () => {
    expect(defaultChatModelSelection(config, 'claude', 'fallback')).toEqual({
      modelID: 'claude-opus',
      modelOptionID: 'claude-opus',
      thinkingLevel: 'default'
    });
    expect(defaultChatModelSelection(null, 'codex', 'gpt-5')).toEqual({
      modelID: 'gpt-5',
      modelOptionID: 'gpt-5',
      thinkingLevel: 'default'
    });
  });
});
