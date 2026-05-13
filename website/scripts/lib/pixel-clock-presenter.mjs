/**
 * @fileoverview JS port of OpenBurnBarCore's `PixelClockFramePresenter`.
 *
 * The source is at:
 *   `OpenBurnBarCore/Sources/OpenBurnBarCore/Views/PixelClockPreviewView.swift`
 *
 * Behavior MUST match the Swift implementation pixel-for-pixel. The Swift
 * file is the source of truth — when the Swift code changes, port the new
 * glyphs / layouts here and update `test-platform-mockups.mjs`.
 *
 * Used by:
 *   - `<PixelMatrix>` Astro component for SSR
 *   - `/public/platform-mockups.js` for runtime ticking
 *   - `scripts/test-platform-mockups.mjs` for parity assertions
 */

export const COLUMNS = 32;
export const ROWS = 8;

/** Palettes mirroring the Swift `PixelClockPalette` enum. */
export const PALETTES = Object.freeze({
  emberWhimsy: { primary: "#ff6a1a", secondary: "#d6d3df", hot: "#ff6a1a" },
  mercury: { primary: "#d6d3df", secondary: "#aeacba", hot: "#ff6a1a" },
  traffic: { primary: "#6fd189", secondary: "#ffc861", hot: "#e5483c" },
  monochrome: { primary: "#f6f1e7", secondary: "#aeacba", hot: "#ff6a1a" },
  rainbow: { primary: "#ff6a1a", secondary: "#d6d3df", hot: "#e5483c" },
});

/** A single pixel in the matrix. */
export function pixel(isLit, color) {
  return { isLit: Boolean(isLit), color: color ?? "transparent" };
}

export const PIXEL_OFF = pixel(false, "transparent");

export function blankGrid() {
  return Array.from({ length: ROWS }, () =>
    Array.from({ length: COLUMNS }, () => PIXEL_OFF)
  );
}

// ─────────────────────────────────── 3×5 glyphs (verbatim port) ────────────

const GLYPH_3X5 = {
  "0": [[1,1,1],[1,0,1],[1,0,1],[1,0,1],[1,1,1]],
  "1": [[0,1,0],[1,1,0],[0,1,0],[0,1,0],[1,1,1]],
  "2": [[1,1,1],[0,0,1],[1,1,1],[1,0,0],[1,1,1]],
  "3": [[1,1,1],[0,0,1],[1,1,1],[0,0,1],[1,1,1]],
  "4": [[1,0,1],[1,0,1],[1,1,1],[0,0,1],[0,0,1]],
  "5": [[1,1,1],[1,0,0],[1,1,1],[0,0,1],[1,1,1]],
  "6": [[1,1,1],[1,0,0],[1,1,1],[1,0,1],[1,1,1]],
  "7": [[1,1,1],[0,0,1],[0,1,0],[0,1,0],[0,1,0]],
  "8": [[1,1,1],[1,0,1],[1,1,1],[1,0,1],[1,1,1]],
  "9": [[1,1,1],[1,0,1],[1,1,1],[0,0,1],[1,1,1]],
  "%": [[1,0,1],[0,0,1],[0,1,0],[1,0,0],[1,0,1]],
  "!": [[1,0,0],[1,0,0],[1,0,0],[0,0,0],[1,0,0]],
  "A": [[0,1,0],[1,0,1],[1,1,1],[1,0,1],[1,0,1]],
  "B": [[1,1,0],[1,0,1],[1,1,0],[1,0,1],[1,1,0]],
  "C": [[0,1,1],[1,0,0],[1,0,0],[1,0,0],[0,1,1]],
  "D": [[1,1,0],[1,0,1],[1,0,1],[1,0,1],[1,1,0]],
  "E": [[1,1,1],[1,0,0],[1,1,0],[1,0,0],[1,1,1]],
  "F": [[1,1,1],[1,0,0],[1,1,0],[1,0,0],[1,0,0]],
  "G": [[0,1,1],[1,0,0],[1,0,1],[1,0,1],[0,1,1]],
  "H": [[1,0,1],[1,0,1],[1,1,1],[1,0,1],[1,0,1]],
  "I": [[1,1,1],[0,1,0],[0,1,0],[0,1,0],[1,1,1]],
  "J": [[0,0,1],[0,0,1],[0,0,1],[1,0,1],[0,1,0]],
  "K": [[1,0,1],[1,1,0],[1,0,0],[1,1,0],[1,0,1]],
  "L": [[1,0,0],[1,0,0],[1,0,0],[1,0,0],[1,1,1]],
  "M": [[1,0,1],[1,1,1],[1,1,1],[1,0,1],[1,0,1]],
  "N": [[1,0,1],[1,1,1],[1,1,1],[1,1,1],[1,0,1]],
  "O": [[0,1,0],[1,0,1],[1,0,1],[1,0,1],[0,1,0]],
  "P": [[1,1,0],[1,0,1],[1,1,0],[1,0,0],[1,0,0]],
  "Q": [[0,1,0],[1,0,1],[1,0,1],[1,1,1],[0,1,1]],
  "R": [[1,1,0],[1,0,1],[1,1,0],[1,0,1],[1,0,1]],
  "S": [[0,1,1],[1,0,0],[0,1,0],[0,0,1],[1,1,0]],
  "T": [[1,1,1],[0,1,0],[0,1,0],[0,1,0],[0,1,0]],
  "U": [[1,0,1],[1,0,1],[1,0,1],[1,0,1],[1,1,1]],
  "V": [[1,0,1],[1,0,1],[1,0,1],[1,0,1],[0,1,0]],
  "W": [[1,0,1],[1,0,1],[1,1,1],[1,1,1],[1,0,1]],
  "X": [[1,0,1],[1,0,1],[0,1,0],[1,0,1],[1,0,1]],
  "Y": [[1,0,1],[1,0,1],[0,1,0],[0,1,0],[0,1,0]],
  "Z": [[1,1,1],[0,0,1],[0,1,0],[1,0,0],[1,1,1]],
};

