// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { DatabaseRecoveryStatusResult, LinuxShellBridge } from '../../tauriBridge.js';
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
});
