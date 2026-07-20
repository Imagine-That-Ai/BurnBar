import { useEffect, useState } from 'react';
import { Banner } from '../../components/Banner.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  recoveryActionLabel,
  recoveryImportMessage,
  recoveryPhaseLabel,
  recoveryStatusMessage
} from '../database/recoveryCopy.js';
import { SettingRow } from './SettingRow.js';

const RECOVERY_IMPORT_CONFIRMATION = 'IMPORT RECOVERY BUNDLE';

/**
 * Bridges Settings to the canonical database recovery surface. The daemon
 * owns key custody and the crypto operation; this surface only collects
 * ephemeral paths/passphrases, requires an explicit import confirmation, and
 * renders redacted receipts. The Database route remains available for the
 * deeper inspector workflow.
 */
export function RecoveryAndRestoreControl({
  fixtureMode,
  onOpenDatabase
}: {
  fixtureMode: boolean;
  onOpenDatabase: () => void;
}) {
  const bridge = useShellStore((state) => state.bridge);
  const statusAction = useDatabaseStore((state) => state.recoveryStatusAction);
  const exportAction = useDatabaseStore((state) => state.recoveryExportAction);
  const importAction = useDatabaseStore((state) => state.recoveryImportAction);
  const loadRecoveryStatus = useDatabaseStore((state) => state.loadRecoveryStatus);
  const exportRecoveryBundle = useDatabaseStore((state) => state.exportRecoveryBundle);
  const importRecoveryBundle = useDatabaseStore((state) => state.importRecoveryBundle);
  const supported = !fixtureMode && typeof bridge?.databaseRecoveryBundleStatus === 'function';
  const recoveryStatus = statusAction.result;
  const exportAvailable = supported && typeof bridge?.databaseRecoveryBundleExport === 'function';
  const importAvailable = supported && typeof bridge?.databaseRecoveryBundleImport === 'function';
  const [exportPath, setExportPath] = useState('');
  const [exportPassphrase, setExportPassphrase] = useState('');
  const [importPath, setImportPath] = useState('');
  const [importPassphrase, setImportPassphrase] = useState('');
  const [importConfirmation, setImportConfirmation] = useState('');

  useEffect(() => {
    if (supported) void loadRecoveryStatus();
  }, [loadRecoveryStatus, supported]);

  const stateLabel = statusAction.pending
    ? 'Checking…'
    : recoveryStatus
      ? recoveryPhaseLabel(recoveryStatus.phase)
      : supported
        ? 'Unknown'
        : 'Open Database';

  const description = recoveryStatus
    ? recoveryStatusMessage(recoveryStatus)
    : supported
      ? 'The daemon has not returned a trusted recovery state yet.'
      : 'Recovery status is available from the Database workspace when the packaged daemon exposes SQLCipher custody.';

  const exportBusy = exportAction.pending;
  const importBusy = importAction.pending;
  const recoveryBusy = statusAction.pending || exportBusy || importBusy;
  const canExport = exportAvailable && recoveryStatus?.canExport === true;
  const canImport = importAvailable && recoveryStatus?.canImport === true;

  const exportBundle = async () => {
    await exportRecoveryBundle(exportPath, exportPassphrase);
    if (!useDatabaseStore.getState().recoveryExportAction.error) {
      setExportPath('');
      setExportPassphrase('');
    }
  };

  const importBundle = async () => {
    if (importConfirmation !== RECOVERY_IMPORT_CONFIRMATION) return;
    await importRecoveryBundle(importPath, importPassphrase);
    if (!useDatabaseStore.getState().recoveryImportAction.error) {
      setImportPath('');
      setImportPassphrase('');
      setImportConfirmation('');
    }
  };

  return (
    <>
      <SettingRow
        iconGlyph="↺"
        label="Recovery and restore"
        description={description}
        control={
          <span className="settings-verification-value">
            <span className="muted" role="status" aria-live="polite">
              {stateLabel}
            </span>
            <button
              type="button"
              className="ghost"
              onClick={onOpenDatabase}
              aria-label="Open Database recovery"
            >
              Open Database
            </button>
          </span>
        }
        readOnlyNote="Export and restore remain daemon-owned; this pane never accepts passphrases or writes recovery files."
      />
      {statusAction.error ? (
        <Banner tone="degraded" role="alert">
          {statusAction.error}
        </Banner>
      ) : null}
      {recoveryStatus ? (
        <p className="muted settings-tab-lede" role="status" aria-live="polite">
          {recoveryStatus.recommendedAction !== 'none'
            ? `Next action: ${recoveryActionLabel(recoveryStatus.recommendedAction)}.`
            : recoveryStatus.restartRequired
              ? 'Restart the daemon after the recovery step completes.'
              : 'No recovery action is required.'}
        </p>
      ) : null}
      {supported && (exportAvailable || importAvailable) ? (
        <div className="settings-recovery-controls" aria-label="Encrypted recovery bundle controls">
          <p className="muted settings-tab-lede">
            Keep an encrypted recovery bundle separate from this machine. The daemon performs PBKDF2/AES-GCM and
            native key-store writes; passphrases never enter renderer state or storage.
          </p>
          {exportAvailable ? (
            <div className="settings-recovery-action">
              <strong>Export recovery bundle</strong>
              <label className="setting-field">
                <span>Destination path</span>
                <input
                  type="text"
                  value={exportPath}
                  aria-label="Recovery bundle export destination"
                  autoComplete="off"
                  placeholder="/home/user/openburnbar-recovery.obb"
                  disabled={recoveryBusy}
                  onChange={(event) => setExportPath(event.currentTarget.value)}
                />
              </label>
              <label className="setting-field">
                <span>Passphrase</span>
                <input
                  type="password"
                  value={exportPassphrase}
                  aria-label="Recovery bundle export passphrase"
                  autoComplete="new-password"
                  disabled={recoveryBusy}
                  onChange={(event) => setExportPassphrase(event.currentTarget.value)}
                />
              </label>
              <button
                type="button"
                className="ghost"
                disabled={recoveryBusy || !canExport || exportPath.trim().length === 0 || exportPassphrase.length === 0}
                aria-busy={exportBusy}
                onClick={() => void exportBundle()}
              >
                {exportBusy ? 'Exporting…' : 'Export bundle'}
              </button>
              {exportAction.result ? (
                <p className="muted" role="status">
                  Recovery bundle exported successfully ({exportAction.result.byteCount.toLocaleString()} bytes).
                </p>
              ) : null}
              {exportAction.error ? <p className="muted" role="alert">{exportAction.error}</p> : null}
            </div>
          ) : null}
          {importAvailable ? (
            <div className="settings-recovery-action">
              <strong>Import recovery bundle</strong>
              <p className="muted">Import only a bundle you trust. The daemon verifies the candidate key and database integrity before adoption.</p>
              <label className="setting-field">
                <span>Source path</span>
                <input
                  type="text"
                  value={importPath}
                  aria-label="Recovery bundle import source"
                  autoComplete="off"
                  placeholder="/home/user/openburnbar-recovery.obb"
                  disabled={recoveryBusy}
                  onChange={(event) => setImportPath(event.currentTarget.value)}
                />
              </label>
              <label className="setting-field">
                <span>Passphrase</span>
                <input
                  type="password"
                  value={importPassphrase}
                  aria-label="Recovery bundle import passphrase"
                  autoComplete="current-password"
                  disabled={recoveryBusy}
                  onChange={(event) => setImportPassphrase(event.currentTarget.value)}
                />
              </label>
              <label className="setting-field">
                <span>Type {RECOVERY_IMPORT_CONFIRMATION} to continue</span>
                <input
                  type="text"
                  value={importConfirmation}
                  aria-label="Recovery bundle import confirmation"
                  autoComplete="off"
                  disabled={recoveryBusy}
                  onChange={(event) => setImportConfirmation(event.currentTarget.value)}
                />
              </label>
              <button
                type="button"
                className="danger"
                disabled={recoveryBusy || !canImport || importPath.trim().length === 0 || importPassphrase.length === 0 || importConfirmation !== RECOVERY_IMPORT_CONFIRMATION}
                aria-busy={importBusy}
                onClick={() => void importBundle()}
              >
                {importBusy ? 'Importing…' : 'Import bundle'}
              </button>
              {importAction.result ? (
                <p className="muted" role="status">{recoveryImportMessage(importAction.result)}</p>
              ) : null}
              {importAction.error ? <p className="muted" role="alert">{importAction.error}</p> : null}
            </div>
          ) : null}
        </div>
      ) : null}
    </>
  );
}
