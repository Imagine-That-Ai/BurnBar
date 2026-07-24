// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureConfigSnapshot } from '../../daemonFixture.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import type { ConfigSnapshot, LinuxCloudSyncStatus, LinuxShellBridge } from '../../tauriBridge.js';
import { CloudSyncControls } from './CloudSyncControls.js';

function config(overrides: Partial<ConfigSnapshot> = {}): ConfigSnapshot {
  return { ...fixtureConfigSnapshot(), ...overrides };
}

describe('CloudSyncControls', () => {
  beforeEach(() => {
    useSettingsWiringStore.setState({
      busy: null,
      privacyMutation: { status: 'idle', message: null },
      updatePrivacySettings: vi.fn(async () => {})
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('renders opt-in cloud consent with Linux scope and current values', () => {
    render(<CloudSyncControls config={config({ cloudSyncEnabled: true, privacyOptIn: false })} />);

    expect((screen.getByRole('checkbox', { name: 'Encrypted cloud sync' }) as HTMLInputElement).checked).toBe(true);
    expect((screen.getByRole('checkbox', { name: 'Metadata privacy opt-in' }) as HTMLInputElement).checked).toBe(false);
    expect(screen.getByText(/local SQLite canonical/i)).toBeTruthy();
    expect(screen.getByText(/Conversation backup, iCloud mirroring/i)).toBeTruthy();
  });

  it('writes only the daemon-owned consent field that changed', () => {
    const update = vi.fn(async () => {});
    useSettingsWiringStore.setState({ updatePrivacySettings: update });
    render(<CloudSyncControls config={config()} />);

    fireEvent.click(screen.getByRole('checkbox', { name: 'Encrypted cloud sync' }));
    fireEvent.click(screen.getByRole('checkbox', { name: 'Metadata privacy opt-in' }));

    expect(update).toHaveBeenNthCalledWith(1, { cloudSyncEnabled: true });
    expect(update).toHaveBeenNthCalledWith(2, { privacyOptIn: true });
  });

  it('disables both toggles and announces a failed readback', () => {
    useSettingsWiringStore.setState({
      busy: 'privacy.config.update',
      privacyMutation: { status: 'error', message: 'Daemon did not confirm cloudSyncEnabled after save.' }
    });
    render(<CloudSyncControls config={config()} />);

    expect((screen.getByRole('checkbox', { name: 'Encrypted cloud sync' }) as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByRole('checkbox', { name: 'Metadata privacy opt-in' }) as HTMLInputElement).disabled).toBe(true);
    expect(screen.getByRole('alert').textContent).toMatch(/did not confirm cloudSyncEnabled/i);
  });

  it('surfaces daemon sync posture and keeps text-expansion consent explicit', async () => {
    const status: LinuxCloudSyncStatus = {
      phase: 'ready',
      pendingMutationCount: 2,
      consecutiveFailures: 0,
      enabledDomains: [],
      remoteAccessEnabled: false,
      vaultKeyAvailable: true
    };
    const linuxCloudSyncStatus = vi.fn(async () => status);
    const linuxCloudSyncPolicyUpdate = vi.fn(async () => ({
      ...status,
      enabledDomains: ['text_expansion']
    }));
    const linuxCloudSyncRun = vi.fn(async () => ({
      pushedCount: 1,
      appliedRemoteCount: 1,
      retainedLocalConflictCount: 0,
      status: { ...status, pendingMutationCount: 0 }
    }));
    const bridge = {
      linuxCloudSyncStatus,
      linuxCloudSyncPolicyUpdate,
      linuxCloudSyncRun
    } as unknown as LinuxShellBridge;

    render(<CloudSyncControls config={config({ cloudSyncEnabled: true })} bridge={bridge} />);

    await waitFor(() => expect(screen.getByRole('checkbox', { name: 'Sync text-expansion snippets' })).toBeTruthy());
    const consent = screen.getByRole('checkbox', { name: 'Sync text-expansion snippets' }) as HTMLInputElement;
    expect(consent.checked).toBe(false);
    expect(screen.getByText(/2 pending changes/i)).toBeTruthy();

    fireEvent.click(consent);
    await waitFor(() => expect(linuxCloudSyncPolicyUpdate).toHaveBeenCalledWith({
      enabledDomains: ['text_expansion'],
      remoteAccessEnabled: false
    }));

    fireEvent.click(screen.getByRole('button', { name: 'Sync now' }));
    await waitFor(() => expect(linuxCloudSyncRun).toHaveBeenCalledWith(false));
  });
});
