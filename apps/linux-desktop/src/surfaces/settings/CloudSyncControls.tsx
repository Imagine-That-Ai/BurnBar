import type { ConfigSnapshot } from '../../tauriBridge.js';
import { Banner } from '../../components/Banner.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';

/**
 * Linux's cloud consent surface is intentionally narrower than macOS's
 * Cloud Store pane. The daemon currently exposes one persisted cloud-sync
 * consent bit, so this UI names that scope instead of implying iCloud or
 * session-log backup support that Linux cannot verify.
 */
export function CloudSyncControls({ config }: { config: ConfigSnapshot }) {
  const updatePrivacySettings = useSettingsWiringStore((state) => state.updatePrivacySettings);
  const privacyMutation = useSettingsWiringStore((state) => state.privacyMutation);
  const busy = useSettingsWiringStore((state) => state.busy === 'privacy.config.update');
  const cloudEnabled = Boolean(config.cloudSyncEnabled);

  const toggle = (key: 'cloudSyncEnabled' | 'privacyOptIn', checked: boolean) => {
    void updatePrivacySettings({ [key]: checked });
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
    </SettingGroup>
  );
}
