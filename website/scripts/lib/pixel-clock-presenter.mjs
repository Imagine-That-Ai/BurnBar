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
 * Pixel-art provider marks, painted into the leftmost 9 columns of the
 * matrix. Verbatim spirit-of-the-Swift `PixelClockQuotaRenderer`. Each
 * provider gets a recognizable 5×5 silhouette + 2 trailing letter glyphs.
 */
const PROVIDER_LOGOS = {
  anthropic: { hex: "#c79a6c", shape: [
    // a stylized "A" wedge
    [0,0,1,0,0],
    [0,1,1,1,0],
    [0,1,0,1,0],
    [1,1,1,1,1],
    [1,0,0,0,1],
  ]},
  openai: { hex: "#f6f1e7", shape: [
    // hex-like rosette
    [0,1,1,1,0],
    [1,0,0,0,1],
    [1,0,1,0,1],
    [1,0,0,0,1],
    [0,1,1,1,0],
  ]},
  google: { hex: "#f6f1e7", shape: [
    [0,1,1,1,1],
    [1,0,0,0,0],
    [1,0,1,1,1],
    [1,0,0,0,1],
    [0,1,1,1,1],
  ]},
  zai: { hex: "#ffb547", shape: [
    [1,1,1,1,1],
    [0,0,0,1,0],
    [0,0,1,0,0],
    [0,1,0,0,0],
    [1,1,1,1,1],
  ]},
  minimax: { hex: "#ff6a1a", shape: [
    [1,0,0,0,1],
    [1,1,0,1,1],
    [1,0,1,0,1],
    [1,0,0,0,1],
    [1,0,0,0,1],
  ]},
  kimi: { hex: "#1d75ff", shape: [
    [1,0,0,0,1],
    [1,0,0,1,0],
    [1,1,1,0,0],
    [1,0,0,1,0],
    [1,0,0,0,1],
  ]},
  deepseek: { hex: "#aeacba", shape: [
    [0,1,1,1,0],
    [1,0,0,0,1],
    [1,0,1,0,1],
    [1,0,0,0,1],
    [0,1,1,1,0],
  ]},
  default: { hex: "#d6d3df", shape: [
    [0,1,1,1,0],
    [1,0,0,0,1],
    [1,0,0,0,1],
    [1,0,0,0,1],
    [0,1,1,1,0],
  ]},
};

function logoFor(providerID) {
  const id = String(providerID ?? "").toLowerCase();
  if (id.includes("claude") || id.includes("anthropic")) return PROVIDER_LOGOS.anthropic;
  if (id.includes("openai") || id.includes("gpt") || id.includes("codex")) return PROVIDER_LOGOS.openai;
  if (id.includes("google") || id.includes("gemini")) return PROVIDER_LOGOS.google;
  if (id.includes("zai") || id.includes("glm") || id.includes("z.ai")) return PROVIDER_LOGOS.zai;
  if (id.includes("minimax")) return PROVIDER_LOGOS.minimax;
  if (id.includes("kimi") || id.includes("moonshot")) return PROVIDER_LOGOS.kimi;
  if (id.includes("deepseek")) return PROVIDER_LOGOS.deepseek;
  return PROVIDER_LOGOS.default;
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

export function paintProviderLogo(grid, item) {
  const logo = logoFor(item?.providerID);
  for (let r = 0; r < logo.shape.length; r++) {
    for (let c = 0; c < logo.shape[r].length; c++) {
      if (logo.shape[r][c] === 1 && inBounds(r + 1, c + 1)) {
        grid[r + 1][c + 1] = pixel(true, logo.hex);
      }
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