const BLANK_3X5 = [[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0]];

export function glyph3x5(ch) {
  const key = String(ch).toUpperCase();
  return GLYPH_3X5[key] ?? BLANK_3X5;
}

// ─────────────────────────────────── 6×7 big glyphs ────────────────────────

const GLYPH_6X7 = {
  "0": [
    [0,1,1,1,1,0],
    [1,0,0,0,0,1],
    [1,0,0,0,1,1],
    [1,0,0,1,0,1],
    [1,1,0,0,0,1],
    [1,0,0,0,0,1],
    [0,1,1,1,1,0],
  ],
  "1": [
    [0,0,1,1,0,0],
    [0,1,1,1,0,0],
    [0,0,1,1,0,0],
    [0,0,1,1,0,0],
    [0,0,1,1,0,0],
    [0,0,1,1,0,0],
    [0,1,1,1,1,0],
  ],
  "2": [
    [0,1,1,1,1,0],
    [1,0,0,0,0,1],
    [0,0,0,0,1,0],
    [0,0,0,1,0,0],
    [0,0,1,0,0,0],
    [0,1,0,0,0,0],
    [1,1,1,1,1,1],
  ],
  "3": [
    [0,1,1,1,1,0],
    [1,0,0,0,0,1],
    [0,0,0,0,0,1],
    [0,0,1,1,1,0],
    [0,0,0,0,0,1],
    [1,0,0,0,0,1],
    [0,1,1,1,1,0],
  ],
  "4": [
    [0,0,0,0,1,0],
    [0,0,0,1,1,0],
    [0,0,1,0,1,0],
    [0,1,0,0,1,0],
    [1,1,1,1,1,1],
    [0,0,0,0,1,0],
    [0,0,0,0,1,0],
  ],
  "5": [
    [1,1,1,1,1,1],
    [1,0,0,0,0,0],
    [1,0,0,0,0,0],
    [1,1,1,1,1,0],
    [0,0,0,0,0,1],
    [1,0,0,0,0,1],
    [0,1,1,1,1,0],
  ],
  "6": [
    [0,0,1,1,1,0],
    [0,1,0,0,0,0],
    [1,0,0,0,0,0],
    [1,1,1,1,1,0],
    [1,0,0,0,0,1],
    [1,0,0,0,0,1],
    [0,1,1,1,1,0],
  ],
  "7": [
    [1,1,1,1,1,1],
    [0,0,0,0,0,1],
    [0,0,0,0,1,0],
    [0,0,0,1,0,0],
    [0,0,1,0,0,0],
    [0,1,0,0,0,0],
    [1,0,0,0,0,0],
  ],
  "8": [
    [0,1,1,1,1,0],
    [1,0,0,0,0,1],
    [1,0,0,0,0,1],
    [0,1,1,1,1,0],
    [1,0,0,0,0,1],
    [1,0,0,0,0,1],
    [0,1,1,1,1,0],
  ],
  "9": [
    [0,1,1,1,1,0],
    [1,0,0,0,0,1],
    [1,0,0,0,0,1],
    [0,1,1,1,1,1],
    [0,0,0,0,0,1],
    [0,0,0,0,1,0],
    [0,1,1,1,0,0],
  ],
};

