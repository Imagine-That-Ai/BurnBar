import { beforeEach, describe, expect, it } from 'vitest';

import {
  createAnalytics,
  bootAnalytics,
  grantAnalyticsConsent,
  declineAnalyticsConsent,
  revokeAnalyticsConsent,
  EVENT,
  SURFACE,
  type AnalyticsHost
} from '../../src/analytics/index';
import type { AnalyticsTransport, AnalyticsProps } from '../../src/analytics/recorder';
import type { ConsentStorage } from '../../src/analytics/consent';

class FakeTransport implements AnalyticsTransport {
  startCalls = 0;
  events: { name: string; category: string; props: AnalyticsProps }[] = [];
  private _started = false;
  get isStarted(): boolean {
    return this._started;
  }
  start(): void {
    this.startCalls += 1;
    this._started = true;
  }
  track(name: string, category: string, props: AnalyticsProps): void {
    this.events.push({ name, category, props });
  }
  stop(): void {
    this._started = false;
  }
}

function memoryStorage(): ConsentStorage {
  const m = new Map<string, string>();
  return { get: (k) => m.get(k), update: (k, v) => void m.set(k, v) };
}

function host(transport: FakeTransport): AnalyticsHost {
  return {
    storage: memoryStorage(),
    deviceId: 'fixed-device-uuid',
    appVersion: '1.2.3',
    telemetrySignal: { isEnabled: true },
    transport,
    apiKey: 'wiring-test-key-0123',
    serverZone: 'US'
  };
}

describe('analytics wiring (index.ts graph)', () => {
  let transport: FakeTransport;

  beforeEach(() => {
    transport = new FakeTransport();
  });

  it('boot before consent is fully dark', () => {
    const graph = createAnalytics(host(transport));
    bootAnalytics(graph, { isFirstActivation: true, hostKind: 'VS Code' });
    expect(transport.startCalls).toBe(0);
    expect(transport.events).toHaveLength(0);
  });

  it('boot while host telemetry is off does not mark the analytics spine as fired', () => {
    const telemetry = { isEnabled: false };
    const graph = createAnalytics({ ...host(transport), telemetrySignal: telemetry });
    grantAnalyticsConsent(graph, { isFirstActivation: true, hostKind: 'VS Code' });
    expect(transport.startCalls).toBe(0);
    expect(transport.events).toHaveLength(0);

    telemetry.isEnabled = true;
    bootAnalytics(graph, { isFirstActivation: true, hostKind: 'VS Code' });

    const names = transport.events.map((e) => e.name);
    expect(names).toContain(EVENT.appSessionStarted);
    expect(names).toContain(EVENT.appOpened);
    expect(names).toContain(EVENT.installStarted);
    expect(names).toContain(EVENT.vscodeExtensionActivated);
    expect(names).toContain(EVENT.screenViewed);
  });

  it('grant emits grant + the lifecycle spine, with vscode super-properties', () => {
    const graph = createAnalytics(host(transport));
    grantAnalyticsConsent(graph, { isFirstActivation: true, hostKind: 'VS Code' });

    const names = transport.events.map((e) => e.name);
    expect(names).toContain(EVENT.consentAnalyticsGranted);
    expect(names).toContain(EVENT.appSessionStarted);
    expect(names).toContain(EVENT.appOpened);
    expect(names).toContain(EVENT.installStarted);
    expect(names).toContain(EVENT.vscodeExtensionActivated);
    expect(names).toContain(EVENT.screenViewed);

    // consent.granted first, exactly once.
    expect(names.filter((n) => n === EVENT.consentAnalyticsGranted)).toHaveLength(1);

    // Every event carries the platform super-property.
    for (const e of transport.events) {
      expect(e.props.platform).toBe('vscode');
      expect(e.props.app_version).toBe('1.2.3');
    }

    // session start carries the right flags, screen.viewed carries a bounded surface.
    const start = transport.events.find((e) => e.name === EVENT.appSessionStarted);
    expect(start).toBeDefined();
    if (!start) throw new Error('missing session start analytics event');
    expect(start.props).toMatchObject({ is_first_launch: true, cold_start: true });
    const opened = transport.events.find((e) => e.name === EVENT.appOpened);
    expect(opened).toBeDefined();
    if (!opened) throw new Error('missing app opened analytics event');
    expect(opened.props.surface).toBe('extension');
    const installed = transport.events.find((e) => e.name === EVENT.installStarted);
    expect(installed).toBeDefined();
    if (!installed) throw new Error('missing install started analytics event');
    expect(installed.props.surface).toBe('extension');
    const view = transport.events.find((e) => e.name === EVENT.screenViewed);
    expect(view).toBeDefined();
    if (!view) throw new Error('missing screen viewed analytics event');
    expect(view.props.surface).toBe(SURFACE.app);
    expect(view.props.is_first_view).toBe(true);
  });

  it('boot after grant (relaunch) resumes WITHOUT a second grant', () => {
    const sharedStorage = memoryStorage();
    const h1: AnalyticsHost = { ...host(transport), storage: sharedStorage };
    const graph1 = createAnalytics(h1);
    grantAnalyticsConsent(graph1, { isFirstActivation: true, hostKind: 'VS Code' });

    // Simulate a relaunch: new transport + graph, same persisted consent.
    const transport2 = new FakeTransport();
    const graph2 = createAnalytics({ ...host(transport2), storage: sharedStorage });
    bootAnalytics(graph2, { isFirstActivation: false, hostKind: 'VS Code' });

    const grants = transport2.events.filter((e) => e.name === EVENT.consentAnalyticsGranted);
    expect(grants).toHaveLength(0);
    expect(transport2.startCalls).toBe(1); // resumed
    // session start on relaunch is not a first launch.
    const start = transport2.events.find((e) => e.name === EVENT.appSessionStarted);
    expect(start).toBeDefined();
    if (!start) throw new Error('missing relaunch session start analytics event');
    expect(start.props.is_first_launch).toBe(false);
    expect(transport2.events.some((e) => e.name === EVENT.installStarted)).toBe(false);
  });

  it('boot is idempotent: the session spine fires at most once per process', () => {
    const graph = createAnalytics(host(transport));
    grantAnalyticsConsent(graph, { isFirstActivation: true, hostKind: 'VS Code' });
    // Simulate the initialize() path that boots again after sync-driven grant.
    bootAnalytics(graph, { isFirstActivation: true, hostKind: 'VS Code' });
    bootAnalytics(graph, { isFirstActivation: true, hostKind: 'VS Code' });

    const sessionStarts = transport.events.filter((e) => e.name === EVENT.appSessionStarted);
    const views = transport.events.filter((e) => e.name === EVENT.screenViewed);
    expect(sessionStarts).toHaveLength(1);
    expect(views).toHaveLength(1);
  });

  it('decline stays dark', () => {
    const graph = createAnalytics(host(transport));
    declineAnalyticsConsent(graph);
    bootAnalytics(graph, { isFirstActivation: true, hostKind: 'VS Code' });
    expect(transport.startCalls).toBe(0);
    expect(transport.events).toHaveLength(0);
    expect(graph.consent.state).toBe('declined');
  });

  it('revoke after grant goes silent and lands in declined', () => {
    const graph = createAnalytics(host(transport));
    grantAnalyticsConsent(graph, { isFirstActivation: true, hostKind: 'VS Code' });
    transport.events.length = 0;
    revokeAnalyticsConsent(graph);
    expect(transport.isStarted).toBe(false);
    expect(transport.events).toHaveLength(0);
    expect(graph.consent.state).toBe('declined');
  });
});
