/**
 * Cross-platform provider glyph catalog used by the macOS and Linux swarm
 * controls. The renderer currently has point data for this subset; keeping
 * the catalog here prevents settings and the kernel from drifting apart.
 */
export const SWARM_PROVIDER_GLYPH_OPTIONS = [
  { id: 'factory', label: 'Factory' },
  { id: 'claudecode', label: 'Claude Code' },
  { id: 'codex', label: 'Codex' },
  { id: 'opencode', label: 'OpenCode' },
  { id: 'openclaw', label: 'OpenClaw' },
  { id: 'openclaude', label: 'OpenClaude' },
  { id: 'omp', label: 'OMP' },
  { id: 'hermes', label: 'Hermes' },
  { id: 'geminicli', label: 'Gemini CLI' },
  { id: 'junie', label: 'Junie' },
  { id: 'antigravity', label: 'Antigravity' },
  { id: 'openai', label: 'OpenAI' },
  { id: 'openburnbar', label: 'OpenBurnBar' },
  { id: 'deepseek', label: 'DeepSeek' },
  { id: 'minimax', label: 'MiniMax' },
  { id: 'zai', label: 'Zai' },
  { id: 'xai', label: 'xAI' },
  { id: 'mimo', label: 'MiMo' },
  { id: 'cursor', label: 'Cursor' },
  { id: 'copilot', label: 'Copilot' },
  { id: 'kimi', label: 'Kimi' },
  { id: 'aider', label: 'Aider' },
  { id: 'cline', label: 'Cline' },
  { id: 'kilocode', label: 'Kilo Code' },
  { id: 'roocode', label: 'Roo Code' },
  { id: 'forgedev', label: 'Forge' },
  { id: 'augment', label: 'Augment' },
  { id: 'piagent', label: 'Pi Agent' },
  { id: 'goose', label: 'Goose' },
  { id: 'ollama', label: 'Ollama' },
  { id: 'windsurf', label: 'Windsurf' },
  { id: 'warp', label: 'Warp' },
  { id: 'cursoragent', label: 'Cursor Agent' },
  { id: 'fx', label: 'fx' },
] as const;

export type SwarmProviderGlyphId = (typeof SWARM_PROVIDER_GLYPH_OPTIONS)[number]['id'];

export const SWARM_PROVIDER_GLYPH_IDS: readonly SwarmProviderGlyphId[] =
  SWARM_PROVIDER_GLYPH_OPTIONS.map(({ id }) => id);

/** Preserve macOS's catalog order while rejecting stale/unknown persisted IDs. */
export function normalizeSwarmProviderGlyphs(value: readonly string[] | undefined): SwarmProviderGlyphId[] {
  if (value == null) return [...SWARM_PROVIDER_GLYPH_IDS];
  const selected = new Set(value);
  return SWARM_PROVIDER_GLYPH_IDS.filter((id) => selected.has(id));
}