const BLANK_6X7 = Array.from({ length: 7 }, () => [0,0,0,0,0,0]);

export function glyph6x7(ch) {
  return GLYPH_6X7[String(ch)] ?? BLANK_6X7;
}

// ─────────────────────────────────── Provider logos (5×5) ──────────────────

/**
 * Provider logos — verbatim port of `PixelClockProviderLogoAssets.generated.swift`.
 *
 * Each entry is an 8×8 multi-color pixel array (row-major, [rows][columns]).
 * `null` means transparent (skip), hex string means a lit pixel of that color.
 * Logos paint at column 0, row 0 — taking the leftmost 8 columns × all 8 rows
 * of the 32×8 matrix, exactly like the Swift source. Layouts (carousel /
 * dashboard) place spinners + glyphs starting at column 10 to avoid overlap.
 *
 * DO NOT hand-edit shapes here. Regenerate via:
 *   `python3 scripts/generate-pixel-clock-logos.py`
 * in the OpenBurnBarCore Swift project, then copy the new arrays across.
 */
const PROVIDER_LOGOS = Object.freeze({
  claudeCode: [
    [null, null, null, null, null, null, null, null],
    [null, "#D97757", "#D97757", "#D97757", "#D97757", "#D97757", "#D97757", null],
    [null, "#D97757", "#1A1208", "#D97757", "#D97757", "#1A1208", "#D97757", null],
    ["#D97757", "#D97757", "#D97757", "#D97757", "#D97757", "#D97757", "#D97757", "#D97757"],
    ["#D97757", "#D97757", "#D97757", "#D97757", "#D97757", "#D97757", "#D97757", "#D97757"],
    ["#D97757", null, "#D97757", null, null, "#D97757", null, "#D97757"],
    ["#D97757", null, "#D97757", null, null, "#D97757", null, "#D97757"],
    [null, null, null, null, null, null, null, null],
  ],
  codex: [
    [null, null, "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", null, null],
    [null, "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", null],
    ["#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF"],
    ["#8EA0FF", "#8EA0FF", "#FFFFFF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF"],
    ["#8EA0FF", "#8EA0FF", "#8EA0FF", "#FFFFFF", "#8EA0FF", "#8EA0FF", "#8EA0FF", "#8EA0FF"],
    ["#8EA0FF", "#8EA0FF", "#FFFFFF", "#8EA0FF", "#8EA0FF", "#FFFFFF", "#FFFFFF", "#FFFFFF"],
    [null, "#4258FF", "#4258FF", "#4258FF", "#4258FF", "#4258FF", "#4258FF", null],
    [null, null, "#4258FF", "#4258FF", "#4258FF", "#4258FF", null, null],
  ],
  copilot: [
    [null, "#0F4E70", "#1A80B6", "#187DB4", "#1050A2", "#091F60", null, null],
    ["#05293E", "#118BD1", "#1397E1", "#148FDD", "#1558D0", "#1652BA", "#031121", null],
    ["#1B656E", "#2BA1AF", "#2EA3A9", "#257F90", "#172C62", "#675CBC", "#7350AF", "#572E73"],
    ["#529F62", "#60B46C", "#66B666", "#305A32", "#381429", "#C64FAF", "#BB51CC", "#B24FCB"],
    ["#A5BB36", "#AFC033", "#ABB92D", "#2A310B", "#762D45", "#E55898", "#D954A7", "#BC4A97"],
    ["#6C610A", "#AC8D13", "#D19422", "#75341D", "#CD5E5E", "#F46A80", "#F16187", "#963B57"],
    [null, null, "#D26238", "#F36544", "#F88D61", "#F9886D", "#E6756A", "#452121"],
    [null, null, "#67251B", "#B05634", "#BA7B40", "#BA7445", "#72442D", null],
  ],
  miniMax: [
    ["#EC1970", null, null, "#EC1970", "#EC1970", null, null, "#EC1970"],
    ["#EC1970", "#EC1970", null, "#EC1970", "#EC1970", null, "#EC1970", "#EC1970"],
    ["#EC1970", "#EC1970", "#EC1970", "#EC1970", "#EC1970", "#EC1970", "#EC1970", "#EC1970"],
    ["#EC1970", null, null, "#EC1970", "#EC1970", null, null, "#EC1970"],
    ["#FF5B3F", null, null, "#FF5B3F", "#FF5B3F", null, null, "#FF5B3F"],
    ["#FF5B3F", "#FF5B3F", null, "#FF5B3F", "#FF5B3F", null, "#FF5B3F", "#FF5B3F"],
    ["#FF5B3F", "#FF5B3F", "#FF5B3F", "#FF5B3F", "#FF5B3F", "#FF5B3F", "#FF5B3F", "#FF5B3F"],
    ["#FF5B3F", null, null, "#FF5B3F", "#FF5B3F", null, null, "#FF5B3F"],
  ],
  zai: [
    ["#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF", null],
    ["#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF", null],
    [null, null, null, null, "#FFFFFF", "#FFFFFF", "#FFFFFF", null],
    [null, null, null, "#FFFFFF", "#FFFFFF", "#FFFFFF", null, null],
    [null, null, "#FFFFFF", "#FFFFFF", "#FFFFFF", null, null, null],
    [null, "#FFFFFF", "#FFFFFF", "#FFFFFF", null, null, null, null],
    [null, "#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF"],
    [null, "#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF", "#C9B6FF"],
  ],
  factory: [
    [null, null, null, "#FFFFFF", null, null, null, null],
    [null, "#FFFFFF", null, "#FFFFFF", null, "#FFFFFF", null, null],
    ["#FFFFFF", null, "#FFFFFF", null, "#FFFFFF", null, "#FFFFFF", null],
    [null, "#FFFFFF", "#FFFFFF", "#B8B8B8", "#FFFFFF", "#FFFFFF", null, null],
    ["#FFFFFF", null, "#FFFFFF", null, "#FFFFFF", null, "#FFFFFF", null],
    [null, "#FFFFFF", null, "#FFFFFF", null, "#FFFFFF", null, null],
    [null, null, null, "#FFFFFF", null, null, null, null],
    [null, null, null, null, null, null, null, null],
  ],
  cursor: [
    [null, null, null, null, null, null, null, null],
    [null, null, null, "#FFFFFF", "#FFFFFF", null, null, null],
    [null, null, "#FFFFFF", "#AEB7C2", "#AEB7C2", "#FFFFFF", null, null],
    [null, "#FFFFFF", "#AEB7C2", "#30343A", "#7F8790", "#FFFFFF", null, null],
    [null, null, "#30343A", "#30343A", "#7F8790", null, null, null],
    [null, null, null, "#30343A", null, null, null, null],
    [null, null, null, null, null, null, null, null],
    [null, null, null, null, null, null, null, null],
  ],
  warp: [
    ["#FFFFFF", "#FBFBFB", "#F4F5F6", "#F4F5F6", "#F5F6F7", "#F5F6F7", "#FBFBFB", "#FFFFFF"],
    ["#FCFCFC", "#DCE0E3", "#D0D6DA", "#CFD5D9", "#D0D6DA", "#D0D6DA", "#DCE0E3", "#FBFCFC"],
    ["#F6F7F8", "#CCD2D6", "#ADB2B6", "#A1A6AA", "#6E7173", "#777A7C", "#C4C9CD", "#F6F7F8"],
    ["#F5F6F7", "#B3B8BC", "#3B3C3D", "#47494A", "#282828", "#373838", "#B2B7BB", "#F5F6F7"],
    ["#F4F5F6", "#ACB1B4", "#313233", "#4B4C4D", "#323333", "#494A4B", "#B4B9BD", "#F4F5F6"],
    ["#F4F5F6", "#C1C6CA", "#787B7D", "#8C8F92", "#ADB1B5", "#BBC0C4", "#CFD5D9", "#F3F5F5"],
    ["#FBFCFC", "#E3E8EB", "#D4DADE", "#D2D8DC", "#D8DEE2", "#D6DCE0", "#E1E6E9", "#FBFCFC"],
    ["#FFFFFF", "#FCFCFC", "#F5F7F7", "#F5F7F7", "#F6F7F8", "#F6F8F8", "#FCFCFD", "#FFFFFF"],
  ],
  ollama: [
    [null, null, "#F6F8FF", null, null, null, null, null],
    [null, "#F6F8FF", "#F6F8FF", "#F6F8FF", null, null, null, null],
    [null, null, "#F6F8FF", "#F6F8FF", "#F6F8FF", "#F6F8FF", null, null],
    [null, null, "#F6F8FF", "#1EA7FF", "#F6F8FF", "#F6F8FF", null, null],
    [null, null, "#F6F8FF", "#F6F8FF", "#F6F8FF", "#0B0B0B", null, null],
    [null, null, null, "#F6F8FF", "#F6F8FF", "#F6F8FF", null, null],
    [null, null, null, "#F6F8FF", "#F6F8FF", null, null, null],
    [null, null, null, "#F6F8FF", "#F6F8FF", null, null, null],
  ],
  kimi: [
    [null, null, null, null, null, null, "#0A2E57", "#136CD2"],
    [null, "#919191", null, null, "#828282", "#858585", "#0F1C2B", "#052040"],
    ["#252525", "#C2C2C2", "#2F2F2F", "#8B8B8B", "#C2C2C2", "#2D2D2D", null, null],
    ["#242424", "#C9C9C9", "#B2B2B2", "#D7D7D7", "#303030", null, null, null],
    ["#232323", "#DFDFDF", "#DDDDDD", "#D3D3D3", "#8D8D8D", null, null, null],
    ["#242424", "#CDCDCD", "#404040", "#313131", "#B8B8B8", "#C3C3C3", "#2F2F2F", null],
    [null, "#7C7C7C", null, null, null, "#6F6F6F", "#343434", null],
    [null, null, null, null, null, null, null, null],
  ],
});

