import type {
  DatabaseRecoveryAction,
  DatabaseRecoveryBundleExportResult,
  DatabaseRecoveryBundleImportResult,
  DatabaseRecoveryPhase,
  DatabaseRecoveryStatusResult
} from '../../tauriBridge.js';

const PHASE_LABELS: Record<DatabaseRecoveryPhase, string> = {
  ready: 'Ready',
  database_missing: 'Database missing',
  cipher_unavailable: 'Encryption unavailable',
  database_not_encrypted: 'Database is not encrypted',
  key_unavailable: 'Key unavailable',
  integrity_failed: 'Integrity check failed',
  awaiting_database_verification: 'Awaiting database verification',
  unavailable: 'Unavailable'
};

const ACTION_LABELS: Record<DatabaseRecoveryAction, string> = {
  none: 'No action required',
  export_recovery_bundle: 'Export a recovery bundle',
  import_recovery_bundle: 'Import a recovery bundle',
  restore_encrypted_snapshot: 'Restore an encrypted snapshot',
  unlock_secret_store: 'Unlock the native key store',
  restart_daemon: 'Restart the daemon'
};

/**
 * Keep daemon recovery messages out of the renderer. Native errors may contain
 * absolute paths, provider identifiers, or other local details that do not
 * belong in a visible support surface.
 */
export function recoveryPhaseLabel(phase: DatabaseRecoveryPhase): string {
  return PHASE_LABELS[phase];
}

export function recoveryActionLabel(action: DatabaseRecoveryAction): string {
  return ACTION_LABELS[action];
}

export function recoveryStatusMessage(status: DatabaseRecoveryStatusResult): string {
  switch (status.phase) {
    case 'ready':
      return 'The encrypted database is present and integrity-verified. Keep a recovery bundle in a separate secure location.';
    case 'database_missing':
      return 'No encrypted database is present. Restore an encrypted snapshot before claiming recovery succeeded.';
    case 'cipher_unavailable':
      return 'SQLCipher is unavailable, so the encrypted database cannot be opened or recovered on this installation.';
    case 'database_not_encrypted':
      return 'The database is not encrypted. Recovery is blocked until the daemon opens the canonical encrypted store.';
    case 'key_unavailable':
      return 'The database key is unavailable from native secret storage. Unlock the key store or import a recovery bundle.';
    case 'integrity_failed':
      return 'The database failed integrity verification. Do not continue; restore a known-good encrypted snapshot.';
    case 'awaiting_database_verification':
      return 'A recovery key is stored, but the encrypted database is not verified yet. Restore the database, then restart the daemon.';
    case 'unavailable':
    default:
      return 'The daemon did not provide a trusted recovery state. Retry after confirming the packaged daemon is running.';
  }
}

export function recoveryImportMessage(result: DatabaseRecoveryBundleImportResult): string {
  if (result.phase === 'ready' && result.candidateKeyVerified && result.databaseIntegrityVerified) {
    return result.restartRequired
      ? 'Recovery bundle imported and database integrity verified. Restart the daemon to adopt recovered key custody.'
      : 'Recovery bundle imported and database integrity verified.';
  }
  if (result.phase === 'awaiting_database_verification') {
    return 'The recovery key was stored, but no encrypted database was present to verify it. Restore an encrypted snapshot, then restart the daemon.';
  }
  if (result.phase === 'key_unavailable' || !result.candidateKeyVerified) {
    return 'The recovery key could not be verified. Unlock native secret storage or choose a known-good recovery bundle.';
  }
  if (result.phase === 'integrity_failed' || !result.databaseIntegrityVerified) {
    return 'The recovery key was accepted, but database integrity is not verified. Restore a known-good encrypted snapshot.';
  }
  return recoveryStatusMessage({
    phase: result.phase,
    code: 'recovery_import',
    message: '',
    recommendedAction: result.recommendedAction,
    canExport: false,
    canImport: true,
    databasePresent: result.databaseIntegrityVerified,
    databaseIntegrityVerified: result.databaseIntegrityVerified,
    restartRequired: result.restartRequired
  });
}

export function redactRecoveryStatus(status: DatabaseRecoveryStatusResult): DatabaseRecoveryStatusResult {
  return {
    ...status,
    message: recoveryStatusMessage(status)
  };
}

export function redactRecoveryExportResult(
  result: DatabaseRecoveryBundleExportResult
): DatabaseRecoveryBundleExportResult {
  return {
    ...result,
    destinationPath: ''
  };
}

export function redactRecoveryImportResult(
  result: DatabaseRecoveryBundleImportResult
): DatabaseRecoveryBundleImportResult {
  return {
    ...result,
    sourcePath: '',
    message: recoveryImportMessage(result)
  };
}

export const RECOVERY_STATUS_UNAVAILABLE =
  'Recovery status is unavailable. Confirm the packaged Linux daemon is running and try again.';
export const RECOVERY_EXPORT_UNAVAILABLE =
  'Encrypted recovery export requires the packaged Linux daemon and native secret storage.';
export const RECOVERY_IMPORT_UNAVAILABLE =
  'Encrypted recovery import requires the packaged Linux daemon and native secret storage.';
export const RECOVERY_PATH_REQUIRED = 'Choose a destination or source path before continuing.';
export const RECOVERY_PASSPHRASE_REQUIRED = 'Enter a passphrase before continuing.';
export const RECOVERY_OPERATION_FAILED =
  'The recovery operation failed without a trusted result. Refresh recovery status and retry.';
