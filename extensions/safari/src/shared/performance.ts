import { isSafariActionKind, isStringLiteral, type SafariActionKind } from './protocol';

export const SAFARI_PERFORMANCE_SCHEMA_VERSION = 1;
export const SAFARI_PERFORMANCE_RETENTION_LIMIT = 240;
export const SAFARI_PERFORMANCE_MAX_DURATION_MS = 10 * 60 * 1_000;

export const SAFARI_PERFORMANCE_METRICS = [
  'popup_bootstrap',
  'native_attach',
  'command_poll',
  'command_completion',
  'viewport_capture',
  'image_resize',
  'ask_first_token',
  'action_verification',
  'stop_panic',
  'learning_load',
  'learning_mutation'
] as const;

export type SafariPerformanceMetricName = (typeof SAFARI_PERFORMANCE_METRICS)[number];
export type SafariPerformanceOutcome = 'success' | 'error' | 'aborted';

export interface SafariPerformanceContext {
  route?: 'local' | 'cloud';
  capture?: 'viewport' | 'full_page_segment';
  imagePath?: 'offscreen' | 'content_fallback' | 'full_page_stitch';
  action?: SafariActionKind;
  trigger?: 'stop_button' | 'popup_shortcut' | 'daemon_abort';
  learningOperation?: 'load' | 'opt_in' | 'opt_out' | 'propose' | 'approve' | 'reject' | 'forget';
  command?: 'empty' | 'issued';
}

export interface SafariPerformanceSample {
  sequence: number;
  metric: SafariPerformanceMetricName;
  durationMs: number;
  outcome: SafariPerformanceOutcome;
  recordedAt: string;
  context?: SafariPerformanceContext;
}

export interface SafariPerformanceSummary {
  metric: SafariPerformanceMetricName;
  retainedCount: number;
  successCount: number;
  errorCount: number;
  abortedCount: number;
  minimumMs: number;
  medianMs: number;
  p95Ms: number;
  maximumMs: number;
  latestMs: number;
}

export interface SafariPerformanceDiagnostics {
  schemaVersion: typeof SAFARI_PERFORMANCE_SCHEMA_VERSION;
  retentionLimit: number;
  totalRecorded: number;
  droppedCount: number;
  persistence: 'ready' | 'memory_only';
  samples: SafariPerformanceSample[];
  summaries: SafariPerformanceSummary[];
}

export interface StoredSafariPerformanceState {
  schemaVersion: typeof SAFARI_PERFORMANCE_SCHEMA_VERSION;
  retentionLimit: number;
  totalRecorded: number;
  droppedCount: number;
  nextSequence: number;
  samples: SafariPerformanceSample[];
}

const METRIC_SET = new Set<string>(SAFARI_PERFORMANCE_METRICS);
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function finiteInteger(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : fallback;
}

function boundedDuration(value: unknown): number | undefined {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }
  return Math.min(Math.round(value * 100) / 100, SAFARI_PERFORMANCE_MAX_DURATION_MS);
}

function isoTimestamp(value: unknown): string | undefined {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) {
    return undefined;
  }
  return new Date(value).toISOString();
}

function isSafariPerformanceMetricName(value: unknown): value is SafariPerformanceMetricName {
  return typeof value === 'string' && METRIC_SET.has(value);
}

function isSafariPerformanceOutcome(value: unknown): value is SafariPerformanceOutcome {
  return isStringLiteral(value, ['success', 'error', 'aborted']);
}

export function sanitizeSafariPerformanceContext(value: unknown): SafariPerformanceContext | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  const context: SafariPerformanceContext = {};
  if (isStringLiteral(value.route, ['local', 'cloud'])) {
    context.route = value.route;
  }
  if (isStringLiteral(value.capture, ['viewport', 'full_page_segment'])) {
    context.capture = value.capture;
  }
  if (isStringLiteral(value.imagePath, ['offscreen', 'content_fallback', 'full_page_stitch'])) {
    context.imagePath = value.imagePath;
  }
  if (isSafariActionKind(value.action)) {
    context.action = value.action;
  }
  if (isStringLiteral(value.trigger, ['stop_button', 'popup_shortcut', 'daemon_abort'])) {
    context.trigger = value.trigger;
  }
  if (
    isStringLiteral(value.learningOperation, ['load', 'opt_in', 'opt_out', 'propose', 'approve', 'reject', 'forget'])
  ) {
    context.learningOperation = value.learningOperation;
  }
  if (isStringLiteral(value.command, ['empty', 'issued'])) {
    context.command = value.command;
  }
  return Object.keys(context).length > 0 ? context : undefined;
}

