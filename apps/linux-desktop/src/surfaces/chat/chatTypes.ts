import type { SessionEntry } from '../../tauriBridge.js';

export type ChatBackendId = 'hermes' | 'codex' | 'claude' | 'pi-agent' | 'cli';

export const CHAT_BACKENDS: { id: ChatBackendId; label: string }[] = [
  { id: 'hermes', label: 'Hermes' },
  { id: 'codex', label: 'Codex' },
  { id: 'claude', label: 'Claude Code' },
  { id: 'pi-agent', label: 'Pi' },
  { id: 'cli', label: 'CLI' }
];

export type ChatWarningBanner = {
  id: string;
  title: string;
  message: string;
};

export type MemoryCitation = {
  id: string;
  label: string;
  messageId?: string;
};

export function threadPreview(session: SessionEntry): string {
  return `Indexed ${session.provider} / ${session.model} · ${session.tokens.toLocaleString()} tokens · $${session.costUsd.toFixed(2)}`;
}

export function threadMessageCount(session: SessionEntry): number {
  return Math.max(2, Math.round(session.tokens / 1200));
}

export function formatThreadActivity(startedAt: string): string {
  const d = new Date(startedAt);
  if (Number.isNaN(d.getTime())) return startedAt;
  return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

export function composerPlaceholder(backend: ChatBackendId): string {
  switch (backend) {
    case 'codex':
      return 'Ask Codex…';
    case 'claude':
      return 'Ask Claude Code…';
    case 'pi-agent':
      return 'Ask Pi…';
    case 'cli':
      return 'Ask CLI…';
    default:
      return 'Ask Hermes…';
  }
}