/**
 * Provider brand identity for data-viz surfaces (profile breakdowns, heatmap
 * hover cards): fixed brand colors, display names, and model-name prettifying.
 *
 * Colors mirror native `DesignSystem.Colors.primary(for:)` 1:1
 * (AgentLens/Theme/DesignSystem.swift) plus the catalog-only entries from
 * `ProviderBrand.colorForProviderID` — brand colors are identity, not theme,
 * and stay fixed under every skin (see docs/EDITORIAL_SKIN.md). Fills should
 * be mixed toward the theme text token for contrast
 * (`providerBarFill`) rather than re-hueing per skin: xAI's near-black and
 * Warp's near-white would otherwise vanish on one skin each.
 */

import { brandKey, matchBrandKey } from "./brandLogos";

/** Canonical brand color per provider id (lowercase, dashed). */
const PROVIDER_COLORS: Record<string, string> = {
  factory: "#8B5CF6",
  "claude-code": "#CC785C",
  copilot: "#23EA3B",
  aider: "#FF6B35",
  cursor: "#AC8C57",
  openai: "#00A67E",
  deepseek: "#6366F1",
  codex: "#2563EB",
  opencode: "#2563EB",
  zai: "#8B5CF6",
  minimax: "#F59E0B",
  kimi: "#6366F1",
  cline: "#D4A373",
  kilocode: "#10B981",
  "kilo-code": "#10B981",
  roocode: "#EC4899",
  "roo-code": "#EC4899",
  forge: "#F97316",
  augment: "#3B82F6",
  hermes: "#A855F7",
  piagent: "#7C3AED",
  "pi-agent": "#7C3AED",
  geminicli: "#4285F4",
  "gemini-cli": "#4285F4",
  antigravity: "#6C63FF",
  goose: "#0D9488",
  openclaw: "#FF6B6B",
  openclaude: "#D97757",
  omp: "#EC4899",
  ollama: "#6B7280",
  windsurf: "#06B6D4",
  devin: "#0A84FF",
  warp: "#DDE4EA",
  xai: "#1A1A1A",
  mimo: "#FF6900",
  "cursor-agent": "#00E5FF",
  junie: "#48E054",
  fx: "#A1A1AA",
  "prime-agent": "#582CFF",
  muse: "#0668E1",
  // Catalog-only aliases (native colorForProviderID).
  anthropic: "#CC785C",
  google: "#4285F4",
  moonshot: "#6366F1",
  qwen: "#FF6A00",
  mistral: "#FF7000",
  cohere: "#39594D",
  amazon: "#FF9900",
  bedrock: "#FF9900",
  perplexity: "#20808C",
  grok: "#1A1A1A",
};

/**
 * Fixed brand color for a provider id or display name. Always returns a
 * usable CSS color — unknown ids fall back to the theme accent, never null.
 */
export function providerColor(idOrName: string | undefined): string {
  if (!idOrName) return "var(--accent)";
  return matchBrandKey(idOrName, PROVIDER_COLORS) ?? "var(--accent)";
}

/**
 * Contrast-safe bar/dot fill for a provider: the fixed brand hue pulled 18%
 * toward the theme's bright text token, so near-black hues survive dark
 * skins and near-white hues survive paper.
 */
export function providerBarFill(idOrName: string | undefined): string {
  return `color-mix(in srgb, ${providerColor(idOrName)} 82%, var(--color-text-bright))`;
}

/** Curated display names (native AgentProvider.rawValue + catalog). */
const PROVIDER_DISPLAY_NAMES: Record<string, string> = {
  factory: "Factory",
  "claude-code": "Claude Code",
  copilot: "Copilot",
  aider: "Aider",
  cursor: "Cursor",
  "cursor-agent": "Cursor Agent",
  openai: "OpenAI",
  openburnbar: "BurnBar",
  deepseek: "DeepSeek",
  codex: "Codex",
  opencode: "OpenCode",
  zai: "Zai",
  minimax: "MiniMax",
  kimi: "Kimi",
  cline: "Cline",
  kilocode: "Kilo Code",
  "kilo-code": "Kilo Code",
  roocode: "Roo Code",
  "roo-code": "Roo Code",
  forge: "Forge",
  augment: "Augment",
  hermes: "Hermes",
  piagent: "Pi Agent",
  "pi-agent": "Pi Agent",
  geminicli: "Gemini CLI",
  "gemini-cli": "Gemini CLI",
  antigravity: "Antigravity",
  goose: "Goose",
  openclaw: "OpenClaw",
  openclaude: "OpenClaude",
  omp: "OMP",
  ollama: "Ollama",
  windsurf: "Windsurf",
  devin: "Devin",
  warp: "Warp",
  xai: "xAI",
  mimo: "MiMo",
  junie: "Junie",
  "prime-agent": "Prime Agent",
  muse: "Muse",
  fx: "fx",
  anthropic: "Anthropic",
  google: "Google",
  moonshot: "Moonshot",
  qwen: "Qwen",
  mistral: "Mistral",
  grok: "Grok",
};

