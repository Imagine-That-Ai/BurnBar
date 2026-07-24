import type {
  DaemonSubscriptionResponse,
  LinuxShellBridge
} from '../tauriBridge.js';

type SubscriptionBridge = Pick<
  LinuxShellBridge,
  'subscriptionStart' | 'subscriptionResume' | 'subscriptionStop'
>;

export type DaemonSubscriptionSupervisorOptions = {
  activeIntervalMs?: number;
  backgroundIntervalMs?: number;
  failureBaseMs?: number;
  failureMaxMs?: number;
  isForeground?: () => boolean;
  isOnline?: () => boolean;
  clientId?: string;
  onStatus?: (status: DaemonSubscriptionStatus) => void;
};

export type DaemonSubscriptionStatus = {
  state: 'connecting' | 'live' | 'pull' | 'offline' | 'error' | 'stopped';
  error?: string;
};

export class DaemonSubscriptionSupervisor {
  private readonly activeIntervalMs: number;
  private readonly backgroundIntervalMs: number;
  private readonly failureBaseMs: number;
  private readonly failureMaxMs: number;
  private readonly isForeground: () => boolean;
  private readonly isOnline: () => boolean;
  private readonly clientId: string;
  private readonly onStatus: (status: DaemonSubscriptionStatus) => void;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private running = false;
  private stopped = true;
  private wakePending = false;
  private consecutiveFailures = 0;
  private subscriptionId: string | null = null;
  private seq = 0;
  // A stop/start cycle creates a new logical consumer. Responses from an
  // earlier cycle must never restore its cursor or publish stale events.
  private lifecycleGeneration = 0;

  constructor(
    private readonly bridge: SubscriptionBridge,
    private readonly onEvent: (response: DaemonSubscriptionResponse) => void | Promise<void>,
    options: DaemonSubscriptionSupervisorOptions = {}
  ) {
    this.activeIntervalMs = options.activeIntervalMs ?? 15_000;
    this.backgroundIntervalMs = options.backgroundIntervalMs ?? 60_000;
    this.failureBaseMs = options.failureBaseMs ?? 1_000;
    this.failureMaxMs = options.failureMaxMs ?? 30_000;
    this.isForeground = options.isForeground ?? (() => document.visibilityState === 'visible');
    this.isOnline = options.isOnline ?? (() => navigator.onLine);
    this.clientId = options.clientId ?? 'linux-desktop-shell';
    this.onStatus = options.onStatus ?? (() => {});
  }

  start(): void {
    if (!this.stopped) return;
    this.lifecycleGeneration += 1;
    this.subscriptionId = null;
    this.seq = 0;
    this.consecutiveFailures = 0;
    this.wakePending = false;
    this.stopped = false;
    this.onStatus({ state: 'connecting' });
    this.schedule(0);
  }

  stop(): void {
    if (this.stopped) return;
    this.lifecycleGeneration += 1;
    this.stopped = true;
    this.onStatus({ state: 'stopped' });
    this.wakePending = false;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    const subscriptionId = this.subscriptionId;
    this.subscriptionId = null;
    this.seq = 0;
    this.consecutiveFailures = 0;
    if (subscriptionId) void this.stopRemote(subscriptionId);
  }

  wake(): void {
    if (this.stopped) return;
    if (this.running) {
      this.wakePending = true;
      return;
    }
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    this.schedule(0);
  }

  private schedule(delayMs: number): void {
    if (this.stopped || this.timer !== null) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.runTick(this.lifecycleGeneration);
    }, Math.max(0, delayMs));
  }

  private async runTick(generation: number): Promise<void> {
    if (this.stopped || generation !== this.lifecycleGeneration || this.running) return;
    this.running = true;
    let succeeded = false;
    try {
      if (!this.isOnline()) {
        succeeded = true;
        this.onStatus({ state: 'offline' });
      } else {
        const response = this.subscriptionId
          ? await this.bridge.subscriptionResume({
              subscription_id: this.subscriptionId,
              topic: 'data',
              after_seq: this.seq,
              client_id: this.clientId
            })
          : await this.bridge.subscriptionStart({
              topic: 'data',
              client_id: this.clientId
            });
        if (this.stopped || generation !== this.lifecycleGeneration) {
          await this.stopRemote(response.subscriptionId);
          if (!this.stopped && generation !== this.lifecycleGeneration) this.schedule(0);
          return;
        }
        this.validateResponse(response);
        this.subscriptionId = response.subscriptionId;
        this.seq = response.seq;
        succeeded = true;
        if (this.stopped || generation !== this.lifecycleGeneration) {
          await this.stopRemote(response.subscriptionId);
          if (!this.stopped && generation !== this.lifecycleGeneration) this.schedule(0);
          return;
        }
        this.onStatus({ state: response.degradedFallback ? 'pull' : 'live' });
        await this.onEvent(response);
      }
    } catch (error) {
      succeeded = false;
      if (!this.stopped && generation === this.lifecycleGeneration) {
        this.onStatus({
          state: 'error',
          error: error instanceof Error ? error.message : 'Daemon subscription refresh failed.'
        });
      }
    } finally {
      this.running = false;
    }
    if (this.stopped) {
      if (this.subscriptionId) await this.stopRemote(this.subscriptionId);
      return;
    }
    if (generation !== this.lifecycleGeneration) {
      this.schedule(0);
      return;
    }
    this.consecutiveFailures = succeeded ? 0 : this.consecutiveFailures + 1;
    if (this.wakePending) {
      this.wakePending = false;
      this.schedule(0);
      return;
    }
    if (succeeded) {
      this.schedule(this.isForeground() ? this.activeIntervalMs : this.backgroundIntervalMs);
      return;
    }
    const backoff = this.failureBaseMs * 2 ** Math.max(0, this.consecutiveFailures - 1);
    this.schedule(Math.min(this.failureMaxMs, backoff));
  }

  private validateResponse(response: DaemonSubscriptionResponse): void {
    if (response.topic !== 'data') throw new Error('Daemon subscription topic changed unexpectedly.');
    if (response.terminalStateDelivered || response.events.some((event) => event.terminal)) {
      throw new Error('Daemon subscription delivered an unexpected terminal event.');
    }
    if (this.subscriptionId && response.subscriptionId !== this.subscriptionId) {
      throw new Error('Daemon subscription identifier changed during resume.');
    }
    if (response.seq <= this.seq) throw new Error('Daemon subscription cursor did not advance.');
  }

  private async stopRemote(subscriptionId: string): Promise<void> {
    try {
      await this.bridge.subscriptionStop({
        subscription_id: subscriptionId,
        client_id: this.clientId
      });
    } catch {
      // The daemon may already be gone; its bounded registry expires the record.
    }
  }
}

export function installDaemonSubscriptionLifecycle(
  supervisor: DaemonSubscriptionSupervisor
): () => void {
  const wake = () => supervisor.wake();
  const wakeWhenVisible = () => {
    if (document.visibilityState === 'visible') supervisor.wake();
  };
  window.addEventListener('focus', wake);
  window.addEventListener('online', wake);
  window.addEventListener('offline', wake);
  document.addEventListener('visibilitychange', wakeWhenVisible);
  supervisor.start();
  return () => {
    window.removeEventListener('focus', wake);
    window.removeEventListener('online', wake);
    window.removeEventListener('offline', wake);
    document.removeEventListener('visibilitychange', wakeWhenVisible);
    supervisor.stop();
  };
}
