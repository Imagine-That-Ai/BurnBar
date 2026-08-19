/**
 * Swarm Ember — living embers that condense into the BurnBar flame mark.
 *
 * The console default (`logoHero`) is a two-beat cycle: the flock murmurates
 * as a warm fire, then locks onto a precomputed sampling of the official
 * flame + bar-chart mark (color-accurate), holds with heat and tip-sparks,
 * and dissolves. The Linux/macOS dashboard cycle — provider glyphs, $,
 * rings, router — is unchanged behind `buildDashboardCycle`.
 */

import { curl2 } from "../noise/simplex";
import { mixRgb, toCss } from "../palette";
import {
  BURNBAR_LOGO_COUNT,
  BURNBAR_LOGO_PACKED,
  ROLE_FLAME,
  ROLE_TIP,
} from "./swarmEmberLogoData";
import { PROVIDER_SHAPE_POINTS } from "./swarmEmberShapeData";
import {
  normalizeSwarmProviderGlyphs,
  SWARM_PROVIDER_GLYPH_IDS,
  SWARM_PROVIDER_GLYPH_OPTIONS,
  type SwarmProviderGlyphId,
} from "./swarmCatalog";
import type {
  Kernel,
  KernelFrameContext,
  KernelPalette,
  KernelRenderingContext,
  RGB,
  ThemeName,
} from "../types";

// ── Pace ────────────────────────────────────────────────────────────────
const DASHBOARD_CYCLE_MS = 14_000;
const HERO_LOGO_MS = 16_000;
const HERO_SWARM_MS = 7_500;
const MOUSE_FORCE = 0.9;
const POINTER_REPULSE_R = 170;

const PARTICLE_DIVISOR = 620;
const PARTICLE_MIN = 980;
const PARTICLE_MAX = 1500;

const SWARM_CURL = 0.62;
const SWARM_RISE = 0.018;
const SWARM_DRAG = 0.962;
const SWARM_MAX_SPEED = 2.05;
const CURL_SCALE = 0.0015;
const CURL_TIME = 0.000065;
const HOME_PULL = 0.000055;

const MORPH_SPRING = 0.092;
const MORPH_NOISE = 0.01;
const MORPH_DRAG = 0.86;
const MORPH_MAX_SPEED = 2.15;

const EMBER_CORE: RGB = [250, 107, 6];
const EMBER_BRIGHT: RGB = [253, 196, 44];
const WARM_DARK: RGB = [18, 7, 3];
const SHAPE_BOOST = 1.55;

const LOGO_URLS = ["/brand/burnbar-logo-mark.png", "/provider-logos/openburnbar.png"];

const PROVIDER_ACCENTS: Record<string, RGB> = {
  openai: [16, 163, 127],
  anthropic: [204, 120, 92],
  google: [66, 133, 244],
  cursor: [0, 229, 255],
  ollama: [255, 255, 255],
  copilot: [255, 255, 255],
  deepseek: [77, 163, 255],
  codex: [250, 107, 6],
  opencode: [139, 92, 246],
  hermes: [200, 191, 181],
  xai: [255, 255, 255],
};

type FormationMode =
  | "swarm"
  | "shapeDollar"
  | "shapeCode"
  | "shapeBurnBarLogo"
  | "shapeRings"
  | "shapeRouterFlow"
  | { type: "shapeProviderLogo"; providers: string[] };

/** macOS SwarmFormationMode.defaultCycle(excludeBrandShapes: true) — [logo, swarm] per segment. */
const SHOWCASE_PROVIDER_IDS: string[] = [
  "factory",
  "claudecode",
  "codex",
  "opencode",
  "openclaw",
  "openclaude",
  "omp",
  "hermes",
  "geminicli",
  "junie",
  "antigravity",
  "openai",
  "openburnbar",
  "deepseek",
  "minimax",
  "zai",
  "xai",
  "mimo",
  "cursor",
  "copilot",
  "kimi",
  "aider",
  "cline",
  "kilocode",
  "roocode",
  "forgedev",
  "augment",
  "piagent",
  "goose",
  "ollama",
  "windsurf",
  "warp",
  "cursoragent",
];

const PROVIDER_LOGO_ASSETS: Record<string, string> = {
  claudecode: "claude-code.png",
  geminicli: "gemini.png",
  xai: "grok.png",
};

const providerLogoPointsCache = new Map<string, ShapePoint[]>();
const providerLogoLoadStarted = new Set<string>();

const SHAPE_PROVIDER_ALIASES: Record<string, string> = {
  claudecode: "anthropic",
  geminicli: "google",
  openai: "openai",
};

export type BurnBarLogoPoint = { x: number; y: number; rgb: RGB; role: number };

let unpackedLogo: BurnBarLogoPoint[] | null = null;

export function burnBarLogoPoints(): BurnBarLogoPoint[] {
  if (unpackedLogo) return unpackedLogo;
  const src = BURNBAR_LOGO_PACKED;
  const out: BurnBarLogoPoint[] = new Array(BURNBAR_LOGO_COUNT);
  let n = 0;
  for (let i = 0; i + 3 < src.length; i += 4) {
    const packed = src[i + 2]!;
    out[n++] = {
      x: src[i]!,
      y: src[i + 1]!,
      rgb: [(packed >> 16) & 255, (packed >> 8) & 255, packed & 255],
      role: src[i + 3]!,
    };
  }
  unpackedLogo = out;
  return out;
}

function shapeProviderKey(persistedId: string): string | null {
  const alias = SHAPE_PROVIDER_ALIASES[persistedId] ?? persistedId;
  const flat = PROVIDER_SHAPE_POINTS[alias];
  return flat && flat.length >= 2 ? alias : null;
}

function normalizedShowcaseProviders(providerGlyphs?: readonly string[]): string[] {
  const selected = normalizeSwarmProviderGlyphs(providerGlyphs);
  return SHOWCASE_PROVIDER_IDS.filter((id) => selected.includes(id as SwarmProviderGlyphId));
}

