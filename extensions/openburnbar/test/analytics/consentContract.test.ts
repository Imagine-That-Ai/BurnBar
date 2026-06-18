import { beforeEach, describe, expect, it } from 'vitest';

import { ConsentStore, CONSENT_STORAGE_KEY, type ConsentStorage } from '../../src/analytics/consent';
import {
  Analytics,
  type AnalyticsTransport,
  type AnalyticsProps,
  type ConsentSignal
} from '../../src/analytics/recorder';
import { EVENT } from '../../src/analytics/events';

/** In-memory storage standing in for VS Code globalState. */
function memoryStorage(initial?: Record<string, string>): ConsentStorage {
  const m = new Map<string, string>(Object.entries(initial ?? {}));
  return {
    get: (k) => m.get(k),
    update: (k, v) => {
      m.set(k, v);
    }
  };
}

interface RecordedEvent {
  name: string;
  category: string;
  props: AnalyticsProps;
}

/** Fake transport: records every call so the test can assert the gate. Crucially
 *  it counts how many times `start` was invoked — the proof of pre-consent
 *  darkness is `startCalls === 0`. */
class FakeTransport implements AnalyticsTransport {
  startCalls = 0;
  stopCalls = 0;
  startedWithKey: string | undefined;
  events: RecordedEvent[] = [];
  private _started = false;

  get isStarted(): boolean {
    return this._started;
  }

  start(apiKey: string): void {
    this.startCalls += 1;
    this.startedWithKey = apiKey;
    this._started = true;
  }

  track(name: string, category: string, props: AnalyticsProps): void {
    this.events.push({ name, category, props });
  }

  stop(): void {
    this.stopCalls += 1;
    this._started = false;
  }
}

/** A flippable AND-gate signal (stands in for VS Code's isTelemetryEnabled). */
class FakeSignal implements ConsentSignal {
  constructor(public enabled = true) {}
  get isEnabled(): boolean {
    return this.enabled;
  }
}

const KEY = 'amp-test-key-0123456789';

function build(opts?: { state?: 'unset' | 'granted' | 'declined'; apiKey?: string; signal?: FakeSignal }) {
  const storage = memoryStorage(opts?.state ? { [CONSENT_STORAGE_KEY]: opts.state } : undefined);
  const consent = new ConsentStore(storage);
  const transport = new FakeTransport();
  const signal = opts?.signal ?? new FakeSignal(true);
  const analytics = new Analytics({
    consent,
    transport,
    apiKey: opts?.apiKey ?? KEY,
    superProperties: () => ({ platform: 'vscode', app_version: '9.9.9', surface: 'app' }),
    extraSignals: [signal]
  });
  return { storage, consent, transport, analytics, signal };
}

