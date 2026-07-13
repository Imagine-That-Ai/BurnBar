import { describe, expect, it, vi } from 'vitest';
import type { SessionEntry } from '../../tauriBridge.js';
import {
  ACTIVITY_HISTORY_EXPORT_MAX_BYTES,
  ACTIVITY_HISTORY_EXPORT_LIMIT,
  buildDaemonActivityHistoryExport,
  buildActivityExportDocument,
  downloadActivityExport,
  sanitizeActivityExportFilename,
  serializeActivityExport
} from './activityExport.js';

const sessions: SessionEntry[] = [
  {
    id: 'session-1',
    provider: 'openai',
    model: 'gpt-5',
    startedAt: '2026-07-13T12:00:00Z',
    tokens: 1200,
    costUsd: 0.42,
    title: 'Parity review'
  },
  {
    id: 'session-2',
    provider: 'anthropic',
    model: 'claude-sonnet',
    startedAt: '2026-07-13T13:00:00Z',
    tokens: 800,
    costUsd: 0.18,
    title: 'Release check'
  }
];

describe('activity export', () => {
  it('exports only the allowlisted fields from currently loaded rows', () => {
    const document = buildActivityExportDocument(
      sessions.map((session) => ({
        ...session,
        apiKey: 'must-not-export',
        internalReasoning: 'must-not-export'
      }) as SessionEntry),
      'live daemon session index',
      '2026-07-13T14:00:00Z'
    );

    expect(document).toEqual({
      version: 1,
      scope: 'loaded-session-index',
      source: 'live daemon session index',
      generatedAt: '2026-07-13T14:00:00Z',
      loadedCount: 2,
      sessions
    });

    const serialized = serializeActivityExport(document, 'json');
    expect(JSON.parse(serialized)).toEqual(document);
    expect(serialized).not.toMatch(/apiKey|internalReasoning|must-not-export/i);
  });

  it('serializes a readable loaded-only Markdown report', () => {
    const document = buildActivityExportDocument(sessions, 'fixture transcript', '2026-07-13T14:00:00Z');
    const markdown = serializeActivityExport(document, 'markdown');

    expect(markdown).toContain('# OpenBurnBar Activity Export');
    expect(markdown).toContain('Scope: `loaded-session-index`');
    expect(markdown).toContain('Loaded rows: 2');
    expect(markdown).toContain('older history or session bodies');
    expect(markdown).toContain('## Parity review');
    expect(markdown).toContain('Session ID: `session-1`');
    expect(markdown.endsWith('\n')).toBe(true);
  });

  it('sanitizes export filenames and chooses the correct extension', () => {
    expect(sanitizeActivityExportFilename('Activity / logs: July', 'markdown')).toBe(
      'openburnbar-Activity-logs-July.md'
    );
    expect(sanitizeActivityExportFilename('   ', 'json')).toBe('openburnbar-activity-export.json');
    expect(sanitizeActivityExportFilename('../..', 'json')).toBe('openburnbar-activity-export.json');
  });

  it('fails closed when the shell cannot provide a document download surface', () => {
    expect(() => downloadActivityExport({
      filename: 'activity.json',
      content: '{}\n',
      mimeType: 'application/json'
    }, undefined)).toThrow(/unavailable/i);
  });

  it('exports a complete daemon snapshot only after resolving every source and body', async () => {
    const replay = vi.fn(async (sourceID: string) => ({
      kind: 'native',
      briefingMD: `# ${sourceID}\n\nUntrusted persisted body`,
      briefingTruncated: false
    }));
    const result = await buildDaemonActivityHistoryExport({
      sessionList: async () => ({
        sessions: [
          {
            ...sessions[0]!,
            sourceID: 'Codex:session-1',
            providerSessionID: 'session-1',
            projectName: 'BurnBar'
          }
        ],
        nextCursor: null,
        complete: true
      }),
      sessionReplay: replay
    }, '2026-07-13T14:00:00Z');

    expect(result.kind).toBe('available');
    if (result.kind !== 'available') return;
    expect(result.document).toMatchObject({
      scope: 'daemon-session-history',
      source: 'live daemon session index',
      historyComplete: true,
      historyLimit: ACTIVITY_HISTORY_EXPORT_LIMIT,
      loadedCount: 1
    });
    expect(result.document.sessions[0]).toMatchObject({
      sourceID: 'Codex:session-1',
      providerSessionID: 'session-1',
      bodyMD: '# Codex:session-1\n\nUntrusted persisted body'
    });
    expect(replay).toHaveBeenCalledWith('Codex:session-1');

    const markdown = serializeActivityExport(result.document, 'markdown');
    expect(markdown).toContain('bounded export was read from the daemon');
    expect(markdown).toContain('Persisted body (untrusted)');
    expect(markdown).toContain('Untrusted persisted body');
  });

  it('returns a typed unavailable result for paged history instead of exporting a partial page', async () => {
    const replay = vi.fn();
    const result = await buildDaemonActivityHistoryExport({
      sessionList: async () => ({
        sessions,
        nextCursor: 'older-page',
        complete: false
      }),
      sessionReplay: replay
    });

    expect(result).toEqual({
      kind: 'unavailable',
      code: 'history_not_complete',
      message: expect.stringMatching(/paged or incomplete/i)
    });
    expect(replay).not.toHaveBeenCalled();
  });

  it('fails closed when any listed row lacks a verified source identity', async () => {
    const replay = vi.fn();
    const result = await buildDaemonActivityHistoryExport({
      sessionList: async () => ({ sessions, nextCursor: null, complete: true }),
      sessionReplay: replay
    });

    expect(result).toMatchObject({ kind: 'unavailable', code: 'source_identity_unavailable' });
    expect(replay).not.toHaveBeenCalled();
  });

  it('rejects truncated bodies and total history over the byte bound', async () => {
    const truncated = await buildDaemonActivityHistoryExport({
      sessionList: async () => ({
        sessions: [{ ...sessions[0]!, sourceID: 'Codex:session-1' }],
        nextCursor: null,
        complete: true
      }),
      sessionReplay: async () => ({ kind: 'native', briefingMD: 'body', briefingTruncated: true })
    });
    expect(truncated).toMatchObject({ kind: 'unavailable', code: 'session_body_truncated' });

    const oversized = await buildDaemonActivityHistoryExport({
      sessionList: async () => ({
        sessions: [{ ...sessions[0]!, sourceID: 'Codex:session-1' }],
        nextCursor: null,
        complete: true
      }),
      sessionReplay: async () => ({
        kind: 'native',
        briefingMD: 'x'.repeat(ACTIVITY_HISTORY_EXPORT_MAX_BYTES + 1),
        briefingTruncated: false
      })
    });
    expect(oversized).toMatchObject({ kind: 'unavailable', code: 'history_size_exceeded' });
  });
});
