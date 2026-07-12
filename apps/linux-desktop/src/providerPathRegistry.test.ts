import { describe, expect, it } from 'vitest';
import {
  LINUX_PROVIDER_PATH_REGISTRY,
  providerDisplayPaths,
  providerPathById,
  resolveProviderLogicalPath
} from './providerPathRegistry.js';

describe('providerPathRegistry', () => {
  it('covers all canonical providers and explicit no-local-log cases', () => {
    expect(LINUX_PROVIDER_PATH_REGISTRY).toHaveLength(33);
    expect(providerPathById('codex')?.linuxLogicalPath).toBe('~/.codex/sessions');
    expect(providerPathById('openai')?.linuxLogicalPath).toBeNull();
    expect(providerPathById('openai')?.unsupportedReasons.localLogs).toBeTruthy();
    expect(providerPathById('openclaude')?.parserSource).toBeNull();
    expect(providerPathById('openclaude')?.linuxLogicalPath).toBe('~/.openclaude/sessions');
  });

  it('resolves all path-bearing rows under custom XDG homes', () => {
    for (const row of LINUX_PROVIDER_PATH_REGISTRY) {
      if (row.linuxLogicalPath === null) continue;
      const resolved = resolveProviderLogicalPath(row.linuxLogicalPath, '/home/alice', {
        XDG_CONFIG_HOME: '/xdg/config', XDG_DATA_HOME: '/xdg/data'
      });
      if (row.xdgBehavior === 'xdg-config') expect(resolved.startsWith('/xdg/config')).toBe(true);
      if (row.xdgBehavior === 'xdg-data') expect(resolved.startsWith('/xdg/data')).toBe(true);
      if (row.xdgBehavior === 'home-relative') expect(resolved.startsWith('/home/alice')).toBe(true);
    }
  });

  it('honors explicit and Snap provider-home overrides without overriding XDG paths', () => {
    expect(resolveProviderLogicalPath('~/.codex/sessions', '/sandbox/home', { SNAP_REAL_HOME: '/home/alice' })).toBe('/home/alice/.codex/sessions');
    expect(resolveProviderLogicalPath('~/.codex/sessions', '/sandbox/home', { OPENBURNBAR_PROVIDER_HOME: '/mnt/host-home', SNAP_REAL_HOME: '/home/alice' })).toBe('/mnt/host-home/.codex/sessions');
    expect(resolveProviderLogicalPath('~/.local/share/opencode', '/sandbox/home', { XDG_DATA_HOME: '/flatpak/data', OPENBURNBAR_PROVIDER_HOME: '/home/alice' })).toBe('/flatpak/data/opencode');
  });

  it('exports only real display paths', () => {
    const paths = providerDisplayPaths();
    expect(paths).toContain('~/.codex/sessions');
    expect(paths).not.toContain('');
    expect(paths.length).toBe(LINUX_PROVIDER_PATH_REGISTRY.filter((row) => row.linuxLogicalPath !== null).length);
  });
});
