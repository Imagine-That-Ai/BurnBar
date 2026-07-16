import { useEffect } from 'react';
import { Banner } from '../../components/Banner.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  recoveryActionLabel,
  recoveryPhaseLabel,
  recoveryStatusMessage
} from '../database/recoveryCopy.js';
import { SettingRow } from './SettingRow.js';

/**
 * Bridges Settings to the canonical database recovery surface. The database
 * lane owns export/import mutation; Settings only exposes the current,
 * redacted posture and a deterministic handoff into that workflow.
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
  const loadRecoveryStatus = useDatabaseStore((state) => state.loadRecoveryStatus);
  const supported = !fixtureMode && typeof bridge?.databaseRecoveryBundleStatus === 'function';
  const recoveryStatus = statusAction.result;

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
    </>
  );
}