function providerLogoGroups(providerGlyphs?: readonly string[]): string[][] {
  const enabled = normalizedShowcaseProviders(providerGlyphs);
  const groups: string[][] = [];
  for (let i = 0; i < enabled.length; i += 2) {
    groups.push(enabled.slice(i, i + 2));
  }
  return groups;
}

export function buildDashboardCycle(
  providerGlyphs: readonly string[] | undefined,
  excludeBrandShapes: boolean,
  autoCycleShapes: boolean
): FormationMode[] {
  if (!autoCycleShapes) return ["swarm"];
  const logoModes: FormationMode[] = providerLogoGroups(providerGlyphs).map((providers) => ({
    type: "shapeProviderLogo",
    providers,
  }));
  if (excludeBrandShapes) {
    if (logoModes.length === 0) return ["swarm"];
    return logoModes.flatMap((mode) => [mode, "swarm"]);
  }
  return [
    "swarm",
    "shapeDollar",
    "swarm",
    "shapeCode",
    "swarm",
    "shapeBurnBarLogo",
    ...logoModes.flatMap((mode) => ["swarm" as const, mode]),
    "swarm",
    "shapeRings",
    "swarm",
    "shapeRouterFlow",
  ];
}

/** Console default: the official mark, then a murmur, forever. */
export function logoHeroCycle(): FormationMode[] {
  return ["shapeBurnBarLogo", "swarm"];
}

interface LogoSlot {
  centerX: number;
  centerY: number;
  scale: number;
}

function providerLogoSlots(count: number, w: number, h: number): LogoSlot[] {
  if (count <= 0) return [];
  if (count === 1) {
    return [
      {
        centerX: w > 960 ? w * 0.74 : w * 0.5,
        centerY: w > 960 ? h * 0.3 : h * 0.24,
        scale: Math.min(w, h) * 0.34,
      },
    ];
  }
  let maxColumns: number;
  if (w >= 1320) maxColumns = 5;
  else if (w >= 920) maxColumns = 4;
  else maxColumns = 2;
  const columns = Math.min(count, maxColumns);
  const rows = Math.ceil(count / columns);
  const xStep = Math.min(300, Math.max(180, (w * 0.78) / Math.max(columns - 1, 1)));
  const yStep = Math.min(210, Math.max(130, (h * 0.44) / Math.max(rows - 1, 1)));
  const gridHeight = yStep * Math.max(rows - 1, 0);
  const gridCenterY = h * (rows > 1 ? 0.4 : 0.34);
  const scale = Math.min(
    Math.min(w, h) * 0.32,
    Math.max(110, Math.min(xStep, rows > 1 ? yStep : h * 0.32) * 0.72)
  );
  const slots: LogoSlot[] = [];
  for (let index = 0; index < count; index++) {
    const row = Math.floor(index / columns);
    const column = index % columns;
    const rowCount = Math.min(columns, count - row * columns);
    const rowWidth = xStep * Math.max(rowCount - 1, 0);
    const x = w * 0.5 - rowWidth / 2 + xStep * column;
    const y = gridCenterY - gridHeight / 2 + yStep * row;
    slots.push({ centerX: x, centerY: y, scale });
  }
  return slots;
}

interface ShapePoint {
  x: number;
  y: number;
  role: string | null;
  progress: number;
  rgb?: RGB;
}

function flatToShapePoints(flat: number[]): ShapePoint[] {
  const pts: ShapePoint[] = [];
  for (let i = 0; i + 1 < flat.length; i += 2) {
    pts.push({
      x: flat[i]!,
      y: flat[i + 1]!,
      role: "logo-flame-inner",
      progress: Math.random(),
    });
  }
  return pts;
}

function providerLabel(providerId: string): string {
  return SWARM_PROVIDER_GLYPH_OPTIONS.find((option) => option.id === providerId)?.label ?? providerId;
}

function sampleTextPoints(text: string, fontSize: number): ShapePoint[] {
  if (typeof document === "undefined") return [];
  const side = 400;
  const canvas = document.createElement("canvas");
  canvas.width = side;
  canvas.height = side;
  const c = canvas.getContext("2d");
  if (!c) return [];

  c.fillStyle = "#000";
  c.fillRect(0, 0, side, side);
  c.fillStyle = "#fff";
  c.font = `600 ${fontSize}px ui-monospace, Menlo, monospace`;
  c.textAlign = "center";
  c.textBaseline = "middle";
  c.fillText(text, side / 2, side / 2);

  const data = c.getImageData(0, 0, side, side).data;
  const pts: ShapePoint[] = [];
  const gap = 6;
  for (let y = 0; y < side; y += gap) {
    for (let x = 0; x < side; x += gap) {
      const i = (y * side + x) * 4;
      if (data[i]! > 128) {
        pts.push({
          x: (x - side / 2) / (side / 2),
          y: -((y - side / 2) / (side / 2)),
          role: null,
          progress: Math.random(),
        });
      }
    }
  }
  return pts;
}

function providerTextFallbackPoints(providerId: string): ShapePoint[] {
  const words = providerLabel(providerId).split(/\s+/).filter(Boolean);
  const initials =
    words.length > 1
      ? words.map((word) => word[0]).join("").slice(0, 4)
      : providerLabel(providerId).replace(/[^a-z0-9]/gi, "").slice(0, 6);
  return sampleTextPoints(initials || "?", 150);
}