export function parseSafariPerformanceSample(value: unknown): SafariPerformanceSample | undefined {
  if (!isRecord(value) || !isSafariPerformanceMetricName(value.metric) || !isSafariPerformanceOutcome(value.outcome)) {
    return undefined;
  }
  const sequence = finiteInteger(value.sequence, 0);
  const durationMs = boundedDuration(value.durationMs);
  const recordedAt = isoTimestamp(value.recordedAt);
  if (sequence < 1 || durationMs === undefined || !recordedAt) {
    return undefined;
  }
  const context = sanitizeSafariPerformanceContext(value.context);
  return {
    sequence,
    metric: value.metric,
    durationMs,
    outcome: value.outcome,
    recordedAt,
    ...(context ? { context } : {})
  };
}

export function parseStoredSafariPerformanceState(
  value: unknown,
  retentionLimit = SAFARI_PERFORMANCE_RETENTION_LIMIT
): StoredSafariPerformanceState {
  const safeRetentionLimit = Math.max(1, Math.floor(retentionLimit));
  if (!isRecord(value) || value.schemaVersion !== SAFARI_PERFORMANCE_SCHEMA_VERSION) {
    return emptyStoredSafariPerformanceState(safeRetentionLimit);
  }
  const allParsed = Array.isArray(value.samples)
    ? value.samples
        .map(parseSafariPerformanceSample)
        .filter((sample): sample is SafariPerformanceSample => sample !== undefined)
        .sort((left, right) => left.sequence - right.sequence)
    : [];
  const parsed = allParsed.slice(-safeRetentionLimit);
  const maximumSequence = parsed.at(-1)?.sequence ?? 0;
  const declaredDroppedCount = finiteInteger(value.droppedCount, 0);
  const totalRecorded = Math.max(
    finiteInteger(value.totalRecorded, allParsed.length),
    allParsed.length,
    declaredDroppedCount + parsed.length
  );
  const droppedCount = totalRecorded - parsed.length;
  const nextSequence = Math.max(finiteInteger(value.nextSequence, maximumSequence + 1), maximumSequence + 1, 1);
  return {
    schemaVersion: SAFARI_PERFORMANCE_SCHEMA_VERSION,
    retentionLimit: safeRetentionLimit,
    totalRecorded,
    droppedCount,
    nextSequence,
    samples: parsed
  };
}

export function emptyStoredSafariPerformanceState(
  retentionLimit = SAFARI_PERFORMANCE_RETENTION_LIMIT
): StoredSafariPerformanceState {
  return {
    schemaVersion: SAFARI_PERFORMANCE_SCHEMA_VERSION,
    retentionLimit: Math.max(1, Math.floor(retentionLimit)),
    totalRecorded: 0,
    droppedCount: 0,
    nextSequence: 1,
    samples: []
  };
}

function percentile(sorted: number[], fraction: number): number {
  if (sorted.length === 0) {
    return 0;
  }
  const index = Math.max(0, Math.ceil(sorted.length * fraction) - 1);
  return sorted[Math.min(index, sorted.length - 1)] ?? 0;
}

export function summarizeSafariPerformance(samples: SafariPerformanceSample[]): SafariPerformanceSummary[] {
  return SAFARI_PERFORMANCE_METRICS.flatMap((metric) => {
    const metricSamples = samples.filter((sample) => sample.metric === metric);
    if (metricSamples.length === 0) {
      return [];
    }
    const durations = metricSamples.map((sample) => sample.durationMs).sort((left, right) => left - right);
    const latest = metricSamples.at(-1);
    return [
      {
        metric,
        retainedCount: metricSamples.length,
        successCount: metricSamples.filter((sample) => sample.outcome === 'success').length,
        errorCount: metricSamples.filter((sample) => sample.outcome === 'error').length,
        abortedCount: metricSamples.filter((sample) => sample.outcome === 'aborted').length,
        minimumMs: durations[0] ?? 0,
        medianMs: percentile(durations, 0.5),
        p95Ms: percentile(durations, 0.95),
        maximumMs: durations.at(-1) ?? 0,
        latestMs: latest?.durationMs ?? 0
      }
    ];
  });
}

export function buildSafariPerformanceDiagnostics(
  state: StoredSafariPerformanceState,
  persistence: SafariPerformanceDiagnostics['persistence']
): SafariPerformanceDiagnostics {
  const samples = state.samples.map((sample) => structuredClone(sample));
  return {
    schemaVersion: SAFARI_PERFORMANCE_SCHEMA_VERSION,
    retentionLimit: state.retentionLimit,
    totalRecorded: state.totalRecorded,
    droppedCount: state.droppedCount,
    persistence,
    samples,
    summaries: summarizeSafariPerformance(samples)
  };
}

export function emptySafariPerformanceDiagnostics(): SafariPerformanceDiagnostics {
  return buildSafariPerformanceDiagnostics(emptyStoredSafariPerformanceState(), 'ready');
}
