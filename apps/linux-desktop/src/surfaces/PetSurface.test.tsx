// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PetSurface } from './PetSurface.js';
import { useShellStore } from '../state/shellStore.js';
import { makeAvailableRuntimeCapabilityManifest } from '../testing/bridgeStubs.js';

const mountMock = vi.fn();
const stopMock = vi.fn();
const openCompanionMock = vi.fn();
const clickThroughMock = vi.fn();

vi.mock('../petGltfRuntime.js', () => ({
  mountPetGltfRuntime: (...args: unknown[]) => mountMock(...args),
  stopPetGltfRuntime: () => stopMock()
}));

vi.mock('../petCompanionWindow.js', () => ({
  openPetCompanionWindow: (...args: unknown[]) => openCompanionMock(...args),
  setPetCompanionClickThrough: (...args: unknown[]) => clickThroughMock(...args)
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
    openCompanionMock.mockReset();
    clickThroughMock.mockReset();
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

  it('offers keyboard repositioning for the contained Wayland-safe fallback', async () => {
    render(<PetSurface />);
    const stage = await screen.findByRole('img', {
      name: /pet companion contained preview/i
    });

    expect(stage.getAttribute('tabindex')).toBe('0');
    expect(stage.getAttribute('aria-describedby')).toBe('pet-contained-move-help');
    expect(stage.getAttribute('data-contained-offset')).toBe('0,0');

    fireEvent.keyDown(stage, { key: 'ArrowRight' });
    expect(stage.getAttribute('data-contained-offset')).toBe('16,0');
    expect(document.querySelector('.pet-action-status')?.textContent).toMatch(/keyboard/i);

    fireEvent.keyDown(stage, { key: 'ArrowDown', shiftKey: true });
    expect(stage.getAttribute('data-contained-offset')).toBe('16,48');

    fireEvent.keyDown(stage, { key: 'Home' });
    expect(stage.getAttribute('data-contained-offset')).toBe('0,0');
  });

  it('moves the contained preview with bounded pointer drag without enabling desktop input', async () => {
    render(<PetSurface />);
    const stage = await screen.findByRole('img', {
      name: /pet companion contained preview/i
    });

    fireEvent.mouseDown(stage, { button: 0, clientX: 10, clientY: 20 });
    fireEvent.mouseMove(stage, { clientX: 200, clientY: 160 });
    fireEvent.mouseUp(stage, { clientX: 200, clientY: 160 });

    expect(stage.getAttribute('data-contained-offset')).toBe('96,64');
    expect(stage.getAttribute('data-input-passthrough')).toBe('false');
    expect(document.querySelector('.pet-action-status')?.textContent).toMatch(/pointer drag/i);
  });

  it('summons and focuses the native companion only for an available X11 contract', async () => {
    const runtimeCapabilities = makeAvailableRuntimeCapabilityManifest();
    const status = {
      state: 'available' as const,
      compositor: 'GNOME/x11',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'tauri-x11-companion-v1',
      reason: 'ready',
      source: 'test'
    };
    openCompanionMock.mockResolvedValue({ status, opened: true, clickThrough: false });
    useShellStore.setState({
      runtimeCapabilities,
      bridge: { petCompanionStatus: vi.fn().mockResolvedValue(status) } as never,
      bridgeReady: true
    });
    render(<PetSurface />);

    const open = await screen.findByRole('button', { name: /open native companion/i });
    fireEvent.click(open);
    await waitFor(() => expect(openCompanionMock).toHaveBeenCalledTimes(1));
    expect(screen.getByText(/opened and focused/i)).toBeTruthy();
    expect(screen.getByRole('button', { name: /enable click-through/i })).toBeTruthy();
  });

  it('switches to the contained fallback when an X11 summon fails at runtime', async () => {
    const runtimeCapabilities = makeAvailableRuntimeCapabilityManifest();
    const availableStatus = {
      state: 'available' as const,
      compositor: 'GNOME/x11',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'tauri-x11-companion-v1',
      reason: 'ready',
      source: 'test'
    };
    const degradedStatus = {
      ...availableStatus,
      state: 'degraded' as const,
      overlaySupported: false,
      clickThroughSupported: false,
      windowContract: 'none',
      reason: 'The window manager rejected the companion child.',
      source: 'tauri-x11-companion-fallback'
    };
    openCompanionMock.mockResolvedValue({ status: degradedStatus, opened: false, clickThrough: false });
    useShellStore.setState({
      runtimeCapabilities,
      bridge: { petCompanionStatus: vi.fn().mockResolvedValue(availableStatus) } as never,
      bridgeReady: true
    });
    render(<PetSurface />);

    fireEvent.click(await screen.findByRole('button', { name: /open native companion/i }));
    const stage = await screen.findByRole('img', {
      name: /pet companion contained preview/i
    });
    await waitFor(() => expect(stage.getAttribute('data-contained-fallback')).toBe('true'));
    expect(stage.getAttribute('tabindex')).toBe('0');
    expect(screen.getByRole('button', { name: /summon contained preview/i })).toBeTruthy();
    expect(screen.getByText(/window manager rejected/i)).toBeTruthy();
  });

  it('requires an explicit click-through action and restores focus when disabled', async () => {
    const runtimeCapabilities = makeAvailableRuntimeCapabilityManifest();
    const status = {
      state: 'available' as const,
      compositor: 'KDE/x11',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'tauri-x11-companion-v1',
      reason: 'ready',
      source: 'test'
    };
    openCompanionMock.mockResolvedValue({ status, opened: true, clickThrough: false });
    clickThroughMock
      .mockResolvedValueOnce({ status, opened: true, clickThrough: true })
      .mockResolvedValueOnce({ status, opened: true, clickThrough: false });
    useShellStore.setState({
      runtimeCapabilities,
      bridge: { petCompanionStatus: vi.fn().mockResolvedValue(status) } as never,
      bridgeReady: true
    });
    render(<PetSurface />);
    fireEvent.click(await screen.findByRole('button', { name: /open native companion/i }));
    const enable = await screen.findByRole('button', { name: /enable click-through/i });
    fireEvent.click(enable);
    await waitFor(() => expect(clickThroughMock).toHaveBeenCalledWith(true));
    expect(screen.getByRole('img', { name: /pet companion contained preview/i }).getAttribute('data-input-passthrough'))
      .toBe('true');
    fireEvent.click(screen.getByRole('button', { name: /restore companion interaction/i }));
    await waitFor(() => expect(clickThroughMock).toHaveBeenLastCalledWith(false));
    expect(screen.getByRole('img', { name: /pet companion contained preview/i }).getAttribute('data-input-passthrough'))
      .toBe('false');
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

  it('summons the contained preview without claiming a native overlay', async () => {
    render(<PetSurface />);
    const stage = await screen.findByRole('img', {
      name: /pet companion contained preview/i
    });
    const scrollIntoView = vi.fn();
    Object.defineProperty(stage, 'scrollIntoView', {
      configurable: true,
      value: scrollIntoView
    });

    fireEvent.click(screen.getByRole('button', { name: /summon contained preview/i }));

    expect(scrollIntoView).toHaveBeenCalledWith({
      block: 'center',
      behavior: 'smooth'
    });
    expect(stage.getAttribute('data-pet-summoned')).toBe('true');
    expect(stage.getAttribute('data-overlay-tier')).toBe('draggable-contained');
    const status = document.querySelector('.pet-action-status');
    expect(status?.textContent).toMatch(/native overlay behavior remains unavailable/i);
  });

  it('selects and clears the contained pet in-app', async () => {
    render(<PetSurface />);
    const stage = await screen.findByRole('img', {
      name: /pet companion contained preview/i
    });
    const select = screen.getByRole('button', {
      name: /select contained pet/i
    });

    fireEvent.click(select);
    expect(select.getAttribute('aria-pressed')).toBe('true');
    expect(stage.getAttribute('data-pet-selected')).toBe('true');
    expect(document.querySelector('.pet-action-status')?.textContent).toMatch(
      /native desktop selection remains unavailable/i
    );

    fireEvent.click(screen.getByRole('button', { name: /pet selected/i }));
    expect(screen.getByRole('button', { name: /select contained pet/i }).getAttribute('aria-pressed')).toBe('false');
    expect(stage.getAttribute('data-pet-selected')).toBe('false');
    expect(document.querySelector('.pet-action-status')?.textContent).toMatch(/selection cleared/i);
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

  it('stops the GLB runtime on unmount', () => {
    const view = render(<PetSurface />);
    view.unmount();
    expect(stopMock).toHaveBeenCalledTimes(1);
  });

  it('renders tier matrix table rows', async () => {
    render(<PetSurface />);
    expect(await screen.findByText(/pet tier matrix/i)).toBeTruthy();
    expect(screen.getByText('GNOME Wayland')).toBeTruthy();
    expect(screen.getByText('KDE Wayland')).toBeTruthy();
  });
});