const DISPLAY_ACRONYMS: Record<string, string> = {
  ai: "AI",
  api: "API",
  cli: "CLI",
  ide: "IDE",
  llm: "LLM",
  omp: "OMP",
};

/** "claude-code" → "Claude Code". Unknown ids Title-Case prettily, never raw. */
export function providerDisplayName(idOrName: string | undefined): string {
  if (!idOrName || !idOrName.trim()) return "Unknown";
  const curated = PROVIDER_DISPLAY_NAMES[brandKey(idOrName)];
  if (curated) return curated;
  // Already a display name ("Claude Code")? Keep it verbatim.
  if (/[A-Z]/.test(idOrName) && /[\s]/.test(idOrName)) return idOrName.trim();
  return idOrName
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => {
      const lower = part.toLowerCase();
      if (DISPLAY_ACRONYMS[lower]) return DISPLAY_ACRONYMS[lower];
      if (/^\d/.test(part)) return part; // versions stay untouched
      return part.charAt(0).toUpperCase() + part.slice(1).toLowerCase();
    })
    .join(" ");
}

const MODEL_ACRONYMS: Record<string, string> = {
  gpt: "GPT",
  oai: "OAI",
  claude: "Claude",
  opus: "Opus",
  sonnet: "Sonnet",
  haiku: "Haiku",
  gemini: "Gemini",
  grok: "Grok",
  deepseek: "DeepSeek",
  qwen: "Qwen",
  kimi: "Kimi",
  glm: "GLM",
  minimax: "MiniMax",
  mistral: "Mistral",
  codestral: "Codestral",
  mixtral: "Mixtral",
  llama: "Llama",
  codellama: "Code Llama",
  command: "Command",
  cohere: "Cohere",
  palm: "PaLM",
  imagen: "Imagen",
  whisper: "Whisper",
  codex: "Codex",
  copilot: "Copilot",
  phi: "Phi",
  gemma: "Gemma",
  yi: "Yi",
  falcon: "Falcon",
  mpt: "MPT",
  starcoder: "StarCoder",
  wizardlm: "WizardLM",
  vicuna: "Vicuna",
  orca: "Orca",
  solar: "Solar",
};

/**
 * "gpt-5.6-sol" → "GPT 5.6 Sol". Already-pretty names (spaces/parens, e.g.
 * "Gemini 3.8 Flash (High)") pass through untouched; dotted versions stay
 * verbatim and split versions rejoin ("claude-3-5-sonnet" → "Claude 3.5
 * Sonnet"). Uniform spacing keeps a mixed list scannable.
 */
export function modelDisplayName(model: string | undefined): string {
  if (!model || !model.trim()) return "Unknown model";
  const trimmed = model.trim();
  if (/[\s()]/.test(trimmed)) return trimmed;
  const parts = trimmed
    .split(/[-_/]+/)
    .filter(Boolean)
    .map((part) => {
      const lower = part.toLowerCase();
      if (MODEL_ACRONYMS[lower]) return MODEL_ACRONYMS[lower];
      if (/^v\d/i.test(part)) return `V${part.slice(1)}`;
      if (/^\d/.test(part)) return part;
      if (part === part.toUpperCase() && part.length <= 4) return part; // OMP, XL
      return part.charAt(0).toUpperCase() + part.slice(1);
    });
  // Rejoin split versions: ["Claude", "3", "5", "Sonnet"] → "Claude 3.5 Sonnet".
  const merged: string[] = [];
  for (const part of parts) {
    const prev = merged[merged.length - 1];
    if (prev !== undefined && /^\d+(\.\d+)*$/.test(prev) && /^\d+(\.\d+)*$/.test(part)) {
      merged[merged.length - 1] = `${prev}.${part}`;
    } else {
      merged.push(part);
    }
  }
  // "dall e" → the one model whose brand mark is an acronym with a dash.
  return merged.join(" ").replace(/^Dall E\b/, "DALL-E");
}

/**
 * Combo shorthand: drops model words the harness name already says, so
 * "Claude Code × Claude Opus 4.6" reads "Claude Code × Opus 4.6" and
 * "Codex × GPT 5.3 Codex" reads "Codex × GPT 5.3". Leading and trailing
 * overlaps go; at least one word always survives.
 */
export function comboModelShortName(sourceName: string, model: string): string {
  const sourceWords = new Set(sourceName.toLowerCase().split(/[\s-]+/).filter(Boolean));
  const words = modelDisplayName(model).split(" ");
  let start = 0;
  let end = words.length;
  while (start < end - 1 && sourceWords.has((words[start] ?? "").toLowerCase())) start++;
  while (end - 1 > start && sourceWords.has((words[end - 1] ?? "").toLowerCase())) end--;
  return words.slice(start, end).join(" ");
}