function imageToShapePoints(image: HTMLImageElement): ShapePoint[] {
  const side = 240;
  const canvas = document.createElement("canvas");
  canvas.width = side;
  canvas.height = side;
  const context = canvas.getContext("2d");
  if (!context) return [];
  context.clearRect(0, 0, side, side);
  const scale = Math.min(
    side / Math.max(image.naturalWidth || side, 1),
    side / Math.max(image.naturalHeight || side, 1)
  );
  const width = (image.naturalWidth || side) * scale;
  const height = (image.naturalHeight || side) * scale;
  context.drawImage(image, (side - width) / 2, (side - height) / 2, width, height);
  const pixels = context.getImageData(0, 0, side, side).data;
  const points: ShapePoint[] = [];
  const stride = 4;
  for (let y = 0; y < side; y += stride) {
    for (let x = 0; x < side; x += stride) {
      const offset = (y * side + x) * 4;
      const alpha = pixels[offset + 3] ?? 0;
      const luminance = (pixels[offset] ?? 0) + (pixels[offset + 1] ?? 0) + (pixels[offset + 2] ?? 0);
      if (alpha < 48 || luminance < 30) continue;
      points.push({
        x: (x - side / 2) / (side / 2),
        y: -((y - side / 2) / (side / 2)),
        role: "logo-flame-inner",
        progress: Math.random(),
        rgb: [pixels[offset] ?? 0, pixels[offset + 1] ?? 0, pixels[offset + 2] ?? 0],
      });
    }
  }
  return points;
}

function requestProviderLogoPoints(providerId: string, onReady: () => void): void {
  if (providerLogoLoadStarted.has(providerId) || typeof Image === "undefined") return;
  providerLogoLoadStarted.add(providerId);
  const image = new Image();
  image.onload = () => {
    const points = imageToShapePoints(image);
    if (points.length > 0) {
      providerLogoPointsCache.set(providerId, points);
      onReady();
    }
  };
  image.onerror = () => undefined;
  const asset = PROVIDER_LOGO_ASSETS[providerId] ?? `${providerId}.png`;
  image.src = `/provider-logos/${asset}`;
}

function providerShapePoints(providerId: string, onImageReady: () => void): ShapePoint[] {
  const key = shapeProviderKey(providerId);
  if (key) return flatToShapePoints(PROVIDER_SHAPE_POINTS[key]!);
  const cached = providerLogoPointsCache.get(providerId);
  if (cached) return cached;
  requestProviderLogoPoints(providerId, onImageReady);
  return providerTextFallbackPoints(providerId);
}

function generateRingPoints(numRings = 3): ShapePoint[] {
  const pts: ShapePoint[] = [];
  for (let ring = 0; ring < numRings; ring++) {
    const radius = 0.2 + ring * 0.25;
    const count = 80 + ring * 50;
    for (let i = 0; i < count; i++) {
      const angle = (i / count) * Math.PI * 2;
      pts.push({
        x: Math.cos(angle) * radius,
        y: Math.sin(angle) * radius,
        role: null,
        progress: Math.random(),
      });
    }
  }
  return pts;
}

function generateRouterFlowPoints(): ShapePoint[] {
  const pts: ShapePoint[] = [];
  const gatewayCount = 100;
  for (let i = 0; i < gatewayCount; i++) {
    const angle = (i / gatewayCount) * Math.PI * 2;
    const r = 0.08;
    pts.push({
      x: -0.45 + Math.cos(angle) * r,
      y: Math.sin(angle) * r,
      role: "gateway",
      progress: i / gatewayCount,
    });
  }
  const targets = [
    { x: 0.45, y: -0.28, role: "target-1" },
    { x: 0.45, y: 0.0, role: "target-2" },
    { x: 0.45, y: 0.28, role: "target-3" },
  ];
  for (const tgt of targets) {
    for (let i = 0; i < 50; i++) {
      const angle = (i / 50) * Math.PI * 2;
      const r = 0.05;
      pts.push({
        x: tgt.x + Math.cos(angle) * r,
        y: tgt.y + Math.sin(angle) * r,
        role: tgt.role,
        progress: i / 50,
      });
    }
  }
  for (let idx = 0; idx < targets.length; idx++) {
    const tgt = targets[idx]!;
    const pathRole = `path-${idx + 1}`;
    for (let i = 0; i < 60; i++) {
      const t = i / 60;
      const px = -0.45 + (tgt.x - -0.45) * t;
      const py = tgt.y * (3 * t * t - 2 * t * t * t);
      pts.push({ x: px, y: py, role: pathRole, progress: t });
    }
  }
  return pts;
}

function shuffleIndices(n: number): number[] {
  const idx = Array.from({ length: n }, (_, i) => i);
  for (let i = n - 1; i > 0; i--) {
    const j = (Math.random() * (i + 1)) | 0;
    const tmp = idx[i]!;
    idx[i] = idx[j]!;
    idx[j] = tmp;
  }
  return idx;
}

function punchWhite(image: HTMLImageElement): HTMLCanvasElement | null {
  const w = image.naturalWidth || image.width;
  const h = image.naturalHeight || image.height;
  if (!w || !h) return null;
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const g = canvas.getContext("2d");
  if (!g) return null;
  g.drawImage(image, 0, 0);
  const data = g.getImageData(0, 0, w, h);
  const px = data.data;
  for (let i = 0; i < px.length; i += 4) {
    const r = px[i] ?? 0;
    const gg = px[i + 1] ?? 0;
    const b = px[i + 2] ?? 0;
    const a = px[i + 3] ?? 0;
    const max = Math.max(r, gg, b);
    const min = Math.min(r, gg, b);
    const sat = max === 0 ? 0 : 1 - min / max;
    if (a < 16 || (max > 245 && sat < 0.08)) px[i + 3] = 0;
  }
  g.putImageData(data, 0, 0);
  return canvas;
}

export type SwarmEmberKernelOptions = {
  /** macOS SwarmCanvasView.enableSwarmSparkles — dashboard default false. */
  enableSwarmSparkles?: boolean;
  /** macOS SwarmCanvasView.motionSpeedMultiplier — clamped 0.35…2.5. */
  motionSpeedMultiplier?: number;
  /** Provider IDs selected in macOS Appearance > Customize Provider Glyphs. */
  providerGlyphs?: readonly string[];
  /** Include the non-provider $, code, BurnBar, rings, and router formations. */
  excludeBrandShapes?: boolean;
  /** Keep the formation cycle running; false leaves the field in swarm mode. */
  autoCycleShapes?: boolean;
  /** macOS clickDesktopToCycleSwarm equivalent for the Linux backdrop surface. */
  allowsClickCycle?: boolean;
  /**
   * Console hero: ignore the provider slideshow and cycle only
   * BurnBar flame mark ↔ murmurating swarm.
   */
  logoHero?: boolean;
};

