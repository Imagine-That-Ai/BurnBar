// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useIntegrationsStore } from '../../state/integrationsStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { SettingsSurface } from './SettingsSurface.js';
import { IntegrationsSection } from './IntegrationsSection.js';

function resetStores(): void {
  localStorage.clear();
  useShellStore.setState({
    bridge: null,
    bridgeReady: false,
    fixtureMode: false,
    health: null,
    healthError: null,
    healthBusy: false,
    route: 'settings'
  });
  useIntegrationsStore.setState({
    status: null,
    loading: false,
    error: null
  });
}

describe('IntegrationsSection', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('renders the fixture matrix for all five canonical kinds across all four states', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<IntegrationsSection />);

    await waitFor(() => expect(screen.getAllByRole('status')).toHaveLength(20));
    for (const name of ['SmartHub Bridge', 'Google Cast', 'Home Assistant', 'PixelClock', 'AWTRIX HTTP']) {
      expect(screen.getByRole('heading', { name })).toBeTruthy();
    }
    expect(screen.getAllByText('Connected')).toHaveLength(5);
    expect(screen.getAllByText('Configured')).toHaveLength(5);
    expect(screen.getAllByText('Unavailable')).toHaveLength(5);
    expect(screen.getAllByText('Disabled')).toHaveLength(5);
    expect(screen.getAllByText('Capability absent')).toHaveLength(5);
    expect(screen.getByRole('link', { name: /Read smart-display device QA notes for Google Cast configured/i })).toBeTruthy();
  });

  it('shows loading while the packaged bridge is still reading CLI parity', () => {
    useShellStore.setState({
      bridge: { integrationsStatus: vi.fn(() => new Promise(() => {})) } as never,
      bridgeReady: true
    });
    render(<IntegrationsSection />);
    expect(screen.getByText(/Loading smart-display integration status/i)).toBeTruthy();
  });

  it('shows empty state when the daemon reports no configured integrations', async () => {
    useShellStore.setState({
      bridge: { integrationsStatus: vi.fn().mockResolvedValue({ integrations: [] }) } as never,
      bridgeReady: true
    });
    render(<IntegrationsSection />);
    await waitFor(() => expect(screen.getByText('No integrations configured.')).toBeTruthy());
  });

  it('shows offline/capability state without a packaged bridge', async () => {
    render(<IntegrationsSection />);
    await waitFor(() => expect(screen.getByText('Integration status unavailable')).toBeTruthy());
    expect(screen.getByText(/Packaged shell or openburnbar-cli/i)).toBeTruthy();
  });

  it('shows CLI parse or execution errors without rendering controls', async () => {
    useShellStore.setState({
      bridge: {
        integrationsStatus: vi.fn().mockRejectedValue(new Error('Invalid devices parity JSON'))
      } as never,
      bridgeReady: true
    });
    render(<IntegrationsSection />);
    await waitFor(() => expect(screen.getByText('Invalid devices parity JSON')).toBeTruthy());
    expect(screen.queryByRole('textbox')).toBeNull();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('is mounted inside SettingsSurface', async () => {
    useShellStore.setState({ fixtureMode: true });
    render(<SettingsSurface />);
    await waitFor(() => expect(screen.getByRole('region', { name: 'Smart display integrations' })).toBeTruthy());
  });
});
