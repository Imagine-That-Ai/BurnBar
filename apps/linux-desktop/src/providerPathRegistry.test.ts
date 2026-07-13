import { describe, expect, it } from 'vitest';
import {
  LINUX_PROVIDER_PATH_REGISTRY,
  providerCoverageCounts,
  providerCoverageSummary,
  providerDisplayPaths,
  providerPathById,
  resolveProviderLogicalPath
} from './providerPathRegistry.js';

const REQUIRED_PROVIDER_IDS = [
  'droid',
  'claude',
  'copilot',
  'aider',
  'cursor',
  'openai',
  'openburnbar',
  'deepseek',
  'codex',
  'opencode',
  'zai',
  'minimax',
  'kimi',
  'cline',
  'kilocode',
  'roocode',
  'forge',
  'augment',
  'hermes',
  'pi',
  'gemini',
  'antigravity',
  'goose',
  'openclaw',
  'openclaude',
  'omp',
  'ollama',
  'windsurf',
  'warp',
  'grok',
  'mimo',
  'cursor-agent',
  'junie'
] as const;

describe('providerPathRegistry', () => {
  it('covers every VAL-PARSER-001 provider id exactly once', () => {
    const ids = LINUX_PROVIDER_PATH_REGISTRY.map((r) => r.providerId);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).toHaveLength(REQUIRED_PROVIDER_IDS.length);
    for (const id of REQUIRED_PROVIDER_IDS) {
      expect(ids).toContain(id);
    }
  });

  it('makes non-parser coverage explicit instead of implying local ingestion', () => {
    expect(providerCoverageCounts()).toEqual({
      total: 33,
      localParser: 27,
      apiBacked: 4,
      unavailable: 2
    });
    expect(providerPathById('openclaude')?.coverage).toBe('unavailable');
    expect(providerPathById('omp')?.coverage).toBe('unavailable');
    expect(providerPathById('openai')?.coverage).toBe('api-backed');
    expect(providerPathById('mimo')?.coverage).toBe('api-backed');
    expect(providerPathById('openclaude')?.coverageNote).toMatch(/No ParserRegistry entry/);
    expect(providerCoverageSummary()).toBe(
      '27 local parsers, 4 API-backed sources, 2 unavailable local sources (33 canonical providers)'
    );
  });

  it('matches parser discovery logical paths for primary providers', () => {
    expect(providerPathById('codex')?.logicalPath).toBe('~/.codex/sessions');
    expect(providerPathById('claude')?.logicalPath).toBe('~/.claude/projects');
    expect(providerPathById('grok')?.logicalPath).toBe('~/.grok/sessions');
    expect(providerPathById('opencode')?.logicalPath).toBe('~/.local/share/opencode');
    expect(providerPathById('goose')?.logicalPath).toBe('~/.local/share/goose/sessions');
    expect(providerPathById('windsurf')?.logicalPath).toBe('~/.config/Windsurf - Next/User/globalStorage');
    expect(providerPathById('warp')?.filePattern).toBe('warp_network*.log');
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

  it('table-driven golden resolutions for all 33 providers under custom XDG', () => {
    const home = '/home/alice';
    const env = { XDG_CONFIG_HOME: '/xdg/config', XDG_DATA_HOME: '/xdg/data' };
    const expected: Record<string, string> = {
      droid: '/home/alice/.factory/sessions',
      claude: '/home/alice/.claude/projects',
      copilot: '/home/alice/.copilot/session-state',
      aider: '/home/alice/.aider',
      cursor: '/home/alice/.cursor/ai-tracking',
      openai: '/home/alice/.codex',
      openburnbar: '/home/alice/.codex',
      deepseek: '/home/alice/.codex',
      codex: '/home/alice/.codex/sessions',
      grok: '/home/alice/.grok/sessions',
      opencode: '/xdg/data/opencode',
      zai: '/home/alice/.factory/sessions',
      minimax: '/home/alice/.factory/sessions',
      goose: '/xdg/data/goose/sessions',
      cline: '/xdg/config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks',
      kilocode: '/xdg/config/Code/User/globalStorage/kilocode.kilo-code/tasks',
      roocode: '/xdg/config/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks',
      forge: '/home/alice/.forge/sessions',
      augment: '/xdg/config/Code/User/globalStorage/augment.vscode-augment',
      hermes: '/home/alice/.hermes/sessions',
      pi: '/home/alice/.pi/sessions',
      gemini: '/home/alice/.gemini/tmp',
      antigravity: '/home/alice/.gemini/antigravity-cli',
      openclaw: '/home/alice/.openclaw/sessions',
      openclaude: '/home/alice/.openclaude/sessions',
      omp: '/home/alice/.omp/agent/sessions',
      ollama: '/home/alice/.ollama/logs',
      windsurf: '/xdg/config/Windsurf - Next/User/globalStorage',
      warp: '/xdg/config/Warp',
      kimi: '/home/alice/.kimi/sessions',
      mimo: '/home/alice/.codex',
      'cursor-agent': '/home/alice/.cursor-agent/sessions',
      junie: '/home/alice/.junie/sessions'
    };
    for (const row of LINUX_PROVIDER_PATH_REGISTRY) {
      expect(resolveProviderLogicalPath(row.logicalPath, home, env)).toBe(expected[row.providerId]);
    }
  });
});
