export type ProviderGlyph = { id: string; label: string; accent: string };

export const PROVIDER_GLYPHS: ProviderGlyph[] = [
  { id: 'openai', label: 'OpenAI', accent: '#10a37f' },
  { id: 'anthropic', label: 'Anthropic', accent: '#cc785c' },
  { id: 'google', label: 'Google', accent: '#4285f4' },
  { id: 'hermes', label: 'Hermes', accent: '#c8bfb5' },
  { id: 'codex', label: 'Codex', accent: '#fa6b06' },
  { id: 'cursor', label: 'Cursor', accent: '#00e5ff' },
  { id: 'opencode', label: 'OpenCode', accent: '#8b5cf6' },
  { id: 'ollama', label: 'Ollama', accent: '#ffffff' }
];