describe('analytics consent contract (VS Code extension)', () => {
  let env: ReturnType<typeof build>;

  describe('PROVABLY dark before opt-in (default unset)', () => {
    beforeEach(() => {
      env = build({ state: 'unset' });
    });

    it('never constructs/starts the transport and emits nothing', () => {
      env.analytics.startIfConsented();
      env.analytics.track(EVENT.vscodeCommandInvoked, { command_id: 'refresh' });
      env.analytics.track(EVENT.screenViewed, { surface: 'panel', is_first_view: true });

      // The transport's start() is the gate to ever constructing the SDK.
      expect(env.transport.startCalls).toBe(0);
      expect(env.transport.isStarted).toBe(false);
      expect(env.transport.events).toHaveLength(0);
    });

    it('stays dark even when consentDidChange is called while still unset', () => {
      env.analytics.consentDidChange();
      expect(env.transport.startCalls).toBe(0);
      expect(env.transport.events).toHaveLength(0);
    });
  });

  describe('declined is identical to unset (also dark)', () => {
    it('drops every call and never starts', () => {
      env = build({ state: 'declined' });
      env.analytics.startIfConsented();
      env.analytics.track(EVENT.vscodeRunAction, { action: 'start', outcome: 'success' });
      expect(env.transport.startCalls).toBe(0);
      expect(env.transport.events).toHaveLength(0);
    });
  });

  describe('on grant', () => {
    beforeEach(() => {
      env = build({ state: 'unset' });
    });

    it('starts the transport and emits EXACTLY ONE consent.analytics.granted', () => {
      env.consent.grant();
      env.analytics.consentDidChange();

      expect(env.transport.startCalls).toBe(1);
      expect(env.transport.startedWithKey).toBe(KEY);
      const grants = env.transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted);
      expect(grants).toHaveLength(1);
      expect(grants[0].category).toBe('lifecycle');
      expect(grants[0].props.consent_version).toBe('1');
    });

    it('does not re-emit grant if consentDidChange fires again while granted', () => {
      env.consent.grant();
      env.analytics.consentDidChange();
      env.analytics.consentDidChange();
      env.analytics.consentDidChange();
      const grants = env.transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted);
      expect(grants).toHaveLength(1);
      expect(env.transport.startCalls).toBe(1); // started once, not re-started
    });

    it('stamps super-properties and the correct category on a tracked event', () => {
      env.consent.grant();
      env.analytics.consentDidChange();
      env.analytics.track(EVENT.vscodeCommandInvoked, { command_id: 'start_run' });

      const cmd = env.transport.events.find((e) => e.name === EVENT.vscodeCommandInvoked);
      expect(cmd).toBeDefined();
      if (!cmd) throw new Error('missing command analytics event');
      expect(cmd.category).toBe('primary_action');
      expect(cmd.props).toMatchObject({
        platform: 'vscode',
        app_version: '9.9.9',
        surface: 'app',
        command_id: 'start_run'
      });
    });
  });

  describe('resume of an already-consented session (relaunch)', () => {
    it('starts WITHOUT re-emitting grant', () => {
      env = build({ state: 'granted' });
      env.analytics.startIfConsented();
      expect(env.transport.startCalls).toBe(1);
      const grants = env.transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted);
      expect(grants).toHaveLength(0); // resume is not a new opt-in
    });
  });

  describe('on revoke (granted → declined)', () => {
    it('stops the transport, flushes nothing, and goes silent', () => {
      env = build({ state: 'granted' });
      env.analytics.startIfConsented();
      env.transport.events.length = 0; // ignore boot-time events

      env.consent.revoke();
      env.analytics.consentDidChange();
      expect(env.transport.stopCalls).toBe(1);
      expect(env.transport.isStarted).toBe(false);

      // No "revoked" event is emitted (that would be a send after revoke).
      expect(env.transport.events).toHaveLength(0);

      // Subsequent tracks are dropped.
      env.analytics.track(EVENT.vscodeCommandInvoked, { command_id: 'refresh' });
      expect(env.transport.events).toHaveLength(0);
    });

    it('revoke lands in declined, never back to unset', () => {
      env = build({ state: 'granted' });
      env.consent.revoke();
      expect(env.consent.state).toBe('declined');
      expect(env.consent.hasDecided).toBe(true);
    });

    it('re-grant after revoke announces grant again exactly once', () => {
      env = build({ state: 'granted' });
      env.analytics.startIfConsented();
      env.consent.revoke();
      env.analytics.consentDidChange();
      env.transport.events.length = 0;

      env.consent.grant();
      env.analytics.consentDidChange();
      const grants = env.transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted);
      expect(grants).toHaveLength(1);
    });
  });

  describe('no-key dark (key+consent gate)', () => {
    it('stays dark even when consent is granted but the key is empty', () => {
      env = build({ state: 'granted', apiKey: '' });
      env.analytics.startIfConsented();
      env.analytics.consentDidChange();
      env.analytics.track(EVENT.vscodeCommandInvoked, { command_id: 'refresh' });
      expect(env.transport.startCalls).toBe(0);
      expect(env.transport.events).toHaveLength(0);
    });
  });

  describe('VS Code telemetry signal is ANDed into the gate', () => {
    it('granted + key but host telemetry OFF → dark', () => {
      const signal = new FakeSignal(false);
      env = build({ state: 'granted', signal });
      env.analytics.startIfConsented();
      env.analytics.track(EVENT.vscodeCommandInvoked, { command_id: 'refresh' });
      expect(env.transport.startCalls).toBe(0);
      expect(env.transport.events).toHaveLength(0);
    });

    it('flipping host telemetry from on→off stops the transport (consentDidChange)', () => {
      const signal = new FakeSignal(true);
      env = build({ state: 'granted', signal });
      env.analytics.startIfConsented();
      expect(env.transport.isStarted).toBe(true);

      signal.enabled = false;
      env.analytics.consentDidChange();
      expect(env.transport.stopCalls).toBe(1);
      expect(env.transport.isStarted).toBe(false);
    });

    it('flipping host telemetry off→on resumes without re-announcing grant', () => {
      const signal = new FakeSignal(false);
      env = build({ state: 'granted', signal });
      env.analytics.startIfConsented(); // dark: signal off
      expect(env.transport.startCalls).toBe(0);

      signal.enabled = true;
      env.analytics.consentDidChange();
      expect(env.transport.startCalls).toBe(1);
      // Grant is announced here because it was never announced (first time gates opened).
      const grants = env.transport.events.filter((e) => e.name === EVENT.consentAnalyticsGranted);
      expect(grants).toHaveLength(1);
    });
  });
});
