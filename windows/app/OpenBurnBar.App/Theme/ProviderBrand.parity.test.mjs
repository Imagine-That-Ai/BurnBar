// Swift ↔ C# provider/model brand PARITY test.
//
// Ground truth = the macOS brand tables in AgentLens/Theme/. This test regex-
// extracts every switch arm from the Swift source and asserts the C# port
// (ProviderBrand.cs) returns the identical hex, provider-by-provider and
// model-by-model, so the two platforms can never silently drift. It runs with
// plain Node (no Swift/.NET toolchain), so CI can gate it on any host:
//
//   node --test windows/app/OpenBurnBar.App/Theme/ProviderBrand.parity.test.mjs
//
// Adaptive Swift colors (Colors.ember / Colors.blaze / Color.primary /
// DesignSystem.Colors.textSecondary) have no single hex; the Windows shell is
// dark-first, so the C# port uses their DARK value. SYMBOLS encodes that mapping.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..", "..", "..");
const read = (p) => readFileSync(p, "utf8");

const designSwift = read(join(ROOT, "AgentLens", "Theme", "DesignSystem.swift"));
const brandSwift = read(join(ROOT, "AgentLens", "Theme", "LLMModelBrand.swift"));
const providerCs = read(join(HERE, "ProviderBrand.cs"));

// Dark-shell resolutions for adaptive Swift colors.
const SYMBOLS = {
  ember: "FA5053",
  "Colors.ember": "FA5053",
  blaze: "E86100",
  "Colors.blaze": "E86100",
  "Color.primary": "FFFFFF",
  "DesignSystem.Colors.textSecondary": "8B949E",
  'Color.adaptive(light: "171717", dark: "FFFFFF")': "FFFFFF",
  'Color.adaptive(light: "4A4A4A", dark: "D4D4D8")': "D4D4D8",
};

// Swift enum case → C# enum member.
const PROVIDER_MAP = {
  factory: "Factory", claudeCode: "ClaudeCode", copilot: "Copilot", aider: "Aider",
  cursor: "Cursor", openAI: "OpenAI", deepSeek: "DeepSeek", codex: "Codex",
  openCode: "OpenCode", zai: "Zai", minimax: "MiniMax", kimi: "Kimi", cline: "Cline",
  kiloCode: "KiloCode", rooCode: "RooCode", forgeDev: "ForgeDev", augment: "Augment",
  hermes: "Hermes", piAgent: "PiAgent", geminiCLI: "GeminiCLI", antigravity: "Antigravity",
  goose: "Goose", openClaw: "OpenClaw", openClaude: "OpenClaude", omp: "Omp",
  ollama: "Ollama", windsurf: "Windsurf", warp: "Warp", xAI: "XAI", mimo: "Mimo",
  cursorAgent: "CursorAgent", openBurnBar: "OpenBurnBar", fx: "Fx",
  junie: "Junie", primeAgent: "PrimeAgent", muse: "Muse", devin: "Devin",
};

const BRAND_MAP = {
  anthropic: "Anthropic", openAI: "OpenAI", google: "Google", deepSeek: "DeepSeek",
  kimi: "Kimi", miniMax: "MiniMax", meta: "Meta", mistral: "Mistral", qwen: "Qwen",
  xAI: "XAI", cohere: "Cohere", perplexity: "Perplexity", apple: "Apple",
  amazon: "Amazon", alibaba: "Alibaba", ollama: "Ollama", openBurnBar: "OpenBurnBar",
  zai: "Zai", unknown: "Unknown",
};

/** Slice a source between two anchors (start inclusive, end exclusive). */
function region(src, startAnchor, endAnchor) {
  const s = src.indexOf(startAnchor);
  assert.notEqual(s, -1, `anchor not found: ${startAnchor}`);
  const e = src.indexOf(endAnchor, s + startAnchor.length);
  assert.notEqual(e, -1, `anchor not found: ${endAnchor}`);
  return src.slice(s, e);
}

/** Parse Swift `case .a, .b: return <expr>` arms → { csMember: HEX }. */
function swiftArms(block, caseMap) {
  const arms = {};
  // Separators between labels are a single `[\s,]*` class (not the ambiguous
  // `\s*,?\s*`) so the group has no overlapping quantifiers — avoids the
  // js/redos exponential-backtracking CodeQL alert. Labels are re-extracted
  // below via matchAll, so collapsing the separator is semantically identical.
  const re = /case\s+((?:\.\w+[\s,]*)+):\s*return\s+([^\n/]+)/g;
  let m;
  while ((m = re.exec(block))) {
    const labels = [...m[1].matchAll(/\.(\w+)/g)].map((x) => x[1]);
    const expr = m[2].trim();
    const hx = expr.match(/Color\(hex:\s*"([0-9A-Fa-f]{6})"\)/);
    let hex;
    if (hx) hex = hx[1].toUpperCase();
    else if (SYMBOLS[expr] !== undefined) hex = SYMBOLS[expr];
    else continue;
    for (const lab of labels) if (caseMap[lab]) arms[caseMap[lab]] = hex;
  }
  return arms;
}

