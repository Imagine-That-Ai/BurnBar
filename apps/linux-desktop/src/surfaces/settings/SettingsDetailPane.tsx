import type { ReactNode } from 'react';
import type { ConfigSnapshot } from '../../tauriBridge.js';
import type { DaemonStatusCopy } from '../../daemonStatusCopy.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useSupportStore } from '../../state/supportStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { CopyPathButton } from '../system/CopyPathButton.js';
import { VersionGrid } from '../support/VersionGrid.js';
import { OnboardingSurface } from '../OnboardingSurface.js';
import { TextExpansionSurface } from '../TextExpansionSurface.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';
import { ReadOnlyToggle } from './ReadOnlyToggle.js';
import { SettingsHomeView } from './SettingsHomeView.js';
import { SettingsAppearanceControls } from './SettingsAppearanceControls.js';
import { SettingsDrillRow } from './SettingsDrillRow.js';
import { settingsTabMeta, type SettingsTabId } from './settingsTabs.js';

const UPDATE_CHANNEL_COPY: Record<'deb' | 'appimage' | 'unknown', string> = {
  deb: 'Installed via the Debian package channel; apt/dpkg owns upgrades.',
  appimage: 'Installed as AppImage; replace the image file from your release source.',
  unknown: 'Package channel could not be determined; use your distro package manager or release notes.'
};

function SettingsDetailHeader({
  title,
  onDone
}: {
  title: string;
  onDone: () => void;
}) {
  return (
    <header className="settings-detail-header">
      <h2 className="settings-detail-title">{title}</h2>
      <button type="button" className="settings-done-btn" onClick={onDone}>
        Done
      </button>
    </header>
  );
}

function UpdatesDetail({ fixtureMode, status }: { fixtureMode: boolean; status: DaemonStatusCopy }) {
  const versionInfo = useSupportStore((s) => s.versionInfo);
  const versionLoading = useSupportStore((s) => s.versionLoading);
  const versionError = useSupportStore((s) => s.versionError);
  const loadVersion = useSupportStore((s) => s.loadVersion);
  useLaneLoad(loadVersion);

  if (versionLoading && !versionInfo) {
    return <p className="muted">Loading package channel and version facts…</p>;
  }
  if (versionError && !versionInfo) {
    return (
      <OfflineNotice
        status={status}
        summary="Updates needs the packaged shell to read version and channel facts."
        fixtureMode={fixtureMode}
      />
    );
  }
  if (!versionInfo) {
    return (
      <OfflineNotice
        status={status}
        summary="Version facts are unavailable without the packaged shell or fixture mode."
        fixtureMode={fixtureMode}
      />
    );
  }
  return (
    <>
      <p className="muted settings-tab-lede">
        Updates are delivered by your package manager — this shell does not download or install upgrades in-app.
      </p>
      <VersionGrid info={versionInfo} />
      <SettingGroup title="Package channel" sectionHeader>
        <p>{UPDATE_CHANNEL_COPY[versionInfo.packageChannel]}</p>
        <p className="muted mono">Update check: {versionInfo.updateCheck}</p>
      </SettingGroup>
    </>
  );
}

function ConfigRefreshRow({ onRefresh, busy }: { onRefresh: () => void; busy: boolean }) {
  return (
    <SettingRow
      iconGlyph="↻"
      label="Refresh daemon config"
      description="Reload paths, Secret Service status, and privacy flags from the local peer."
      control={
        <button type="button" className="ghost" onClick={onRefresh} disabled={busy} aria-busy={busy}>
          {busy ? 'Refreshing…' : 'Refresh'}
        </button>
      }
    />
  );
}

