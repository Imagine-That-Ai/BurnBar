// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureConfigSnapshot } from '../../daemonFixture.js';
import { useSettingsWiringStore } from '../../state/settingsWiringStore.js';
import type { ConfigSnapshot } from '../../tauriBridge.js';
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
});
