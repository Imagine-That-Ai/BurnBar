/**
 * Maps provider / agent-harness identifiers to the brand logos in
 * public/brand/logos. Unknown ids return null so callers can fall back to an
 * initial tile — never a broken image.
 */

const LOGOS: Record<string, string> = {
  // agent harnesses
  "claude-code": "/brand/logos/claude-code.png",
  codex: "/brand/logos/codex.png",
  cursor: "/brand/logos/cursor.png",
  factory: "/brand/logos/factory.png",
  droid: "/brand/logos/factory.png",
  kimi: "/brand/logos/kimi.svg",
  "gemini-cli": "/brand/logos/gemini-cli.png",
  opencode: "/brand/logos/opencode.png",
  aider: "/brand/logos/aider.png",
  goose: "/brand/logos/goose.png",
  cline: "/brand/logos/cline.png",
  "roo-code": "/brand/logos/roo-code.png",
  "kilo-code": "/brand/logos/kilo-code.png",
  windsurf: "/brand/logos/windsurf.png",
  augment: "/brand/logos/augment.png",
  copilot: "/brand/logos/copilot.png",
  warp: "/brand/logos/warp.png",
  openclaw: "/brand/logos/openclaw.png",
  hermes: "/brand/logos/hermes.png",
  forge: "/brand/logos/forge.png",
  antigravity: "/brand/logos/antigravity.png",
  "pi-agent": "/brand/logos/pi-agent.svg",
  mimo: "/brand/logos/mimo.svg",
  // providers
  openai: "/brand/logos/openai.png",
  anthropic: "/brand/logos/anthropic.png",
  google: "/brand/logos/google.svg",
  xai: "/brand/logos/xai.png",
  deepseek: "/brand/logos/deepseek.svg",
  minimax: "/brand/logos/minimax.png",
  zai: "/brand/logos/zai.png",
  ollama: "/brand/logos/ollama.png",
  qwen: "/brand/logos/qwen.svg",
};

/** Normalize "Claude Code" / "claude_code" / "CLAUDE-CODE" → "claude-code". */
export function brandKey(idOrName: string): string {
  return idOrName
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/**
 * Exact-then-loose lookup in a brand-keyed table: "factory-droid" resolves
 * to factory, "roo code nightly" to roo-code. Shared by the logo and color
 * resolvers so both agree on what a provider id means.
 */
export function matchBrandKey<T>(idOrName: string, table: Record<string, T>): T | undefined {
  const key = brandKey(idOrName);
  if (table[key] !== undefined) return table[key];
  for (const [known, value] of Object.entries(table)) {
    if (key.startsWith(`${known}-`) || key.endsWith(`-${known}`)) return value;
  }
  return undefined;
}

export function brandLogo(idOrName: string | undefined): string | null {
  if (!idOrName) return null;
  return matchBrandKey(idOrName, LOGOS) ?? null;
}
