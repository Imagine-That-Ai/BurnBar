import { describe, expect, it } from 'vitest';
import {
  canOpenChatCitation,
  citationAffordance,
  normalizeMemoryCitations
} from './chatTypes.js';

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
