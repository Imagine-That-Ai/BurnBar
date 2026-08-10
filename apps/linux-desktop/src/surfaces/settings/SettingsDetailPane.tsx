import type { ReactNode } from 'react';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type {
  AccountStatus,
  ConfigSnapshot,
  AccountCloudDataExportResult,
  AccountCloudDataDeletionResult,
  TrustedDevice,
  LinuxPrivacyStoreID,
  LinuxShellBridge,
  LinuxPrivacyRetentionRule,
  NotificationConfig,
  MercuryMediaStatus
} from '../../tauriBridge.js';
import { ACCOUNT_CLOUD_DATA_DELETION_CONFIRMATION } from '../../tauriBridge.js';
import type { DaemonStatusCopy } from '../../daemonStatusCopy.js';
import { Banner } from '../../components/Banner.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import {
  LINUX_PROVIDER_PATH_REGISTRY,
  providerCoverageSummary,
  resolveProviderLogicalPath
} from '../../providerPathRegistry.js';
import { useSupportStore } from '../../state/supportStore.js';
import {
  useSettingsWiringStore,
  type PrivacySettingsPatch
} from '../../state/settingsWiringStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useShellStore } from '../../state/shellStore.js';
import { CopyPathButton } from '../system/CopyPathButton.js';
import { VersionGrid } from '../support/VersionGrid.js';
import { OnboardingSurface } from '../OnboardingSurface.js';
import { TextExpansionSurface } from '../TextExpansionSurface.js';
import { UpdateStatusCard } from '../updates/UpdateStatusCard.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';
import { RecoveryAndRestoreControl } from './RecoveryAndRestoreControl.js';
import { SettingsHomeView } from './SettingsHomeView.js';
import { SettingsAppearanceControls } from './SettingsAppearanceControls.js';
import { AgentsDetail } from './AgentsSettingsDetail.js';
import { DashboardDefaultsControls, IndexingSummaryControl, LaunchAtLoginControl } from './GeneralSettingsControls.js';
import { SettingsDrillRow } from './SettingsDrillRow.js';
import { settingsTabMeta, type SettingsTabId } from './settingsTabs.js';
import { fixtureAccountStatus } from '../../daemonFixture.js';
import { CloudSyncControls } from './CloudSyncControls.js';
import { AIInboxSettingsDetail } from './AIInboxSettingsDetail.js';

const UPDATE_CHANNEL_COPY: Record<'deb' | 'rpm' | 'arch' | 'appimage' | 'unknown', string> = {
  deb: 'Installed via the Debian package channel; apt/dpkg owns upgrades.',
  rpm: 'Installed via the RPM package channel; dnf/rpm owns upgrades.',
  arch: 'Installed via the Arch package channel; pacman owns upgrades.',
  appimage: 'Installed as AppImage; replace the image file from your release source.',
  unknown: 'Package channel could not be determined; use your distro package manager or release notes.'
};

const CALENDAR_DURATION_OPTIONS = [15, 30, 45, 60, 90];

function accountErasureCompleted(result: AccountCloudDataDeletionResult): boolean {
  return result.ok
    && result.cloudDataDeleted
    && !result.retryRequired
    && result.failedSecretDestroys === 0
    && result.failedStorageDeletes === 0
    && (result.deletedAuthUser || result.authUserAlreadyMissing);
}

function accountErasureRetryMessage(result: AccountCloudDataDeletionResult): string {
  const reasons: string[] = [];
  if (!result.cloudDataDeleted) reasons.push('cloud data is still present');
  if (result.failedSecretDestroys > 0) reasons.push(`${result.failedSecretDestroys} secret deletion(s) failed`);
  if (result.failedStorageDeletes > 0) reasons.push(`${result.failedStorageDeletes} storage deletion(s) failed`);
  if (!result.deletedAuthUser && !result.authUserAlreadyMissing) reasons.push('the cloud account remains');
  if (result.retryRequired && reasons.length === 0) reasons.push('the server requested another attempt');
  if (!result.ok && reasons.length === 0) reasons.push('the server did not confirm completion');
  return `Account erasure is incomplete; retry required. ${reasons.join('; ')}.`;
}

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
  const updateStatus = useSupportStore((s) => s.updateStatus);
  const updateLoading = useSupportStore((s) => s.updateLoading);
  const updateError = useSupportStore((s) => s.updateError);
  const checkUpdate = useSupportStore((s) => s.checkUpdate);
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
      <UpdateStatusCard
        status={updateStatus}
        loading={updateLoading}
        error={updateError}
        onCheck={() => void checkUpdate()}
      />
      <SettingGroup title="Package channel" sectionHeader>
        <p>{UPDATE_CHANNEL_COPY[versionInfo.packageChannel]}</p>
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

function PrivacyToggle({
  checked,
  label,
  disabled,
  onChange,
  status
}: {
  checked: boolean;
  label: string;
  disabled: boolean;
  onChange: (checked: boolean) => void;
  status: string;
}) {
  return (
    <label className="setting-toggle setting-toggle--privacy">
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        aria-busy={disabled}
        aria-label={label}
        onChange={(event) => onChange(event.currentTarget.checked)}
      />
      <span className="muted">{status}</span>
    </label>
  );
}

function ProxyRouteRetentionControl({ fixtureMode }: { fixtureMode: boolean }) {
  const routeLog = useSettingsWiringStore((state) => state.routeLog);
  const loadingRouteLog = useSettingsWiringStore((state) => state.loadingRouteLog);
  const busy = useSettingsWiringStore((state) => state.busy);
  const error = useSettingsWiringStore((state) => state.error);
  const loadRouteLog = useSettingsWiringStore((state) => state.loadRouteLog);
  const clearRouteLog = useSettingsWiringStore((state) => state.clearRouteLog);
  const [confirming, setConfirming] = useState(false);

  useEffect(() => {
    void loadRouteLog();
  }, [loadRouteLog]);

  const clearBusy = busy === 'route-log.clear';
  const disabled = Boolean(busy) || loadingRouteLog;
  const requestClear = () => {
    if (!confirming) {
      setConfirming(true);
      return;
    }
    setConfirming(false);
    void clearRouteLog();
  };

  return (
    <>
      <SettingRow
        iconGlyph="⌫"
        label="Proxy route retention"
        description={
          fixtureMode
            ? 'Fixture route events are local-only and can be cleared from this pane.'
            : 'Clear the daemon-owned local proxy route log. This does not delete transcripts, credentials, or account data.'
        }
        control={
          <span className="settings-verification-value">
            <span className="muted" role="status">{routeLog.length} retained</span>
            <button type="button" className="ghost" disabled={disabled} onClick={() => void loadRouteLog()}>
              {loadingRouteLog ? 'Refreshing…' : 'Refresh'}
            </button>
          </span>
        }
      />
      <div className="actions">
        <button
          type="button"
          className={confirming ? 'danger' : 'ghost'}
          disabled={disabled || routeLog.length === 0}
          aria-busy={clearBusy}
          onClick={requestClear}
        >
          {clearBusy ? 'Clearing…' : confirming ? 'Confirm clear route log' : 'Clear local route log'}
        </button>
        {confirming ? <button type="button" className="ghost" onClick={() => setConfirming(false)}>Cancel</button> : null}
      </div>
      {error && (clearBusy || confirming) ? <p className="muted" role="alert">{error}</p> : null}
    </>
  );
}

const PRIVACY_STORE_LABELS: Record<LinuxPrivacyStoreID, string> = {
  proxy_route_log: 'Proxy route log',
  text_expansion_store: 'Encrypted text-expansion store'
};

