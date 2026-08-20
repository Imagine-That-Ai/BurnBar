import { SafariPerformanceRecorder, SAFARI_PERFORMANCE_STORAGE_KEY } from '../src/background/performance';
import {
  buildSafariPerformanceExport,
  formatPerformanceDuration,
  safariPerformanceExportFilename
} from '../src/popup/diagnostics';
import type { PopupSnapshot } from '../src/shared/messages';
import {
  SAFARI_PERFORMANCE_MAX_DURATION_MS,
  buildSafariPerformanceDiagnostics,
  parseSafariPerformanceSample,
  parseStoredSafariPerformanceState,
  sanitizeSafariPerformanceContext,
  summarizeSafariPerformance
} from '../src/shared/performance';
import { createMockBrowser } from './helpers/mockBrowser';

function popupSnapshot(): PopupSnapshot {
  return {
    stateVersion: 1,
    bridge: {
      connection: 'connected',
      daemonVersion: '1.0.34',
      gatewayReady: true,
      killSwitchEnabled: false,
      agents: []
    },
    mode: 'ask',
    trust: {
      globalKillSwitch: false,
      onlyCurrentTab: true,
      siteAllowed: true,
      sensitiveSiteOverride: false,
      cloudScreenshotAcknowledged: false
    },
    learning: {
      eligible: false,
      optedIn: false,
      consentSeen: false,
      items: []
    },
    transcript: [],
    approvals: [],
    activity: [],
    performance: buildSafariPerformanceDiagnostics(
      {
        schemaVersion: 1,
        retentionLimit: 3,
        totalRecorded: 1,
        droppedCount: 0,
        nextSequence: 2,
        samples: [
          {
            sequence: 1,
            metric: 'popup_bootstrap',
            durationMs: 42.5,
            outcome: 'success',
            recordedAt: '2026-08-12T12:00:00.000Z'
          }
        ]
      },
      'ready'
    ),
    running: false,
    busy: false
  };
}

