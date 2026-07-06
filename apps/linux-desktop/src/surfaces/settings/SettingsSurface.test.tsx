// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fixtureConfigSnapshot } from '../../daemonFixture.js';
import { useShellStore } from '../../state/shellStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import { SettingsSurface } from './SettingsSurface.js';

function resetStores(): void {
  localStorage.clear();
  useShellStore.setState({
    bridge: null,
    fixtureMode: false,
    health: null,
    healthError: null,
    healthBusy: false,
    route: 'settings'
  });
  useSystemStore.setState({
    config: null,
    db: null,
    projects: null,
    memory: null,
    loading: false,
    error: null
  });
}

describe('SettingsSurface', () => {
  beforeEach(resetStores);
  afterEach(cleanup);

  it('keeps evidence-pinned failure-state ids from SystemStatusSection', () => {
    const { container } = render(<SettingsSurface />);
    expect(container.querySelector('[data-failure-state="secret-store"]')).not.toBeNull();
    expect(container.querySelector('[data-failure-state="permission-denied"]')).not.toBeNull();
  });

  it('renders home landing with hero and sidebar sections', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    expect(screen.getByText('OpenBurnBar Settings')).toBeTruthy();
    expect(screen.getByText('Agents & Models')).toBeTruthy();
    expect(screen.getByText('Look & Feel')).toBeTruthy();
    expect(screen.getByText('Account & Sync')).toBeTruthy();
  });
  it('renders populated fixture config with read-only toggles on Data & Privacy', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    expect(screen.getByText(/fixture transcript/i)).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: /Data & Privacy/i })[0]!);
    const toggles = screen.getAllByRole('checkbox');
    for (const input of toggles) {
      expect(input.getAttribute('aria-disabled')).toBe('true');
      expect((input as HTMLInputElement).disabled).toBe(true);
    }
  });

  it('shows loading skeleton without fixture', () => {
    vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useSystemStore.setState({ loading: true, config: null, error: null });
    const { container } = render(<SettingsSurface />);
    expect(container.querySelector('.settings-split--loading')).toBeTruthy();
  });

  it('shows offline notice on daemon detail without bridge', () => {
    vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useSystemStore.setState({ config: null, loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Engine Room/i }));
    expect(screen.getByText(/Settings need the local daemon/i)).toBeTruthy();
  });

  it('shows error with retry on detail pane', () => {
    const spy = vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as never, fixtureMode: false });
    useSystemStore.setState({ config: null, loading: false, error: 'Config RPC failed' });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Engine Room/i }));
    expect(screen.getByText('Config RPC failed')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(spy).toHaveBeenCalled();
  });

  it('announces Copied after copy path on daemon pane', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    vi.spyOn(useSystemStore.getState(), 'loadConfig').mockImplementation(async () => {});
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /Engine Room/i }));
    const copyBtn = screen.getAllByRole('button', { name: /^Copy path$/i })[0]!;
    fireEvent.click(copyBtn);
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(fixtureConfigSnapshot().paths.supportDir));
    await waitFor(() => expect(screen.getByText('Copied')).toBeTruthy());
  });

  it('Done returns to overview route', () => {
    useShellStore.setState({ fixtureMode: true, route: 'settings' });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: 'Done' }));
    expect(useShellStore.getState().route).toBe('overview');
  });

  it('General pane exposes appearance controls and onboarding wizard', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.click(screen.getByRole('button', { name: /^General/i }));
    expect(screen.getByRole('radiogroup', { name: 'Color scheme' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Refresh' })).toBeTruthy();
    expect(screen.getByText(/Step 1 of/i)).toBeTruthy();
  });

  it('sidebar search filters sections', () => {
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ config: fixtureConfigSnapshot(), loading: false, error: null });
    render(<SettingsSurface />);
    fireEvent.change(screen.getByLabelText('Search settings'), { target: { value: 'text expansion' } });
    expect(screen.queryByRole('button', { name: /^General$/i })).toBeNull();
    expect(screen.getAllByRole('button', { name: /Text Expansion/i }).length).toBeGreaterThanOrEqual(1);
  });
});