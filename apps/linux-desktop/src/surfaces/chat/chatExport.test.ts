import { describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '../../state/chatStore.js';
import type { ChatThreadGetResult, ChatThreadSummary, PersistedChatMessage } from '../../tauriBridge.js';
import {
  buildChatExportDocument,
  chatMessagesForExport,
  downloadChatExport,
  loadCompleteChatHistory,
  sanitizeChatExportFilename,
  serializeChatExport
} from './chatExport.js';

const thread: ChatThreadSummary = {
  id: 'thread-export-1',
  title: 'Quarterly spend / audit',
  preview: 'Provider spend review',
  messageCount: 4,
  createdAt: '2026-07-10T12:00:00Z',
  updatedAt: '2026-07-10T12:04:00Z',
  lastMessageAt: '2026-07-10T12:04:00Z',
  backendID: 'codex'
};

const messages: ChatMessage[] = [
  {
    id: 'user-1',
    threadID: thread.id,
    role: 'user',
    text: 'How much did we spend?',
    timestamp: '2026-07-10T12:00:00Z'
  },
  {
    id: 'assistant-1',
    threadID: thread.id,
    role: 'assistant',
    text: 'The weekly total is $42.',
    timestamp: '2026-07-10T12:04:00Z',
    provider: 'codex',
    viaHermes: true,
    memoryCitations: [{ id: 'memory-secret', label: 'Private memory', messageId: 'assistant-1' }]
  },
  {
    id: 'system-1',
    threadID: thread.id,
    role: 'system',
    text: 'This is a durable system note.'
  },
  {
    id: 'tool-1',
    threadID: thread.id,
    role: 'tool',
    text: 'Read provider usage',
    toolName: 'usage.read',
    toolArgsSummary: '{ token: secret }',
    toolState: 'done'
  },
  {
    id: 'thinking-1',
    threadID: thread.id,
    role: 'thinking',
    text: 'Internal reasoning must stay out of exports.'
  },
  {
    id: 'other-thread',
    threadID: 'other-thread',
    role: 'user',
    text: 'Do not export this message.'
  },
  {
    id: 'blank-1',
    threadID: thread.id,
    role: 'user',
    text: '   '
  }
];

describe('chat export', () => {
  const persisted = (
    id: string,
    timestamp: string,
    content: string
  ): PersistedChatMessage => ({
    id,
    threadID: thread.id,
    role: id.includes('assistant') ? 'assistant' : 'user',
    content,
    timestamp
  });

  it('exports only durable transcript fields for the selected thread', () => {
    const document = buildChatExportDocument(thread, messages);

    expect(document).toEqual({
      version: 1,
      thread: { id: thread.id, title: thread.title },
      messages: [
        {
          id: 'user-1',
          role: 'user',
          content: 'How much did we spend?',
          timestamp: '2026-07-10T12:00:00Z'
        },
        {
          id: 'assistant-1',
          role: 'assistant',
          content: 'The weekly total is $42.',
          timestamp: '2026-07-10T12:04:00Z'
        },
        {
          id: 'system-1',
          role: 'system',
          content: 'This is a durable system note.'
        }
      ]
    });

    const serialized = serializeChatExport(document, 'json');
    expect(serialized).not.toMatch(/provider|memory-secret|usage\.read|token: secret|Private memory|reasoning/i);
    expect(JSON.parse(serialized)).toEqual(document);
  });

  it('serializes a readable Markdown transcript', () => {
    const document = buildChatExportDocument(thread, messages);
    const markdown = serializeChatExport(document, 'markdown');

    expect(markdown).toContain('# Quarterly spend / audit');
    expect(markdown).toContain('Thread: thread-export-1');
    expect(markdown).toContain('## User');
    expect(markdown).toContain('## Assistant');
    expect(markdown).toContain('## System');
    expect(markdown).not.toContain('usage.read');
    expect(markdown).not.toContain('Internal reasoning');
    expect(markdown.endsWith('\n')).toBe(true);
  });

  it('sanitizes export filenames and chooses the correct extension', () => {
    expect(sanitizeChatExportFilename('Quarterly / spend: audit', '../../thread', 'markdown')).toBe(
      'openburnbar-chat-Quarterly-spend-audit.md'
    );
    expect(sanitizeChatExportFilename('   ', 'thread/with unsafe chars', 'json')).toBe(
      'openburnbar-chat-thread-with-unsafe-chars.json'
    );
    expect(sanitizeChatExportFilename('..', '...', 'json')).toBe('openburnbar-chat-thread.json');
  });

  it('fails closed when the shell cannot provide a document download surface', () => {
    expect(() => downloadChatExport({
      filename: 'chat.json',
      content: '{}\n',
      mimeType: 'application/json'
    }, undefined)).toThrow(/unavailable/i);
  });

  it('loads every daemon page in chronological order for a complete export', async () => {
    const pages: ChatThreadGetResult[] = [
      {
        thread,
        messages: [persisted('assistant-new', '2026-07-10T12:04:00Z', 'Newest')],
        hasMoreBefore: true
      },
      {
        thread,
        messages: [persisted('user-old', '2026-07-10T12:00:00Z', 'Oldest')],
        hasMoreBefore: false
      }
    ];
    const fetchPage = vi.fn(async (_threadID: string, _maxMessages: number, _before?: unknown) => {
      const page = pages.shift();
      if (!page) throw new Error('unexpected page');
      return page;
    });

    const loaded = await loadCompleteChatHistory(thread, fetchPage);
    expect(loaded.map((message) => message.id)).toEqual(['user-old', 'assistant-new']);
    expect(fetchPage).toHaveBeenNthCalledWith(1, thread.id, 500, undefined);
    expect(fetchPage).toHaveBeenNthCalledWith(2, thread.id, 500, {
      timestamp: '2026-07-10T12:04:00Z',
      messageID: 'assistant-new'
    });
    expect(chatMessagesForExport(loaded)[0]).toMatchObject({ text: 'Oldest', role: 'user' });
  });

  it('rejects duplicate/no-progress pages instead of writing partial history', async () => {
    const duplicate = persisted('assistant-new', '2026-07-10T12:04:00Z', 'Newest');
    const fetchPage = vi.fn(async () => ({
      thread,
      messages: [duplicate],
      hasMoreBefore: true
    }));
    await expect(loadCompleteChatHistory(thread, fetchPage)).rejects.toThrow(/duplicate|cursor/i);
  });

  it('rejects a response with the wrong thread identity', async () => {
    const other: ChatThreadSummary = { ...thread, id: 'other-thread' };
    const fetchPage = async (): Promise<ChatThreadGetResult> => ({
      thread: other,
      messages: [],
      hasMoreBefore: false
    });
    await expect(loadCompleteChatHistory(thread, fetchPage)).rejects.toThrow(/different thread|identity/i);
  });

  it('enforces message and content bounds before serializing', async () => {
    const page = {
      thread,
      messages: [persisted('assistant-new', '2026-07-10T12:04:00Z', 'too large')],
      hasMoreBefore: false
    };
    await expect(
      loadCompleteChatHistory(thread, async () => page, { maxContentBytes: 3 })
    ).rejects.toThrow(/safe export limit/i);
  });

  it('enforces message bounds within a single oversized page', async () => {
    const page = {
      thread,
      messages: [
        persisted('user-1', '2026-07-10T12:00:00Z', 'one'),
        persisted('assistant-1', '2026-07-10T12:01:00Z', 'two')
      ],
      hasMoreBefore: false
    };
    await expect(
      loadCompleteChatHistory(thread, async () => page, { maxMessages: 1 })
    ).rejects.toThrow(/safe export limit/i);
  });
});