function clampMotionSpeedMultiplier(value: number): number {
  return Math.min(2.5, Math.max(0.35, value));
}

function adjustRgb(rgb: RGB, lighten: number, darken: number, seed: number): RGB {
  const white: RGB = [255, 255, 255];
  const black: RGB = [0, 0, 0];
  const frac = seed - Math.floor(seed);
  const hot = mixRgb(rgb, white, lighten);
  const shadow = mixRgb(rgb, black, darken);
  return mixRgb(shadow, hot, frac);
}

function providerBrandRgb(providerId: string): RGB {
  const key = shapeProviderKey(providerId) ?? providerId;
  return PROVIDER_ACCENTS[key] ?? PROVIDER_ACCENTS[providerId] ?? [242, 242, 247];
}

function hotter(rgb: RGB, amount = 0.35): RGB {
  return mixRgb(rgb, [255, 236, 200], amount);
}

function animationFrameScale(elapsedSec: number | null): number {
  if (elapsedSec == null || !Number.isFinite(elapsedSec) || elapsedSec <= 0) return 1;
  return Math.min(4, Math.max(0.25, elapsedSec * 60));
}

function formationKind(mode: FormationMode): string {
  return typeof mode === "string" ? mode : mode.type;
}

function isProviderLogoMode(
  mode: FormationMode
): mode is { type: "shapeProviderLogo"; providers: string[] } {
  return typeof mode !== "string" && mode.type === "shapeProviderLogo";
}

interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  seed: number;
  home: number;
  tx: number | null;
  ty: number | null;
  tr: number;
  tg: number;
  tb: number;
  cr: number;
  cg: number;
  cb: number;
  role: number;
  roleStr: string | null;
  logoProviderId: string | null;
  slotIndex: number | null;
  flowProgress: number;
  opacity: number;
}

