import type {
  LinuxShellBridge,
  NativeDeepLink,
  NativeTraySnapshot,
  ProviderCatalog,
  UsageSummary
} from '../tauriBridge.js';

type NativeShellBridge = Pick<
  LinuxShellBridge,
  | 'nativeShellReady'
  | 'onNativeDeepLink'
  | 'nativeTrayUpdate'
  | 'usageSummary'
  | 'providerCatalog'
>;

export type NativeShellRuntimeStatus = {
  daemonOk: boolean;
  online: boolean;
  lastDaemonEventAt: string | null;
};

export type NativeShellSupervisorOptions = {
  now?: () => number;
  staleAfterMs?: number;
  status?: () => NativeShellRuntimeStatus;
  onError?: (error: unknown) => void;
};

function boundedInteger(value: number, max: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.min(max, Math.floor(value));
}

export function buildNativeTraySnapshot(
  summary: UsageSummary,
  catalog: ProviderCatalog,
  runtime: NativeShellRuntimeStatus,
  now: number,
  staleAfterMs: number
): NativeTraySnapshot {
  const eligibleBuckets = catalog.flatMap((provider) =>
    provider.quotaBuckets.filter((bucket) => bucket.state !== 'missing_credential')
  );
  const connectedProviders = catalog.filter((provider) =>
    provider.quotaBuckets.some((bucket) => bucket.state !== 'missing_credential')
  ).length;
  const remaining = eligibleBuckets.map((bucket) =>
    Math.max(0, Math.min(100, Math.round(100 - bucket.usedPct)))
  );
  const eventAt = runtime.lastDaemonEventAt ? Date.parse(runtime.lastDaemonEventAt) : NaN;
  const stale = Number.isFinite(eventAt) && now - eventAt > staleAfterMs;
  const freshness: NativeTraySnapshot['freshness'] = !runtime.online
    ? 'offline'
    : !runtime.daemonOk
      ? 'unavailable'
      : stale
        ? 'stale'
        : 'live';
  return {
    todayCostUsd: Math.max(0, Number.isFinite(summary.todayCostUsd) ? summary.todayCostUsd : 0),
    todayTokens: boundedInteger(summary.todayTokens, Number.MAX_SAFE_INTEGER),
    connectedProviders: boundedInteger(connectedProviders, 1_024),
    quotaFloorRemainingPercent: remaining.length > 0 ? Math.min(...remaining) : undefined,
    freshness
  };
}

export class NativeShellSupervisor {
  private readonly now: () => number;
  private readonly staleAfterMs: number;
  private readonly status: () => NativeShellRuntimeStatus;
  private readonly onError: (error: unknown) => void;
  private stopped = true;
  private running = false;
  private refreshPending = false;
  private unlisten: (() => void) | null = null;

  constructor(
    private readonly bridge: NativeShellBridge,
    private readonly onDeepLink: (link: NativeDeepLink) => void | Promise<void>,
    options: NativeShellSupervisorOptions = {}
  ) {
    this.now = options.now ?? Date.now;
    this.staleAfterMs = options.staleAfterMs ?? 120_000;
    this.status = options.status ?? (() => ({
      daemonOk: false,
      online: navigator.onLine,
      lastDaemonEventAt: null
    }));
    this.onError = options.onError ?? ((error) => console.error('linux_native_shell_failed', error));
  }

  async start(): Promise<void> {
    if (!this.stopped) return;
    this.stopped = false;
    try {
      const unlisten = await this.bridge.onNativeDeepLink((link) => {
        void this.dispatch(link).catch(this.onError);
      });
      if (this.stopped) {
        unlisten();
        return;
      }
      this.unlisten = unlisten;
      const pending = await this.bridge.nativeShellReady();
      for (const link of pending) await this.dispatch(link);
      await this.refresh();
    } catch (error) {
      this.onError(error);
    }
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.refreshPending = false;
    this.unlisten?.();
    this.unlisten = null;
  }

  async refresh(): Promise<void> {
    if (this.stopped) return;
    if (this.running) {
      this.refreshPending = true;
      return;
    }
    this.running = true;
    try {
      const [summary, catalog] = await Promise.all([
        this.bridge.usageSummary(),
        this.bridge.providerCatalog()
      ]);
      if (!this.stopped) {
        await this.bridge.nativeTrayUpdate(
          buildNativeTraySnapshot(summary, catalog, this.status(), this.now(), this.staleAfterMs)
        );
      }
    } catch (error) {
      this.onError(error);
    } finally {
      this.running = false;
    }
    if (this.refreshPending && !this.stopped) {
      this.refreshPending = false;
      await this.refresh();
    }
  }

  private async dispatch(link: NativeDeepLink): Promise<void> {
    if (!this.stopped) await this.onDeepLink(link);
  }
}
