import type { LinuxShellBridge, SessionEntry, SessionReplayResult } from '../../tauriBridge.js';

export type ActivityExportFormat = 'json' | 'markdown';
export type ActivityExportSource = 'fixture transcript' | 'live daemon session index';

export const ACTIVITY_HISTORY_EXPORT_LIMIT = 500;
export const ACTIVITY_HISTORY_EXPORT_MAX_BYTES = 8 * 1024 * 1024;

export type ActivityExportSession = {
  id: string;
  provider: string;
  model: string;
  startedAt: string;
  tokens: number;
  costUsd: number;
  title: string;
  sourceID?: string;
  providerSessionID?: string;
  projectName?: string;
  bodyMD?: string;
};

export type ActivityExportDocument = {
  version: 1;
  scope: 'loaded-session-index' | 'daemon-session-history';
  source: ActivityExportSource;
  generatedAt: string;
  loadedCount: number;
  sessions: ActivityExportSession[];
  historyComplete?: boolean;
  historyLimit?: number;
};

export type ActivityHistoryExportUnavailableCode =
  | 'bridge_unavailable'
  | 'history_not_complete'
  | 'history_limit_exceeded'
  | 'source_identity_unavailable'
  | 'session_body_unavailable'
  | 'session_body_truncated'
  | 'history_size_exceeded'
  | 'daemon_error';

export type ActivityHistoryExportResult =
  | { kind: 'available'; document: ActivityExportDocument }
  | {
      kind: 'unavailable';
      code: ActivityHistoryExportUnavailableCode;
      message: string;
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
  const exported: ActivityExportSession = {
    id: text(session.id),
    provider: text(session.provider),
    model: text(session.model),
    startedAt: text(session.startedAt),
    tokens: finiteNumber(session.tokens),
    costUsd: finiteNumber(session.costUsd),
    title: text(session.title)
  };
  if (session.sourceID) exported.sourceID = text(session.sourceID);
  if (session.providerSessionID) exported.providerSessionID = text(session.providerSessionID);
  if (session.projectName) exported.projectName = text(session.projectName);
  return exported;
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

function utf8Bytes(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function unavailable(
  code: ActivityHistoryExportUnavailableCode,
  message: string
): ActivityHistoryExportResult {
  return { kind: 'unavailable', code, message };
}

/**
 * Resolve a bounded history snapshot through the existing daemon list and
 * `run.resume` contracts. A missing cursor, identity, or body is a hard stop:
 * exporting a partial transcript as "full history" would be misleading.
 */
export async function buildDaemonActivityHistoryExport(
  bridge: Pick<LinuxShellBridge, 'sessionList'> & {
    sessionReplay?: LinuxShellBridge['sessionReplay'];
  },
  generatedAt = new Date().toISOString()
): Promise<ActivityHistoryExportResult> {
  if (typeof bridge.sessionList !== 'function' || typeof bridge.sessionReplay !== 'function') {
    return unavailable(
      'bridge_unavailable',
      'Full activity history export requires the live daemon and persisted session replay.'
    );
  }

  let listed: Awaited<ReturnType<LinuxShellBridge['sessionList']>>;
  try {
    listed = await bridge.sessionList();
  } catch {
    return unavailable(
      'daemon_error',
      'The daemon could not provide a stable activity history snapshot.'
    );
  }

  if (listed.nextCursor !== null || listed.complete !== true) {
    return unavailable(
      'history_not_complete',
      'Full activity history export is unavailable because the daemon returned a paged or incomplete history.'
    );
  }
  if (listed.sessions.length > ACTIVITY_HISTORY_EXPORT_LIMIT) {
    return unavailable(
      'history_limit_exceeded',
      `Full activity history export is limited to ${ACTIVITY_HISTORY_EXPORT_LIMIT} sessions.`
    );
  }

  const sessions: ActivityExportSession[] = [];
  let bodyBytes = 0;
  for (const session of listed.sessions) {
    const sourceID = session.sourceID;
    if (!sourceID) {
      return unavailable(
        'source_identity_unavailable',
        'Full activity history export is unavailable for a row without a verified conversation identity.'
      );
    }

    let replay: SessionReplayResult;
    try {
      replay = await bridge.sessionReplay(sourceID);
    } catch {
      return unavailable(
        'daemon_error',
        'The daemon could not replay every activity session in the export snapshot.'
      );
    }
    if (replay.kind === 'error' || replay.errorCode || !replay.briefingMD) {
      return unavailable(
        'session_body_unavailable',
        'Full activity history export is unavailable because one or more session bodies could not be read.'
      );
    }
    if (replay.briefingTruncated) {
      return unavailable(
        'session_body_truncated',
        'Full activity history export is unavailable because one or more session bodies were truncated.'
      );
    }

    bodyBytes += utf8Bytes(replay.briefingMD);
    if (bodyBytes > ACTIVITY_HISTORY_EXPORT_MAX_BYTES) {
      return unavailable(
        'history_size_exceeded',
        `Full activity history export is limited to ${ACTIVITY_HISTORY_EXPORT_MAX_BYTES} UTF-8 bytes.`
      );
    }

    sessions.push({
      ...exportSession(session),
      bodyMD: replay.briefingMD
    });
  }

  return {
    kind: 'available',
    document: {
      version: 1,
      scope: 'daemon-session-history',
      source: 'live daemon session index',
      generatedAt,
      loadedCount: sessions.length,
      sessions,
      historyComplete: true,
      historyLimit: ACTIVITY_HISTORY_EXPORT_LIMIT
    }
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
    document.scope === 'daemon-session-history'
      ? `> This bounded export was read from the daemon's indexed history and includes persisted session bodies (limit: ${document.historyLimit ?? ACTIVITY_HISTORY_EXPORT_LIMIT} sessions).`
      : '> This export contains only rows currently loaded in Activity. It does not fetch older history or session bodies.',
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
    if (session.sourceID) lines.push(`- Source ID: ${markdownValue(session.sourceID)}`);
    if (session.providerSessionID) {
      lines.push(`- Provider session ID: ${markdownValue(session.providerSessionID)}`);
    }
    if (session.projectName) lines.push(`- Project: ${markdownValue(session.projectName)}`);
    if (session.bodyMD) {
      const indentedBody = session.bodyMD
        .replace(/\r\n|\r/g, '\n')
        .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, ' ')
        .split('\n')
        .map((line) => `    ${line}`)
        .join('\n');
      lines.push('', '### Persisted body (untrusted)', '', indentedBody, '');
    }
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
