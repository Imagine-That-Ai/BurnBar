// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PetSurface } from './PetSurface.js';
import { useShellStore } from '../state/shellStore.js';
import { makeAvailableRuntimeCapabilityManifest } from '../testing/bridgeStubs.js';

const mountMock = vi.fn();
const stopMock = vi.fn();

vi.mock('../petGltfRuntime.js', () => ({
  mountPetGltfRuntime: (...args: unknown[]) => mountMock(...args),
  stopPetGltfRuntime: () => stopMock()
}));

function stubMatchMedia(matches = false): void {
  Object.defineProperty(window, 'matchMedia', {
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  });
}

function resetShell(): void {
  localStorage.clear();
  useShellStore.setState({
    bridge: null,
    fixtureMode: false,
    health: null,
    route: 'pet',
    skin: 'editorial',
    runtimeCapabilities: null,
    bridgeReady: true
  });
}

describe('PetSurface', () => {
  beforeEach(() => {
    stubMatchMedia(false);
    resetShell();
    mountMock.mockReset();
    stopMock.mockReset();
    mountMock.mockResolvedValue({
      asset: { version: '2.0' },
      nodes: [],
      animations: ['idle'],
      points: [{ x: 0, y: 0, z: 0 }]
    });
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it('fails closed to a contained preview when the runtime probe is absent', async () => {
    render(<PetSurface />);
    await waitFor(() => {
      expect(screen.getByText(/preview only/i)).toBeTruthy();
    });
    const stage = screen.getByRole('img', {
      name: /pet companion contained preview/i
    });
    expect(stage.getAttribute('data-overlay-tier')).toBe('draggable-contained');
    expect(stage.getAttribute('data-input-passthrough')).toBe('false');
    expect(stage.hasAttribute('draggable')).toBe(true);
    expect(screen.getByText(/No canonical Linux summon/i)).toBeTruthy();
  });

  it('keeps a contained fallback when the native companion window is not wired', async () => {
    const runtimeCapabilities = makeAvailableRuntimeCapabilityManifest();
    useShellStore.setState({
      runtimeCapabilities,
      bridgeReady: true
    });
    render(<PetSurface />);
    await waitFor(() => {
      expect(screen.queryByText(/preview only/i)).toBeNull();
    });
    const stage = screen.getByRole('img', {
      name: /pet companion contained preview/i
    });
    expect(stage.getAttribute('data-overlay-tier')).toBe('draggable-contained');
    expect(stage.getAttribute('data-input-passthrough')).toBe('false');
    expect(screen.getByText(/companion-window contract is not wired/i)).toBeTruthy();
  });
  it('renders behavior graph SVG nodes for the active tier', async () => {
    render(<PetSurface />);
    await waitFor(() => {
      expect(screen.getByText('Idle bob')).toBeTruthy();
      expect(screen.getByText('React wave')).toBeTruthy();
      expect(screen.getByText('GNOME: no click-through')).toBeTruthy();
    });
    expect(document.querySelector('.pet-behavior-svg')).toBeTruthy();
    expect(document.querySelector('.pet-graph')).toBeNull();
  });

  it('toggles raw graph disclosure', async () => {
    render(<PetSurface />);
    const toggle = await screen.findByRole('button', {
      name: /show raw graph/i
    });
    fireEvent.click(toggle);
    const raw = document.querySelector('pre.pet-graph');
    expect(raw).toBeTruthy();
    expect(raw?.textContent).toContain('idle-bob');
    fireEvent.click(screen.getByRole('button', { name: /hide raw graph/i }));
    expect(document.querySelector('pre.pet-graph')).toBeNull();
  });

  it('wave button triggers react-wave highlight on stage', () => {
    vi.useFakeTimers();
    render(<PetSurface />);
    const stage = screen.getByRole('img', {
      name: /pet companion contained preview/i
    });
    fireEvent.click(screen.getByRole('button', { name: /wave at preview/i }));
    expect(stage.className).toContain('pet-stage--react-wave');
    act(() => {
      vi.advanceTimersByTime(2500);
    });
    expect(stage.className).not.toContain('pet-stage--react-wave');
  });

  it('shows role=alert when runtime mount fails', async () => {
    mountMock.mockRejectedValueOnce(new Error('asset fetch failed'));
    render(<PetSurface />);
    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toContain('asset fetch failed');
    const stage = screen.getByRole('img', {
      name: /pet companion contained preview/i
    });
    expect(stage.getAttribute('data-pet-runtime')).toBe('error');
  });

  it('sets data-pet-runtime loaded after successful mount', async () => {
    render(<PetSurface />);
    const stage = await screen.findByRole('img', {
      name: /pet companion contained preview/i
    });
    await waitFor(() => {
      expect(stage.getAttribute('data-pet-runtime')).toBe('loaded');
    });
  });

  it('renders tier matrix table rows', async () => {
    render(<PetSurface />);
    expect(await screen.findByText(/pet tier matrix/i)).toBeTruthy();
    expect(screen.getByText('GNOME Wayland')).toBeTruthy();
    expect(screen.getByText('KDE Wayland')).toBeTruthy();
  });
});
