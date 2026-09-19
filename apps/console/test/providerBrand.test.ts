import { describe, expect, it } from "vitest";

import {
  comboModelShortName,
  modelDisplayName,
  providerBarFill,
  providerColor,
  providerDisplayName,
} from "../lib/providerBrand";

describe("providerColor", () => {
  it("mirrors the native brand palette for the majors", () => {
    expect(providerColor("claude-code")).toBe("#CC785C");
    expect(providerColor("codex")).toBe("#2563EB");
    expect(providerColor("openai")).toBe("#00A67E");
    expect(providerColor("antigravity")).toBe("#6C63FF");
    expect(providerColor("factory")).toBe("#8B5CF6");
    expect(providerColor("xai")).toBe("#1A1A1A");
    expect(providerColor("ollama")).toBe("#6B7280");
    expect(providerColor("mimo")).toBe("#FF6900");
    expect(providerColor("cursor-agent")).toBe("#00E5FF");
    expect(providerColor("prime-agent")).toBe("#582CFF");
  });

  it("resolves display names and separators to the same hue", () => {
    expect(providerColor("Claude Code")).toBe("#CC785C");
    expect(providerColor("claude_code")).toBe("#CC785C");
    expect(providerColor(" Pi Agent ")).toBe("#7C3AED");
    expect(providerColor("pi-agent")).toBe("#7C3AED");
    expect(providerColor("Kilo Code")).toBe("#10B981");
  });

  it("covers the full uploader catalog without falling back to accent", () => {
    // Every providerID the Swift AgentProvider catalog can emit (production
    // census 2026-09-19: 19 distinct ids across 91,684 docs).
    const catalog = [
      "factory", "claude-code", "copilot", "aider", "cursor", "openai", "openburnbar",
      "deepseek", "codex", "opencode", "zai", "minimax", "kimi", "cline", "kilocode",
      "roocode", "forge", "augment", "hermes", "piagent", "geminicli", "antigravity",
      "goose", "openclaw", "openclaude", "omp", "ollama", "windsurf", "devin", "warp",
      "xai", "mimo", "cursor-agent", "junie", "prime-agent", "muse", "fx",
    ];
    for (const id of catalog) {
      // openburnbar resolves to the theme accent (native maps it to ember).
      if (id === "openburnbar") {
        expect(providerColor(id)).toBe("var(--accent)");
        continue;
      }
      expect(providerColor(id), id).toMatch(/^#[0-9A-Fa-f]{6}$/);
    }
  });

  it("falls back to the theme accent for unknowns, never null", () => {
    expect(providerColor("not-a-provider")).toBe("var(--accent)");
    expect(providerColor("")).toBe("var(--accent)");
    expect(providerColor(undefined)).toBe("var(--accent)");
  });

  it("bar fills mix the brand hue toward theme text for contrast", () => {
    expect(providerBarFill("codex")).toBe(
      "color-mix(in srgb, #2563EB 82%, var(--color-text-bright))",
    );
    expect(providerBarFill("nope")).toBe(
      "color-mix(in srgb, var(--accent) 82%, var(--color-text-bright))",
    );
  });
});

describe("providerDisplayName", () => {
  it("renders curated names with correct casing", () => {
    expect(providerDisplayName("claude-code")).toBe("Claude Code");
    expect(providerDisplayName("openai")).toBe("OpenAI");
    expect(providerDisplayName("xai")).toBe("xAI");
    expect(providerDisplayName("mimo")).toBe("MiMo");
    expect(providerDisplayName("minimax")).toBe("MiniMax");
    expect(providerDisplayName("omp")).toBe("OMP");
    expect(providerDisplayName("gemini-cli")).toBe("Gemini CLI");
    expect(providerDisplayName("cursor-agent")).toBe("Cursor Agent");
    expect(providerDisplayName("roo-code")).toBe("Roo Code");
  });

  it("keeps real display names verbatim and prettifies unknown slugs", () => {
    expect(providerDisplayName("Claude Code")).toBe("Claude Code");
    expect(providerDisplayName("my-provider")).toBe("My Provider");
    expect(providerDisplayName("cool_ai")).toBe("Cool AI");
    expect(providerDisplayName("")).toBe("Unknown");
    expect(providerDisplayName(undefined)).toBe("Unknown");
  });
});

describe("modelDisplayName", () => {
  it("prettifies slugs with acronym-aware casing", () => {
    expect(modelDisplayName("gpt-5.6-sol")).toBe("GPT 5.6 Sol");
    expect(modelDisplayName("gpt-5.6-luna")).toBe("GPT 5.6 Luna");
    expect(modelDisplayName("gpt-5.5")).toBe("GPT 5.5");
    expect(modelDisplayName("claude-opus-4.6")).toBe("Claude Opus 4.6");
    expect(modelDisplayName("claude-sonnet-4.6")).toBe("Claude Sonnet 4.6");
    expect(modelDisplayName("kimi-k2.5")).toBe("Kimi K2.5");
    expect(modelDisplayName("gpt-5.3-codex")).toBe("GPT 5.3 Codex");
    expect(modelDisplayName("deepseek-v3")).toBe("DeepSeek V3");
    expect(modelDisplayName("claude-3-5-sonnet")).toBe("Claude 3.5 Sonnet");
  });

  it("passes already-pretty names through untouched", () => {
    expect(modelDisplayName("Gemini 3.8 Flash (High)")).toBe("Gemini 3.8 Flash (High)");
    expect(modelDisplayName("Claude Opus 4.6 (Thinking)")).toBe("Claude Opus 4.6 (Thinking)");
  });

  it("never renders an empty label", () => {
    expect(modelDisplayName("")).toBe("Unknown model");
    expect(modelDisplayName(undefined)).toBe("Unknown model");
  });
});

describe("comboModelShortName", () => {
  it("drops harness-duplicate words from either end", () => {
    expect(comboModelShortName("Claude Code", "claude-opus-4.6")).toBe("Opus 4.6");
    expect(comboModelShortName("Codex", "gpt-5.3-codex")).toBe("GPT 5.3");
    expect(comboModelShortName("Kimi Code", "kimi-k2.5")).toBe("K2.5");
    expect(comboModelShortName("Cursor", "gpt-5.3")).toBe("GPT 5.3");
  });

  it("keeps at least one word when everything overlaps", () => {
    expect(comboModelShortName("Codex", "codex")).toBe("Codex");
  });
});