/** Parse C# `Prefix.Member => "#HEX",` arms → { Member: HEX }. */
function csArms(block, prefix) {
  const arms = {};
  const re = new RegExp(`${prefix}\\.(\\w+)\\s*=>\\s*"#([0-9A-Fa-f]{6})"`, "g");
  let m;
  while ((m = re.exec(block))) arms[m[1]] = m[2].toUpperCase();
  return arms;
}

function assertArmsEqual(swiftMap, csMap, label) {
  const keys = new Set([...Object.keys(swiftMap), ...Object.keys(csMap)]);
  for (const k of keys) {
    assert.ok(k in swiftMap, `${label}: C# has ${k} but Swift does not`);
    assert.ok(k in csMap, `${label}: Swift maps ${k} but C# does not`);
    assert.equal(csMap[k], swiftMap[k], `${label}: ${k} hex drift — Swift ${swiftMap[k]} vs C# ${csMap[k]}`);
  }
  return keys.size;
}

test("primary(for:) — all 37 providers match Swift", () => {
  const sw = swiftArms(
    region(designSwift, "static func primary(for provider: AgentProvider) -> Color {", "static func accent(for provider"),
    PROVIDER_MAP
  );
  const cs = csArms(region(providerCs, "public static string PrimaryHex", "// MARK: accent"), "AgentProviderBrand");
  const n = assertArmsEqual(sw, cs, "primary");
  assert.equal(n, 37, `expected 37 providers, got ${n}`);
});

test("accent(for:) — all 37 providers match Swift", () => {
  const sw = swiftArms(
    region(designSwift, "static func accent(for provider: AgentProvider) -> Color {", "static func chartPalette"),
    PROVIDER_MAP
  );
  const cs = csArms(region(providerCs, "public static string AccentHex", "// MARK: colorForModel"), "AgentProviderBrand");
  const n = assertArmsEqual(sw, cs, "accent");
  assert.equal(n, 37, `expected 37 providers, got ${n}`);
});

test("LLMModelBrand.emblemColor — every brand matches Swift", () => {
  const sw = swiftArms(
    region(brandSwift, "var emblemColor: Color {", "var sfSymbolFallback"),
    BRAND_MAP
  );
  const cs = csArms(region(providerCs, "public static string EmblemHex", "// MARK: LLMModelBrand.infer"), "LLMModelBrand");
  const n = assertArmsEqual(sw, cs, "emblem");
  assert.ok(n >= 19, `expected >=19 brands, got ${n}`);
});

test("colorForModel — known-family colors match in the same order", () => {
  const swBlock = region(designSwift, "static func colorForModel(_ modelName: String) -> Color {", "static func gradientForModel");
  const palIdx = swBlock.indexOf("let palette:");
  const swKnown = [...swBlock.slice(0, palIdx).matchAll(/Color\(hex:\s*"([0-9A-Fa-f]{6})"\)/g)].map((m) => m[1].toUpperCase());

  const csBlock = region(providerCs, "public static string ColorForModel(string modelName)", "// MARK: LLMModelBrand.emblemColor");
  const csKnown = [...csBlock.matchAll(/return\s+"#([0-9A-Fa-f]{6})"/g)].map((m) => m[1].toUpperCase());

  assert.deepEqual(csKnown, swKnown, "colorForModel known-family color sequence drifted");
  assert.equal(swKnown.length, 16, `expected 16 known-family arms, got ${swKnown.length}`);
});

test("colorForModel — fallback palette matches in the same order", () => {
  const swBlock = region(designSwift, "let palette: [Color] = [", "]");
  const swPal = [...swBlock.matchAll(/Color\(hex:\s*"([0-9A-Fa-f]{6})"\)/g)].map((m) => m[1].toUpperCase());

  const csBlock = region(providerCs, "private static readonly string[] ModelFallbackPalette", "};");
  const csPal = [...csBlock.matchAll(/"#([0-9A-Fa-f]{6})"/g)].map((m) => m[1].toUpperCase());

  assert.deepEqual(csPal, swPal, "colorForModel fallback palette drifted");
  assert.equal(swPal.length, 12, `expected 12 palette colors, got ${swPal.length}`);
});
