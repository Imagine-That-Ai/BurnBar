/**
 * Checked Linux provider/path/usage catalog.
 *
 * The rows below mirror the canonical OpenBurnBarCore
 * `AgentProviderLogDiscovery` table. `coverage` describes the macOS
 * ingestion source that is actually registered today; it is deliberately
 * not inferred from a provider logo or a route in the Linux shell.
 *
 * Keep this catalog in sync with:
 * - OpenBurnBarCore/.../SharedModels/AgentProviderLogDiscovery.swift
 * - OpenBurnBarKernel/.../SharedModels/AgentProvider.swift
 * - AgentLens/Services/UsageAggregation/ParserRegistry.swift
 *
 * `providerPathRegistry.swiftParity.test.ts` fails when any canonical
 * provider, path, pattern, or parser registration drifts. The catalog is
 * checked in so packaged Linux builds can expose coverage without reading
 * source files at runtime.
 */

export type ProviderIngestionCoverage = 'local-parser' | 'api-backed' | 'unavailable';

export type ProviderPathRow = {
  /** Stable Linux/provider route id used by settings and shell surfaces. */
  providerId: string;
  /** Canonical AgentProvider case token. */
  parserSourceId: string;
  /** User-facing label. */
  displayLabel: string;
  /** Logical path (tilde form) used in docs and settings. */
  logicalPath: string;
  /** Glob / file pattern the canonical discovery table advertises. */
  filePattern: string;
  /** How usage is sourced on the macOS gold-standard path. */
  coverage: ProviderIngestionCoverage;
  /** Honest explanation shown beside the path in Settings/onboarding. */
  coverageNote: string;
  /** How XDG/home expansion applies. */
  xdgBehavior: 'home-relative' | 'xdg-config-code' | 'xdg-data' | 'no-local-logs';
  /** Whether symlink targets keep session identity on resolved path. */
  symlinkBehavior: 'identity-on-resolved-path';
};

/**
 * Canonical provider path and ingestion coverage rows.
 *
 * There are 33 canonical AgentProvider cases and 27 ParserRegistry entries.
 * The six rows without a local parser remain visible with an explicit
 * `api-backed` or `unavailable` state; they must not be presented as parsed
 * local usage until a real source is wired.
 */