/**
 * Match a quota item to its 8×8 logo asset. Mirrors the matching order in
 * `PixelClockQuotaRenderer.providerLogo(for:)` — both providerID and
 * providerName participate in the token, and order is significant
 * (specific brand keys before generic terms).
 */
function logoFor(item) {
  const token = `${item?.providerID ?? ""} ${item?.providerName ?? ""}`.toLowerCase();
  if (token.includes("claude")) return PROVIDER_LOGOS.claudeCode;
  if (token.includes("codex")) return PROVIDER_LOGOS.codex;
  if (token.includes("factory") || token.includes("droid")) return PROVIDER_LOGOS.factory;
  if (token.includes("cursor")) return PROVIDER_LOGOS.cursor;
  if (token.includes("warp")) return PROVIDER_LOGOS.warp;
  if (token.includes("copilot")) return PROVIDER_LOGOS.copilot;
  if (token.includes("kimi") || token.includes("moonshot")) return PROVIDER_LOGOS.kimi;
  if (token.includes("ollama")) return PROVIDER_LOGOS.ollama;
  if (token.includes("minimax")) return PROVIDER_LOGOS.miniMax;
  if (token.includes("z.ai") || token.includes("zai")) return PROVIDER_LOGOS.zai;
  return monogramLogoFor(item);
}

