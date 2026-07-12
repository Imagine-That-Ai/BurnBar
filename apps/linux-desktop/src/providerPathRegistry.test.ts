import { describe, expect, it } from 'vitest';
import {
  LINUX_PROVIDER_PATH_REGISTRY,
  providerDisplayPaths,
  providerPathById,
  resolveProviderLogicalPath
} from './providerPathRegistry.js';

const REQUIRED_PROVIDER_IDS = [
  'codex',
  'claude',
  'grok',
  'opencode',
  'goose',
  'cline',
  'cursor',
  'gemini',
  'kimi',
  'pi',
  'omp',
  'droid',
  'forge',
  'antigravity',
  'junie'
] as const;

describe('providerPathRegistry', () => {
  it('covers every VAL-PARSER-001 provider id exactly once', () => {
    const ids = LINUX_PROVIDER_PATH_REGISTRY.map((r) => r.providerId);
    expect(new Set(ids).size).toBe(ids.length);
    for (const id of REQUIRED_PROVIDER_IDS) {
      expect(ids).toContain(id);
    }
  });

  it('matches parser discovery logical paths for primary providers', () => {
    expect(providerPathById('codex')?.logicalPath).toBe('~/.codex/sessions');
    expect(providerPathById('claude')?.logicalPath).toBe('~/.claude/projects');
    expect(providerPathById('grok')?.logicalPath).toBe('~/.grok/sessions');
    expect(providerPathById('opencode')?.logicalPath).toBe('~/.local/share/opencode');
    expect(providerPathById('goose')?.logicalPath).toBe('~/.local/share/goose/sessions');
  });

  it('resolves display and parser paths identically under default and custom XDG', () => {
    const home = '/home/alice';
    for (const row of LINUX_PROVIDER_PATH_REGISTRY) {
      const defaultResolved = resolveProviderLogicalPath(row.logicalPath, home);
      const customResolved = resolveProviderLogicalPath(row.logicalPath, home, {
        XDG_CONFIG_HOME: '/xdg/config',
        XDG_DATA_HOME: '/xdg/data'
      });
      // Display path and parser discovery path share the same resolver.
      expect(defaultResolved.startsWith('/')).toBe(true);
      expect(customResolved.startsWith('/')).toBe(true);
      if (row.logicalPath.startsWith('~/.config/')) {
        expect(customResolved.startsWith('/xdg/config/')).toBe(true);
      }
      if (row.logicalPath.startsWith('~/.local/share/')) {
        expect(customResolved.startsWith('/xdg/data/')).toBe(true);
      }
    }
  });

  it('exports display paths for settings/onboarding', () => {
    const paths = providerDisplayPaths();
    expect(paths).toContain('~/.codex/sessions');
    expect(paths).toContain('~/.local/share/opencode');
    expect(paths.length).toBe(LINUX_PROVIDER_PATH_REGISTRY.length);
  });

  it('table-driven golden resolutions for all 15 providers under custom XDG', () => {
    const home = '/home/alice';
    const env = { XDG_CONFIG_HOME: '/xdg/config', XDG_DATA_HOME: '/xdg/data' };
    const expected: Record<string, string> = {
      codex: '/home/alice/.codex/sessions',
      claude: '/home/alice/.claude/projects',
      grok: '/home/alice/.grok/sessions',
      opencode: '/xdg/data/opencode',
      goose: '/xdg/data/goose/sessions',
      cline: '/xdg/config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks',
      cursor: '/home/alice/.cursor/ai-tracking',
      gemini: '/home/alice/.gemini/tmp',
      kimi: '/home/alice/.kimi/sessions',
      pi: '/home/alice/.pi/sessions',
      omp: '/home/alice/.omp/agent/sessions',
      droid: '/home/alice/.factory/sessions',
      forge: '/home/alice/.forge/sessions',
      antigravity: '/home/alice/.gemini/antigravity-cli',
      junie: '/home/alice/.junie/sessions'
    };
    for (const row of LINUX_PROVIDER_PATH_REGISTRY) {
      expect(resolveProviderLogicalPath(row.logicalPath, home, env)).toBe(expected[row.providerId]);
    }
  });
});
