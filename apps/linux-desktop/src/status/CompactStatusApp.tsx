import { useEffect, useMemo, useState } from 'react';
import {
  loadShellBridge,
  type LinuxShellBridge,
  type NativeDeepLink,
  type NativeNotificationCapabilities,
  type NativeStatusSnapshot
} from '../tauriBridge.js';
import './compact-status.css';

type CompactStatusPanelProps = {
  snapshot: NativeStatusSnapshot | null;
  capabilities: NativeNotificationCapabilities | null;
  degradedReason?: string | null;
  onRoute(route: NativeDeepLink['route'], action: NativeDeepLink['action']): void;
  onClose(): void;
};

const fallbackSnapshot: NativeStatusSnapshot = {
  shell: {
    loginStartEnabled: false,
    loginStartPath: '',
    backgroundLaunch: false,
    rejectedDeepLinks: 0
  },
  tray: {
    todayCostUsd: 0,
    todayTokens: 0,
    connectedProviders: 0,
    freshness: 'unavailable'
  }
};

const actionRows: { label: string; route: NativeDeepLink['route']; action: NativeDeepLink['action'] }[] = [
  { label: 'Dashboard', route: 'overview', action: 'open-dashboard' },
  { label: 'Chat', route: 'chat', action: 'open-chat' },
  { label: 'Providers', route: 'providers', action: 'open-providers' },
  { label: 'Updates', route: 'updates', action: 'open-updates' },
  { label: 'Reconnect daemon', route: 'support', action: 'reconnect-daemon' }
];

function freshnessCopy(freshness: NativeStatusSnapshot['tray']['freshness']): { title: string; detail: string } {
  switch (freshness) {
    case 'live':
      return { title: 'Live daemon data', detail: 'Usage, quota, and provider facts are current.' };
    case 'stale':
      return { title: 'Daemon data is stale', detail: 'OpenBurnBar is keeping the last values visible while reconnecting.' };
    case 'offline':
      return { title: 'Network offline', detail: 'Local values stay visible; cloud-backed checks may wait.' };
    case 'unavailable':
      return { title: 'Daemon unavailable', detail: 'Start or reconnect the daemon to refresh usage and provider state.' };
  }
}

function formatMoney(value: number): string {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(value);
}

function formatInteger(value: number): string {
  return new Intl.NumberFormat('en-US').format(value);
}

export function CompactStatusPanel({
  snapshot,
  capabilities,
  degradedReason,
  onRoute,
  onClose
}: CompactStatusPanelProps) {
  const data = snapshot ?? fallbackSnapshot;
  const freshness = freshnessCopy(data.tray.freshness);
  const quota = data.tray.quotaFloorRemainingPercent;
  const notificationCopy = useMemo(() => {
    if (!capabilities) return 'Notification server not checked yet.';
    if (!capabilities.available) return 'Notifications unavailable on this desktop session.';
    return capabilities.actions
      ? 'Notification actions available.'
      : 'Notifications available without action buttons.';
  }, [capabilities]);
  const detail = degradedReason ?? data.shell.degradedReason ?? capabilities?.degradedReason ?? notificationCopy;

  return (
    <div className="compact-status-shell">
      <main className="compact-status" aria-labelledby="compact-status-title">
        <header className="compact-status__header">
          <div>
            <p className="compact-status__eyebrow">OpenBurnBar</p>
            <h1 className="compact-status__title" id="compact-status-title">Quick status</h1>
          </div>
          <button className="compact-status__close" type="button" aria-label="Close status" onClick={onClose}>
            x
          </button>
        </header>

        <section className="compact-status__summary" aria-label="Usage summary">
          <div className="compact-status__metric">
            <p className="compact-status__label">Today</p>
            <p className="compact-status__value">{formatMoney(data.tray.todayCostUsd)}</p>
          </div>
          <div className="compact-status__metric">
            <p className="compact-status__label">Tokens</p>
            <p className="compact-status__value">{formatInteger(data.tray.todayTokens)}</p>
          </div>
          <div className="compact-status__metric">
            <p className="compact-status__label">Providers</p>
            <p className="compact-status__value">{formatInteger(data.tray.connectedProviders)}</p>
          </div>
          <div className="compact-status__metric">
            <p className="compact-status__label">Quota floor</p>
            <p className="compact-status__value">{quota == null ? 'None' : `${quota}%`}</p>
          </div>
        </section>

        <section className="compact-status__band" aria-live="polite" aria-label="Daemon freshness">
          <p className="compact-status__band-title">{freshness.title}</p>
          <p className="compact-status__band-detail">{freshness.detail}</p>
        </section>

        <section className="compact-status__actions" aria-label="Quick actions">
          {actionRows.map((row) => (
            <button
              className={`compact-status__button${row.action === 'reconnect-daemon' ? ' compact-status__button--wide' : ''}`}
              key={row.action}
              type="button"
              onClick={() => onRoute(row.route, row.action)}
            >
              {row.label}
            </button>
          ))}
        </section>

        <footer className="compact-status__footer">
          <span className="compact-status__dot" data-freshness={data.tray.freshness} aria-hidden="true" />
          <span role="status">{detail}</span>
        </footer>
      </main>
    </div>
  );
}

export function CompactStatusApp({ bridge: injectedBridge }: { bridge?: LinuxShellBridge | null }) {
  const [bridge, setBridge] = useState<LinuxShellBridge | null>(injectedBridge ?? null);
  const [snapshot, setSnapshot] = useState<NativeStatusSnapshot | null>(null);
  const [capabilities, setCapabilities] = useState<NativeNotificationCapabilities | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | null = null;
    async function load() {
      try {
        const loaded = injectedBridge === undefined ? await loadShellBridge() : injectedBridge;
        if (cancelled) return;
        setBridge(loaded ?? null);
        if (!loaded) {
          setError('Packaged shell required for quick status.');
          return;
        }
        const [nextSnapshot, nextCapabilities] = await Promise.all([
          loaded.nativeStatusSnapshot(),
          loaded.nativeNotificationCapabilities()
        ]);
        if (cancelled) return;
        setSnapshot(nextSnapshot);
        setCapabilities(nextCapabilities);
        const nextUnlisten = await loaded.onNativeStatusSnapshot(setSnapshot);
        if (cancelled) {
          nextUnlisten();
          return;
        }
        unlisten = nextUnlisten;
      } catch (loadError) {
        if (!cancelled) setError(loadError instanceof Error ? loadError.message : 'Quick status failed.');
      }
    }
    void load();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [injectedBridge]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      event.preventDefault();
      void bridge?.nativeStatusClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [bridge]);

  return (
    <CompactStatusPanel
      snapshot={snapshot}
      capabilities={capabilities}
      degradedReason={error}
      onRoute={(route, action) => {
        void bridge?.nativeStatusRoute(route, action);
      }}
      onClose={() => {
        void bridge?.nativeStatusClose();
      }}
    />
  );
}
