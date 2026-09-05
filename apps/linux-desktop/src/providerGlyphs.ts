import { colorForProviderID } from './providerColors.js';

export type ProviderGlyph = { id: string; label: string; accent: string; logo: string };

export const PROVIDER_GLYPHS: ProviderGlyph[] = [
  { id: 'openai', label: 'OpenAI', accent: '#10a37f', logo: '/provider-logos/openai.png' },
  { id: 'anthropic', label: 'Anthropic', accent: '#cc785c', logo: '/provider-logos/anthropic.png' },
  { id: 'google', label: 'Google', accent: '#4285f4', logo: '/provider-logos/google.svg' },
  { id: 'hermes', label: 'Hermes', accent: '#c8bfb5', logo: '/provider-logos/hermes.png' },
  { id: 'codex', label: 'Codex', accent: '#fa6b06', logo: '/provider-logos/codex.png' },
  { id: 'cursor', label: 'Cursor', accent: '#00e5ff', logo: '/provider-logos/cursor.png' },
  { id: 'opencode', label: 'OpenCode', accent: '#8b5cf6', logo: '/provider-logos/opencode.png' },
  { id: 'ollama', label: 'Ollama', accent: '#ffffff', logo: '/provider-logos/ollama.png' },
  { id: 'claude-code', label: 'Claude Code', accent: '#d97757', logo: '/provider-logos/claude-code.png' },
  { id: 'copilot', label: 'Copilot', accent: '#8b5cf6', logo: '/provider-logos/copilot.png' },
  { id: 'factory', label: 'Factory', accent: '#8b5cf6', logo: '/provider-logos/factory.png' },
  { id: 'minimax', label: 'MiniMax', accent: '#8b5cf6', logo: '/provider-logos/minimax.png' },
  { id: 'deepseek', label: 'DeepSeek', accent: '#4d8eff', logo: '/provider-logos/deepseek.png' },
  { id: 'gemini', label: 'Gemini', accent: '#4285f4', logo: '/provider-logos/gemini.png' },
  { id: 'grok', label: 'xAI', accent: '#ffffff', logo: '/provider-logos/grok.png' },
  { id: 'kimi', label: 'Kimi', accent: '#8b5cf6', logo: '/provider-logos/kimi.png' },
  { id: 'cline', label: 'Cline', accent: '#8b5cf6', logo: '/provider-logos/cline.png' },
  { id: 'windsurf', label: 'Windsurf', accent: '#8b5cf6', logo: '/provider-logos/windsurf.png' },
  { id: 'goose', label: 'Goose', accent: '#8b5cf6', logo: '/provider-logos/goose.png' },
  { id: 'openclaw', label: 'OpenClaw', accent: '#8b5cf6', logo: '/provider-logos/openclaw.png' },
  { id: 'fx', label: 'fx', accent: '#a1a1aa', logo: '/provider-logos/fx.png' },
  { id: 'muse', label: 'Muse Code', accent: '#0668e1', logo: '/provider-logos/meta.png' },
];

/** Find a glyph by provider id, with graceful fallback */
export function findProviderGlyph(id: string): ProviderGlyph {
  return PROVIDER_GLYPHS.find((g) => g.id === id) ?? { id, label: id, accent: colorForProviderID(id), logo: '' };
}
