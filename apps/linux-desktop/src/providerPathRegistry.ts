/**
 * Shared Linux provider path registry.
 *
 * Parser discovery and Settings UI must share these rows so displayed paths
 * match the paths OpenBurnBarCore AgentProviderLogDiscovery resolves.
 *
 * Keep in sync with:
 * OpenBurnBarCore/.../SharedModels/AgentProviderLogDiscovery.swift
 */

export type ProviderPathRow = {
  /** Stable provider id used by parsers / settings. */
  providerId: string;
  /** User-facing label. */
  displayLabel: string;
  /** Logical path (tilde form) used in docs and settings. */
  logicalPath: string;
  /** Glob / file pattern the parser watches. */
  filePattern: string;
  /** Parser source id (AgentProvider raw value when known). */
  parserSourceId: string;
  /** How XDG/home expansion applies. */
  xdgBehavior: 'home-relative' | 'xdg-config-code' | 'no-local-logs';
  /** Whether symlink targets keep session identity on resolved path. */
  symlinkBehavior: 'identity-on-resolved-path';
};

/** VAL-PARSER-001 registry — one row per product-facing provider on Linux. */
export const LINUX_PROVIDER_PATH_REGISTRY: readonly ProviderPathRow[] = [
  {
    providerId: 'codex',
    displayLabel: 'Codex',
    logicalPath: '~/.codex/sessions',
    filePattern: '*.jsonl',
    parserSourceId: 'codex',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'claude',
    displayLabel: 'Claude Code',
    logicalPath: '~/.claude/projects',
    filePattern: '*.jsonl',
    parserSourceId: 'claudeCode',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'grok',
    displayLabel: 'Grok / xAI',
    logicalPath: '~/.grok/sessions',
    filePattern: 'summary.json',
    parserSourceId: 'xAI',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'opencode',
    displayLabel: 'OpenCode',
    logicalPath: '~/.local/share/opencode',
    filePattern: 'opencode.db',
    parserSourceId: 'openCode',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'goose',
    displayLabel: 'Goose',
    logicalPath: '~/.local/share/goose/sessions',
    filePattern: 'sessions.db',
    parserSourceId: 'goose',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'cline',
    displayLabel: 'Cline',
    logicalPath: '~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks',
    filePattern: '*.json',
    parserSourceId: 'cline',
    xdgBehavior: 'xdg-config-code',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'cursor',
    displayLabel: 'Cursor',
    logicalPath: '~/.cursor/ai-tracking',
    filePattern: '*.db',
    parserSourceId: 'cursor',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'gemini',
    displayLabel: 'Gemini CLI',
    logicalPath: '~/.gemini/tmp',
    filePattern: '*.json',
    parserSourceId: 'geminiCLI',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'kimi',
    displayLabel: 'Kimi',
    logicalPath: '~/.kimi/sessions',
    filePattern: '*.jsonl',
    parserSourceId: 'kimi',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'pi',
    displayLabel: 'Pi Agent',
    logicalPath: '~/.pi/sessions',
    filePattern: '*.jsonl',
    parserSourceId: 'piAgent',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'omp',
    displayLabel: 'OMP',
    logicalPath: '~/.omp/agent/sessions',
    filePattern: '*.jsonl',
    parserSourceId: 'omp',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'droid',
    displayLabel: 'Droid / Factory',
    logicalPath: '~/.factory/sessions',
    filePattern: '*.jsonl',
    parserSourceId: 'factory',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'forge',
    displayLabel: 'Forge',
    logicalPath: '~/.forge/sessions',
    filePattern: '*.jsonl',
    parserSourceId: 'forgeDev',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'antigravity',
    displayLabel: 'Antigravity',
    logicalPath: '~/.gemini/antigravity-cli',
    filePattern: 'history.jsonl',
    parserSourceId: 'antigravity',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'junie',
    displayLabel: 'Junie',
    logicalPath: '~/.junie/sessions',
    filePattern: '*.jsonl',
    parserSourceId: 'junie',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  }
] as const;

export function resolveProviderLogicalPath(
  logicalPath: string,
  home: string,
  env: { XDG_CONFIG_HOME?: string; XDG_DATA_HOME?: string } = {}
): string {
  if (!logicalPath.startsWith('~')) return logicalPath;
  const rest = logicalPath === '~' ? '' : logicalPath.slice(1); // keep leading /
  // XDG-aware expansion for known prefixes under ~/.config and ~/.local/share
  if (rest.startsWith('/.config/') && env.XDG_CONFIG_HOME) {
    return env.XDG_CONFIG_HOME + rest.slice('/.config'.length);
  }
  if (rest.startsWith('/.local/share/') && env.XDG_DATA_HOME) {
    return env.XDG_DATA_HOME + rest.slice('/.local/share'.length);
  }
  return home + rest;
}

export function providerPathById(providerId: string): ProviderPathRow | undefined {
  return LINUX_PROVIDER_PATH_REGISTRY.find((row) => row.providerId === providerId);
}

/** Display list used by settings / onboarding. */
export function providerDisplayPaths(): string[] {
  return LINUX_PROVIDER_PATH_REGISTRY.map((row) => row.logicalPath);
}