function PrivacyDeletionControl({ fixtureMode }: { fixtureMode: boolean }) {
  const bridge = useShellStore((state) => state.bridge);
  const busy = useSettingsWiringStore((state) => state.busy);
  const deletion = useSettingsWiringStore((state) => state.privacyDeletion);
  const loadInventory = useSettingsWiringStore((state) => state.loadPrivacyInventory);
  const previewDeletion = useSettingsWiringStore((state) => state.previewPrivacyDeletion);
  const executeDeletion = useSettingsWiringStore((state) => state.executePrivacyDeletion);
  const clearPreview = useSettingsWiringStore((state) => state.clearPrivacyDeletionPreview);
  const [selectedStores, setSelectedStores] = useState<LinuxPrivacyStoreID[]>([
    'proxy_route_log',
    'text_expansion_store'
  ]);
  const [confirmation, setConfirmation] = useState('');
  const supported = !fixtureMode
    && typeof bridge?.linuxPrivacyInventory === 'function'
    && typeof bridge.linuxPrivacyDeletionPreview === 'function'
    && typeof bridge.linuxPrivacyDeletionExecute === 'function';

  useEffect(() => {
    if (supported) void loadInventory();
  }, [loadInventory, supported]);

  useEffect(() => {
    if (!deletion.inventory) return;
    setSelectedStores((current) => current.filter((store) =>
      deletion.inventory?.stores.some((entry) => entry.store === store && entry.state !== 'blocked')
    ));
  }, [deletion.inventory]);

  if (!supported) {
    return (
      <SettingRow
        iconGlyph="⌫"
        label="Delete local data"
        description="A destructive local purge requires a daemon-owned scope preview, confirmation, and receipt."
        control={<span className="muted" role="status">Unavailable</span>}
        readOnlyNote="No destructive deletion RPC is exposed; nothing is deleted from this pane."
      />
    );
  }

  const preview = deletion.preview;
  const deleting = deletion.status === 'deleting';
  const loading = deletion.status === 'loading';
  const previewing = deletion.status === 'previewing';
  const stores = deletion.inventory?.stores ?? [];
  const selectedCount = selectedStores.length;
  const toggleStore = (store: LinuxPrivacyStoreID, checked: boolean) => {
    setSelectedStores((current) => checked
      ? Array.from(new Set([...current, store]))
      : current.filter((item) => item !== store));
  };

  return (
    <>
      <SettingRow
        iconGlyph="⌫"
        label="Delete selected local data"
        description="Preview and confirm deletion of daemon-owned local stores only. Transcripts, credentials, and account data are never included."
        control={
          <button
            type="button"
            className="ghost"
            disabled={Boolean(busy) || loading || previewing || deleting || selectedCount === 0}
            onClick={() => void previewDeletion(selectedStores)}
          >
            {previewing ? 'Preparing…' : 'Preview deletion'}
          </button>
        }
      />
      <fieldset className="privacy-store-picker" disabled={Boolean(busy) || deleting || Boolean(preview)}>
        <legend className="muted">Stores included in the preview</legend>
        {stores.map((entry) => (
          <label key={entry.store} className="setting-toggle">
            <input
              type="checkbox"
              checked={selectedStores.includes(entry.store)}
              disabled={entry.state === 'blocked'}
              onChange={(event) => toggleStore(entry.store, event.currentTarget.checked)}
            />
            <span>{PRIVACY_STORE_LABELS[entry.store]} ({entry.state}, {entry.bytes} bytes)</span>
          </label>
        ))}
      </fieldset>
      <button type="button" className="ghost" disabled={Boolean(busy) || loading || deleting} onClick={() => void loadInventory()}>
        {loading ? 'Refreshing…' : 'Refresh local store inventory'}
      </button>
      {preview ? (
        <div className="actions">
          <p className="muted" role="status">
            Preview expires {new Date(preview.expiresAt).toLocaleString()}. {preview.entries.length} store(s) are in scope.
          </p>
          <label className="setting-field">
            <span>Type {preview.confirmationPhrase} to confirm</span>
            <input
              type="text"
              value={confirmation}
              aria-label="Privacy deletion confirmation"
              autoComplete="off"
              onChange={(event) => setConfirmation(event.currentTarget.value)}
            />
          </label>
          <span className="settings-verification-value">
            <button
              type="button"
              className="danger"
              disabled={deleting || confirmation !== preview.confirmationPhrase}
              onClick={() => {
                setConfirmation('');
                void executeDeletion(preview.confirmationPhrase);
              }}
            >
              {deleting ? 'Deleting…' : 'Confirm deletion'}
            </button>
            <button type="button" className="ghost" disabled={deleting} onClick={() => { setConfirmation(''); clearPreview(); }}>
              Cancel
            </button>
          </span>
        </div>
      ) : null}
      {deletion.status === 'success' ? <Banner tone="ok" role="status">{deletion.message}</Banner> : null}
      {deletion.status === 'error' ? <Banner tone="degraded" role="alert">{deletion.message}</Banner> : null}
    </>
  );
}

function PrivacyExportControl({ fixtureMode }: { fixtureMode: boolean }) {
  const bridge = useShellStore((state) => state.bridge);
  const busy = useSettingsWiringStore((state) => state.busy);
  const exportState = useSettingsWiringStore((state) => state.privacyExport);
  const exportPrivacyData = useSettingsWiringStore((state) => state.exportPrivacyData);
  const [selectedStores, setSelectedStores] = useState<LinuxPrivacyStoreID[]>([
    'proxy_route_log',
    'text_expansion_store'
  ]);
  const [destinationPath, setDestinationPath] = useState('');
  const [passphrase, setPassphrase] = useState('');
  const [destinationBusy, setDestinationBusy] = useState(false);
  const [destinationError, setDestinationError] = useState<string | null>(null);
  const supported = !fixtureMode
    && typeof bridge?.linuxPrivacyExport === 'function'
    && typeof bridge?.pickExportDestination === 'function';

  if (!supported) {
    return (
      <SettingRow
        iconGlyph="⇩"
        label="Encrypted local export"
        description="Export selected daemon-owned local privacy stores with a passphrase."
        control={<span className="muted" role="status">Unavailable</span>}
        readOnlyNote="The packaged daemon must expose the encrypted privacy export contract."
      />
    );
  }

  const disabled = Boolean(busy) || exportState.status === 'pending';
  const canExport = selectedStores.length > 0 && destinationPath.trim().startsWith('/') && passphrase.length >= 8;
  const chooseDestination = async () => {
    if (!bridge?.pickExportDestination || destinationBusy || disabled) return;
    setDestinationBusy(true);
    setDestinationError(null);
    try {
      const path = await bridge.pickExportDestination('linux-privacy');
      if (path) setDestinationPath(path);
    } catch (cause) {
      setDestinationError(cause instanceof Error ? cause.message : 'Could not choose an export destination.');
    } finally {
      setDestinationBusy(false);
    }
  };
  const toggleStore = (store: LinuxPrivacyStoreID, checked: boolean) => {
    setSelectedStores((current) => checked
      ? Array.from(new Set([...current, store]))
      : current.filter((item) => item !== store));
  };

  return (
    <>
      <SettingRow
        iconGlyph="⇩"
        label="Encrypted local export"
        description="Export selected daemon-owned local stores into a passphrase-encrypted 0600 bundle. Contents never return through the renderer bridge."
        control={
          <button
            type="button"
            className="ghost"
            disabled={disabled || !canExport}
            aria-busy={exportState.status === 'pending'}
            onClick={() => {
              const request = { stores: selectedStores, destinationPath: destinationPath.trim(), passphrase };
              setPassphrase('');
              void exportPrivacyData(request);
            }}
          >
            {exportState.status === 'pending' ? 'Encrypting…' : 'Export selected data'}
          </button>
        }
      />
      <fieldset className="privacy-store-picker" disabled={disabled}>
        <legend className="muted">Stores included in the encrypted export</legend>
        {(Object.keys(PRIVACY_STORE_LABELS) as LinuxPrivacyStoreID[]).map((store) => (
          <label key={store} className="setting-toggle">
            <input
              type="checkbox"
              checked={selectedStores.includes(store)}
              onChange={(event) => toggleStore(store, event.currentTarget.checked)}
            />
            <span>{PRIVACY_STORE_LABELS[store]}</span>
          </label>
        ))}
      </fieldset>
      <div className="setting-field">
        <span>Export destination</span>
        <div className="actions">
          <button
            type="button"
            className="ghost"
            disabled={disabled || destinationBusy}
            aria-busy={destinationBusy}
            aria-label="Choose privacy export destination"
            onClick={() => void chooseDestination()}
          >
            {destinationBusy ? 'Opening…' : 'Choose destination'}
          </button>
          {destinationPath ? <code>{destinationPath}</code> : <span className="muted">No destination selected</span>}
        </div>
      </div>
      <label className="setting-field">
        <span>Export passphrase (8+ characters)</span>
        <input
          type="password"
          value={passphrase}
          aria-label="Privacy export passphrase"
          autoComplete="new-password"
          onChange={(event) => setPassphrase(event.currentTarget.value)}
        />
      </label>
      {destinationError ? <Banner tone="degraded" role="alert">{destinationError}</Banner> : null}
      {exportState.status === 'success' ? (
        <>
          <Banner tone="ok" role="status">{exportState.message ?? 'Encrypted local privacy export written.'}</Banner>
          {exportState.result ? (
            <div className="actions" aria-label="Encrypted local export receipt">
              <p className="muted" role="status">
                Exported {exportState.result.stores.map((store) => PRIVACY_STORE_LABELS[store]).join(', ')} ·{' '}
                {exportState.result.byteCount.toLocaleString()} bytes · format v{exportState.result.formatVersion}.
              </p>
              <p className="system-path-row">
                <strong>Destination:</strong>
                <code>{exportState.result.destinationPath}</code>
                <CopyPathButton path={exportState.result.destinationPath} label="Copy export path" />
              </p>
              <p className="muted">
                Keep the passphrase separate from this owner-only bundle. The export contains only the selected local
                stores; transcripts, credentials, and account data are not included.
              </p>
            </div>
          ) : null}
        </>
      ) : null}
      {exportState.status === 'error' ? <Banner tone="degraded" role="alert">{exportState.message}</Banner> : null}
    </>
  );
}

