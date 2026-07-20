// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  DatabaseRecoveryBundleExportResult,
  DatabaseRecoveryBundleImportResult,
  DatabaseRecoveryStatusResult,
  LinuxShellBridge
} from '../../tauriBridge.js';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { RecoveryAndRestoreControl } from './RecoveryAndRestoreControl.js';

const readyStatus: DatabaseRecoveryStatusResult = {
  phase: 'ready',
  code: 'ready',
  message: 'native detail must not leak',
  recommendedAction: 'none',
  canExport: true,
  canImport: true,
  databasePresent: true,
  databaseIntegrityVerified: true,
  restartRequired: false
};

const exportedBundle: DatabaseRecoveryBundleExportResult = {
  destinationPath: '',
  byteCount: 128,
  formatVersion: 1
};

const importedBundle: DatabaseRecoveryBundleImportResult = {
  sourcePath: '',
  stored: true,
  candidateKeyVerified: true,
  databaseIntegrityVerified: true,
  phase: 'ready',
  recommendedAction: 'none',
  message: '',
  restartRequired: false
};

function resetState(): void {
  useShellStore.setState({ bridge: null, fixtureMode: false });
  useDatabaseStore.setState({
    recoveryStatusAction: { pending: false, error: null, result: null },
    recoveryExportAction: { pending: false, error: null, result: null },
    recoveryImportAction: { pending: false, error: null, result: null }
  });
}

describe('RecoveryAndRestoreControl', () => {
  beforeEach(resetState);
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('loads redacted recovery posture and hands off to the canonical Database surface', async () => {
    const databaseRecoveryBundleStatus = vi.fn(async () => readyStatus);
    const onOpenDatabase = vi.fn();
    useShellStore.setState({
      bridge: { ...bridgeStubDefaults, databaseRecoveryBundleStatus } as unknown as LinuxShellBridge,
      fixtureMode: false
    });

    render(<RecoveryAndRestoreControl fixtureMode={false} onOpenDatabase={onOpenDatabase} />);

    expect(await screen.findByText('Ready')).toBeTruthy();
    expect(databaseRecoveryBundleStatus).toHaveBeenCalledOnce();
    expect(screen.getByText(/integrity-verified/i)).toBeTruthy();
    expect(screen.queryByText('native detail must not leak')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Open Database recovery' }));
    expect(onOpenDatabase).toHaveBeenCalledOnce();
  });

  it('keeps the handoff available while clearly reporting packaged-shell absence', async () => {
    const onOpenDatabase = vi.fn();
    render(<RecoveryAndRestoreControl fixtureMode={false} onOpenDatabase={onOpenDatabase} />);

    expect(screen.getByRole('button', { name: 'Open Database recovery' })).toBeTruthy();
    expect(screen.getByText(/packaged daemon exposes SQLCipher custody/i)).toBeTruthy();
    await waitFor(() => expect(screen.queryByText('Ready')).toBeNull());

    fireEvent.click(screen.getByRole('button', { name: 'Open Database recovery' }));
    expect(onOpenDatabase).toHaveBeenCalledOnce();
  });

  it('exports an encrypted recovery bundle from Data & Privacy and clears the passphrase', async () => {
    const databaseRecoveryBundleStatus = vi.fn(async () => readyStatus);
    const databaseRecoveryBundleExport = vi.fn(async () => exportedBundle);
    useShellStore.setState({
      bridge: {
        ...bridgeStubDefaults,
        databaseRecoveryBundleStatus,
        databaseRecoveryBundleExport
      } as unknown as LinuxShellBridge,
      fixtureMode: false
    });

    render(<RecoveryAndRestoreControl fixtureMode={false} onOpenDatabase={vi.fn()} />);

    await waitFor(() => expect(screen.getByText('Ready')).toBeTruthy());
    const destination = screen.getByRole('textbox', { name: 'Recovery bundle export destination' });
    const passphrase = screen.getByLabelText('Recovery bundle export passphrase');
    fireEvent.change(destination, { target: { value: '/tmp/recovery.obb' } });
    fireEvent.change(passphrase, { target: { value: 'correct horse battery' } });
    fireEvent.click(screen.getByRole('button', { name: 'Export bundle' }));

    await waitFor(() => expect(databaseRecoveryBundleExport).toHaveBeenCalledWith({
      destinationPath: '/tmp/recovery.obb',
      passphrase: 'correct horse battery'
    }));
    expect(await screen.findByText(/Recovery bundle exported successfully \(128 bytes\)/i)).toBeTruthy();
    expect((passphrase as HTMLInputElement).value).toBe('');
    expect(screen.queryByText('/tmp/recovery.obb')).toBeNull();
  });

  it('requires an exact confirmation before importing a recovery bundle', async () => {
    const databaseRecoveryBundleStatus = vi.fn(async () => readyStatus);
    const databaseRecoveryBundleImport = vi.fn(async () => importedBundle);
    useShellStore.setState({
      bridge: {
        ...bridgeStubDefaults,
        databaseRecoveryBundleStatus,
        databaseRecoveryBundleImport
      } as unknown as LinuxShellBridge,
      fixtureMode: false
    });

    render(<RecoveryAndRestoreControl fixtureMode={false} onOpenDatabase={vi.fn()} />);

    await waitFor(() => expect(screen.getByText('Ready')).toBeTruthy());
    const source = screen.getByRole('textbox', { name: 'Recovery bundle import source' });
    const passphrase = screen.getByLabelText('Recovery bundle import passphrase');
    const confirmation = screen.getByRole('textbox', { name: 'Recovery bundle import confirmation' });
    fireEvent.change(source, { target: { value: '/tmp/recovery.obb' } });
    fireEvent.change(passphrase, { target: { value: 'correct horse battery' } });
    const importButton = screen.getByRole('button', { name: 'Import bundle' }) as HTMLButtonElement;
    expect(importButton.disabled).toBe(true);
    fireEvent.change(confirmation, { target: { value: 'IMPORT RECOVERY BUNDLE' } });
    expect(importButton.disabled).toBe(false);
    fireEvent.click(importButton);

    await waitFor(() => expect(databaseRecoveryBundleImport).toHaveBeenCalledWith({
      sourcePath: '/tmp/recovery.obb',
      passphrase: 'correct horse battery'
    }));
    expect(await screen.findByText(/Recovery bundle imported and database integrity verified/i)).toBeTruthy();
    expect((passphrase as HTMLInputElement).value).toBe('');
    expect((confirmation as HTMLInputElement).value).toBe('');
  });
});