export const LINUX_PROVIDER_PATH_REGISTRY: readonly ProviderPathRow[] = [
  {
    providerId: 'droid',
    parserSourceId: 'factory',
    displayLabel: 'Droid / Factory',
    logicalPath: '~/.factory/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'claude',
    parserSourceId: 'claudeCode',
    displayLabel: 'Claude Code',
    logicalPath: '~/.claude/projects',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'copilot',
    parserSourceId: 'copilot',
    displayLabel: 'Copilot',
    logicalPath: '~/.copilot/session-state',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'aider',
    parserSourceId: 'aider',
    displayLabel: 'Aider',
    logicalPath: '~/.aider',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'cursor',
    parserSourceId: 'cursor',
    displayLabel: 'Cursor',
    logicalPath: '~/.cursor/ai-tracking',
    filePattern: '*.db',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'openai',
    parserSourceId: 'openAI',
    displayLabel: 'OpenAI',
    logicalPath: '~/.codex',
    filePattern: 'openai-no-local-logs',
    coverage: 'api-backed',
    coverageNote: 'No local parser; usage is supplied by the official API path.',
    xdgBehavior: 'no-local-logs',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'openburnbar',
    parserSourceId: 'openBurnBar',
    displayLabel: 'OpenBurnBar',
    logicalPath: '~/.codex',
    filePattern: 'openburnbar-no-local-logs',
    coverage: 'api-backed',
    coverageNote: 'No local parser; usage is recorded by the native app/ledger path.',
    xdgBehavior: 'no-local-logs',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'deepseek',
    parserSourceId: 'deepSeek',
    displayLabel: 'DeepSeek',
    logicalPath: '~/.codex',
    filePattern: 'deepseek-no-local-logs',
    coverage: 'api-backed',
    coverageNote: 'No local parser; quota and usage require the provider API path.',
    xdgBehavior: 'no-local-logs',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'codex',
    parserSourceId: 'codex',
    displayLabel: 'Codex',
    logicalPath: '~/.codex/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'opencode',
    parserSourceId: 'openCode',
    displayLabel: 'OpenCode',
    logicalPath: '~/.local/share/opencode',
    filePattern: 'opencode.db',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'xdg-data',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'zai',
    parserSourceId: 'zai',
    displayLabel: 'Z.ai',
    logicalPath: '~/.factory/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local model-filter parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'minimax',
    parserSourceId: 'minimax',
    displayLabel: 'MiniMax',
    logicalPath: '~/.factory/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local model-filter parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'kimi',
    parserSourceId: 'kimi',
    displayLabel: 'Kimi',
    logicalPath: '~/.kimi/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'cline',
    parserSourceId: 'cline',
    displayLabel: 'Cline',
    logicalPath: '~/.config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks',
    filePattern: '*.json',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'xdg-config-code',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'kilocode',
    parserSourceId: 'kiloCode',
    displayLabel: 'Kilo Code',
    logicalPath: '~/.config/Code/User/globalStorage/kilocode.kilo-code/tasks',
    filePattern: '*.json',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'xdg-config-code',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'roocode',
    parserSourceId: 'rooCode',
    displayLabel: 'Roo Code',
    logicalPath: '~/.config/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks',
    filePattern: '*.json',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'xdg-config-code',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'forge',
    parserSourceId: 'forgeDev',
    displayLabel: 'Forge',
    logicalPath: '~/.forge/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'augment',
    parserSourceId: 'augment',
    displayLabel: 'Augment',
    logicalPath: '~/.config/Code/User/globalStorage/augment.vscode-augment',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Parser is registered, but macOS marks this source unsupported.',
    xdgBehavior: 'xdg-config-code',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'hermes',
    parserSourceId: 'hermes',
    displayLabel: 'Hermes',
    logicalPath: '~/.hermes/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'pi',
    parserSourceId: 'piAgent',
    displayLabel: 'Pi Agent',
    logicalPath: '~/.pi/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'gemini',
    parserSourceId: 'geminiCLI',
    displayLabel: 'Gemini CLI',
    logicalPath: '~/.gemini/tmp',
    filePattern: '*.json',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'antigravity',
    parserSourceId: 'antigravity',
    displayLabel: 'Antigravity',
    logicalPath: '~/.gemini/antigravity-cli',
    filePattern: 'history.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'goose',
    parserSourceId: 'goose',
    displayLabel: 'Goose',
    logicalPath: '~/.local/share/goose/sessions',
    filePattern: 'sessions.db',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'xdg-data',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'openclaw',
    parserSourceId: 'openClaw',
    displayLabel: 'OpenClaw',
    logicalPath: '~/.openclaw/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'openclaude',
    parserSourceId: 'openClaude',
    displayLabel: 'OpenClaude',
    logicalPath: '~/.openclaude/sessions',
    filePattern: '*.jsonl',
    coverage: 'unavailable',
    coverageNote: 'No ParserRegistry entry; local usage is unavailable.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'omp',
    parserSourceId: 'omp',
    displayLabel: 'OMP',
    logicalPath: '~/.omp/agent/sessions',
    filePattern: '*.jsonl',
    coverage: 'unavailable',
    coverageNote: 'No ParserRegistry entry; local usage is unavailable.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'ollama',
    parserSourceId: 'ollama',
    displayLabel: 'Ollama',
    logicalPath: '~/.ollama/logs',
    filePattern: 'server*.log',
    coverage: 'local-parser',
    coverageNote: 'Local model-filter parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'windsurf',
    parserSourceId: 'windsurf',
    displayLabel: 'Windsurf',
    logicalPath: '~/.config/Windsurf - Next/User/globalStorage',
    filePattern: 'state.vscdb',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'xdg-config-code',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'warp',
    parserSourceId: 'warp',
    displayLabel: 'Warp',
    logicalPath: '~/.config/Warp',
    filePattern: 'warp_network*.log',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'xdg-config-code',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'grok',
    parserSourceId: 'xAI',
    displayLabel: 'Grok / xAI',
    logicalPath: '~/.grok/sessions',
    filePattern: 'summary.json',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'mimo',
    parserSourceId: 'mimo',
    displayLabel: 'MiMo',
    logicalPath: '~/.codex',
    filePattern: 'mimo-no-local-logs',
    coverage: 'api-backed',
    coverageNote: 'No local parser; usage requires the MiMo API/token-plan path.',
    xdgBehavior: 'no-local-logs',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'cursor-agent',
    parserSourceId: 'cursorAgent',
    displayLabel: 'Cursor Agent',
    logicalPath: '~/.cursor-agent/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  },
  {
    providerId: 'junie',
    parserSourceId: 'junie',
    displayLabel: 'Junie',
    logicalPath: '~/.junie/sessions',
    filePattern: '*.jsonl',
    coverage: 'local-parser',
    coverageNote: 'Local parser registered in ParserRegistry.',
    xdgBehavior: 'home-relative',
    symlinkBehavior: 'identity-on-resolved-path'
  }
] as const;

export type ProviderCoverageCounts = {
  total: number;
  localParser: number;
  apiBacked: number;
  unavailable: number;
};

export function providerCoverageCounts(): ProviderCoverageCounts {
  return LINUX_PROVIDER_PATH_REGISTRY.reduce<ProviderCoverageCounts>(
    (counts, row) => {
      counts.total += 1;
      if (row.coverage === 'local-parser') counts.localParser += 1;
      if (row.coverage === 'api-backed') counts.apiBacked += 1;
      if (row.coverage === 'unavailable') counts.unavailable += 1;
      return counts;
    },
    { total: 0, localParser: 0, apiBacked: 0, unavailable: 0 }
  );
}

export function providerCoverageSummary(): string {
  const counts = providerCoverageCounts();
  return `${counts.localParser} local parsers, ${counts.apiBacked} API-backed sources, ${counts.unavailable} unavailable local sources (${counts.total} canonical providers)`;
}

export function resolveProviderLogicalPath(
  logicalPath: string,
  home: string,
  env: { XDG_CONFIG_HOME?: string; XDG_DATA_HOME?: string } = {}
): string {
  if (!logicalPath.startsWith('~')) return logicalPath;
  const rest = logicalPath === '~' ? '' : logicalPath.slice(1); // keep leading /
  // XDG-aware expansion for known prefixes under ~/.config and ~/.local/share.
  if (rest.startsWith('/.config/') && env.XDG_CONFIG_HOME) {
    return env.XDG_CONFIG_HOME + rest.slice('/.config'.length);
  }
  if (rest.startsWith('/.local/share/') && env.XDG_DATA_HOME) {
    return env.XDG_DATA_HOME + rest.slice('/.local/share'.length);
  }
  return home + rest;
}

export function providerPathById(providerId: string): ProviderPathRow | undefined {
  const normalized = providerId.trim().toLowerCase().replace(/[\s._-]+/g, '');
  if (!normalized) return undefined;

  // The daemon catalog uses vendor IDs while the usage/path oracle uses
  // AgentProvider route IDs. Keep the same aliases as
  // AgentProvider.fromCatalogProviderID so a catalog row can always resolve
  // to its canonical path and ingestion coverage without guessing from a logo.
  const aliases: Record<string, string> = {
    anthropic: 'claude',
    claude: 'claude',
    claudecode: 'claude',
    google: 'gemini',
    gemini: 'gemini',
    geminicli: 'gemini',
    factory: 'droid',
    factorydroid: 'droid',
    droid: 'droid',
    openai: 'openai',
    openburnbar: 'openburnbar',
    deepseek: 'deepseek',
    opencode: 'opencode',
    opencodego: 'opencode',
    moonshot: 'kimi',
    kimi: 'kimi',
    zai: 'zai',
    minimax: 'minimax',
    pi: 'pi',
    piagent: 'pi',
    antigravitycli: 'antigravity',
    ollama: 'ollama',
    openclaw: 'openclaw',
    openclaude: 'openclaude',
    ohmypi: 'omp',
    forge: 'forge',
    forgedev: 'forge',
    kilocode: 'kilocode',
    roocode: 'roocode',
    xai: 'grok',
    grok: 'grok',
    mimo: 'mimo',
    xiaomimimo: 'mimo',
    cursoragent: 'cursor-agent',
    jetbrainsjunie: 'junie'
  };
  const canonicalID = aliases[normalized] ?? normalized;
  return LINUX_PROVIDER_PATH_REGISTRY.find((row) => {
    const rowTokens = [row.providerId, row.parserSourceId, row.displayLabel]
      .map((value) => value.toLowerCase().replace(/[\s._-]+/g, ''));
    return row.providerId === canonicalID || rowTokens.includes(canonicalID);
  });
}

/** Display list used by settings / onboarding. */
export function providerDisplayPaths(): string[] {
  return LINUX_PROVIDER_PATH_REGISTRY.map((row) => row.logicalPath);
}