export function SettingsDetailPane({
  activeTab,
  config,
  fixtureMode,
  bridge,
  status,
  loading,
  error,
  onRetryConfig,
  onRefreshConfig,
  refreshBusy,
  onDone,
  onSelectTab
}: {
  activeTab: SettingsTabId;
  config: ConfigSnapshot | null;
  fixtureMode: boolean;
  bridge: unknown;
  status: DaemonStatusCopy;
  loading: boolean;
  error: string | null;
  onRetryConfig: () => void;
  onRefreshConfig: () => void;
  refreshBusy: boolean;
  onDone: () => void;
  onSelectTab: (tab: SettingsTabId) => void;
}) {
  const meta = settingsTabMeta(activeTab);

  let content: ReactNode = null;

  if (activeTab === 'home') {
    content = (
      <SettingsHomeView
        config={config}
        status={status}
        fixtureMode={fixtureMode}
        onSelectTab={onSelectTab}
      />
    );
  } else if (!config && loading) {
    content = <p className="muted">Loading settings…</p>;
  } else if (!config) {
    const offline = !fixtureMode && !bridge && !loading;
    content = offline ? (
      <OfflineNotice
        status={status}
        summary="Settings need the local daemon before paths, Secret Service, and privacy flags can load."
        fixtureMode={fixtureMode}
      />
    ) : (
      <Banner tone="degraded" role="alert">
        {error ?? 'Config unavailable'}
        <div className="actions">
          <button type="button" className="ghost" onClick={onRetryConfig}>
            Retry
          </button>
        </div>
      </Banner>
    );
  } else {
    const secretLocked =
      config.secretServiceStatus === 'locked' || config.secretServiceStatus === 'unavailable';

    switch (activeTab) {
      case 'general':
        content = (
          <>
            <SettingGroup title="Appearance" sectionHeader hideTitle>
              <SettingsAppearanceControls />
            </SettingGroup>
            <SettingGroup title="Data refresh" sectionHeader hideTitle>
              <ConfigRefreshRow onRefresh={onRefreshConfig} busy={refreshBusy} />
            </SettingGroup>
            <SettingGroup title="First-run setup" sectionHeader hideTitle>
              <p className="muted settings-tab-lede">
                Linux onboarding wizard for daemon, Secret Service, and desktop environment limits.
              </p>
              <OnboardingSurface />
            </SettingGroup>
          </>
        );
        break;
      case 'updates':
        content = <UpdatesDetail fixtureMode={fixtureMode} status={status} />;
        break;
      case 'daemon':
        content = (
          <SettingGroup title="Engine Room" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              Local peer health, AF_UNIX RPC, and Secret Service status.
            </p>
            <SettingRow
              iconGlyph="⎔"
              label="AF_UNIX socket"
              description="Local health and RPC traffic; never expose this socket outside your user session."
              control={<CopyPathButton path={config.paths.socketPath} label="Copy socket path" />}
            />
            <p className="system-path-row">
              <code>{config.paths.socketPath}</code>
            </p>
            <SettingRow
              iconGlyph="📁"
              label="Support directory (XDG data)"
              description="Canonical state and logs live here."
              control={<CopyPathButton path={config.paths.supportDir} />}
            />
            <p className="system-path-row">
              <code>{config.paths.supportDir}</code>
            </p>
            <SettingRow
              iconGlyph="⚙"
              label="Config directory (XDG config)"
              description="Daemon-managed configuration."
              control={<CopyPathButton path={config.paths.configDir} />}
            />
            <p className="system-path-row">
              <code>{config.paths.configDir}</code>
            </p>
            {config.paths.providerLogPaths.map((logPath) => (
              <div key={logPath}>
                <SettingRow
                  iconGlyph="📄"
                  label="Provider log path"
                  description="Parser ingest reads these directories."
                  control={<CopyPathButton path={logPath} label="Copy log path" />}
                />
                <p className="system-path-row">
                  <code>{logPath}</code>
                </p>
              </div>
            ))}
            <SettingRow
              iconGlyph="🔐"
              label="GNOME Keyring / KWallet"
              description={
                secretLocked
                  ? 'Unlock your desktop keyring so provider credentials can be stored without plain-text files.'
                  : 'Secret Service is reachable; credentials stay off disk when unlocked.'
              }
              control={
                <span className="muted" role="status">
                  {config.secretServiceStatus}
                </span>
              }
            />
          </SettingGroup>
        );
        break;
      case 'agents':
        content = (
          <SettingGroup title="Agents & Models" sectionHeader hideTitle>
            <SettingsDrillRow
              as="div"
              iconGlyph="◇"
              iconTint="var(--color-brass-core)"
              title="Providers & routing"
              subtitle="Catalog, credentials, and quota buckets"
              value="Open"
              trailing={
                <a className="system-danger-link settings-drill-link" href="#/providers">
                  Providers
                </a>
              }
            />
            <p className="muted settings-tab-lede">
              Model proxy and gateway controls ship when Linux bridge RPCs land.
            </p>
          </SettingGroup>
        );
        break;
      case 'account':
        content = (
          <SettingGroup title="Account" sectionHeader hideTitle>
            <SettingsDrillRow
              as="div"
              iconGlyph="◎"
              iconTint="var(--color-brass-bright)"
              title="Account & cloud"
              subtitle="BurnBar session, entitlements, and optional cloud mirror"
              trailing={
                <a className="system-danger-link settings-drill-link" href="#/account">
                  Open Account
                </a>
              }
            />
          </SettingGroup>
        );
        break;
      case 'cloud':
        content = (
          <SettingGroup title="Cloud" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              OpenBurnBar Cloud — hosted refresh, backup, and Hermes anywhere — is managed from the Account lane on
              Linux until cloud store RPCs ship in Settings.
            </p>
            <SettingsDrillRow
              as="div"
              iconGlyph="✦"
              iconTint="var(--color-brass-bright)"
              title="OpenBurnBar Cloud"
              subtitle="Subscription and hosted services"
              trailing={
                <a className="system-danger-link settings-drill-link" href="#/account">
                  Account
                </a>
              }
            />
          </SettingGroup>
        );
        break;
      case 'alerts':
      case 'notifications':
      case 'devices-and-sync':
      case 'media':
        content = (
          <SettingGroup title={meta.detailTitle} sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              {meta.subtitle}. Full macOS parity for this section is deferred — configure related features from Account,
              Support, or the dashboard lanes until Linux settings RPCs land.
            </p>
            {activeTab === 'devices-and-sync' ? (
              <SettingsDrillRow
                as="div"
                iconGlyph="⊞"
                iconTint="var(--color-tier-end-to-end)"
                title="Devices & sync"
                subtitle="Cloud sync and trusted devices"
                trailing={
                  <a className="system-danger-link settings-drill-link" href="#/account">
                    Account
                  </a>
                }
              />
            ) : null}
          </SettingGroup>
        );
        break;
      case 'text-expansion':
        content = (
          <div className="settings-embedded-surface">
            <TextExpansionSurface />
          </div>
        );
        break;
      case 'data-privacy':
        content = (
          <>
            <SettingGroup title="Consent flags" sectionHeader hideTitle>
              <SettingRow
                iconGlyph="📡"
                label="Telemetry"
                description="Opt-in only. When enabled, the daemon may emit anonymized stability events — never prompt content."
                control={<ReadOnlyToggle checked={config.telemetryEnabled} label="Telemetry" />}
                readOnlyNote="Managed by daemon config"
              />
              <SettingRow
                iconGlyph="🛡"
                label="Privacy opt-in"
                description="Explicit consent before cloud-adjacent features sync metadata off this machine."
                control={<ReadOnlyToggle checked={config.privacyOptIn} label="Privacy opt-in" />}
                readOnlyNote="Managed by daemon config"
              />
            </SettingGroup>
            <SettingGroup title="Diagnostics" sectionHeader hideTitle>
              <SettingsDrillRow
                as="div"
                iconGlyph="⚠"
                iconTint="var(--color-tier-server-readable)"
                title="Support & diagnostics"
                subtitle="Export redacted logs and perf samples"
                trailing={
                  <a className="system-danger-link settings-drill-link" href="#/support">
                    Support
                  </a>
                }
              />
            </SettingGroup>
          </>
        );
        break;
      default:
        content = null;
    }
  }

  return (
    <div className="settings-detail" role="region" aria-label={meta.detailTitle}>
      <SettingsDetailHeader title={meta.detailTitle} onDone={onDone} />
      <div className="settings-detail-scroll">{content}</div>
    </div>
  );
}