export function createSwarmEmberKernel(options: SwarmEmberKernelOptions = {}): Kernel {
  let ctx: CanvasRenderingContext2D | null = null;
  let width = 0;
  let height = 0;
  let dpr = 1;
  let palette: KernelPalette | null = null;
  let reducedMotion = false;
  const motionSpeedMultiplier = clampMotionSpeedMultiplier(options.motionSpeedMultiplier ?? 1);
  const enableSwarmSparkles = options.enableSwarmSparkles ?? false;
  const logoHero = options.logoHero === true;
  const providerGlyphs = options.providerGlyphs ?? SWARM_PROVIDER_GLYPH_IDS;
  const modeCycle: FormationMode[] = logoHero
    ? options.autoCycleShapes === false
      ? ["shapeBurnBarLogo"]
      : logoHeroCycle()
    : buildDashboardCycle(
        providerGlyphs,
        options.excludeBrandShapes ?? true,
        options.autoCycleShapes ?? true
      );
  const allowsClickCycle = options.allowsClickCycle ?? false;

  const logoPts = burnBarLogoPoints();

  let particles: Particle[] = [];
  let mode: FormationMode = modeCycle[0] ?? "swarm";
  let cycleIndex = 0;
  let nextCycleAtMs = 0;
  let flowTime = 0;
  let lastAdvanceMs: number | null = null;
  let shapeSettledAtMs: number | null = null;
  let modeAssignedAtMs = 0;
  let settleAmt = 0;

  let pointer: { x: number; y: number; active: boolean } = { x: 0, y: 0, active: false };

  let dollarPoints: ShapePoint[] = [];
  let codePoints: ShapePoint[] = [];
  let ringPoints: ShapePoint[] = [];
  let routerFlowPoints: ShapePoint[] = [];
  let shapesReady = false;

  let logoSprite: HTMLCanvasElement | null = null;
  let logoLoadStarted = false;

  const curlOut: [number, number] = [0, 0];

  function intervalFor(m: FormationMode): number {
    if (!logoHero) return DASHBOARD_CYCLE_MS / motionSpeedMultiplier;
    return (formationKind(m) === "swarm" ? HERO_SWARM_MS : HERO_LOGO_MS) / motionSpeedMultiplier;
  }

  function particleCount(): number {
    const area = width * height;
    const n = Math.round(area / PARTICLE_DIVISOR);
    return Math.max(PARTICLE_MIN, Math.min(PARTICLE_MAX, n, logoPts.length));
  }

  function requestLogoSprite(): void {
    if (logoLoadStarted || typeof Image === "undefined") return;
    logoLoadStarted = true;
    const tryUrl = (index: number) => {
      if (index >= LOGO_URLS.length) return;
      const image = new Image();
      image.onload = () => {
        const punched = punchWhite(image);
        if (punched) logoSprite = punched;
      };
      image.onerror = () => tryUrl(index + 1);
      image.src = LOGO_URLS[index]!;
    };
    tryUrl(0);
  }

  function ensureShapeCaches(): void {
    if (shapesReady) return;
    if (!logoHero) {
      dollarPoints = sampleTextPoints("$", 280);
      codePoints = sampleTextPoints("</>", 220);
      ringPoints = generateRingPoints();
      routerFlowPoints = generateRouterFlowPoints();
    }
    shapesReady = true;
  }

  function homePoint(index: number): BurnBarLogoPoint {
    const n = particles.length || particleCount();
    const srcIndex =
      n <= 1 ? 0 : Math.round((index * (logoPts.length - 1)) / Math.max(n - 1, 1));
    return logoPts[srcIndex] ?? logoPts[0]!;
  }

  function makeParticle(index: number): Particle {
    const home = homePoint(index);
    const ember = mixRgb(home.rgb, EMBER_BRIGHT, 0.25);
    const { cx, cy, scale } = width > 0 ? logoLayout() : { cx: 300, cy: 300, scale: 180 };
    const ang = Math.random() * Math.PI * 2;
    const rad = scale * (0.45 + Math.random() * 1.15);
    return {
      x: cx + Math.cos(ang) * rad,
      y: cy + Math.sin(ang) * rad,
      vx: (Math.random() - 0.5) * 0.9,
      vy: (Math.random() - 0.5) * 0.9 - 0.15,
      size: 0.85 + Math.random() * 1.55,
      seed: Math.random() * Math.PI * 2,
      home: index,
      tx: null,
      ty: null,
      tr: home.rgb[0],
      tg: home.rgb[1],
      tb: home.rgb[2],
      cr: ember[0],
      cg: ember[1],
      cb: ember[2],
      role: home.role,
      roleStr: null,
      logoProviderId: null,
      slotIndex: null,
      flowProgress: Math.random(),
      opacity: 0.55 + Math.random() * 0.4,
    };
  }

  function buildParticles(): void {
    const n = particleCount();
    particles = new Array(n);
    for (let i = 0; i < n; i++) particles[i] = makeParticle(i);
  }

  function clearFormation(p: Particle): void {
    p.tx = null;
    p.ty = null;
    p.roleStr = null;
    p.logoProviderId = null;
    p.slotIndex = null;
    const home = homePoint(p.home);
    p.role = home.role;
    p.tr = home.rgb[0];
    p.tg = home.rgb[1];
    p.tb = home.rgb[2];
  }

  function logoLayout(): { cx: number; cy: number; scale: number } {
    const cx = width * 0.5;
    const cy = height * 0.5;
    const scale = Math.min(width, height) * (width > 960 ? 0.46 : 0.5);
    return { cx, cy, scale };
  }

  function layoutForMode(m: FormationMode): { cx: number; cy: number; scale: number } {
    if (m === "shapeBurnBarLogo" || logoHero) return logoLayout();
    let centerX = width * 0.5;
    let centerY = height * 0.45;
    let scaleFactor = 0.35;
    const wide = width > 960;
    if (wide) {
      switch (m) {
        case "shapeRings":
          centerX = width * 0.78;
          centerY = height * 0.3;
          scaleFactor = 0.38;
          break;
        case "shapeRouterFlow":
          centerX = width * 0.5;
          centerY = height * 0.26;
          scaleFactor = 0.6;
          break;
        default:
          centerX = width * 0.74;
          centerY = height * 0.28;
          scaleFactor = 0.32;
      }
    } else {
      switch (m) {
        case "shapeRings":
          centerY = height * 0.24;
          scaleFactor = 0.34;
          break;
        case "shapeRouterFlow":
          centerY = height * 0.24;
          scaleFactor = 0.62;
          break;
        default:
          centerY = height * 0.22;
          scaleFactor = 0.32;
      }
    }
    return { cx: centerX, cy: centerY, scale: Math.min(width, height) * scaleFactor };
  }

  function shapePointsFor(m: FormationMode): ShapePoint[] {
    switch (m) {
      case "shapeDollar":
        return dollarPoints;
      case "shapeCode":
        return codePoints;
      case "shapeRings":
        return ringPoints;
      case "shapeRouterFlow":
        return routerFlowPoints;
      default:
        return [];
    }
  }

  function assignBurnBarLogo(): void {
    const { cx, cy, scale } = logoLayout();
    const n = particles.length;
    const total = logoPts.length;
    for (let i = 0; i < n; i++) {
      const p = particles[i]!;
      const srcIndex = n <= 1 ? 0 : Math.round((i * (total - 1)) / Math.max(n - 1, 1));
      const pt = logoPts[srcIndex] ?? logoPts[0]!;
      p.tx = cx + pt.x * scale;
      p.ty = cy - pt.y * scale;
      p.tr = pt.rgb[0];
      p.tg = pt.rgb[1];
      p.tb = pt.rgb[2];
      p.role = pt.role;
      p.roleStr = null;
      p.logoProviderId = null;
      p.slotIndex = 0;
      p.home = i;
      p.x += (p.tx - p.x) * 0.22;
      p.y += (p.ty - p.y) * 0.22;
    }
  }

  function assignProviderLogoFormation(specs: { providerId: string; points: ShapePoint[] }[]): void {
    const visible = specs.filter((s) => s.points.length > 0);
    const count = visible.length;
    if (count === 0) {
      for (const p of particles) clearFormation(p);
      return;
    }
    const groups: number[][] = Array.from({ length: count }, () => []);
    const order = shuffleIndices(particles.length);
    for (let slot = 0; slot < order.length; slot++) {
      groups[slot % count]!.push(order[slot]!);
    }
    const slots = providerLogoSlots(count, width, height);
    for (let specIndex = 0; specIndex < count; specIndex++) {
      const spec = visible[specIndex]!;
      const logoSlot = slots[specIndex]!;
      const groupParticles = groups[specIndex]!;
      const brand = providerBrandRgb(spec.providerId);
      for (let slot = 0; slot < groupParticles.length; slot++) {
        const particleIdx = groupParticles[slot]!;
        const p = particles[particleIdx]!;
        let pointIndex: number;
        if (groupParticles.length <= spec.points.length) {
          const t = slot / Math.max(groupParticles.length - 1, 1);
          pointIndex = Math.min(spec.points.length - 1, Math.round((spec.points.length - 1) * t));
        } else {
          pointIndex = slot % spec.points.length;
        }
        const pt = spec.points[pointIndex]!;
        p.tx = logoSlot.centerX + pt.x * logoSlot.scale;
        p.ty = logoSlot.centerY - pt.y * logoSlot.scale;
        const rgb = pt.rgb ?? adjustRgb(brand, 0.18, 0.12, p.seed);
        p.tr = rgb[0];
        p.tg = rgb[1];
        p.tb = rgb[2];
        p.roleStr = pt.role;
        p.logoProviderId = spec.providerId;
        p.slotIndex = specIndex;
        p.flowProgress = pt.progress;
      }
    }
  }

  function assignGenericShape(m: FormationMode): void {
    ensureShapeCaches();
    const points = shapePointsFor(m);
    const { cx, cy, scale } = layoutForMode(m);
    const order = shuffleIndices(particles.length);
    for (let slot = 0; slot < order.length; slot++) {
      const p = particles[order[slot]!]!;
      if (slot < points.length) {
        const pt = points[slot]!;
        p.tx = cx + pt.x * scale;
        p.ty = cy - pt.y * scale;
        p.roleStr = pt.role;
        p.flowProgress = pt.progress;
        p.logoProviderId = null;
        p.slotIndex = 0;
        const tint = mixRgb(EMBER_CORE, EMBER_BRIGHT, (p.seed % 1 + 1) / 2);
        p.tr = tint[0];
        p.tg = tint[1];
        p.tb = tint[2];
      } else {
        clearFormation(p);
      }
    }
  }

  function sameFormation(a: FormationMode, b: FormationMode): boolean {
    if (typeof a === "string" || typeof b === "string") return a === b;
    return a.type === b.type && a.providers.join(",") === b.providers.join(",");
  }

  function assignMode(next: FormationMode, atMs: number): void {
    mode = next;
    modeAssignedAtMs = atMs;
    shapeSettledAtMs = null;
    settleAmt = 0;
    if (ctx) paintBase(0.5);
    if (next === "swarm") {
      for (const p of particles) clearFormation(p);
      return;
    }
    if (next === "shapeBurnBarLogo") {
      assignBurnBarLogo();
      return;
    }
    if (isProviderLogoMode(next)) {
      ensureShapeCaches();
      const specs = next.providers.map((providerId) => ({
        providerId,
        points: providerShapePoints(providerId, () => {
          if (isProviderLogoMode(mode) && sameFormation(mode, next)) {
            assignMode(mode, lastAdvanceMs ?? 0);
          }
        }),
      }));
      assignProviderLogoFormation(specs);
      return;
    }
    assignGenericShape(next);
  }

  function cycleFormation(atMs: number): void {
    if (!allowsClickCycle || modeCycle.length < 2) return;
    const currentIndex = modeCycle.findIndex((candidate) => sameFormation(candidate, mode));
    cycleIndex = (currentIndex < 0 ? cycleIndex : currentIndex) + 1;
    cycleIndex %= modeCycle.length;
    assignMode(modeCycle[cycleIndex]!, atMs);
    nextCycleAtMs = atMs + intervalFor(mode);
  }

  function applyTransform(): void {
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function fieldBg(): RGB {
    if (!palette) return WARM_DARK;
    if (palette.theme === "light") return palette.bg;
    return mixRgb(palette.bg, WARM_DARK, 0.72);
  }

  function paintBase(alpha: number): void {
    if (!ctx) return;
    ctx.globalCompositeOperation = "source-over";
    ctx.fillStyle = toCss(fieldBg(), alpha);
    ctx.fillRect(0, 0, width, height);
  }

  function paintVignette(): void {
    if (!ctx) return;
    const { cx, cy } = logoLayout();
    const r = Math.max(width, height) * 0.72;
    const g = ctx.createRadialGradient(cx, cy, r * 0.18, cx, cy, r);
    g.addColorStop(0, "rgba(48,14,4,0)");
    g.addColorStop(1, palette?.theme === "light" ? "rgba(40,24,12,0.08)" : "rgba(0,0,0,0.46)");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, width, height);
  }

  function stepParticle(
    p: Particle,
    motion: number,
    attract: number,
    frameScale: number,
    pointerX: number | null,
    pointerY: number | null,
    tMs: number
  ): void {
    curl2(p.x * CURL_SCALE, p.y * CURL_SCALE, tMs * CURL_TIME, curlOut);
    const noiseX = curlOut[0];
    const noiseY = curlOut[1];

    let pushX = 0;
    let pushY = 0;
    if (pointerX != null && pointerY != null) {
      const dx = p.x - pointerX;
      const dy = p.y - pointerY;
      const dist = Math.sqrt(dx * dx + dy * dy);
      if (dist < POINTER_REPULSE_R && dist > 0) {
        const force = (POINTER_REPULSE_R - dist) / POINTER_REPULSE_R;
        pushX = (dx / dist) * force * MOUSE_FORCE;
        pushY = (dy / dist) * force * MOUSE_FORCE;
      }
    }

    const speedMul = motionSpeedMultiplier;
    const inForm = p.tx != null && p.ty != null;

    if (!inForm) {
      const { cx, cy } = logoLayout();
      p.vx += (noiseX * SWARM_CURL + pushX) * motion * frameScale * speedMul;
      p.vy += (noiseY * SWARM_CURL + pushY - SWARM_RISE) * motion * frameScale * speedMul;
      p.vx += (cx - p.x) * HOME_PULL * frameScale;
      p.vy += (cy - p.y) * HOME_PULL * frameScale;
      const drag = Math.pow(SWARM_DRAG, frameScale);
      p.vx *= drag;
      p.vy *= drag;
      const speed = Math.hypot(p.vx, p.vy);
      const maxSpeed = SWARM_MAX_SPEED * speedMul;
      if (speed > maxSpeed && speed > 0) {
        p.vx = (p.vx / speed) * maxSpeed;
        p.vy = (p.vy / speed) * maxSpeed;
      }
      p.x += p.vx * frameScale;
      p.y += p.vy * frameScale;
      if (p.x < -20) p.x = width + 20;
      if (p.x > width + 20) p.x = -20;
      if (p.y < -20) p.y = height + 20;
      if (p.y > height + 20) p.y = -20;
      const ember = mixRgb([p.tr, p.tg, p.tb], EMBER_BRIGHT, 0.28);
      const k = 0.08;
      p.cr += (ember[0] - p.cr) * k;
      p.cg += (ember[1] - p.cg) * k;
      p.cb += (ember[2] - p.cb) * k;
      p.opacity = 0.64 + 0.22 * (0.5 + 0.5 * Math.sin(tMs * 0.003 + p.seed));
      return;
    }

    if (formationKind(mode) === "shapeRouterFlow" && p.roleStr) {
      const centerX = width * 0.5;
      const centerY = height * 0.48;
      const scaleFactor = width > 960 ? 0.7 : 0.8;
      const scale = Math.min(width, height) * scaleFactor;
      const role = p.roleStr;
      if (role === "gateway") {
        const angle = p.seed + flowTime * 15;
        p.tx = centerX + (-0.45 + Math.cos(angle) * 0.08) * scale;
        p.ty = centerY + Math.sin(angle) * 0.08 * scale;
      } else if (role.startsWith("target-")) {
        let tgtY = 0;
        if (role === "target-1") tgtY = -0.28;
        if (role === "target-3") tgtY = 0.28;
        const angle = p.seed + flowTime * 12;
        p.tx = centerX + (0.45 + Math.cos(angle) * 0.05) * scale;
        p.ty = centerY + (tgtY + Math.sin(angle) * 0.05) * scale;
      } else if (role.startsWith("path-")) {
        let tgtY = 0;
        if (role === "path-1") tgtY = -0.28;
        if (role === "path-3") tgtY = 0.28;
        p.flowProgress += 0.003 * frameScale * motionSpeedMultiplier;
        if (p.flowProgress > 1) p.flowProgress = 0;
        const t = p.flowProgress;
        p.tx = centerX + (-0.45 + 0.9 * t) * scale;
        p.ty = centerY + tgtY * (3 * t * t - 2 * t * t * t) * scale;
      }
    }

    let tx = p.tx!;
    let ty = p.ty!;
    // Living fire: flame tongue flickers; tip sparks lift off.
    if (mode === "shapeBurnBarLogo") {
      const flick = Math.sin(tMs * 0.011 + p.seed) * (p.role === ROLE_TIP ? 3.4 : p.role === ROLE_FLAME ? 1.6 : 0.45);
      const lift = p.role === ROLE_TIP || p.role === ROLE_FLAME ? Math.sin(tMs * 0.007 + p.seed * 1.7) * 2.2 : 0;
      tx += flick;
      ty -= lift;
      if (enableSwarmSparkles && p.role === ROLE_TIP) {
        const burst = Math.sin(tMs * 0.004 + p.seed * 9.1);
        if (burst > 0.94) {
          p.vy -= 1.8 * motion * speedMul;
          p.vx += Math.sin(p.seed * 13) * 0.6;
        }
      }
    }

    const dx = tx - p.x;
    const dy = ty - p.y;
    const dist = Math.hypot(dx, dy);
    if (dist > 0.4) {
      p.vx += (dx / dist) * MORPH_SPRING * attract * frameScale * speedMul * Math.min(dist, 80);
      p.vy += (dy / dist) * MORPH_SPRING * attract * frameScale * speedMul * Math.min(dist, 80);
    }
    p.vx += (noiseX * MORPH_NOISE + pushX) * motion * frameScale * speedMul;
    p.vy += (noiseY * MORPH_NOISE + pushY) * motion * frameScale * speedMul;
    const drag = Math.pow(MORPH_DRAG, frameScale);
    p.vx *= drag;
    p.vy *= drag;
    const speed = Math.hypot(p.vx, p.vy);
    const maxSpeed = MORPH_MAX_SPEED * speedMul;
    if (speed > maxSpeed && speed > 0) {
      p.vx = (p.vx / speed) * maxSpeed;
      p.vy = (p.vy / speed) * maxSpeed;
    }
    p.x += p.vx * frameScale;
    p.y += p.vy * frameScale;

    const ck = 0.16;
    p.cr += (p.tr - p.cr) * ck;
    p.cg += (p.tg - p.cg) * ck;
    p.cb += (p.tb - p.cb) * ck;
    p.opacity = Math.min(1, 0.72 * SHAPE_BOOST);
  }

  function updateShapeSettled(tMs: number): void {
    if (formationKind(mode) === "swarm") {
      settleAmt += (0 - settleAmt) * 0.08;
      return;
    }
    let assigned = 0;
    let settled = 0;
    for (const p of particles) {
      if (p.tx == null || p.ty == null) continue;
      assigned++;
      const dx = p.tx - p.x;
      const dy = p.ty - p.y;
      if (dx * dx + dy * dy < 64) settled++;
    }
    const ratio = assigned > 0 ? settled / assigned : 0;
    if (ratio >= 0.9 || tMs - modeAssignedAtMs > 5500) {
      if (shapeSettledAtMs == null) shapeSettledAtMs = tMs;
    }
    const target = shapeSettledAtMs != null ? 1 : Math.min(1, ratio);
    settleAmt += (target - settleAmt) * 0.07;
  }

  function drawLogoCoal(): void {
    if (!ctx || !logoSprite || mode !== "shapeBurnBarLogo") return;
    const { cx, cy, scale } = logoLayout();
    const side = scale * 2;
    const alpha = (palette?.theme === "light" ? 0.16 : 0.34) * settleAmt * (palette?.intensity ?? 1);
    if (alpha < 0.02) return;
    ctx.save();
    ctx.globalCompositeOperation = "source-over";
    ctx.globalAlpha = alpha;
    ctx.drawImage(logoSprite, cx - side / 2, cy - side / 2, side, side);
    ctx.restore();
  }

  function drawParticles(tMs: number): void {
    if (!ctx || !palette) return;
    const intensity = palette.intensity;
    const light = palette.theme === "light";
    const baseA = (light ? 0.2 : 0.38) * intensity;

    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i]!;
      const pulse = 0.86 + 0.14 * Math.sin(tMs * 0.006 + p.seed);
      const inForm = p.tx != null;
      const spd = Math.hypot(p.vx, p.vy);
      const slim = 1 / (1 + spd * 0.22);
      const rGlow = Math.max(1.0, p.size * (inForm ? 2.35 : 2.05) * pulse * slim);
      const rCore = Math.max(0.4, p.size * (inForm ? 0.64 : 0.58) * pulse * slim);
      const rgb: RGB = [p.cr, p.cg, p.cb];
      const a = baseA * p.opacity;

      ctx.fillStyle = toCss(rgb, a * 0.26);
      ctx.beginPath();
      ctx.arc(p.x, p.y, rGlow, 0, Math.PI * 2);
      ctx.fill();

      ctx.fillStyle = toCss(hotter(rgb, 0.14), a * 0.88);
      ctx.beginPath();
      ctx.arc(p.x, p.y, rCore, 0, Math.PI * 2);
      ctx.fill();

      if (enableSwarmSparkles && inForm && (p.role === ROLE_TIP || p.role === ROLE_FLAME)) {
        const sparkleVal = Math.sin(flowTime * (0.7 + (i % 5) * 0.13) + p.seed);
        if (sparkleVal > 0.93) {
          const s = ((sparkleVal - 0.93) / 0.07) ** 2;
          ctx.fillStyle = toCss([255, 244, 220], s * 0.55);
          ctx.beginPath();
          ctx.arc(p.x, p.y, rCore * 0.55, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }
    ctx.restore();
  }

  function advanceSim(tMs: number, draw: boolean): void {
    if (!ctx || !palette) return;
    ensureShapeCaches();

    const elapsedSec = lastAdvanceMs != null ? (tMs - lastAdvanceMs) / 1000 : null;
    const frameScale = animationFrameScale(elapsedSec);
    lastAdvanceMs = tMs;

    if (!reducedMotion && modeCycle.length > 1 && tMs >= nextCycleAtMs) {
      cycleIndex = (cycleIndex + 1) % modeCycle.length;
      assignMode(modeCycle[cycleIndex]!, tMs);
      nextCycleAtMs = tMs + intervalFor(mode);
    }

    const motion = reducedMotion ? 0 : 1;
    const attract = reducedMotion ? 0.05 : 1;
    flowTime += 0.004 * frameScale * motionSpeedMultiplier;

    const pointerX = pointer.active ? pointer.x : null;
    const pointerY = pointer.active ? pointer.y : null;

    for (const p of particles) {
      stepParticle(p, motion, attract, frameScale, pointerX, pointerY, tMs);
    }
    updateShapeSettled(tMs);

    if (!draw) return;
    drawLogoCoal();
    drawParticles(tMs);
  }

  function snapToLogo(): void {
    assignMode("shapeBurnBarLogo", 0);
    for (const p of particles) {
      if (p.tx == null || p.ty == null) continue;
      p.x = p.tx;
      p.y = p.ty;
      p.vx = 0;
      p.vy = 0;
      p.cr = p.tr;
      p.cg = p.tg;
      p.cb = p.tb;
      p.opacity = 0.95;
    }
    settleAmt = 1;
    shapeSettledAtMs = 0;
  }

  function renderStaticFrame(): void {
    if (!ctx || !palette) return;
    paintBase(1);
    paintVignette();
    snapToLogo();
    drawLogoCoal();
    drawParticles(0);
  }

  return {
    id: "swarmEmber",
    label: "Swarm Ember",
    substrate: "2d",

    init(rc: KernelRenderingContext, frame: KernelFrameContext) {
      ctx = rc as CanvasRenderingContext2D;
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      reducedMotion = frame.reducedMotion;
      palette = frame.palette;
      applyTransform();
      requestLogoSprite();
      buildParticles();
      cycleIndex = 0;
      mode = modeCycle[0] ?? "swarm";
      lastAdvanceMs = null;
      assignMode(mode, 0);
      nextCycleAtMs = intervalFor(mode);
      paintBase(1);
      paintVignette();
      if (reducedMotion) renderStaticFrame();
      else advanceSim(0, true);
    },

    frame(tMs: number, _dtMs: number) {
      if (!ctx || reducedMotion) return;
      const light = palette?.theme === "light";
      const forming = formationKind(mode) !== "swarm" && settleAmt < 0.82;
      const dissolving = formationKind(mode) === "swarm" && tMs - modeAssignedAtMs < 1600;
      paintBase(light ? 0.24 : forming || dissolving ? 0.28 : 0.16);
      advanceSim(tMs, true);
    },

    resize(frame: KernelFrameContext) {
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      reducedMotion = frame.reducedMotion;
      palette = frame.palette;
      applyTransform();
      buildParticles();
      assignMode(mode, lastAdvanceMs ?? 0);
      paintBase(1);
      paintVignette();
      if (reducedMotion) renderStaticFrame();
    },

    setTheme(_theme: ThemeName, next: KernelPalette) {
      palette = next;
      paintBase(1);
      paintVignette();
      if (reducedMotion) renderStaticFrame();
    },

    pointer(x: number, y: number, active: boolean) {
      pointer = { x, y, active };
    },

    click(_x: number, _y: number) {
      cycleFormation(lastAdvanceMs ?? 0);
    },

    wake(x: number, y: number, _dx: number, _dy: number, radius: number, strength: number) {
      if (!pointer.active) pointer = { x, y, active: true };
      const reach = radius * 2.4;
      for (const p of particles) {
        const dx = p.x - x;
        const dy = p.y - y;
        const d2 = dx * dx + dy * dy;
        if (d2 < reach * reach && d2 > 0) {
          const d = Math.sqrt(d2);
          const f = (1 - d / reach) * strength * 0.18;
          p.vx += (dx / d) * f;
          p.vy += (dy / d) * f;
        }
      }
    },

    renderStatic() {
      renderStaticFrame();
    },

    dispose() {
      ctx = null;
      particles = [];
      logoSprite = null;
    },
  };
}