const RETENTION_CONFIRMATION = 'APPLY RETENTION POLICY';
const RETENTION_AGE_OPTIONS = [1, 7, 30, 90, 365];
const RETENTION_SIZE_OPTIONS = [1, 4, 8, 16, 64];

function PrivacyRetentionControl({ fixtureMode }: { fixtureMode: boolean }) {
  const bridge = useShellStore((state) => state.bridge);
  const busy = useSettingsWiringStore((state) => state.busy);
  const retention = useSettingsWiringStore((state) => state.privacyRetention);
  const loadPrivacyRetention = useSettingsWiringStore((state) => state.loadPrivacyRetention);
  const applyPrivacyRetention = useSettingsWiringStore((state) => state.applyPrivacyRetention);
  const [limits, setLimits] = useState<Record<LinuxPrivacyStoreID, { days: number; megabytes: number }>>({
    proxy_route_log: { days: 30, megabytes: 8 },
    text_expansion_store: { days: 365, megabytes: 4 }
  });
  const [confirmation, setConfirmation] = useState('');
  const supported = !fixtureMode && typeof bridge?.linuxPrivacyRetentionStatus === 'function' && typeof bridge?.linuxPrivacyRetentionApply === 'function';

  useEffect(() => {
    if (supported) void loadPrivacyRetention();
  }, [loadPrivacyRetention, supported]);

  if (!supported) {
    return (
      <SettingRow
        iconGlyph="◷"
        label="Automatic local retention"
        description="Apply daemon-owned age and size limits to the proxy route log and encrypted text-expansion store."
        control={<span className="muted" role="status">Unavailable</span>}
        readOnlyNote="The packaged daemon must expose the audited retention policy contract."
      />
    );
  }

  const disabled = Boolean(busy) || retention.status === 'loading' || retention.status === 'applying';
  const rules: LinuxPrivacyRetentionRule[] = (Object.keys(limits) as LinuxPrivacyStoreID[]).map((store) => ({
    store,
    maxAgeSeconds: limits[store].days * 24 * 60 * 60,
    maxBytes: limits[store].megabytes * 1024 * 1024
  }));
  const canApply = confirmation === RETENTION_CONFIRMATION && !disabled;
  const updateLimit = (store: LinuxPrivacyStoreID, field: 'days' | 'megabytes', value: number) => {
    setLimits((current) => ({ ...current, [store]: { ...current[store], [field]: value } }));
  };

  return (
    <>
      <SettingRow
        iconGlyph="◷"
        label="Automatic local retention"
        description="The daemon evaluates and atomically trims only the two allowlisted local stores. Account erasure, cloud data, and recovery receipts remain separate workflows."
        control={
          <span className="settings-verification-value">
            <span className="muted" role="status">
              {retention.status === 'loading' ? 'Loading…' : retention.data?.policyState ?? 'Unknown'}
            </span>
            <button type="button" className="ghost" disabled={disabled} onClick={() => void loadPrivacyRetention()}>
              Refresh
            </button>
          </span>
        }
      />
      <fieldset className="privacy-store-picker" disabled={disabled}>
        <legend className="muted">Retention limits</legend>
        {(Object.keys(PRIVACY_STORE_LABELS) as LinuxPrivacyStoreID[]).map((store) => {
          const status = retention.data?.stores.find((item) => item.store === store);
          return (
            <div key={store} className="settings-verification-value">
              <strong>{PRIVACY_STORE_LABELS[store]}</strong>
              <label className="setting-field">
                <span>Max age</span>
                <select
                  value={limits[store].days}
                  aria-label={`${PRIVACY_STORE_LABELS[store]} maximum age`}
                  onChange={(event) => updateLimit(store, 'days', Number(event.currentTarget.value))}
                >
                  {RETENTION_AGE_OPTIONS.map((days) => <option key={days} value={days}>{days} days</option>)}
                </select>
              </label>
              <label className="setting-field">
                <span>Max size</span>
                <select
                  value={limits[store].megabytes}
                  aria-label={`${PRIVACY_STORE_LABELS[store]} maximum size`}
                  onChange={(event) => updateLimit(store, 'megabytes', Number(event.currentTarget.value))}
                >
                  {RETENTION_SIZE_OPTIONS.map((megabytes) => <option key={megabytes} value={megabytes}>{megabytes} MB</option>)}
                </select>
              </label>
              <span className="muted" role="status">
                {status?.state === 'blocked'
                  ? `Blocked: ${status.reason}`
                  : status?.wouldPurge
                    ? `Over limit (${status.bytes.toLocaleString()} bytes)`
                    : status?.state === 'absent'
                      ? 'No local store'
                      : `${status?.bytes.toLocaleString() ?? 0} bytes within limit`}
              </span>
            </div>
          );
        })}
      </fieldset>
      <label className="setting-field">
        <span>Type {RETENTION_CONFIRMATION} to apply</span>
        <input
          type="text"
          value={confirmation}
          aria-label="Retention policy confirmation"
          autoComplete="off"
          onChange={(event) => setConfirmation(event.currentTarget.value)}
        />
      </label>
      <div className="actions">
        <button
          type="button"
          className="danger"
          disabled={!canApply}
          aria-busy={retention.status === 'applying'}
          onClick={() => {
            setConfirmation('');
            void applyPrivacyRetention({ rules, confirmation: RETENTION_CONFIRMATION });
          }}
        >
          {retention.status === 'applying' ? 'Applying…' : 'Apply retention policy'}
        </button>
      </div>
      {retention.status === 'success' ? <Banner tone="ok" role="status">{retention.message}</Banner> : null}
      {retention.status === 'error' ? <Banner tone="degraded" role="alert">{retention.message}</Banner> : null}
    </>
  );
}

