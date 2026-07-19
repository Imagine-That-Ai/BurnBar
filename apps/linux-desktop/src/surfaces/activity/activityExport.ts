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
  /** Stable daemon run identity retained for source resolution after export. */
  runID?: string;
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

/**
 * `sessionList` is also used by the bounded `daemon.usage.recent` surface.
 * That surface has no cursor or completeness contract, so a nullable cursor
 * and a mapper-provided `complete` boolean are not sufficient proof of full
 * history. New shells use `sessionHistory`, whose daemon-owned response
 * carries this explicit marker; the legacy path remains only for older shells.
 */
type CompleteActivityHistoryList = Awaited<ReturnType<LinuxShellBridge['sessionList']>> & {
  historyComplete?: boolean;
};

export type ActivityHistoryExportResult =
  | { kind: 'available'; document: ActivityExportDocument }
  | {
      kind: 'unavailable';
      code: ActivityHistoryExportUnavailableCode;
      message: string;
    };

export type ActivityExportParseResult =
  | { kind: 'valid'; document: ActivityExportDocument }
  | { kind: 'invalid'; message: string };

export type ActivityExportResumeResult =
  | {
      kind: 'requested';
      session: ActivityExportSession;
      result: SessionReplayResult;
    }
  | {
      kind: 'unavailable';
      code:
        | 'invalid_export'
        | 'session_not_found'
        | 'source_identity_unavailable'
        | 'source_resolution_unavailable'
        | 'bridge_unavailable'
        | 'daemon_error';
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
  if (session.runID) exported.runID = text(session.runID);
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
    sessionHistory?: LinuxShellBridge['sessionHistory'];
    sessionReplay?: LinuxShellBridge['sessionReplay'];
  },
  generatedAt = new Date().toISOString()
): Promise<ActivityHistoryExportResult> {
  if (typeof bridge.sessionHistory === 'function') {
    let history: Awaited<ReturnType<NonNullable<LinuxShellBridge['sessionHistory']>>>;
    try {
      history = await bridge.sessionHistory();
    } catch {
      return unavailable(
        'daemon_error',
        'The daemon could not provide a stable activity history snapshot.'
      );
    }
    if (
      history.nextCursor !== null ||
      history.complete !== true ||
      history.historyComplete !== true
    ) {
      return unavailable(
        'history_not_complete',
        'Full activity history export is unavailable because the daemon returned a paged or incomplete history.'
      );
    }
    if (history.sessions.length > ACTIVITY_HISTORY_EXPORT_LIMIT) {
      return unavailable(
        'history_limit_exceeded',
        `Full activity history export is limited to ${ACTIVITY_HISTORY_EXPORT_LIMIT} sessions.`
      );
    }
    if (history.sessions.length !== history.totalCount) {
      return unavailable(
        'history_not_complete',
        'Full activity history export is unavailable because the daemon history count did not match the returned rows.'
      );
    }

    const sessions: ActivityExportSession[] = [];
    const sourceIDs = new Set<string>();
    let bodyBytes = 0;
    for (const session of history.sessions) {
      const sourceID = session.sourceID?.trim() || null;
      if (!sourceID) {
        return unavailable(
          'source_identity_unavailable',
          'Full activity history export is unavailable for a row without a verified conversation identity.'
        );
      }
      if (sourceIDs.has(sourceID)) {
        return unavailable(
          'source_identity_unavailable',
          'Full activity history export is unavailable because the daemon returned duplicate conversation identities.'
        );
      }
      sourceIDs.add(sourceID);
      const body = session.bodyMD;
      if (!body) {
        return unavailable(
          'session_body_unavailable',
          'Full activity history export is unavailable because one or more session bodies could not be read.'
        );
      }
      const sessionBodyBytes = utf8Bytes(body);
      if (sessionBodyBytes > ACTIVITY_SESSION_BODY_MAX_BYTES) {
        return unavailable(
          'session_body_truncated',
          'Full activity history export is unavailable because one or more session bodies were truncated.'
        );
      }
      bodyBytes += sessionBodyBytes;
      if (bodyBytes > ACTIVITY_HISTORY_EXPORT_MAX_BYTES) {
        return unavailable(
          'history_size_exceeded',
          `Full activity history export is limited to ${ACTIVITY_HISTORY_EXPORT_MAX_BYTES} UTF-8 bytes.`
        );
      }
      sessions.push({
        ...exportSession(session),
        sourceID,
        bodyMD: body
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
        historyLimit: history.historyLimit
      }
    };
  }

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
  if ((listed as CompleteActivityHistoryList).historyComplete !== true) {
    return unavailable(
      'history_not_complete',
      'Full activity history export is unavailable because the daemon did not provide an explicit complete-history proof; the current recent-usage bridge is bounded.'
    );
  }
  if (listed.sessions.length > ACTIVITY_HISTORY_EXPORT_LIMIT) {
    return unavailable(
      'history_limit_exceeded',
      `Full activity history export is limited to ${ACTIVITY_HISTORY_EXPORT_LIMIT} sessions.`
    );
  }

  const sessions: ActivityExportSession[] = [];
  const sourceIDs = new Set<string>();
  let bodyBytes = 0;
  for (const session of listed.sessions) {
    const sourceID = session.sourceID?.trim() || null;
    if (!sourceID) {
      return unavailable(
        'source_identity_unavailable',
        'Full activity history export is unavailable for a row without a verified conversation identity.'
      );
    }
    if (sourceIDs.has(sourceID)) {
      return unavailable(
        'source_identity_unavailable',
        'Full activity history export is unavailable because the daemon returned duplicate conversation identities.'
      );
    }
    sourceIDs.add(sourceID);

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
      sourceID,
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

const ACTIVITY_EXPORT_ID_MAX_CHARS = 512;
const ACTIVITY_EXPORT_TEXT_MAX_CHARS = 4_096;
const ACTIVITY_SESSION_BODY_MAX_BYTES = 65_536;
const ACTIVITY_EXPORT_JSON_MAX_BYTES = ACTIVITY_HISTORY_EXPORT_MAX_BYTES + 1_048_576;

function boundedExportText(
  value: unknown,
  maxChars = ACTIVITY_EXPORT_TEXT_MAX_CHARS,
  allowFormattingWhitespace = false
): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.normalize('NFKC');
  if (!normalized || normalized.length > maxChars) return null;
  if ([...normalized].some((character) => {
    const code = character.charCodeAt(0);
    if (code === 0x09 || code === 0x0a || code === 0x0d) {
      return !allowFormattingWhitespace;
    }
    return code < 0x20 || code === 0x7f;
  })) return null;
  return normalized;
}

function boundedExportOptionalText(
  value: unknown,
  maxChars = ACTIVITY_EXPORT_TEXT_MAX_CHARS
): string | undefined | null {
  if (value === undefined) return undefined;
  return boundedExportText(value, maxChars);
}

/**
 * Validate a JSON history export before it is allowed to select a resume
 * source. Markdown exports intentionally cannot be resumed: they are a
 * presentation format and may have lost machine identity or been edited.
 */
export function parseActivityHistoryExport(serialized: string): ActivityExportParseResult {
  if (typeof serialized !== 'string' || utf8Bytes(serialized) > ACTIVITY_EXPORT_JSON_MAX_BYTES) {
    return { kind: 'invalid', message: 'Activity history export exceeds the bounded import size.' };
  }

  let raw: unknown;
  try {
    raw = JSON.parse(serialized) as unknown;
  } catch {
    return { kind: 'invalid', message: 'Activity history import is not valid JSON.' };
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { kind: 'invalid', message: 'Activity history import must contain one JSON object.' };
  }
  const candidate = raw as Record<string, unknown>;
  if (candidate.version !== 1 || candidate.scope !== 'daemon-session-history' || candidate.historyComplete !== true) {
    return {
      kind: 'invalid',
      message: 'Only complete daemon-session-history exports can be used for resume.'
    };
  }
  if (candidate.source !== 'live daemon session index') {
    return { kind: 'invalid', message: 'Activity history import has an untrusted source declaration.' };
  }
  const generatedAt = boundedExportText(candidate.generatedAt);
  const loadedCount =
    typeof candidate.loadedCount === 'number' && Number.isSafeInteger(candidate.loadedCount)
      ? candidate.loadedCount
      : null;
  const historyLimit =
    typeof candidate.historyLimit === 'number' && Number.isSafeInteger(candidate.historyLimit)
      ? candidate.historyLimit
      : null;
  const rawSessions = candidate.sessions;
  if (
    !generatedAt ||
    loadedCount === null ||
    loadedCount < 0 ||
    loadedCount > ACTIVITY_HISTORY_EXPORT_LIMIT ||
    historyLimit === null ||
    historyLimit < 1 ||
    historyLimit > ACTIVITY_HISTORY_EXPORT_LIMIT ||
    loadedCount > historyLimit ||
    !Array.isArray(rawSessions) ||
    rawSessions.length !== loadedCount
  ) {
    return { kind: 'invalid', message: 'Activity history import has invalid bounded metadata.' };
  }

  const sessions: ActivityExportSession[] = [];
  const sourceIDs = new Set<string>();
  let bodyBytes = 0;
  for (const rawSession of rawSessions) {
    if (!rawSession || typeof rawSession !== 'object' || Array.isArray(rawSession)) {
      return { kind: 'invalid', message: 'Activity history import contains a malformed session row.' };
    }
    const row = rawSession as Record<string, unknown>;
    const id = boundedExportText(row.id, ACTIVITY_EXPORT_ID_MAX_CHARS);
    const provider = boundedExportText(row.provider);
    const model = boundedExportText(row.model);
    const startedAt = boundedExportText(row.startedAt);
    const title = boundedExportText(row.title);
    const sourceID = boundedExportText(row.sourceID, ACTIVITY_EXPORT_ID_MAX_CHARS);
    const providerSessionID = boundedExportOptionalText(row.providerSessionID, ACTIVITY_EXPORT_ID_MAX_CHARS);
    const runID = boundedExportOptionalText(row.runID, ACTIVITY_EXPORT_ID_MAX_CHARS);
    const projectName = boundedExportOptionalText(row.projectName);
    const bodyMD = boundedExportText(row.bodyMD, ACTIVITY_SESSION_BODY_MAX_BYTES, true);
    const tokens = typeof row.tokens === 'number' && Number.isFinite(row.tokens) ? row.tokens : null;
    const costUsd = typeof row.costUsd === 'number' && Number.isFinite(row.costUsd) ? row.costUsd : null;
    if (
      !id ||
      !provider ||
      !model ||
      !startedAt ||
      !title ||
      !sourceID ||
      !bodyMD ||
      providerSessionID === null ||
      runID === null ||
      projectName === null ||
      tokens === null ||
      costUsd === null
    ) {
      return { kind: 'invalid', message: 'Activity history import contains an incomplete session row.' };
    }
    if (sourceIDs.has(sourceID)) {
      return {
        kind: 'invalid',
        message: 'Activity history import contains duplicate source identities and cannot be resumed safely.'
      };
    }
    sourceIDs.add(sourceID);
    bodyBytes += utf8Bytes(bodyMD);
    if (bodyBytes > ACTIVITY_HISTORY_EXPORT_MAX_BYTES) {
      return { kind: 'invalid', message: 'Activity history import exceeds the bounded transcript size.' };
    }
    sessions.push({
      id,
      provider,
      model,
      startedAt,
      tokens,
      costUsd,
      title,
      sourceID,
      ...(providerSessionID ? { providerSessionID } : {}),
      ...(runID ? { runID } : {}),
      ...(projectName ? { projectName } : {}),
      bodyMD
    });
  }

  return {
    kind: 'valid',
    document: {
      version: 1,
      scope: 'daemon-session-history',
      source: 'live daemon session index',
      generatedAt,
      loadedCount,
      sessions,
      historyComplete: true,
      historyLimit
    }
  };
}

/**
 * Resume only the exact source identity selected from a validated export.
 * The transcript body is never sent back as an executable prompt; the daemon
 * remains the authority for current source existence and resume policy.
 */
export async function resumeActivityHistoryExportSession(
  document: ActivityExportDocument,
  sessionID: string,
  bridge: Pick<LinuxShellBridge, 'sessionList' | 'sessionResume'>
): Promise<ActivityExportResumeResult> {
  if (
    document.version !== 1 ||
    document.scope !== 'daemon-session-history' ||
    document.historyComplete !== true ||
    !Array.isArray(document.sessions)
  ) {
    return {
      kind: 'unavailable',
      code: 'invalid_export',
      message: 'Only a complete daemon-session-history export can be resumed.'
    };
  }
  const sourceID = sessionID.trim();
  const matches = document.sessions.filter((session) => session.sourceID?.trim() === sourceID);
  if (matches.length === 0) {
    return {
      kind: 'unavailable',
      code: 'session_not_found',
      message: 'The selected session is not present in this export.'
    };
  }
  if (matches.length !== 1 || !sourceID) {
    return {
      kind: 'unavailable',
      code: 'source_identity_unavailable',
      message: 'The selected export row does not have one verified source identity.'
    };
  }
  if (typeof bridge.sessionList !== 'function' || typeof bridge.sessionResume !== 'function') {
    return {
      kind: 'unavailable',
      code: 'bridge_unavailable',
      message: 'Resume from export requires the live daemon session index and resume bridge.'
    };
  }

  // An export is a portable snapshot, not authority that a source still exists.
  // Re-resolve the selected identity through a complete daemon list immediately
  // before spawning anything. This prevents a stale export from resuming an
  // ambiguous/reassigned usage row after deletion, provider migration, or DB
  // replacement. The daemon remains authoritative for the final run.resume.
  let current: Awaited<ReturnType<LinuxShellBridge['sessionList']>>;
  try {
    current = await bridge.sessionList();
  } catch {
    return {
      kind: 'unavailable',
      code: 'source_resolution_unavailable',
      message: 'Resume from export is unavailable because the daemon source index could not be read.'
    };
  }
  if (current.nextCursor !== null || current.complete !== true) {
    return {
      kind: 'unavailable',
      code: 'source_resolution_unavailable',
      message: 'Resume from export is unavailable because the daemon source index is paged or incomplete.'
    };
  }
  if ((current as CompleteActivityHistoryList).historyComplete !== true) {
    return {
      kind: 'unavailable',
      code: 'source_resolution_unavailable',
      message: 'Resume from export is unavailable because the daemon did not provide an explicit complete-history proof for source resolution.'
    };
  }
  const currentMatches = current.sessions.filter((session) => session.sourceID?.trim() === sourceID);
  if (currentMatches.length === 0) {
    return {
      kind: 'unavailable',
      code: 'session_not_found',
      message: 'The selected exported source is no longer present in the daemon index.'
    };
  }
  if (currentMatches.length !== 1) {
    return {
      kind: 'unavailable',
      code: 'source_identity_unavailable',
      message: 'The daemon returned more than one row for the selected source identity.'
    };
  }

  const exported = matches[0];
  const currentSession = currentMatches[0];
  const identityFields: Array<keyof Pick<
    ActivityExportSession,
    'provider' | 'providerSessionID' | 'runID' | 'projectName'
  >> = ['provider', 'providerSessionID', 'runID', 'projectName'];
  const identityMatches = identityFields.every((field) => {
    const expected = exported[field]?.trim();
    if (!expected) return true;
    return currentSession[field]?.trim() === expected;
  });
  if (!identityMatches) {
    return {
      kind: 'unavailable',
      code: 'source_identity_unavailable',
      message: 'The daemon source identity no longer matches the exported provider/session/project binding.'
    };
  }
  try {
    const result = await bridge.sessionResume(sourceID);
    if (result.kind === 'error' || result.errorCode) {
      return {
        kind: 'unavailable',
        code: 'daemon_error',
        message: result.errorRecovery ?? 'The daemon rejected resume for the selected exported session.'
      };
    }
    return { kind: 'requested', session: exported, result };
  } catch (error) {
    return {
      kind: 'unavailable',
      code: 'daemon_error',
      message: error instanceof Error ? error.message : 'The daemon could not resume the selected exported session.'
    };
  }
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
