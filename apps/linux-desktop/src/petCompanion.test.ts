import { describe, expect, it } from 'vitest';
import { makeAvailableRuntimeCapabilityManifest } from './testing/bridgeStubs.js';
import { detectPetTierFromEnv, petNativeContractFromStatus, probePetCapability } from './petCompanion.js';

describe('probePetCapability', () => {
  it('fails closed when the packaged manifest is unavailable', () => {
    const probe = probePetCapability(null);
    expect(probe.state).toBe('unavailable');
    expect(probe.previewOnly).toBe(true);
    expect(probe.tier).toBe('draggable-contained');
    expect(probe.actions.overlay.supported).toBe(false);
    expect(probe.actions['click-through'].supported).toBe(false);
    expect(probe.actions.summon.reason).toContain('No canonical Linux summon');
    expect(probe.containedActions.summon.supported).toBe(true);
    expect(probe.containedActions.selection.supported).toBe(true);
    expect(probe.containedActions.summon.reason).toContain('contained pet preview');
  });

  it('does not turn an X11 manifest into a UI claim without a native window contract', () => {
    const manifest = makeAvailableRuntimeCapabilityManifest();
    const probe = probePetCapability(manifest);
    expect(probe.state).toBe('degraded');
    expect(probe.tier).toBe('draggable-contained');
    expect(probe.actions.overlay.supported).toBe(false);
    expect(probe.actions['click-through'].supported).toBe(false);
    expect(probe.message).toContain('companion-window contract is not wired');
    expect(probe.actions.selection.supported).toBe(false);
    expect(probe.containedActions.selection.supported).toBe(true);
    expect(probe.compositor).toBe('test/x11');
  });

  it('supports overlay actions only when an explicit native contract is supplied', () => {
    const probe = probePetCapability(makeAvailableRuntimeCapabilityManifest(), {
      overlay: true,
      'click-through': true
    });
    expect(probe.state).toBe('available');
    expect(probe.tier).toBe('overlay-pass-through');
    expect(probe.actions.overlay.supported).toBe(true);
    expect(probe.actions['click-through'].supported).toBe(true);
    expect(probe.actions.summon.supported).toBe(true);
    expect(probe.actions.summon.reason).toContain('Ctrl+Alt+Super+P');
  });

  it('uses the contained fallback for a degraded Wayland capability', () => {
    const manifest = makeAvailableRuntimeCapabilityManifest();
    const entry = manifest.capabilities.find((item) => item.id === 'pet.overlay');
    if (!entry) throw new Error('pet.overlay missing from fixture manifest');
    manifest.sessionType = 'wayland';
    manifest.desktop = 'GNOME';
    entry.state = 'degraded';
    entry.reason = 'The current compositor does not expose a safe click-through overlay contract.';
    entry.substitute = 'Use the contained draggable companion window.';
    const probe = probePetCapability(manifest);
    expect(probe.state).toBe('degraded');
    expect(probe.tier).toBe('draggable-contained');
    expect(probe.actions.overlay.supported).toBe(false);
    expect(probe.actions['click-through'].supported).toBe(false);
    expect(probe.actions.summon.supported).toBe(false);
    expect(probe.substitute).toContain('contained draggable');
    expect(probe.compositor).toBe('GNOME/wayland');
  });
});

describe('detectPetTierFromEnv', () => {
  it('does not treat Wayland environment hints as overlay proof', () => {
    const tier = detectPetTierFromEnv({
      XDG_CURRENT_DESKTOP: 'KDE',
      XDG_SESSION_TYPE: 'wayland'
    });
    expect(tier.tier).toBe('draggable-contained');
    expect(tier.message).toContain('cannot prove');
  });

  it('keeps X11 as an evidence-only overlay hint', () => {
    const tier = detectPetTierFromEnv({
      XDG_CURRENT_DESKTOP: 'XFCE',
      XDG_SESSION_TYPE: 'x11'
    });
    expect(tier.tier).toBe('overlay-pass-through');
    expect(tier.message).toContain('not proof');
  });
});

describe('petNativeContractFromStatus', () => {
  it('only enables overlay actions for an explicitly available native X11 contract', () => {
    expect(petNativeContractFromStatus({
      state: 'available',
      compositor: 'GNOME/x11',
      sessionType: 'x11',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'tauri-x11-companion-v1',
      reason: 'ready',
      source: 'tauri-x11-companion-window'
    })).toEqual({ overlay: true, 'click-through': true });
  });

  it('keeps degraded Wayland and missing statuses fail-closed', () => {
    expect(petNativeContractFromStatus({
      state: 'degraded',
      compositor: 'GNOME/wayland',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'unexpected',
      reason: 'Wayland fallback',
      source: 'test'
    })).toEqual({ overlay: false, 'click-through': false });
    expect(petNativeContractFromStatus(null)).toEqual({ overlay: false, 'click-through': false });
  });

  it('rejects an optimistic available status without the canonical X11 contract', () => {
    expect(petNativeContractFromStatus({
      state: 'available',
      compositor: 'GNOME/wayland',
      sessionType: 'wayland',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'tauri-x11-companion-v1',
      reason: 'forged',
      source: 'test'
    })).toEqual({ overlay: false, 'click-through': false });
    expect(petNativeContractFromStatus({
      state: 'available',
      compositor: 'GNOME/x11',
      sessionType: 'x11',
      overlaySupported: true,
      clickThroughSupported: true,
      windowContract: 'unexpected-contract',
      reason: 'stale',
      source: 'tauri-x11-companion-window'
    })).toEqual({ overlay: false, 'click-through': false });
  });
});
