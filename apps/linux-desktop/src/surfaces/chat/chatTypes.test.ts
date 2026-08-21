import { describe, expect, it } from 'vitest';
import type { ProviderCatalog } from '../../tauriBridge.js';
import {
  canOpenChatCitation,
  chatBackendAvailability,
  CHAT_BACKENDS,
  citationAffordance,
  normalizeMemoryCitations
} from './chatTypes.js';
import { fixtureConfigSnapshot } from '../../daemonFixture.js';

const routingCatalog: ProviderCatalog = [
  {
    id: 'anthropic',
    label: 'Anthropic',
    accountLabel: 'Team workspace',
    quotaBuckets: [],
    capabilities: ['routing'],
    catalogAvailable: true
  },
  {
    id: 'openai',
    label: 'OpenAI',
    accountLabel: 'Personal',
    quotaBuckets: [],
    capabilities: ['routing'],
    catalogAvailable: true
  }
];

describe('chat citation contract', () => {
  it('bounds, deduplicates, and rejects unsafe citation references', () => {
    const citations = normalizeMemoryCitations([
      { id: 'source-1', label: 'Local source', messageId: 'message-1', threadID: 'thread-1' },
      { id: 'source-1', label: 'duplicate', messageId: 'message-2' },
      { id: 'bad/id', label: 'unsafe path', messageId: 'message-3' },
      { id: 'source-2', label: 'control\nlabel', messageId: 'message-4' },
      ...Array.from({ length: 12 }, (_, index) => ({ id: `source-${index + 3}`, label: `Source ${index + 3}` }))
    ]);

    expect(citations).toHaveLength(8);
    expect(citations[0]).toMatchObject({ id: 'source-1', messageId: 'message-1', threadID: 'thread-1' });
    expect(citations.some((citation) => citation.id === 'bad/id')).toBe(false);
    expect(citations.some((citation) => citation.id === 'source-2')).toBe(false);
  });

  it('classifies local, cross-device, and unavailable citations without dead links', () => {
    expect(citationAffordance({ id: 'local', label: 'Local', messageId: 'message-1' })).toBe('jump-local');
    expect(citationAffordance({ id: 'remote', label: 'Remote', state: 'cross-device' })).toBe('cross-device');
    expect(citationAffordance({ id: 'gone', label: 'Gone', state: 'source-unavailable', messageId: 'message-1' })).toBe(
      'source-unavailable'
    );
    expect(canOpenChatCitation({ id: 'local', label: 'Local', messageId: 'message-1', threadID: 'thread-2' }, 'thread-1')).toBe(
      false
    );
    expect(
      canOpenChatCitation(
        { id: 'local', label: 'Local', messageId: 'message-1', threadID: 'thread-2' },
        'thread-1',
        ['thread-1', 'thread-2']
      )
    ).toBe(true);
  });
});

describe('chat backend parity contract', () => {
  it('represents every macOS backend and keeps legacy CLI non-selectable', () => {
    expect(CHAT_BACKENDS.map((entry) => entry.id)).toEqual([
      'codex', 'claude', 'hermes', 'pi-agent', 'openclaw', 'openclaude', 'omp',
      'droid', 'forge', 'antigravity', 'cursor-agent', 'junie', 'fx'
    ]);
    expect(chatBackendAvailability(fixtureConfigSnapshot(), 'cli', routingCatalog)).toMatchObject({ state: 'unsupported' });
  });

  it('reports configured, disabled, and unconfigured routes from daemon config', () => {
    const config = fixtureConfigSnapshot();
    expect(chatBackendAvailability(config, 'claude', routingCatalog).state).toBe('available');
    expect(chatBackendAvailability(config, 'codex', routingCatalog).state).toBe('disabled');
    expect(chatBackendAvailability(config, 'openclaw', routingCatalog).state).toBe('unconfigured');
  });

  it('never treats a credential as a chat route without daemon routing capability evidence', () => {
    const config = fixtureConfigSnapshot();
    const catalog = routingCatalog.map((entry) =>
      entry.id === 'anthropic' ? { ...entry, capabilities: ['accounting'] } : entry
    );
    expect(chatBackendAvailability(config, 'claude', catalog)).toMatchObject({
      state: 'unsupported',
      reason: 'The daemon catalog does not advertise chat routing for this provider.'
    });
    expect(chatBackendAvailability(config, 'claude', null)).toMatchObject({
      state: 'unknown',
      reason: 'Daemon provider capability catalog has not been loaded.'
    });
  });
});
