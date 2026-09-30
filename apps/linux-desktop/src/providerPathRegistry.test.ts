import { describe, expect, it } from 'vitest';
import {
  LINUX_PROVIDER_PATH_REGISTRY,
  providerPathById,
  resolveProviderLogicalPath
} from './providerPathRegistry.js';

describe('providerPathRegistry', () => {
  it('resolves macOS catalog aliases to the canonical Linux path row', () => {
    expect(providerPathById('anthropic')?.providerId).toBe('claude');
    expect(providerPathById('claude-code')?.providerId).toBe('claude');
    expect(providerPathById('google')?.providerId).toBe('gemini');
    expect(providerPathById('factory-droid')?.providerId).toBe('droid');
    expect(providerPathById('x.ai')?.providerId).toBe('grok');
    expect(providerPathById('JetBrains Junie')?.providerId).toBe('junie');
    expect(providerPathById('prime')?.providerId).toBe('prime-agent');
    expect(providerPathById('meta-muse')?.providerId).toBe('muse');
    expect(providerPathById('unknown-vendor')).toBeUndefined();
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

  it('table-driven golden resolutions for all 38 providers under custom XDG', () => {
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
      together: '/home/alice/.codex',
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
      openclaude: '/home/alice/.openclaude/projects',
      omp: '/home/alice/.omp/agent/sessions',
      ollama: '/home/alice/.ollama/logs',
      windsurf: '/xdg/config/Windsurf - Next/User/globalStorage',
      devin: '/xdg/config/Devin/sessions',
      warp: '/xdg/config/Warp',
      kimi: '/home/alice/.kimi/sessions',
      mimo: '/home/alice/.codex',
      'cursor-agent': '/home/alice/.cursor-agent/sessions',
      junie: '/home/alice/.junie/sessions',
      'prime-agent': '/home/alice/.prime/agent/sessions',
      muse: '/xdg/data/muse/sessions',
      fx: '/home/alice/.fx/sessions'
    };
    for (const row of LINUX_PROVIDER_PATH_REGISTRY) {
      expect(resolveProviderLogicalPath(row.logicalPath, home, env)).toBe(expected[row.providerId]);
    }
  });
});