function AccountCloudDataDeletionControl({ fixtureMode }: { fixtureMode: boolean }) {
  const bridge = useShellStore((state) => state.bridge);
  const busy = useSettingsWiringStore((state) => state.busy);
  const [phase, setPhase] = useState<'idle' | 'confirming' | 'deleting' | 'success' | 'error'>('idle');
  const [confirmation, setConfirmation] = useState('');
  const [result, setResult] = useState<AccountCloudDataDeletionResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const supported = !fixtureMode && typeof bridge?.accountDeleteCloudData === 'function';

  if (!supported) {
    return (
      <SettingRow
        iconGlyph="◎"
        label="Account erasure"
        description="Delete cloud account data through the daemon-owned audited erasure callable."
        control={<span className="muted" role="status">Unavailable</span>}
        readOnlyNote="The packaged daemon must expose the authenticated account-erasure RPC; nothing is deleted from this pane."
      />
    );
  }

  const deleting = phase === 'deleting';
  const confirming = phase === 'confirming' || deleting;
  const disabled = Boolean(busy) || deleting;
  const begin = () => {
    setPhase('confirming');
    setConfirmation('');
    setResult(null);
    setError(null);
  };
  const cancel = () => {
    if (deleting) return;
    setPhase('idle');
    setConfirmation('');
    setError(null);
  };
  const execute = async () => {
    if (confirmation !== ACCOUNT_CLOUD_DATA_DELETION_CONFIRMATION || !bridge?.accountDeleteCloudData || deleting) return;
    setPhase('deleting');
    setError(null);
    try {
      const next = await bridge.accountDeleteCloudData(ACCOUNT_CLOUD_DATA_DELETION_CONFIRMATION);
      setResult(next);
      setConfirmation('');
      if (accountErasureCompleted(next)) {
        setPhase('success');
      } else {
        setError(accountErasureRetryMessage(next));
        setPhase('error');
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Account erasure did not complete; retry.');
      setPhase('error');
    }
  };

  return (
    <>
      <SettingRow
        iconGlyph="◎"
        label="Account erasure"
        description="Delete cloud account data through the daemon-owned audited callable. Local data and credentials are not silently removed."
        control={
          <button
            type="button"
            className="danger"
            disabled={disabled}
            onClick={begin}
          >
            {deleting ? 'Deleting…' : phase === 'error' ? 'Retry account erasure' : 'Delete cloud account data'}
          </button>
        }
      />
      {confirming ? (
        <div className="actions">
          <p className="muted" role="status">
            This is irreversible. Type {ACCOUNT_CLOUD_DATA_DELETION_CONFIRMATION} to request trusted-device approval.
          </p>
          <label className="setting-field">
            <span>Account erasure confirmation</span>
            <input
              type="text"
              value={confirmation}
              aria-label="Account erasure confirmation"
              autoComplete="off"
              disabled={deleting}
              onChange={(event) => setConfirmation(event.currentTarget.value)}
            />
          </label>
          <span className="settings-verification-value">
            <button
              type="button"
              className="danger"
              disabled={deleting || confirmation !== ACCOUNT_CLOUD_DATA_DELETION_CONFIRMATION}
              aria-busy={deleting}
              onClick={() => void execute()}
            >
              {deleting ? 'Deleting…' : 'Confirm account erasure'}
            </button>
            <button type="button" className="ghost" disabled={deleting} onClick={cancel}>Cancel</button>
          </span>
        </div>
      ) : null}
      {phase === 'success' && result ? (
        <Banner tone="ok" role="status">
          Cloud account data was deleted. {result.deletedDocuments} document(s), {result.destroyedSecrets} secret(s), and {result.deletedStoragePrefixes} storage prefix(es) removed.
        </Banner>
      ) : null}
      {phase === 'error' ? (
        <Banner tone="degraded" role="alert">
          {error ?? 'Account erasure did not complete; retry.'}
        </Banner>
      ) : null}
    </>
  );
}

function AccountCloudDataExportControl({ fixtureMode }: { fixtureMode: boolean }) {
  const bridge = useShellStore((state) => state.bridge);
  const busy = useSettingsWiringStore((state) => state.busy);
  const [phase, setPhase] = useState<'idle' | 'exporting' | 'success' | 'error'>('idle');
  const [destinationPath, setDestinationPath] = useState('');
  const [destinationBusy, setDestinationBusy] = useState(false);
  const [destinationError, setDestinationError] = useState<string | null>(null);
  const [result, setResult] = useState<AccountCloudDataExportResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const supported = !fixtureMode
    && typeof bridge?.accountExportCloudData === 'function'
    && typeof bridge?.pickExportDestination === 'function';

  if (!supported) {
    return (
      <SettingRow
        iconGlyph="⇩"
        label="Full data export"
        description="Export cloud account data through trusted-device approval; the daemon writes sealed references and redacted fields locally."
        control={<span className="muted" role="status">Unavailable</span>}
        readOnlyNote="The packaged daemon must expose the authenticated account-export RPC; no data is returned through this pane."
      />
    );
  }

  const exporting = phase === 'exporting';
  const disabled = Boolean(busy) || exporting;
  const canExport = destinationPath.trim().startsWith('/');
  const chooseDestination = async () => {
    if (!bridge?.pickExportDestination || destinationBusy || disabled) return;
    setDestinationBusy(true);
    setDestinationError(null);
    try {
      const path = await bridge.pickExportDestination('account-cloud');
      if (path) setDestinationPath(path);
    } catch (cause) {
      setDestinationError(cause instanceof Error ? cause.message : 'Could not choose an export destination.');
    } finally {
      setDestinationBusy(false);
    }
  };
  const execute = async () => {
    if (!bridge?.accountExportCloudData || !canExport || exporting) return;
    setPhase('exporting');
    setResult(null);
    setError(null);
    try {
      const next = await bridge.accountExportCloudData({ destinationPath: destinationPath.trim() });
      setResult(next);
      setPhase('success');
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Account export did not complete; retry.');
      setPhase('error');
    }
  };

  return (
    <>
      <SettingRow
        iconGlyph="⇩"
        label="Full data export"
        description="Export cloud account data through trusted-device approval. The daemon writes bounded JSON with sealed references and redacted fields using owner-only permissions; provider credentials are never exported."
        control={
          <button
            type="button"
            className="ghost"
            disabled={disabled || !canExport}
            aria-busy={exporting}
            onClick={() => void execute()}
          >
            {exporting ? 'Exporting…' : phase === 'error' ? 'Retry account export' : 'Export account data'}
          </button>
        }
      />
      <div className="setting-field">
        <span>Export destination</span>
        <div className="actions">
          <button
            type="button"
            className="ghost"
            disabled={disabled || destinationBusy}
            aria-busy={destinationBusy}
            aria-label="Choose account export destination"
            onClick={() => void chooseDestination()}
          >
            {destinationBusy ? 'Opening…' : 'Choose destination'}
          </button>
          {destinationPath ? <code>{destinationPath}</code> : <span className="muted">No destination selected</span>}
        </div>
      </div>
      {destinationError ? <Banner tone="degraded" role="alert">{destinationError}</Banner> : null}
      <p className="muted">A trusted device must approve this export. Cloud credentials stay inside the daemon; sealed references and redacted fields are written to the selected path.</p>
      {phase === 'success' && result ? (
        <div className="actions" aria-label="Account export receipt">
          <Banner tone="ok" role="status">Account export written by the daemon.</Banner>
          <p className="muted" role="status">
            {result.byteCount.toLocaleString()} bytes · schema v{result.schemaVersion}.
          </p>
          <p className="system-path-row">
            <strong>Destination:</strong>
            <code>{result.destinationPath}</code>
            <CopyPathButton path={result.destinationPath} label="Copy account export path" />
          </p>
        </div>
      ) : null}
      {phase === 'error' ? <Banner tone="degraded" role="alert">{error ?? 'Account export did not complete; retry.'}</Banner> : null}
    </>
  );
}

function providerCoverageLabel(coverage: 'local-parser' | 'api-backed' | 'unavailable'): string {
  switch (coverage) {
    case 'local-parser':
      return 'Local parser registered';
    case 'api-backed':
      return 'API-backed; no local parser';
    case 'unavailable':
      return 'Local usage unavailable';
  }
}

function NotificationsDetail({ mode }: { mode: 'alerts' | 'notifications' }) {
  const config = useSettingsWiringStore((s) => s.notificationConfig);
  const health = useSettingsWiringStore((s) => s.notificationHealth);
  const result = useSettingsWiringStore((s) => s.notificationCommandResult);
  const nativeCapabilities = useSettingsWiringStore((s) => s.nativeNotificationCapabilities);
  const shortcutStatus = useSettingsWiringStore((s) => s.nativeShortcutStatus);
  const loading = useSettingsWiringStore((s) => s.loadingNotifications);
  const busy = useSettingsWiringStore((s) => s.busy);
  const error = useSettingsWiringStore((s) => s.error);
  const load = useSettingsWiringStore((s) => s.loadNotifications);
  const update = useSettingsWiringStore((s) => s.updateNotificationConfig);
  const runCommand = useSettingsWiringStore((s) => s.runNotificationCommand);
  useLaneLoad(load);

  const disabled = Boolean(busy);
  const channels = useMemo(() => new Map((health?.channels ?? []).map((c) => [c.channel, c])), [health]);

  if (loading && !config) return <p className="muted">Loading notification settings…</p>;
  if (!config) {
    return (
      <OfflineNotice
        status={{
          tone: 'warn',
          label: 'Notifications unavailable',
          detail: error ?? 'Packaged shell required for notification settings.',
          ok: false
        }}
        summary="Notifications need the local daemon notification RPCs."
        fixtureMode={false}
      />
    );
  }

  const patch = (mutate: (current: NotificationConfig) => NotificationConfig) => {
    void update(mutate(JSON.parse(JSON.stringify(config)) as NotificationConfig));
  };

  return (
    <>
      {error ? <Banner tone="degraded" role="alert">{error}</Banner> : null}
      {result ? <Banner tone={result.ok ? 'ok' : 'degraded'} role="status">{result.message}</Banner> : null}
      <SettingGroup title={mode === 'alerts' ? 'Alerts' : 'Notifications'} sectionHeader hideTitle>
        <SettingRow
          iconGlyph="◉"
          label="Default snooze"
          description="Minutes used by notification followup snooze actions."
          control={
            <input
              type="number"
              min={1}
              max={1440}
              value={config.defaultSnoozeMinutes}
              disabled={disabled}
              aria-label="Default snooze minutes"
              onChange={(e) => patch((c) => ({ ...c, defaultSnoozeMinutes: Number(e.currentTarget.value) }))}
            />
          }
        />
        <SettingRow
          iconGlyph="⏱"
          label="Nudge hours"
          description="Local hours when digest nudges are allowed."
          control={
            <input
              value={config.nudgeHoursLocal.join(',')}
              disabled={disabled}
              aria-label="Nudge hours"
              onChange={(e) =>
                patch((c) => ({
                  ...c,
                  nudgeHoursLocal: e.currentTarget.value.split(',').map((v) => Number(v.trim())).filter((v) => Number.isFinite(v) && v >= 0 && v <= 23)
                }))
              }
            />
          }
        />
      </SettingGroup>
      <SettingGroup title="Channels" sectionHeader hideTitle>
        <SettingRow
          iconGlyph="◈"
          label="Local notifications"
          description={`Health: ${channels.get('local')?.status ?? 'unknown'}`}
          control={<button type="button" className="ghost" disabled={disabled} onClick={() => patch((c) => ({ ...c, local: { ...c.local, isEnabled: !c.local.isEnabled } }))}>{config.local.isEnabled ? 'Disable' : 'Enable'}</button>}
        />
        <SettingRow
          iconGlyph="✈"
          label="Telegram"
          description={`Health: ${channels.get('telegram')?.status ?? 'unknown'} · Token ${config.telegram.botTokenConfigured ? config.telegram.botTokenHint ?? 'configured' : 'not configured'}`}
          control={<button type="button" className="ghost" disabled={disabled} onClick={() => patch((c) => ({ ...c, telegram: { ...c.telegram, isEnabled: !c.telegram.isEnabled } }))}>{config.telegram.isEnabled ? 'Disable' : 'Enable'}</button>}
        />
        <form
          className="settings-mini-form"
          onSubmit={(event) => {
            event.preventDefault();
            const form = new FormData(event.currentTarget);
            const botToken = String(form.get('botToken') ?? '').trim();
            const chatID = String(form.get('chatID') ?? '').trim();
            patch((c) => ({
              ...c,
              telegram: {
                ...c.telegram,
                botToken: botToken || undefined,
                botTokenConfigured: botToken ? true : c.telegram.botTokenConfigured,
                chatID: chatID || c.telegram.chatID
              }
            }));
            event.currentTarget.reset();
          }}
        >
          <input name="botToken" type="password" placeholder="Bot token" disabled={disabled} aria-label="Telegram bot token" />
          <input name="chatID" placeholder={config.telegram.chatID ?? 'Chat ID'} disabled={disabled} aria-label="Telegram chat ID" />
          <button type="submit" className="ghost" disabled={disabled}>Save Telegram</button>
        </form>
        <SettingRow
          iconGlyph="□"
          label="Calendar"
          description={`Health: ${channels.get('calendar')?.status ?? 'unknown'} · Default ${config.calendar.defaultDurationMinutes}m`}
          control={
            <span className="settings-verification-value">
              <button
                type="button"
                className="ghost"
                disabled={disabled}
                onClick={() => patch((c) => ({ ...c, calendar: { ...c.calendar, isEnabled: !c.calendar.isEnabled } }))}
              >
                {config.calendar.isEnabled ? 'Disable' : 'Enable'}
              </button>
              <select
                value={config.calendar.defaultDurationMinutes}
                disabled={disabled || !config.calendar.isEnabled}
                aria-label="Calendar default duration minutes"
                onChange={(event) => {
                  const minutes = Number(event.currentTarget.value);
                  if (CALENDAR_DURATION_OPTIONS.includes(minutes)) {
                    patch((c) => ({ ...c, calendar: { ...c.calendar, defaultDurationMinutes: minutes } }));
                  }
                }}
              >
                {CALENDAR_DURATION_OPTIONS.map((minutes) => (
                  <option key={minutes} value={minutes}>{minutes} min</option>
                ))}
              </select>
            </span>
          }
        />
      </SettingGroup>
      <SettingGroup title="Commands" sectionHeader hideTitle>
        <div className="actions">
          {['status', 'pending', 'followups', 'latest'].map((command) => (
            <button key={command} type="button" className="ghost" disabled={disabled} onClick={() => void runCommand(command)}>
              {command}
            </button>
          ))}
        </div>
      </SettingGroup>
      <SettingGroup title="Native delivery" sectionHeader hideTitle>
        <SettingRow
          iconGlyph="◌"
          label="Desktop action transport"
          description={nativeCapabilities
            ? nativeCapabilities.actions
              ? `Freedesktop actions available · ${nativeCapabilities.serverCapabilities.join(', ') || 'server did not list capabilities'}`
              : nativeCapabilities.degradedReason ?? 'Desktop notification actions are unavailable on this host.'
            : 'Packaged shell did not expose native notification capabilities.'}
          control={<span className={`status-pill ${nativeCapabilities?.actions ? 'ok' : 'warn'}`}>{nativeCapabilities?.actions ? 'Available' : 'Degraded'}</span>}
        />
        <SettingRow
          iconGlyph="⌘"
          label="Global shortcuts"
          description={shortcutStatus
            ? shortcutStatus.registered
              ? shortcutStatus.shortcuts.join(' · ')
              : shortcutStatus.degradedReason ?? 'Global shortcut registration is unavailable on this host.'
            : 'Packaged shell did not expose global shortcut status.'}
          control={<span className={`status-pill ${shortcutStatus?.registered ? 'ok' : 'warn'}`}>{shortcutStatus?.registered ? 'Registered' : 'Degraded'}</span>}
        />
      </SettingGroup>
    </>
  );
}

type DeviceSyncAction = 'refresh' | 'sign-out' | 'rotate-identity' | null;

function accountPostureCopy(status: AccountStatus | null, loading: boolean, error: string | null): string {
  if (loading) return 'Checking daemon-owned account and enrollment posture…';
  if (error) return `Account posture unavailable: ${error}`;
  if (!status) return 'Account posture has not been loaded.';
  if (status.state === 'unavailable') {
    return status.detail === 'device_rejected'
      ? 'This installation was rejected; replace its identity before requesting approval again.'
      : 'Cloud account services are unavailable; local SQLite remains canonical.';
  }
  if (status.state === 'awaiting-device-approval' || status.deviceApprovalRequired) {
    return 'This installation is enrolled and waiting for approval from a trusted OpenBurnBar device.';
  }
  if (status.signedIn) return `Signed in as ${status.identityLabel ?? 'Linux identity'}; cloud sync is ${status.syncState}.`;
  return 'Signed out; local-first mode remains available.';
}

function DevicesAndSyncDetail({
  config,
  fixtureMode,
  bridge,
  onSelectTab
}: {
  config: ConfigSnapshot;
  fixtureMode: boolean;
  bridge: LinuxShellBridge | null;
  onSelectTab: (tab: SettingsTabId) => void;
}) {
  const [account, setAccount] = useState<AccountStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [action, setAction] = useState<DeviceSyncAction>(null);
  const [error, setError] = useState<string | null>(null);
  const [trustedDevices, setTrustedDevices] = useState<TrustedDevice[]>([]);
  const [trustedDevicesLoading, setTrustedDevicesLoading] = useState(false);
  const [trustedDevicesError, setTrustedDevicesError] = useState<string | null>(null);
  const [trustedDeviceAction, setTrustedDeviceAction] = useState<string | null>(null);

  const trustedDeviceBridgeAvailable = !fixtureMode
    && typeof bridge?.trustedDeviceList === 'function'
    && typeof bridge.trustedDeviceApprove === 'function'
    && typeof bridge.trustedDeviceRevoke === 'function';

  const loadAccountPosture = async (requestedAction: DeviceSyncAction = 'refresh') => {
    if (action !== null) return;
    setLoading(true);
    setAction(requestedAction);
    setError(null);
    try {
      const next = fixtureMode
        ? fixtureAccountStatus()
        : bridge
          ? await bridge.accountStatus()
          : null;
      if (!next) throw new Error('Packaged shell required for live account posture.');
      setAccount(next);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Account status request failed.');
    } finally {
      setLoading(false);
      setAction(null);
    }
  };

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    const request = fixtureMode
      ? Promise.resolve(fixtureAccountStatus())
      : bridge
        ? bridge.accountStatus()
        : Promise.reject(new Error('Packaged shell required for live account posture.'));
    void request
      .then((next) => {
        if (!cancelled) setAccount(next);
      })
      .catch((cause: unknown) => {
        if (!cancelled) setError(cause instanceof Error ? cause.message : 'Account status request failed.');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [fixtureMode, bridge]);

  const loadTrustedDevices = useCallback(async () => {
    if (!trustedDeviceBridgeAvailable || !bridge?.trustedDeviceList) return;
    setTrustedDevicesLoading(true);
    setTrustedDevicesError(null);
    try {
      const result = await bridge.trustedDeviceList();
      setTrustedDevices(result.devices);
    } catch (cause) {
      setTrustedDevicesError(cause instanceof Error ? cause.message : 'Trusted-device state is unavailable.');
    } finally {
      setTrustedDevicesLoading(false);
    }
  }, [bridge, trustedDeviceBridgeAvailable]);

  useEffect(() => {
    if (!trustedDeviceBridgeAvailable) {
      setTrustedDevices([]);
      setTrustedDevicesError(null);
      return;
    }
    void loadTrustedDevices();
  }, [loadTrustedDevices, trustedDeviceBridgeAvailable]);

  const runTrustedDeviceMutation = async (device: TrustedDevice, approve: boolean) => {
    const mutation = approve ? bridge?.trustedDeviceApprove : bridge?.trustedDeviceRevoke;
    if (!trustedDeviceBridgeAvailable || !mutation || trustedDeviceAction !== null) return;
    setTrustedDeviceAction(`${approve ? 'approve' : 'revoke'}:${device.deviceId}`);
    setTrustedDevicesError(null);
    try {
      await mutation(device.deviceId);
      await loadTrustedDevices();
    } catch (cause) {
      setTrustedDevicesError(cause instanceof Error ? cause.message : 'Trusted-device mutation failed.');
    } finally {
      setTrustedDeviceAction(null);
    }
  };

  const runAccountMutation = async (kind: Exclude<DeviceSyncAction, 'refresh' | null>) => {
    if (action !== null || fixtureMode || !bridge) return;
    setAction(kind);
    setError(null);
    try {
      const next = kind === 'sign-out'
        ? await bridge.accountSignOut()
        : await bridge.accountRotateIdentity();
      setAccount(next);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Account mutation failed.');
    } finally {
      setAction(null);
    }
  };

  const rejected = account?.detail === 'device_rejected';
  const awaitingApproval = account?.state === 'awaiting-device-approval' || account?.deviceApprovalRequired;
  const statusText = accountPostureCopy(account, loading, error);

  return (
    <>
      {error ? <Banner tone="degraded" role="alert">{error}</Banner> : null}
      <SettingGroup title="Devices & Sync" sectionHeader hideTitle>
        <p className="muted settings-tab-lede">
          Account and enrollment posture comes from the daemon&apos;s authenticated account RPC. Secrets stay in the native
          Secret Service; local SQLite remains canonical while cloud sync is unavailable.
        </p>
        <SettingRow
          iconGlyph="⊞"
          label="Cloud sync source"
          description={`Provider rows: ${(config.providers ?? []).length}. ${statusText}`}
          control={<button type="button" className="ghost" onClick={() => onSelectTab('account')}>Open Account</button>}
        />
        <SettingRow
          iconGlyph="⛨"
          label="Secret Service"
          description="Cloud credentials require unlocked GNOME Keyring/KWallet before sync credentials can be saved."
          control={<span className="muted">{config.secretServiceStatus}</span>}
        />
        {account?.installationDeviceID ? (
          <SettingRow
            iconGlyph="⌘"
            label="Linux installation identity"
            description={awaitingApproval ? 'Approval is required on a trusted OpenBurnBar device.' : 'Daemon-owned identity used for cloud enrollment.'}
            control={
              <span className="settings-verification-value">
                <code className="mono">{account.installationDeviceID}</code>
                <CopyPathButton path={account.installationDeviceID} label="Copy device ID" />
              </span>
            }
          />
        ) : null}
        {account?.installationSafetyFingerprint ? (
          <SettingRow
            iconGlyph="#"
            label="Safety fingerprint"
            description="Compare this value on the approving device before trusting the installation."
            control={
              <span className="settings-verification-value">
                <code className="mono">{account.installationSafetyFingerprint}</code>
                <CopyPathButton path={account.installationSafetyFingerprint} label="Copy fingerprint" />
              </span>
            }
          />
        ) : null}
        <div className="actions">
          <button type="button" className="ghost" disabled={loading || action !== null} onClick={() => void loadAccountPosture()}>
            {action === 'refresh' ? 'Checking…' : 'Check account posture'}
          </button>
          {account?.signedIn ? (
            <button type="button" className="ghost" disabled={action !== null || fixtureMode} onClick={() => void runAccountMutation('sign-out')}>
              {action === 'sign-out' ? 'Signing out…' : 'Sign out'}
            </button>
          ) : null}
          {rejected ? (
            <button type="button" className="danger" disabled={action !== null || fixtureMode} onClick={() => void runAccountMutation('rotate-identity')}>
              {action === 'rotate-identity' ? 'Replacing identity…' : 'Replace rejected identity'}
            </button>
          ) : null}
        </div>
        {trustedDeviceBridgeAvailable ? (
          <section aria-labelledby="trusted-devices-heading" className="settings-trusted-devices">
            <div className="settings-section-heading">
              <h3 id="trusted-devices-heading">Trusted devices</h3>
              <button
                type="button"
                className="ghost"
                disabled={trustedDevicesLoading || trustedDeviceAction !== null}
                onClick={() => void loadTrustedDevices()}
              >
                {trustedDevicesLoading ? 'Checking…' : 'Refresh'}
              </button>
            </div>
            {trustedDevicesError ? <p className="muted" role="alert">{trustedDevicesError}</p> : null}
            {!trustedDevicesLoading && !trustedDevicesError && trustedDevices.length === 0 ? (
              <p className="muted">No trusted companion devices are registered.</p>
            ) : null}
            {trustedDevices.map((device) => {
              const pending = device.trustState === 'pending';
              const rowAction = `${pending ? 'approve' : 'revoke'}:${device.deviceId}`;
              return (
                <SettingRow
                  key={device.deviceId}
                  iconGlyph={device.isCurrentDevice ? '⌂' : '⛨'}
                  label={device.displayName}
                  description={`${device.platform} · ${device.trustState}${device.safetyFingerprint ? ` · ${device.safetyFingerprint}` : ''}`}
                  control={
                    <span className="actions">
                      {device.safetyFingerprint ? <CopyPathButton path={device.safetyFingerprint} label="Copy fingerprint" /> : null}
                      {!device.isCurrentDevice ? (
                        <button
                          type="button"
                          className={pending ? 'primary' : 'ghost'}
                          disabled={trustedDeviceAction !== null}
                          onClick={() => void runTrustedDeviceMutation(device, pending)}
                        >
                          {trustedDeviceAction === rowAction ? (pending ? 'Approving…' : 'Revoking…') : pending ? 'Approve' : 'Revoke'}
                        </button>
                      ) : null}
                    </span>
                  }
                />
              );
            })}
          </section>
        ) : (
          <p className="muted settings-tab-lede">
            Trusted-device approval and revoke remain unavailable because no authenticated companion-device bridge is connected.
            The pending/rejected state is shown fail-closed instead of presenting a fixture device.
          </p>
        )}
      </SettingGroup>
    </>
  );
}

type MediaSettingsProbe = {
  state: 'loading' | 'available' | 'degraded' | 'unavailable';
  detail: string;
  pairedDevices: number;
};

function mediaViewerDetail(status: NonNullable<MercuryMediaStatus['viewerCapability']>): string {
  const reason = (() => {
    switch (status.status) {
      case 'available':
        return 'Native Mercury viewer is ready.';
      case 'built_without_gstreamer':
        return 'This Linux build was compiled without the GStreamer viewer feature.';
      case 'gstreamer_backend_unavailable':
        return 'The GStreamer runtime is unavailable to the packaged shell.';
      case 'gstreamer_vp9_decoder_missing':
        return 'The GStreamer runtime is missing a VP9 decoder.';
      case 'gstreamer_video_sink_missing':
        return 'The GStreamer runtime is missing a native video sink.';
      case 'unknown':
        return status.reason ?? 'The packaged shell cannot verify a native Mercury viewer.';
    }
  })();
  return status.installHint ? `${reason} ${status.installHint}` : reason;
}

function mediaProbeFromStatus(status: MercuryMediaStatus): MediaSettingsProbe {
  const viewer = status.viewerCapability;
  if (!status.capabilityAvailable) {
    return {
      state: 'unavailable',
      detail: status.reason ?? 'Mercury transport capability is unavailable on this Linux peer.',
      pairedDevices: status.pairedDevices.length
    };
  }
  if (viewer && !viewer.available) {
    return {
      state: 'degraded',
      detail: mediaViewerDetail(viewer),
      pairedDevices: status.pairedDevices.length
    };
  }
  return {
    state: 'available',
    detail: viewer ? mediaViewerDetail(viewer) : 'Mercury daemon transport is available; viewer details were not reported.',
    pairedDevices: status.pairedDevices.length
  };
}

function MediaDetail() {
  const bridge = useShellStore((state) => state.bridge);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const probeRequestID = useRef(0);
  const [probe, setProbe] = useState<MediaSettingsProbe>({
    state: 'loading',
    detail: 'Checking Mercury media capability…',
    pairedDevices: 0
  });

  const runProbe = useCallback(() => {
    const requestID = ++probeRequestID.current;
    setProbe({
      state: 'loading',
      detail: 'Checking Mercury media capability…',
      pairedDevices: 0
    });
    if (fixtureMode) {
      setProbe({
        state: 'unavailable',
        detail: 'Fixture mode: media capability-absent (matches live Linux honesty).',
        pairedDevices: 0
      });
      return;
    }
    if (!bridge?.mediaStatus) {
      setProbe({
        state: 'unavailable',
        detail: 'Packaged shell did not expose the Mercury media status probe.',
        pairedDevices: 0
      });
      return;
    }
    void bridge.mediaStatus()
      .then((status) => {
        if (requestID === probeRequestID.current) setProbe(mediaProbeFromStatus(status));
      })
      .catch((reason: unknown) => {
        if (requestID === probeRequestID.current) {
          setProbe({
            state: 'unavailable',
            detail: reason instanceof Error ? reason.message : 'Mercury media status request failed.',
            pairedDevices: 0
          });
        }
      });
  }, [bridge, fixtureMode]);

  useEffect(() => {
    runProbe();
    return () => {
      // Invalidate an in-flight response when the bridge/session changes or
      // this detail pane unmounts. A stale probe must never replace a newer
      // capability result.
      probeRequestID.current += 1;
    };
  }, [runProbe]);

  const reload = runProbe;

  const label = probe.state === 'loading'
    ? 'Checking…'
    : probe.state === 'available'
      ? 'Available'
      : probe.state === 'degraded'
        ? 'Degraded'
        : 'Unavailable';
  const tone = probe.state === 'available' ? 'ok' : 'warn';

  return (
    <SettingGroup title="Media & Sharing" sectionHeader hideTitle>
      <p className="muted settings-tab-lede">
        Mercury media uses the daemon media transport and the native viewer capability. File transfer, screen share, and calls remain in the dedicated surface.
      </p>
      <SettingRow
        iconGlyph="▣"
        label="Media capability"
        description={`${probe.pairedDevices} paired device${probe.pairedDevices === 1 ? '' : 's'} reported by the daemon.`}
        control={
          <span className="settings-verification-value">
            <span className={`status-pill ${tone}`} role="status" aria-label={label}>{label}</span>
            <button type="button" className="ghost" onClick={reload} disabled={probe.state === 'loading'} aria-busy={probe.state === 'loading'}>
              {probe.state === 'loading' ? 'Checking…' : 'Recheck'}
            </button>
          </span>
        }
        readOnlyNote={probe.detail}
      />
      <SettingRow
        iconGlyph="↗"
        label="Media controls"
        description="Open Mercury to pair devices, accept calls, transfer files, or view a screen share."
        control={<a className="system-danger-link settings-drill-link" href="#/media">Open Media</a>}
      />
    </SettingGroup>
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
  onSelectTab,
  onOpenDatabase
}: {
  activeTab: SettingsTabId;
  config: ConfigSnapshot | null;
  fixtureMode: boolean;
  bridge: LinuxShellBridge | null;
  status: DaemonStatusCopy;
  loading: boolean;
  error: string | null;
  onRetryConfig: () => void;
  onRefreshConfig: () => void;
  refreshBusy: boolean;
  onDone: () => void;
  onSelectTab: (tab: SettingsTabId) => void;
  onOpenDatabase: () => void;
}) {
  const meta = settingsTabMeta(activeTab);
  const privacyMutation = useSettingsWiringStore((s) => s.privacyMutation);
  const updatePrivacySettings = useSettingsWiringStore((s) => s.updatePrivacySettings);

  const providerRegistryRows = useMemo(() => {
    // Browser/test env may lack process.env; fall back to logical-only display.
    const env =
      typeof process !== 'undefined'
        ? {
            XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME,
            XDG_DATA_HOME: process.env.XDG_DATA_HOME
          }
        : {};
    const home =
      typeof process !== 'undefined' && process.env.HOME
        ? process.env.HOME
        : '~';
    return LINUX_PROVIDER_PATH_REGISTRY.map((row) => ({
      ...row,
      resolvedHint:
        home === '~'
          ? undefined
          : resolveProviderLogicalPath(row.logicalPath, home, env)
    }));
  }, []);

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
      case 'ai-inbox':
        content = <AIInboxSettingsDetail bridge={bridge} fixtureMode={fixtureMode} />;
        break;
      case 'general':
        content = (
          <>
            <SettingGroup title="Appearance" sectionHeader hideTitle>
              <SettingsAppearanceControls />
            </SettingGroup>
            <SettingGroup title="Startup" sectionHeader hideTitle>
              <LaunchAtLoginControl />
            </SettingGroup>
            <SettingGroup title="Dashboard defaults" sectionHeader hideTitle>
              <DashboardDefaultsControls />
            </SettingGroup>
            <SettingGroup title="Data refresh" sectionHeader hideTitle>
              <ConfigRefreshRow onRefresh={onRefreshConfig} busy={refreshBusy} />
            </SettingGroup>
            <SettingGroup title="Search & summaries" sectionHeader hideTitle>
              <IndexingSummaryControl onOpenDatabase={onOpenDatabase} />
              <SettingRow
                iconGlyph="▤"
                label="Session summaries"
                description="Automatic transcript summaries require the macOS summary worker; Linux keeps this control read-only until a daemon contract exists."
                control={<span className="muted" role="status">Unavailable</span>}
                readOnlyNote="No Linux summary-generation setting or RPC is exposed; no summaries are generated from this pane."
              />
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
              description="Canonical state and logs live here (~/.local/share/openburnbar). Legacy ~/.config/OpenBurnBar: set OPENBURNBAR_DAEMON_SUPPORT_DIR or move the tree."
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
            <SettingRow
              iconGlyph="∑"
              label="Usage ingestion coverage"
              description="The catalog mirrors all canonical providers and labels local parser, API-backed, and unavailable sources separately."
              control={<span className="muted" role="status">{providerCoverageSummary()}</span>}
            />
            {/* VAL-PARSER-002: the catalog is the source of truth for display paths and coverage. */}
            {providerRegistryRows.map((row) => (
              <div key={row.providerId}>
                <SettingRow
                  iconGlyph="📄"
                  label={`${row.displayLabel} log path`}
                  description={`${providerCoverageLabel(row.coverage)} · ${row.coverageNote} · pattern ${row.filePattern}`}
                  control={<CopyPathButton path={row.logicalPath} label="Copy log path" />}
                />
                <p className="system-path-row">
                  <code>{row.logicalPath}</code>
                  {' '}
                  <span className={`provider-coverage provider-coverage--${row.coverage}`} data-provider-coverage={row.coverage}>
                    {providerCoverageLabel(row.coverage)}
                  </span>
                  {row.resolvedHint ? (
                    <>
                      {' '}
                      → <code>{row.resolvedHint}</code>
                    </>
                  ) : null}
                </p>
              </div>
            ))}
            {config.paths.providerLogPaths.length > 0 &&
            !config.paths.providerLogPaths.every((p) =>
              providerRegistryRows.some((r) => r.logicalPath === p)
            )
              ? config.paths.providerLogPaths
                  .filter((p) => !providerRegistryRows.some((r) => r.logicalPath === p))
                  .map((logPath) => (
                    <div key={`extra-${logPath}`}>
                      <SettingRow
                        iconGlyph="📄"
                        label="Daemon-reported log path"
                        description="Additional path from daemon config snapshot."
                        control={<CopyPathButton path={logPath} label="Copy log path" />}
                      />
                      <p className="system-path-row">
                        <code>{logPath}</code>
                      </p>
                    </div>
                  ))
              : null}
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
        content = <AgentsDetail config={config} fixtureMode={fixtureMode} />;
        break;
      case 'model-proxy':
        content = <AgentsDetail config={config} fixtureMode={fixtureMode} />;
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
          <>
            <CloudSyncControls config={config} bridge={bridge} />
            <SettingGroup title="OpenBurnBar Cloud" sectionHeader hideTitle>
              <SettingsDrillRow
                as="div"
                iconGlyph="✦"
                iconTint="var(--color-brass-bright)"
                title="Account and membership"
                subtitle="Identity, entitlements, and hosted services"
                trailing={
                  <a className="system-danger-link settings-drill-link" href="#/account">
                    Account
                  </a>
                }
              />
            </SettingGroup>
          </>
        );
        break;
      case 'alerts':
      case 'notifications':
        content = <NotificationsDetail mode={activeTab} />;
        break;
      case 'devices-and-sync':
        content = (
          <DevicesAndSyncDetail
            config={config}
            fixtureMode={fixtureMode}
            bridge={bridge as LinuxShellBridge | null}
            onSelectTab={onSelectTab}
          />
        );
        break;
      case 'media':
        content = <MediaDetail />;
        break;
      case 'computer-use':
        content = (
          <SettingGroup title="Computer Use" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              Browser automation remains approval-gated by the daemon. Open the dedicated surface for live session state,
              pending approvals, panic halt, and audit export.
            </p>
            <SettingRow
              iconGlyph="⌁"
              label="Computer Use control surface"
              description="No Linux system-mode controls are shown until the compositor and portal capability is verified."
              control={<a className="system-danger-link settings-drill-link" href="#/computer-use">Open Computer Use</a>}
            />
          </SettingGroup>
        );
        break;
      case 'pets':
        content = (
          <SettingGroup title="Pets" sectionHeader hideTitle>
            <p className="muted settings-tab-lede">
              The companion uses a contained draggable surface when compositor pass-through is unavailable. Open the
              dedicated route to inspect the current asset and capability tier.
            </p>
            <SettingRow
              iconGlyph="✧"
              label="Pet companion"
              description="Linux keeps the fallback visible and honest instead of claiming a click-through overlay."
              control={<a className="system-danger-link settings-drill-link" href="#/pet">Open Pets</a>}
            />
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
        {
          const privacyPending = privacyMutation.status === 'pending';
          const privacyStatus = privacyPending
            ? 'Saving…'
            : privacyMutation.status === 'success'
              ? 'Saved'
              : privacyMutation.status === 'error'
                ? 'Save failed'
                : 'Managed by daemon';
          const savePrivacy = (patch: PrivacySettingsPatch) => {
            void updatePrivacySettings(patch);
          };
        content = (
          <>
            {privacyMutation.status === 'pending' ? (
              <Banner tone="ok" role="status">
                {privacyMutation.message ?? 'Saving privacy choices…'}
              </Banner>
            ) : null}
            {privacyMutation.status === 'success' ? (
              <Banner tone="ok" role="status">
                {privacyMutation.message ?? 'Privacy choices saved.'}
              </Banner>
            ) : null}
            {privacyMutation.status === 'error' ? (
              <Banner tone="degraded" role="alert">
                {privacyMutation.message ?? 'Privacy choices could not be saved.'}
              </Banner>
            ) : null}
            <SettingGroup title="Consent flags" sectionHeader hideTitle>
              <SettingRow
                iconGlyph="📡"
                label="Telemetry"
                description="Opt-in only. When enabled, the daemon may emit anonymized stability events — never prompt content."
                control={
                  <PrivacyToggle
                    checked={config.telemetryEnabled}
                    label="Telemetry"
                    disabled={privacyPending}
                    onChange={(checked) => savePrivacy({ telemetryEnabled: checked })}
                    status={privacyStatus}
                  />
                }
              />
              <SettingRow
                iconGlyph="🛡"
                label="Privacy opt-in"
                description="Explicit consent before cloud-adjacent features sync metadata off this machine."
                control={
                  <PrivacyToggle
                    checked={config.privacyOptIn}
                    label="Privacy opt-in"
                    disabled={privacyPending}
                    onChange={(checked) => savePrivacy({ privacyOptIn: checked })}
                    status={privacyStatus}
                  />
                }
              />
              <SettingRow
                iconGlyph="☁"
                label="Cloud sync"
                description="Allow eligible metadata to leave this machine. Provider prompts and credentials remain local unless separately configured."
                control={
                  <PrivacyToggle
                    checked={Boolean(config.cloudSyncEnabled)}
                    label="Cloud sync"
                    disabled={privacyPending}
                    onChange={(checked) => savePrivacy({ cloudSyncEnabled: checked })}
                    status={privacyStatus}
                  />
                }
              />
            </SettingGroup>
            <SettingGroup title="Data lifecycle" sectionHeader hideTitle>
              <p className="muted settings-tab-lede">
                The controls below are intentionally capability-gated. Linux does not claim destructive or recovery workflows until the daemon exposes an audited RPC for each scope.
              </p>
              <AccountCloudDataExportControl fixtureMode={fixtureMode} />
              <PrivacyExportControl fixtureMode={fixtureMode} />
              <PrivacyDeletionControl fixtureMode={fixtureMode} />
              <ProxyRouteRetentionControl fixtureMode={fixtureMode} />
              <PrivacyRetentionControl fixtureMode={fixtureMode} />
              <AccountCloudDataDeletionControl fixtureMode={fixtureMode} />
              <RecoveryAndRestoreControl
                fixtureMode={fixtureMode}
                onOpenDatabase={onOpenDatabase}
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
        }
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
