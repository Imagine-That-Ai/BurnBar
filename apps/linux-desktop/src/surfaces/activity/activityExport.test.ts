import { describe, expect, it } from 'vitest';
import type { SessionEntry } from '../../tauriBridge.js';
import {
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
});
