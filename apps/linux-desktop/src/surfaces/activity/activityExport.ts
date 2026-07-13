import type { SessionEntry } from '../../tauriBridge.js';

export type ActivityExportFormat = 'json' | 'markdown';
export type ActivityExportSource = 'fixture transcript' | 'live daemon session index';

export type ActivityExportSession = {
  id: string;
  provider: string;
  model: string;
  startedAt: string;
  tokens: number;
  costUsd: number;
  title: string;
};

export type ActivityExportDocument = {
  version: 1;
  scope: 'loaded-session-index';
  source: ActivityExportSource;
  generatedAt: string;
  loadedCount: number;
  sessions: ActivityExportSession[];
};

function finiteNumber(value: number): number {
  return Number.isFinite(value) ? value : 0;
}

function text(value: string): string {
  return value.normalize('NFKC');
}

/**
 * Copy only the activity index fields that are safe to share. This deliberately
 * does not accept or spread daemon payloads, so credentials, tool state, and
 * future internal fields cannot leak into an export by accident.
 */
function exportSession(session: SessionEntry): ActivityExportSession {
  return {
    id: text(session.id),
    provider: text(session.provider),
    model: text(session.model),
    startedAt: text(session.startedAt),
    tokens: finiteNumber(session.tokens),
    costUsd: finiteNumber(session.costUsd),
    title: text(session.title)
  };
}

export function buildActivityExportDocument(
  sessions: SessionEntry[],
  source: ActivityExportSource,
  generatedAt = new Date().toISOString()
): ActivityExportDocument {
  const loadedSessions = sessions.map(exportSession);
  return {
    version: 1,
    scope: 'loaded-session-index',
    source,
    generatedAt,
    loadedCount: loadedSessions.length,
    sessions: loadedSessions
  };
}

function sanitizePart(value: string, maxLength: number): string {
  return value
    .normalize('NFKC')
    .trim()
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/[\\/]+/g, '-')
    .replace(/[^\p{L}\p{N}._-]+/gu, '-')
    .replace(/-{2,}/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
    .slice(0, maxLength);
}

export function sanitizeActivityExportFilename(
  label: string,
  format: ActivityExportFormat
): string {
  const stem = sanitizePart(label, 72) || 'activity-export';
  return `openburnbar-${stem}.${format === 'markdown' ? 'md' : 'json'}`;
}

function inlineMarkdown(value: string): string {
  return value
    .replace(/\r\n|\r/g, '\n')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\n+/g, ' ')
    .replace(/`/g, "'")
    .trim();
}

function markdownHeading(value: string): string {
  return inlineMarkdown(value).replace(/([\\#*_\[\]])/g, '\\$1');
}

function markdownValue(value: string): string {
  return `\`${inlineMarkdown(value)}\``;
}

export function serializeActivityExport(
  document: ActivityExportDocument,
  format: ActivityExportFormat
): string {
  if (format === 'json') {
    return `${JSON.stringify(document, null, 2)}\n`;
  }

  const lines = [
    '# OpenBurnBar Activity Export',
    '',
    `- Scope: ${markdownValue(document.scope)}`,
    `- Source: ${markdownValue(document.source)}`,
    `- Exported at: ${markdownValue(document.generatedAt)}`,
    `- Loaded rows: ${document.loadedCount}`,
    '',
    '> This export contains only rows currently loaded in Activity. It does not fetch older history or session bodies.',
    ''
  ];

  for (const session of document.sessions) {
    const title = markdownHeading(session.title) || markdownHeading(session.id) || 'Untitled session';
    lines.push(
      `## ${title}`,
      '',
      `- Session ID: ${markdownValue(session.id)}`,
      `- Provider: ${markdownValue(session.provider)}`,
      `- Model: ${markdownValue(session.model)}`,
      `- Started: ${markdownValue(session.startedAt)}`,
      `- Tokens: ${session.tokens}`,
      `- Cost (USD): ${session.costUsd}`,
      ''
    );
  }

  return `${lines.join('\n').replace(/\n{3,}/g, '\n\n').trim()}\n`;
}

export type ActivityExportDownload = {
  filename: string;
  content: string;
  mimeType: 'application/json' | 'text/markdown';
};

/** Trigger the WebView's native download handoff without renderer filesystem access. */
export function downloadActivityExport(
  exportData: ActivityExportDownload,
  document: Document | undefined = globalThis.document
): void {
  const url = globalThis.URL;
  if (
    !document?.body ||
    typeof Blob === 'undefined' ||
    !url ||
    typeof url.createObjectURL !== 'function' ||
    typeof url.revokeObjectURL !== 'function'
  ) {
    throw new Error('Activity export is unavailable in this shell.');
  }

  const blob = new Blob([exportData.content], { type: `${exportData.mimeType};charset=utf-8` });
  const objectURL = url.createObjectURL(blob);
  const revokeObjectURL = url.revokeObjectURL;
  const anchor = document.createElement('a');
  anchor.href = objectURL;
  anchor.download = exportData.filename;
  anchor.rel = 'noopener';
  anchor.style.display = 'none';
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  if (typeof globalThis.setTimeout === 'function') {
    globalThis.setTimeout(() => revokeObjectURL.call(url, objectURL), 0);
  } else {
    revokeObjectURL.call(url, objectURL);
  }
}
