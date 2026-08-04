export type DaemonHealthProbe = () => Promise<boolean>;

export type DaemonHealthSupervisorOptions = {
  activeIntervalMs?: number;
  backgroundIntervalMs?: number;
  failureBaseMs?: number;
  failureMaxMs?: number;
  isForeground?: () => boolean;
};

export class DaemonHealthSupervisor {
  private readonly activeIntervalMs: number;
  private readonly backgroundIntervalMs: number;
  private readonly failureBaseMs: number;
  private readonly failureMaxMs: number;
  private readonly isForeground: () => boolean;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private running = false;
  private stopped = true;
  private wakePending = false;
  private consecutiveFailures = 0;

  constructor(
    private readonly probe: DaemonHealthProbe,
    options: DaemonHealthSupervisorOptions = {}
  ) {
    this.activeIntervalMs = options.activeIntervalMs ?? 30_000;
    this.backgroundIntervalMs = options.backgroundIntervalMs ?? 120_000;
    this.failureBaseMs = options.failureBaseMs ?? 1_000;
    this.failureMaxMs = options.failureMaxMs ?? 30_000;
    this.isForeground = options.isForeground ?? (() => document.visibilityState === 'visible');
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.schedule(0);
  }

  stop(): void {
    this.stopped = true;
    this.wakePending = false;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
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
      void this.runProbe();
    }, Math.max(0, delayMs));
  }

  private async runProbe(): Promise<void> {
    if (this.stopped || this.running) return;
    this.running = true;
    let healthy: boolean;
    try {
      healthy = await this.probe();
    } catch {
      healthy = false;
    } finally {
      this.running = false;
    }
    if (this.stopped) return;

    if (healthy) {
      this.consecutiveFailures = 0;
    } else {
      this.consecutiveFailures += 1;
    }
    if (this.wakePending) {
      this.wakePending = false;
      this.schedule(0);
      return;
    }
    if (healthy) {
      this.schedule(this.isForeground() ? this.activeIntervalMs : this.backgroundIntervalMs);
      return;
    }
    const backoff = this.failureBaseMs * 2 ** Math.max(0, this.consecutiveFailures - 1);
    this.schedule(Math.min(this.failureMaxMs, backoff));
  }
}

export function installDaemonHealthLifecycle(supervisor: DaemonHealthSupervisor): () => void {
  const wake = () => supervisor.wake();
  const wakeWhenVisible = () => {
    if (document.visibilityState === 'visible') supervisor.wake();
  };
  window.addEventListener('focus', wake);
  window.addEventListener('online', wake);
  document.addEventListener('visibilitychange', wakeWhenVisible);
  supervisor.start();
  return () => {
    window.removeEventListener('focus', wake);
    window.removeEventListener('online', wake);
    document.removeEventListener('visibilitychange', wakeWhenVisible);
    supervisor.stop();
  };
}