describe('Safari performance evidence', () => {
  it('sanitizes categorical context and rejects malformed samples without retaining sensitive fields', () => {
    expect(
      sanitizeSafariPerformanceContext({
        route: 'cloud',
        action: 'click',
        trigger: 'popup_shortcut',
        url: 'https://secret.example/',
        prompt: 'private question',
        token: 'do-not-retain'
      })
    ).toEqual({
      route: 'cloud',
      action: 'click',
      trigger: 'popup_shortcut'
    });

    expect(
      parseSafariPerformanceSample({
        sequence: 4,
        metric: 'ask_first_token',
        durationMs: SAFARI_PERFORMANCE_MAX_DURATION_MS + 50_000,
        outcome: 'success',
        recordedAt: '2026-08-12T12:00:00Z',
        context: {
          route: 'local',
          providerId: 'private-provider'
        }
      })
    ).toEqual({
      sequence: 4,
      metric: 'ask_first_token',
      durationMs: SAFARI_PERFORMANCE_MAX_DURATION_MS,
      outcome: 'success',
      recordedAt: '2026-08-12T12:00:00.000Z',
      context: {
        route: 'local'
      }
    });
    expect(parseSafariPerformanceSample({ metric: 'unknown' })).toBeUndefined();
    expect(
      parseSafariPerformanceSample({
        sequence: 1,
        metric: 'command_poll',
        durationMs: -1,
        outcome: 'success',
        recordedAt: 'not-a-date'
      })
    ).toBeUndefined();
  });

  it('repairs stored counters, bounds retention, and calculates honest retained percentiles and outcomes', () => {
    const state = parseStoredSafariPerformanceState(
      {
        schemaVersion: 1,
        retentionLimit: 99,
        totalRecorded: 2,
        droppedCount: 0,
        nextSequence: 1,
        samples: [
          {
            sequence: 1,
            metric: 'command_poll',
            durationMs: 10,
            outcome: 'success',
            recordedAt: '2026-08-12T12:00:00Z'
          },
          {
            sequence: 2,
            metric: 'command_poll',
            durationMs: 40,
            outcome: 'error',
            recordedAt: '2026-08-12T12:00:01Z'
          },
          {
            sequence: 3,
            metric: 'command_poll',
            durationMs: 20,
            outcome: 'aborted',
            recordedAt: '2026-08-12T12:00:02Z'
          }
        ]
      },
      2
    );
    expect(state).toMatchObject({
      retentionLimit: 2,
      totalRecorded: 3,
      droppedCount: 1,
      nextSequence: 4
    });
    expect(state.samples.map((sample) => sample.sequence)).toEqual([2, 3]);

    const summaries = summarizeSafariPerformance(state.samples);
    expect(summaries).toEqual([
      {
        metric: 'command_poll',
        retainedCount: 2,
        successCount: 0,
        errorCount: 1,
        abortedCount: 1,
        minimumMs: 20,
        medianMs: 20,
        p95Ms: 40,
        maximumMs: 40,
        latestMs: 20
      }
    ]);

    const contradictoryCounters = parseStoredSafariPerformanceState(
      {
        schemaVersion: 1,
        totalRecorded: 1,
        droppedCount: 9,
        nextSequence: 1,
        samples: state.samples
      },
      2
    );
    expect(contradictoryCounters).toMatchObject({
      totalRecorded: 11,
      droppedCount: 9,
      nextSequence: 4
    });
    expect(contradictoryCounters.totalRecorded).toBe(
      contradictoryCounters.droppedCount + contradictoryCounters.samples.length
    );
  });

  it('records with monotonic time, retains only the bounded window, and reloads durable local evidence', async () => {
    const { browser, controls } = createMockBrowser();
    let monotonicNow = 100;
    let wallTick = 0;
    const recorder = new SafariPerformanceRecorder(browser, {
      retentionLimit: 2,
      persistenceDelayMs: 60_000,
      monotonicNow: () => monotonicNow,
      wallNow: () => new Date(Date.UTC(2026, 7, 12, 12, 0, wallTick++))
    });
    await recorder.load();

    const firstStartedAt = recorder.start();
    monotonicNow = 112.345;
    recorder.recordElapsed('native_attach', firstStartedAt, 'success');
    recorder.recordDuration('command_poll', 4.5, 'success', { command: 'empty' });
    Reflect.apply(recorder.recordDuration, recorder, [
      'stop_panic',
      SAFARI_PERFORMANCE_MAX_DURATION_MS + 50_000,
      'aborted',
      { trigger: 'popup_shortcut', route: 'not-valid' }
    ]);
    await recorder.flush();

    expect(recorder.snapshot()).toMatchObject({
      retentionLimit: 2,
      totalRecorded: 3,
      droppedCount: 1,
      persistence: 'ready'
    });
    expect(recorder.snapshot().samples.map((sample) => sample.metric)).toEqual(['command_poll', 'stop_panic']);
    expect(recorder.snapshot().samples.at(-1)).toMatchObject({
      durationMs: SAFARI_PERFORMANCE_MAX_DURATION_MS,
      context: {
        trigger: 'popup_shortcut'
      }
    });
    expect(controls.storage.get(SAFARI_PERFORMANCE_STORAGE_KEY)).toMatchObject({
      totalRecorded: 3,
      droppedCount: 1,
      nextSequence: 4
    });

    await recorder.clear();
    expect(recorder.snapshot()).toMatchObject({
      retentionLimit: 2,
      totalRecorded: 0,
      droppedCount: 0,
      samples: [],
      summaries: []
    });
    expect(controls.storage.get(SAFARI_PERFORMANCE_STORAGE_KEY)).toMatchObject({
      retentionLimit: 2,
      totalRecorded: 0,
      droppedCount: 0,
      nextSequence: 1,
      samples: []
    });

    const reloaded = new SafariPerformanceRecorder(browser, {
      retentionLimit: 2,
      persistenceDelayMs: 60_000
    });
    await reloaded.load();
    expect(reloaded.snapshot()).toMatchObject({
      totalRecorded: 0,
      droppedCount: 0,
      samples: []
    });
  });

  it('falls back to an exportable memory-only buffer when Safari local storage fails', async () => {
    const { browser } = createMockBrowser();
    browser.storage.local.set = vi.fn(async () => {
      throw new Error('storage unavailable');
    });
    const recorder = new SafariPerformanceRecorder(browser, {
      persistenceDelayMs: 60_000
    });
    await recorder.load();
    recorder.recordDuration('learning_mutation', 15, 'error', {
      learningOperation: 'approve'
    });
    await recorder.flush();
    expect(recorder.snapshot()).toMatchObject({
      persistence: 'memory_only',
      totalRecorded: 1
    });
  });

  it('builds a stable privacy declaration and useful local JSON filename without page or provider data', () => {
    const exportedAt = new Date('2026-08-12T12:34:56.789Z');
    const exported = buildSafariPerformanceExport(popupSnapshot(), '1.0.34', exportedAt);
    expect(exported).toMatchObject({
      schemaVersion: 1,
      exportedAt: '2026-08-12T12:34:56.789Z',
      extension: {
        version: '1.0.34',
        daemonVersion: '1.0.34'
      },
      privacy: {
        localOnly: true
      }
    });
    const serialized = JSON.stringify(exported);
    expect(serialized).not.toContain('example.com');
    expect(serialized).not.toContain('private-provider');
    expect(safariPerformanceExportFilename(exportedAt)).toBe(
      'openburnbar-safari-performance-2026-08-12T12-34-56.789Z.json'
    );
    expect(formatPerformanceDuration(0.42)).toBe('0.42 ms');
    expect(formatPerformanceDuration(42.4)).toBe('42 ms');
    expect(formatPerformanceDuration(1_250)).toBe('1.25 s');
  });
});
