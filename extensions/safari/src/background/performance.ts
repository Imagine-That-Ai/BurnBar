import type { BrowserAPI } from '../shared/browser';
import {
  SAFARI_PERFORMANCE_MAX_DURATION_MS,
  SAFARI_PERFORMANCE_RETENTION_LIMIT,
  SAFARI_PERFORMANCE_SCHEMA_VERSION,
  buildSafariPerformanceDiagnostics,
  emptyStoredSafariPerformanceState,
  parseStoredSafariPerformanceState,
  sanitizeSafariPerformanceContext,
  type SafariPerformanceContext,
  type SafariPerformanceDiagnostics,
  type SafariPerformanceMetricName,
  type SafariPerformanceOutcome,
  type StoredSafariPerformanceState
} from '../shared/performance';

export const SAFARI_PERFORMANCE_STORAGE_KEY = 'openburnbar.safari.performance.v1';

interface SafariPerformanceRecorderOptions {
  retentionLimit?: number;
  persistenceDelayMs?: number;
  monotonicNow?: () => number;
  wallNow?: () => Date;
}

export class SafariPerformanceRecorder {
  private state: StoredSafariPerformanceState;
  private persistence: SafariPerformanceDiagnostics['persistence'] = 'ready';
  private loaded = false;
  private loadPromise: Promise<void> | undefined;
  private persistTimer: ReturnType<typeof setTimeout> | undefined;
  private persistChain = Promise.resolve();
  private readonly persistenceDelayMs: number;
  private readonly monotonicNow: () => number;
  private readonly wallNow: () => Date;

  constructor(
    private readonly browserAPI: BrowserAPI,
    options: SafariPerformanceRecorderOptions = {}
  ) {
    const retentionLimit = Math.max(1, Math.floor(options.retentionLimit ?? SAFARI_PERFORMANCE_RETENTION_LIMIT));
    this.state = emptyStoredSafariPerformanceState(retentionLimit);
    this.persistenceDelayMs = Math.max(0, Math.floor(options.persistenceDelayMs ?? 1_000));
    this.monotonicNow = options.monotonicNow ?? (() => performance.now());
    this.wallNow = options.wallNow ?? (() => new Date());
  }

  start(): number {
    return this.monotonicNow();
  }

  async load(): Promise<void> {
    if (this.loaded) {
      return;
    }
    if (this.loadPromise) {
      return this.loadPromise;
    }
    this.loadPromise = this.performLoad().finally(() => {
      this.loadPromise = undefined;
      this.loaded = true;
    });
    return this.loadPromise;
  }

  recordElapsed(
    metric: SafariPerformanceMetricName,
    startedAt: number,
    outcome: SafariPerformanceOutcome,
    context?: SafariPerformanceContext
  ): void {
    this.recordDuration(metric, this.monotonicNow() - startedAt, outcome, context);
  }

  recordDuration(
    metric: SafariPerformanceMetricName,
    durationMs: number,
    outcome: SafariPerformanceOutcome,
    context?: SafariPerformanceContext
  ): void {
    const normalizedDuration = Math.min(
      Math.max(0, Math.round((Number.isFinite(durationMs) ? durationMs : 0) * 100) / 100),
      SAFARI_PERFORMANCE_MAX_DURATION_MS
    );
    const safeContext = sanitizeSafariPerformanceContext(context);
    this.state.samples.push({
      sequence: this.state.nextSequence,
      metric,
      durationMs: normalizedDuration,
      outcome,
      recordedAt: this.wallNow().toISOString(),
      ...(safeContext ? { context: safeContext } : {})
    });
    this.state.nextSequence += 1;
    this.state.totalRecorded += 1;
    if (this.state.samples.length > this.state.retentionLimit) {
      const removed = this.state.samples.length - this.state.retentionLimit;
      this.state.samples.splice(0, removed);
      this.state.droppedCount += removed;
    }
    this.schedulePersist();
  }

  snapshot(): SafariPerformanceDiagnostics {
    return buildSafariPerformanceDiagnostics(this.state, this.persistence);
  }

  async clear(): Promise<void> {
    if (this.persistTimer !== undefined) {
      clearTimeout(this.persistTimer);
      this.persistTimer = undefined;
    }
    this.state = emptyStoredSafariPerformanceState(this.state.retentionLimit);
    this.enqueuePersist();
    await this.persistChain;
  }

  async flush(): Promise<void> {
    if (this.persistTimer !== undefined) {
      clearTimeout(this.persistTimer);
      this.persistTimer = undefined;
    }
    this.enqueuePersist();
    await this.persistChain;
  }

  private async performLoad(): Promise<void> {
    try {
      const stored = await this.browserAPI.storage.local.get(SAFARI_PERFORMANCE_STORAGE_KEY);
      this.state = parseStoredSafariPerformanceState(stored[SAFARI_PERFORMANCE_STORAGE_KEY], this.state.retentionLimit);
      this.persistence = 'ready';
    } catch {
      this.persistence = 'memory_only';
    }
  }

  private schedulePersist(): void {
    if (this.persistTimer !== undefined) {
      return;
    }
    this.persistTimer = setTimeout(() => {
      this.persistTimer = undefined;
      this.enqueuePersist();
    }, this.persistenceDelayMs);
  }

  private enqueuePersist(): void {
    const value: StoredSafariPerformanceState = {
      schemaVersion: SAFARI_PERFORMANCE_SCHEMA_VERSION,
      retentionLimit: this.state.retentionLimit,
      totalRecorded: this.state.totalRecorded,
      droppedCount: this.state.droppedCount,
      nextSequence: this.state.nextSequence,
      samples: this.state.samples.map((sample) => structuredClone(sample))
    };
    this.persistChain = this.persistChain
      .catch(() => undefined)
      .then(async () => {
        try {
          await this.browserAPI.storage.local.set({
            [SAFARI_PERFORMANCE_STORAGE_KEY]: value
          });
          this.persistence = 'ready';
        } catch {
          this.persistence = 'memory_only';
        }
      });
  }
}
