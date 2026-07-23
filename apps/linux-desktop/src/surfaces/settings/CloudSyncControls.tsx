import { useEffect, useState } from 'react';
import type { ConfigSnapshot, LinuxCloudSyncStatus, LinuxShellBridge } from '../../tauriBridge.js';
import { Banner } from '../../components/Banner.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';

/**
 * Linux's cloud consent surface is intentionally narrower than macOS's
 * Cloud Store pane. The daemon currently exposes one persisted cloud-sync
 * consent and status contracts, so this UI names the encrypted Linux scope
 * instead of implying iCloud or hosted session-log backup support.
 */
export function CloudSyncControls({ config, bridge }: { config: ConfigSnapshot; bridge?: LinuxShellBridge | null }) {
  const updatePrivacySettings = useSettingsWiringStore((state) => state.updatePrivacySettings);
  const privacyMutation = useSettingsWiringStore((state) => state.privacyMutation);
  const busy = useSettingsWiringStore((state) => state.busy === 'privacy.config.update');
  const cloudEnabled = Boolean(config.cloudSyncEnabled);
  const [syncStatus, setSyncStatus] = useState<LinuxCloudSyncStatus | null>(null);
  const [syncBusy, setSyncBusy] = useState(false);
  const [syncError, setSyncError] = useState<string | null>(null);
  const syncAvailable = typeof bridge?.linuxCloudSyncStatus === 'function'
    && typeof bridge.linuxCloudSyncPolicyUpdate === 'function'
    && typeof bridge.linuxCloudSyncRun === 'function';

  useEffect(() => {
    let active = true;
    if (!bridge?.linuxCloudSyncStatus) {
      setSyncStatus(null);
      return () => { active = false; };
    }
    void bridge.linuxCloudSyncStatus()
      .then((status) => {
        if (active) {
          setSyncStatus(status);
          setSyncError(null);
        }
      })
      .catch((error: unknown) => {
        if (active) setSyncError(error instanceof Error ? error.message : 'Linux cloud sync status is unavailable.');
      });
    return () => { active = false; };
  }, [bridge]);

  const toggle = (key: 'cloudSyncEnabled' | 'privacyOptIn', checked: boolean) => {
    void updatePrivacySettings({ [key]: checked });
  };

  const setTextExpansionSync = async (checked: boolean) => {
    if (!syncStatus || !bridge?.linuxCloudSyncPolicyUpdate) return;
    const domains = new Set(syncStatus.enabledDomains);
    if (checked) domains.add('text_expansion');
    else domains.delete('text_expansion');
    setSyncBusy(true);
    setSyncError(null);
    try {
      setSyncStatus(await bridge.linuxCloudSyncPolicyUpdate({
        enabledDomains: [...domains].sort(),
        remoteAccessEnabled: syncStatus.remoteAccessEnabled
      }));
    } catch (error: unknown) {
      setSyncError(error instanceof Error ? error.message : 'Text-expansion sync consent could not be saved.');
    } finally {
      setSyncBusy(false);
    }
  };

  const runSync = async () => {
    if (!bridge?.linuxCloudSyncRun) return;
    setSyncBusy(true);
    setSyncError(null);
    try {
      setSyncStatus((await bridge.linuxCloudSyncRun(false)).status);
    } catch (error: unknown) {
      setSyncError(error instanceof Error ? error.message : 'Linux cloud sync did not complete.');
    } finally {
      setSyncBusy(false);
    }
  };

  return (
    <SettingGroup title="Backup & sync" sectionHeader hideTitle>
      <p className="muted settings-tab-lede">
        Linux keeps local SQLite canonical. Cloud sync is opt-in and daemon-owned; credentials, vault keys, and encrypted
        payloads never pass through this renderer.
      </p>
      {privacyMutation.status === 'error' ? (
        <Banner tone="degraded" role="alert">
          {privacyMutation.message ?? 'Cloud consent could not be saved.'}
        </Banner>
      ) : null}
      {privacyMutation.status === 'success' ? (
        <Banner tone="ok" role="status">
          {privacyMutation.message ?? 'Cloud consent saved.'}
        </Banner>
      ) : null}
      <SettingRow
        iconGlyph="☁"
        label="Encrypted cloud sync"
        description="Allow eligible encrypted metadata to leave this Linux installation. Turning this off stops new cloud sync consent; local rows remain available."
        control={
          <label className="setting-toggle setting-toggle--privacy">
            <input
              type="checkbox"
              checked={cloudEnabled}
              disabled={busy}
              aria-busy={busy}
              aria-label="Encrypted cloud sync"
              onChange={(event) => toggle('cloudSyncEnabled', event.currentTarget.checked)}
            />
            <span className="muted" role="status">{busy ? 'Saving…' : cloudEnabled ? 'On' : 'Off'}</span>
          </label>
        }
      />
      <SettingRow
        iconGlyph="◌"
        label="Metadata privacy opt-in"
        description="Allow cloud-adjacent metadata features that require separate privacy consent. This does not enable telemetry."
        control={
          <label className="setting-toggle setting-toggle--privacy">
            <input
              type="checkbox"
              checked={config.privacyOptIn}
              disabled={busy}
              aria-busy={busy}
              aria-label="Metadata privacy opt-in"
              onChange={(event) => toggle('privacyOptIn', event.currentTarget.checked)}
            />
            <span className="muted" role="status">{busy ? 'Saving…' : config.privacyOptIn ? 'On' : 'Off'}</span>
          </label>
        }
      />
      <p className="muted settings-tab-lede">
        Conversation backup, iCloud mirroring, and hosted Cloud controls remain unavailable until Linux daemon contracts
        and production authorization are present. The Account lane shows current identity and sync posture.
      </p>
      {syncAvailable && syncStatus ? (
        <>
          <SettingRow
            iconGlyph="↻"
            label="Sync text-expansion snippets"
            description="Explicitly opt snippets into the daemon-owned encrypted replica. Snippet text, credentials, and vault keys never enter the renderer."
            control={
              <label className="setting-toggle setting-toggle--privacy">
                <input
                  type="checkbox"
                  checked={syncStatus.enabledDomains.includes('text_expansion')}
                  disabled={syncBusy || !cloudEnabled || !syncStatus.vaultKeyAvailable}
                  aria-busy={syncBusy}
                  aria-label="Sync text-expansion snippets"
                  onChange={(event) => void setTextExpansionSync(event.currentTarget.checked)}
                />
                <span className="muted" role="status">
                  {!cloudEnabled ? 'Cloud off' : !syncStatus.vaultKeyAvailable ? 'Key unavailable' : syncStatus.enabledDomains.includes('text_expansion') ? 'On' : 'Off'}
                </span>
              </label>
            }
          />
          <SettingRow
            iconGlyph="⟳"
            label="Sync status"
            description={syncStatus.phase === 'locked'
              ? 'Unlock the Linux keyring to run encrypted cloud sync.'
              : syncStatus.phase === 'backoff'
                ? 'The daemon is backing off after a failed cycle; retry after the displayed delay.'
                : `${syncStatus.pendingMutationCount} pending change${syncStatus.pendingMutationCount === 1 ? '' : 's'}; ${syncStatus.consecutiveFailures} consecutive failure${syncStatus.consecutiveFailures === 1 ? '' : 's'}.`}
            control={
              <button type="button" className="ghost" onClick={() => void runSync()} disabled={syncBusy || !cloudEnabled || !syncStatus.vaultKeyAvailable}>
                {syncBusy ? 'Syncing…' : 'Sync now'}
              </button>
            }
          />
        </>
      ) : null}
      {syncError ? <Banner tone="degraded" role="alert">{syncError}</Banner> : null}
    </SettingGroup>
  );
}