function shortProviderCode(item) {
  const token = `${item?.providerID ?? ""} ${item?.providerName ?? ""}`.toLowerCase();
  if (token.includes("claude")) return "CLD";
  if (token.includes("codex")) return "CDX";
  if (token.includes("factory") || token.includes("droid")) return "FAC";
  if (token.includes("copilot")) return "COP";
  if (token.includes("minimax")) return "MMX";
  if (token.includes("cursor")) return "CUR";
  if (token.includes("warp")) return "WRP";
  if (token.includes("ollama")) return "OLL";
  if (token.includes("kimi")) return "KIM";
  if (token.includes("z.ai") || token.includes("zai")) return "ZAI";
  const normalized = String(item?.providerName ?? "")
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
  return normalized.slice(0, 3) || "OBB";
}

function monogramLogoFor(item) {
  const rows = Array.from({ length: 8 }, () => Array.from({ length: 8 }, () => null));
  const chars = [...shortProviderCode(item).toUpperCase()].slice(0, 2);
  chars.forEach((char, index) => {
    const glyph = glyph3x5(char);
    const x = index === 0 ? 0 : 4;
    const color = index === 0 ? "#FAFAFA" : "#A0A0A0";
    for (let row = 0; row < glyph.length; row++) {
      for (let column = 0; column < glyph[row].length; column++) {
        if (glyph[row][column] === 1) rows[row + 1][x + column] = color;
      }
    }
  });
  return rows;
}

// ─────────────────────────────────── Painters ──────────────────────────────

function inBounds(row, col) {
  return row >= 0 && row < ROWS && col >= 0 && col < COLUMNS;
}

export function paintGlyph(grid, char, originColumn, originRow, color) {
  const g = glyph3x5(char);
  for (let r = 0; r < g.length; r++) {
    const row = originRow + r;
    for (let c = 0; c < g[r].length; c++) {
      const col = originColumn + c;
      if (!inBounds(row, col)) continue;
      if (g[r][c] === 1) grid[row][col] = pixel(true, color);
    }
  }
}

export function paintBigGlyph(grid, char, originColumn, color) {
  const g = glyph6x7(char);
  for (let r = 0; r < g.length; r++) {
    for (let c = 0; c < g[r].length; c++) {
      const col = originColumn + c;
      if (!inBounds(r, col)) continue;
      if (g[r][c] === 1) grid[r][col] = pixel(true, color);
    }
  }
}

/**
 * Paint the 8×8 multi-color provider logo at native position (col 0, row 0),
 * matching `PixelClockPreviewView.paintProviderLogo(for:into:)`. Null cells
 * are skipped so the background stays unlit; cells with a hex string are
 * painted as lit pixels using that color (no recoloring).
 */
export function paintProviderLogo(grid, item) {
  const logo = logoFor(item);
  if (!logo) return;
  for (let r = 0; r < logo.length; r++) {
    for (let c = 0; c < logo[r].length; c++) {
      const color = logo[r][c];
      if (color == null) continue;
      if (!inBounds(r, c)) continue;
      grid[r][c] = pixel(true, color);
    }
  }
}

// Spinner (4 styles)
export function paintSpinner(grid, style, originColumn, originRow, primary, secondary, tick) {
  const t = Math.abs(tick);
  let points;
  switch (style) {
    case "chase":
      points = [0,1,2,3].map((i) => [i, 1, (i + t) % 2 === 0 ? secondary : primary]);
      break;
    case "pulse":
      points = [[1,1,primary],[2,1,secondary],[1,2,secondary],[2,2,primary]];
      break;
    case "scan":
      points = [[t % 4, 0, secondary], [(t+1) % 4, 1, primary], [(t+2) % 4, 2, primary]];
      break;
    case "orbit":
    default: {
      const orbit = [[1,0],[3,1],[2,3],[0,2]];
      const active = t % orbit.length;
      points = orbit.map((pt, i) => [pt[0], pt[1], i === active ? secondary : primary]);
      break;
    }
  }
  for (const [dc, dr, color] of points) {
    const row = originRow + dr;
    const col = originColumn + dc;
    if (!inBounds(row, col)) continue;
    grid[row][col] = pixel(true, color);
  }
}

// ─────────────────────────────────── Layouts ───────────────────────────────

const PALETTE = PALETTES.emberWhimsy;

/**
 * Layout 1 — provider dashboard. Logo on the left, window label + remaining
 * bar on the right, single provider at a time, rotates with `tick`.
 */
export function providerDashboardFrame(items, tick = 0, palette = PALETTE) {
  const grid = blankGrid();
  if (!items || items.length === 0) {
    return { grid, accessibilityLabel: "Pixel clock preview, idle" };
  }
  const item = items[Math.abs(tick) % items.length];
  paintProviderLogo(grid, item);

  if (Math.abs(tick) % 2 === 0) {
    paintSpinner(grid, "orbit", 10, 1, palette.primary, palette.secondary, tick);
  }

  const window = normalizeWindowLabel(item.windowLabel);
  for (let i = 0; i < window.length; i++) {
    paintGlyph(grid, window[i], Math.max(20, 32 - window.length * 4) + i * 4, 1, palette.primary);
  }

  const remaining = Math.max(0, Math.min(100, 100 - (item.percentUsed ?? 0)));
  const filled = Math.max(0, Math.min(19, Math.round((remaining / 100) * 19)));
  for (let c = 0; c < filled; c++) {
    grid[7][c + 12] = pixel(true, palette.primary);
  }
  return {
    grid,
    accessibilityLabel: `Pixel clock preview, provider dashboard, ${item.providerName ?? "provider"} ${remaining} percent remaining`,
  };
}

/**
 * Layout 2 — quota carousel: logo, top bar, big digits + percent.
 */
export function quotaCarouselFrame(items, tick = 0, palette = PALETTE) {
  const grid = blankGrid();
  if (!items || items.length === 0) {
    return { grid, accessibilityLabel: "Pixel clock preview, carousel idle" };
  }
  const item = items[Math.abs(tick) % items.length];
  paintProviderLogo(grid, item);

  const remaining = Math.max(0, Math.min(100, 100 - (item.percentUsed ?? 0)));
  const barWidth = 21;
  const barColumns = Math.max(0, Math.min(barWidth, Math.round((remaining / 100) * barWidth)));
  const hot = (item.percentUsed ?? 0) >= 85;
  const barColor = hot ? PALETTES.emberWhimsy.primary : palette.primary;
  for (let c = 0; c < barColumns; c++) {
    grid[1][c + 10] = pixel(true, barColor);
  }

  const pct = Math.max(0, Math.min(99, remaining));
  paintGlyph(grid, String(Math.floor(pct / 10)), 17, 3, palette.primary);
  paintGlyph(grid, String(pct % 10), 21, 3, palette.primary);
  paintGlyph(grid, "%", 25, 3, palette.secondary);
  return {
    grid,
    accessibilityLabel: `Pixel clock preview, quota carousel, ${item.providerName ?? "provider"} ${remaining} percent remaining`,
  };
}

/**
 * Layout 3 — burn status: huge central number, mini bars on the right.
 */
export function burnStatusFrame(items, palette = PALETTE) {
  const grid = blankGrid();
  const mainItem = (items && items[0]) || { providerName: "BURN", percentUsed: 0 };
  const pct = Math.max(0, Math.min(99, 100 - (mainItem.percentUsed ?? 0)));
  paintBigGlyph(grid, String(Math.floor(pct / 10)), 4, palette.primary);
  paintBigGlyph(grid, String(pct % 10), 12, palette.primary);
  paintGlyph(grid, "%", 20, 2, palette.secondary);

  const peers = (items || []).slice(0, 4);
  for (let i = 0; i < peers.length; i++) {
    const item = peers[i];
    const col = 26 + i;
    const remaining = Math.max(0, 100 - (item.percentUsed ?? 0));
    const height = Math.max(0, Math.min(6, Math.round((remaining / 100) * 6)));
    const hot = (item.percentUsed ?? 0) >= 85;
    const c = hot ? palette.primary : palette.secondary;
    for (let row = 0; row < 6; row++) {
      const isLit = (5 - row) < height;
      grid[row + 1][col] = pixel(isLit, isLit ? c : "transparent");
    }
  }
  return {
    grid,
    accessibilityLabel: `Pixel clock preview, burn status, ${pct} percent remaining`,
  };
}

/**
 * Layout 4 — alerts only: OK/!! glyph + hottest provider + bar.
 */
export function alertsOnlyFrame(items, palette = PALETTE) {
  const grid = blankGrid();
  const hottest = (items && items.length > 0)
    ? items.reduce((acc, x) => ((x.percentUsed ?? 0) > (acc.percentUsed ?? 0) ? x : acc), items[0])
    : { providerName: "OK", percentUsed: 0 };
  const isHot = (hottest.percentUsed ?? 0) >= 85;
  const warnColor = isHot ? palette.primary : palette.secondary;
  if (isHot) {
    paintGlyph(grid, "!", 2, 1, warnColor);
    paintGlyph(grid, "!", 6, 1, warnColor);
  } else {
    paintGlyph(grid, "O", 2, 1, warnColor);
    paintGlyph(grid, "K", 6, 1, warnColor);
  }
  const label = String(hottest.providerName ?? "").toUpperCase().slice(0, 4);
  for (let i = 0; i < label.length; i++) {
    paintGlyph(grid, label[i], 12 + i * 4, 1, palette.secondary);
  }
  const remaining = Math.max(0, 100 - (hottest.percentUsed ?? 0));
  const barColumns = Math.max(0, Math.min(30, Math.round((remaining / 100) * 30)));
  for (let c = 0; c < barColumns; c++) {
    grid[7][c + 1] = pixel(true, warnColor);
  }
  return {
    grid,
    accessibilityLabel: `Pixel clock preview, alerts, ${hottest.providerName ?? "OK"} ${remaining} percent remaining`,
  };
}

// ─────────────────────────────────── Helpers ───────────────────────────────

function normalizeWindowLabel(label) {
  if (!label) return "";
  const cleaned = String(label).toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (cleaned === "5H" || cleaned === "7D") return cleaned;
  return cleaned.slice(0, 2);
}

/**
 * Top-level entry — dispatches on layout. `items` is an array of
 * `{ providerID, providerName, percentUsed, usageText, windowLabel }`.
 */
export function buildFrame({ layout = "providerDashboard", items = [], tick = 0, palette = "emberWhimsy" }) {
  const pal = PALETTES[palette] ?? PALETTES.emberWhimsy;
  switch (layout) {
    case "quotaCarousel":
      return quotaCarouselFrame(items, tick, pal);
    case "burnStatus":
      return burnStatusFrame(items, pal);
    case "alertsOnly":
      return alertsOnlyFrame(items, pal);
    case "providerDashboard":
    default:
      return providerDashboardFrame(items, tick, pal);
  }
}

/** A deterministic default item set mirroring the Swift mock pool. */
export const DEFAULT_ITEMS = Object.freeze([
  { providerID: "claudecode", providerName: "CLD", percentUsed: 72, usageText: "72%", windowLabel: "5H" },
  { providerID: "codex", providerName: "CDX", percentUsed: 41, usageText: "41%", windowLabel: "5H" },
  { providerID: "zai", providerName: "ZAI", percentUsed: 88, usageText: "88%", windowLabel: "WK" },
  { providerID: "cursor", providerName: "CUR", percentUsed: 23, usageText: "23%", windowLabel: "MO" },
  { providerID: "minimax", providerName: "MMX", percentUsed: 60, usageText: "60%", windowLabel: "MO" },
]);
