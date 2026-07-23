/**
 * Swarm Ember kernel — faithful port of macOS SwarmSimulation (cinematic pace).
 * Noise-driven ember particles periodically form glyph shapes, then dissolve.
 */

import { toCss } from "../palette";
import { PROVIDER_SHAPE_POINTS } from "./swarmEmberShapeData";
import {
  normalizeSwarmProviderGlyphs,
  SWARM_PROVIDER_GLYPH_IDS,
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

// ── Cinematic pace (SwarmCanvasView.Pace.cinematic) ─────────────────────
const TIME_STEP = 0.000004;
const SWARM_NOISE = 0.02;
const SWARM_DRAG = 0.97;
const MAX_SPEED_GLYPH = 0.35;
const MAX_SPEED_PIXEL = 0.6;
const MORPH_ATTRACT = 0.12;
const MORPH_NOISE = 0.008;
const MORPH_DRAG = 0.9;
const CYCLE_INTERVAL_MS = 14_000;
const MOUSE_FORCE = 0.7;
const POINTER_REPULSE_R = 140;

const PARTICLE_DIVISOR = 900;
const PARTICLE_MIN = 520;
const PARTICLE_MAX = 900;
const GLYPH_FRACTION = 0.08;

const GLYPHS = ["$", "{}", "</>", "tok", "ctx", "429", "503", "run", "cache"];

// Editorial ember ramp (brass-core → brass-bright)
const EMBER_CORE: RGB = [250, 107, 6];
const EMBER_BRIGHT: RGB = [253, 196, 44];

const SHAPE_BOOST = 1.7;


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
];

/** Shape tables use a few catalog aliases (anthropic/google) vs persisted tokens. */
const SHAPE_PROVIDER_ALIASES: Record<string, string> = {
  claudecode: "anthropic",
  geminicli: "google",
  openai: "openai",
};

function shapeProviderKey(persistedId: string): string | null {
  const alias = SHAPE_PROVIDER_ALIASES[persistedId] ?? persistedId;
  const flat = PROVIDER_SHAPE_POINTS[alias];
  return flat && flat.length >= 2 ? alias : null;
}

function normalizedShowcaseProviders(providerGlyphs?: readonly string[]): string[] {
  const selected = normalizeSwarmProviderGlyphs(providerGlyphs);
  return SHOWCASE_PROVIDER_IDS.filter(
    (id) => selected.includes(id as SwarmProviderGlyphId) && shapeProviderKey(id) != null
  );
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

function providerShapePoints(providerId: string): ShapePoint[] {
  const key = shapeProviderKey(providerId);
  if (!key) return [];
  const flat = PROVIDER_SHAPE_POINTS[key];
  return flatToShapePoints(flat);
}

function formationKind(mode: FormationMode): string {
  return typeof mode === "string" ? mode : mode.type;
}

function isProviderLogoMode(mode: FormationMode): mode is { type: "shapeProviderLogo"; providers: string[] } {
  return typeof mode !== "string" && mode.type === "shapeProviderLogo";
}


interface ShapePoint {
  x: number;
  y: number;
  role: string | null;
  progress: number;
}

interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  isGlyph: boolean;
  /** Saved isGlyph state before logo formations force it false; restored by clearFormation. */
  wasGlyph: boolean;
  glyph: string;
  colorIndex: number;
  baseOpacity: number;
  opacity: number;
  tx: number | null;
  ty: number | null;
  role: string | null;
  flowProgress: number;
  logoProviderId: string | null;
  slotIndex: number | null;
  toneSeed: number | null;
}

function lerpRgb(a: RGB, b: RGB, t: number): RGB {
  return [
    a[0] + (b[0] - a[0]) * t,
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
  ];
}

function emberFromKey(key: number, intensity: number): RGB {
  const t = (key & 1) === 0 ? 0.35 : 0.85;
  const rgb = lerpRgb(EMBER_CORE, EMBER_BRIGHT, t);
  const k = intensity;
  return [rgb[0] * k, rgb[1] * k, rgb[2] * k];
}

function animationFrameScale(elapsedSec: number | null): number {
  if (elapsedSec == null || !Number.isFinite(elapsedSec) || elapsedSec <= 0) return 1;
  return Math.min(4, Math.max(0.25, elapsedSec * 60));
}

function sampleTextPoints(text: string, fontSize: number): ShapePoint[] {
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
};

function clampMotionSpeedMultiplier(value: number): number {
  return Math.min(2.5, Math.max(0.35, value));
}

function mixRgb(a: RGB, b: RGB, t: number): RGB {
  return lerpRgb(a, b, t);
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

function particleProviderRgb(p: Particle, index: number): RGB | null {
  if (!p.logoProviderId) return null;
  const base = providerBrandRgb(p.logoProviderId);
  const toneSeed = p.toneSeed ?? flameToneSeed(p.role, index);
  if (p.role === "logo-flame-inner") {
    return adjustRgb(base, 0.24, 0.1, toneSeed);
  }
  if (p.role === "logo-flame-outer") {
    return adjustRgb(base, 0.1, 0.3, toneSeed);
  }
  if (p.role === "logo-flame-spark") {
    return adjustRgb(base, 0.18, 0.12, toneSeed + 0.58);
  }
  return adjustRgb(base, 0.1, 0.15, toneSeed);
}

function flameToneSeed(role: string | null, index: number): number {
  const roleShift =
    role === "logo-flame-outer" ? 0.18 : role === "logo-flame-spark" ? 0.58 : 0;
  return ((index * 0.137) % 1) + roleShift;
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
  const providerGlyphs = options.providerGlyphs ?? SWARM_PROVIDER_GLYPH_IDS;
  const modeCycle = buildDashboardCycle(
    providerGlyphs,
    options.excludeBrandShapes ?? true,
    options.autoCycleShapes ?? true
  );

  let particles: Particle[] = [];
  let mode: FormationMode = "swarm";
  let cycleIndex = 0;
  let nextCycleAtMs = 0;
  let flowTime = 0;
  let lastAdvanceMs: number | null = null;
  let shapeSettledAtMs: number | null = null;
  let modeAssignedAtMs = 0;

  const effectiveCycleIntervalMs = () => CYCLE_INTERVAL_MS / motionSpeedMultiplier;

  let pointer: { x: number; y: number; active: boolean } = { x: 0, y: 0, active: false };

  let dollarPoints: ShapePoint[] = [];
  let codePoints: ShapePoint[] = [];
  let burnBarLogoPoints: ShapePoint[] = [];
  let ringPoints: ShapePoint[] = [];
  let routerFlowPoints: ShapePoint[] = [];
  let shapesReady = false;

  function particleCount(): number {
    const area = width * height;
    return Math.max(PARTICLE_MIN, Math.min(PARTICLE_MAX, Math.round(area / PARTICLE_DIVISOR)));
  }

  function ensureShapeCaches(): void {
    if (shapesReady) return;
    dollarPoints = sampleTextPoints("$", 280);
    codePoints = sampleTextPoints("</>", 220);
    burnBarLogoPoints = sampleTextPoints("BurnBar", 200);
    ringPoints = generateRingPoints();
    routerFlowPoints = generateRouterFlowPoints();
    shapesReady = true;
  }

  function makeParticle(): Particle {
    const isGlyph = Math.random() < GLYPH_FRACTION;
    return {
      x: Math.random() * Math.max(width, 600),
      y: Math.random() * Math.max(height, 600),
      vx: (Math.random() - 0.5) * 1.5,
      vy: (Math.random() - 0.5) * 1.5,
      size: 0.8 + Math.random() * 1.5,
      isGlyph,
      wasGlyph: isGlyph,
      glyph: GLYPHS[(Math.random() * GLYPHS.length) | 0]!,
      colorIndex: Math.random(),
      baseOpacity: 0.16 + Math.random() * 0.2,
      opacity: 0.16,
      tx: null,
      ty: null,
      role: null,
      flowProgress: Math.random(),
      logoProviderId: null,
      slotIndex: null,
      toneSeed: null,
    };
  }

  function buildParticles(): void {
    const n = particleCount();
    particles = [];
    for (let i = 0; i < n; i++) particles.push(makeParticle());
    for (const p of particles) {
      p.x = Math.random() * width;
      p.y = Math.random() * height;
    }
  }

  function clearFormation(p: Particle): void {
    p.tx = null;
    p.ty = null;
    p.role = null;
    p.logoProviderId = null;
    p.slotIndex = null;
    p.toneSeed = null;
    // Restore the glyph flag saved before the logo formation overrode it,
    // so token-text particles reappear when returning to swarm mode.
    p.isGlyph = p.wasGlyph;
  }

  function shapePointsFor(m: FormationMode): { points: ShapePoint[]; roles: (string | null)[] } {
    switch (m) {
      case "shapeDollar":
        return { points: dollarPoints, roles: dollarPoints.map(() => null) };
      case "shapeCode":
        return { points: codePoints, roles: codePoints.map(() => null) };
      case "shapeBurnBarLogo":
        return { points: burnBarLogoPoints, roles: burnBarLogoPoints.map(() => null) };
      case "shapeRings":
        return { points: ringPoints, roles: ringPoints.map(() => null) };
      case "shapeRouterFlow":
        return {
          points: routerFlowPoints,
          roles: routerFlowPoints.map((pt) => pt.role),
        };
      default:
        return { points: [], roles: [] };
    }
  }

  function layoutForMode(m: FormationMode): { cx: number; cy: number; scale: number } {
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
        case "shapeBurnBarLogo":
          centerX = width * 0.75;
          centerY = height * 0.32;
          scaleFactor = 0.3;
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
        case "shapeBurnBarLogo":
          centerY = height * 0.24;
          scaleFactor = 0.3;
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
    const scale = Math.min(width, height) * scaleFactor;
    return { cx: centerX, cy: centerY, scale };
  }


  function assignProviderLogoFormation(
    specs: { providerId: string; points: ShapePoint[] }[]
  ): void {
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
      for (let slot = 0; slot < groupParticles.length; slot++) {
        const particleIdx = groupParticles[slot]!;
        const p = particles[particleIdx]!;
        let pointIndex: number;
        if (groupParticles.length <= spec.points.length) {
          const t = slot / Math.max(groupParticles.length - 1, 1);
          pointIndex = Math.min(
            spec.points.length - 1,
            Math.round((spec.points.length - 1) * t)
          );
        } else {
          pointIndex = slot % spec.points.length;
        }
        const pt = spec.points[pointIndex]!;
        p.tx = logoSlot.centerX + pt.x * logoSlot.scale;
        p.ty = logoSlot.centerY + pt.y * logoSlot.scale;
        p.wasGlyph = p.isGlyph;
        p.isGlyph = false;
        p.slotIndex = specIndex;
        p.role = pt.role;
        p.logoProviderId = spec.providerId;
        p.toneSeed = flameToneSeed(pt.role, particleIdx);
        p.flowProgress = pt.progress;
      }
    }
  }

  function assignMode(next: FormationMode, atMs: number): void {
    mode = next;
    modeAssignedAtMs = atMs;
    shapeSettledAtMs = null;
    if (next === "swarm") {
      for (const p of particles) clearFormation(p);
      return;
    }
    if (isProviderLogoMode(next)) {
      ensureShapeCaches();
      const specs = next.providers.map((providerId) => ({
        providerId,
        points: providerShapePoints(providerId),
      }));
      assignProviderLogoFormation(specs);
      return;
    }
    ensureShapeCaches();
    const { points, roles } = shapePointsFor(next);
    const { cx, cy, scale } = layoutForMode(next);
    const order = shuffleIndices(particles.length);
    for (let slot = 0; slot < order.length; slot++) {
      const pi = order[slot]!;
      const p = particles[pi]!;
      if (slot < points.length) {
        const pt = points[slot]!;
        p.tx = cx + pt.x * scale;
        p.ty = cy + pt.y * scale;
        p.role = roles[slot] ?? pt.role;
        p.flowProgress = pt.progress;
        p.logoProviderId = null;
        p.slotIndex = 0;
      } else {
        clearFormation(p);
      }
    }
  }

  function applyTransform(): void {
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function paintBase(alpha: number): void {
    if (!ctx || !palette) return;
    ctx.fillStyle = toCss(palette.bg, alpha);
    ctx.fillRect(0, 0, width, height);
  }

  function colorKey(p: Particle): number {
    return p.colorIndex < 0.5 ? 0 : 1;
  }

  function stepParticle(
    p: Particle,
    motion: number,
    attract: number,
    frameScale: number,
    pointerX: number | null,
    pointerY: number | null
  ): void {
    const noiseX = Math.sin(p.y * 0.005 + flowTime * 2) * Math.cos(p.x * 0.003 + flowTime);
    const noiseY = Math.cos(p.x * 0.005 + flowTime * 3) * Math.sin(p.y * 0.003 + flowTime * 2);

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
    if (formationKind(mode) === "swarm") {
      p.vx += (noiseX * SWARM_NOISE + pushX) * motion * frameScale * speedMul;
      p.vy += (noiseY * SWARM_NOISE + pushY) * motion * frameScale * speedMul;
      const drag = Math.pow(SWARM_DRAG, frameScale);
      p.vx *= drag;
      p.vy *= drag;
      const speed = Math.sqrt(p.vx * p.vx + p.vy * p.vy);
      const maxSpeed = (p.isGlyph ? MAX_SPEED_GLYPH : MAX_SPEED_PIXEL) * speedMul;
      if (speed > maxSpeed && speed > 0) {
        p.vx = (p.vx / speed) * maxSpeed;
        p.vy = (p.vy / speed) * maxSpeed;
      }
      p.x += p.vx * frameScale;
      p.y += p.vy * frameScale;
      if (p.x < 0) p.x = width;
      if (p.x > width) p.x = 0;
      if (p.y < 0) p.y = height;
      if (p.y > height) p.y = 0;
      return;
    }

    if (formationKind(mode) === "shapeRouterFlow" && p.role) {
      const centerX = width * 0.5;
      const centerY = height * 0.48;
      const scaleFactor = width > 960 ? 0.7 : 0.8;
      const scale = Math.min(width, height) * scaleFactor;
      const role = p.role;
      if (role === "gateway") {
        const angle = p.colorIndex * Math.PI * 2 + flowTime * 15;
        p.tx = centerX + (-0.45 + Math.cos(angle) * 0.08) * scale;
        p.ty = centerY + Math.sin(angle) * 0.08 * scale;
      } else if (role.startsWith("target-")) {
        let tgtY = 0;
        if (role === "target-1") tgtY = -0.28;
        if (role === "target-3") tgtY = 0.28;
        const angle = p.colorIndex * Math.PI * 2 + flowTime * 12;
        p.tx = centerX + (0.45 + Math.cos(angle) * 0.05) * scale;
        p.ty = centerY + (tgtY + Math.sin(angle) * 0.05) * scale;
      } else if (role.startsWith("path-")) {
        let tgtY = 0;
        if (role === "path-1") tgtY = -0.28;
        if (role === "path-3") tgtY = 0.28;
        p.flowProgress += 0.003 * frameScale * motionSpeedMultiplier;
        if (p.flowProgress > 1) p.flowProgress = 0;
        const t = p.flowProgress;
        const px = -0.45 + 0.9 * t;
        const py = tgtY * (3 * t * t - 2 * t * t * t);
        p.tx = centerX + px * scale;
        p.ty = centerY + py * scale;
      }
    }

    if (p.tx != null && p.ty != null) {
      const dx = p.tx - p.x;
      const dy = p.ty - p.y;
      const dist = Math.sqrt(dx * dx + dy * dy);
      if (dist > 1) {
        p.vx += (dx / dist) * MORPH_ATTRACT * attract * frameScale * motionSpeedMultiplier;
        p.vy += (dy / dist) * MORPH_ATTRACT * attract * frameScale * motionSpeedMultiplier;
      }
      p.vx += (noiseX * MORPH_NOISE + pushX) * motion * frameScale * motionSpeedMultiplier;
      p.vy += (noiseY * MORPH_NOISE + pushY) * motion * frameScale * motionSpeedMultiplier;
      const drag = Math.pow(MORPH_DRAG, frameScale);
      p.vx *= drag;
      p.vy *= drag;
      p.x += p.vx * frameScale;
      p.y += p.vy * frameScale;
    } else {
      p.vx += (noiseX * SWARM_NOISE * 0.75 + pushX) * motion * frameScale * motionSpeedMultiplier;
      p.vy += (noiseY * SWARM_NOISE * 0.75 + pushY) * motion * frameScale * motionSpeedMultiplier;
      const drag = Math.pow(SWARM_DRAG, frameScale);
      p.vx *= drag;
      p.vy *= drag;
      p.x += p.vx * frameScale;
      p.y += p.vy * frameScale;
      if (p.x < 0) p.x = width;
      if (p.x > width) p.x = 0;
      if (p.y < 0) p.y = height;
      if (p.y > height) p.y = 0;
    }

    const inShape = p.tx != null;
    const boost = inShape ? SHAPE_BOOST : 1;
    p.opacity = Math.min(1, p.baseOpacity * boost);
  }

  function updateShapeSettled(tMs: number): void {
    if (formationKind(mode) === "swarm" || shapeSettledAtMs != null) return;
    let assigned = 0;
    let settled = 0;
    for (const p of particles) {
      if (p.tx == null) continue;
      assigned++;
      const dx = p.tx - p.x;
      const dy = p.ty! - p.y;
      if (dx * dx + dy * dy < 36) settled++;
    }
    if (assigned > 0 && settled / assigned >= 0.95) {
      shapeSettledAtMs = tMs;
    } else if (tMs - modeAssignedAtMs > 6000) {
      shapeSettledAtMs = tMs;
    }
  }

  function advanceSim(tMs: number, dtMs: number, draw: boolean): void {
    if (!ctx || !palette) return;
    ensureShapeCaches();

    const elapsedSec = lastAdvanceMs != null ? (tMs - lastAdvanceMs) / 1000 : null;
    const frameScale = animationFrameScale(elapsedSec);
    lastAdvanceMs = tMs;

    if (!reducedMotion && tMs >= nextCycleAtMs) {
      cycleIndex = (cycleIndex + 1) % modeCycle.length;
      assignMode(modeCycle[cycleIndex]!, tMs);
      nextCycleAtMs = tMs + effectiveCycleIntervalMs();
    }

    const motion = reducedMotion ? 0 : 1;
    const attract = reducedMotion ? 0.04 : 1;
    flowTime += TIME_STEP * 1000 * frameScale * motionSpeedMultiplier;

    const pointerX = pointer.active ? pointer.x : null;
    const pointerY = pointer.active ? pointer.y : null;

    for (const p of particles) {
      stepParticle(p, motion, attract, frameScale, pointerX, pointerY);
    }
    updateShapeSettled(tMs);

    if (!draw) return;

    const intensity = palette.intensity;
    const light = palette.theme === "light";
    const dotAlpha = (light ? 0.38 : 0.42) * intensity;

    const renderProviderLogoIndividually = isProviderLogoMode(mode);

    if (renderProviderLogoIndividually) {
      for (let index = 0; index < particles.length; index++) {
        const p = particles[index]!;
        if (p.isGlyph) continue;
        const inShape = p.tx != null;
        const rgb = particleProviderRgb(p, index) ?? emberFromKey(colorKey(p), 1);
        let r = Math.max(0.4, p.size * (inShape ? 1.2 : 0.85));
        const alphaMul = inShape && p.logoProviderId ? SHAPE_BOOST : 1;

        let sparkleIntensity = 0;
        if (enableSwarmSparkles && inShape && shapeSettledAtMs != null) {
          const pHash = ((index * 127) % 1000) / 1000;
          const speed = 0.5 + ((index * 17) % 5) * 0.15;
          const sparkleVal = Math.sin(flowTime * speed + pHash * Math.PI * 2);
          if (sparkleVal > 0.94) {
            const normalized = (sparkleVal - 0.94) / 0.06;
            sparkleIntensity = normalized * normalized;
            r *= 1 + sparkleIntensity * 0.06;
          }
        }

        ctx.fillStyle = toCss(rgb, dotAlpha * alphaMul);
        ctx.beginPath();
        ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
        ctx.fill();

        if (sparkleIntensity > 0) {
          const sr = r * 0.35;
          ctx.fillStyle = toCss([255, 255, 255], sparkleIntensity * 0.55);
          ctx.beginPath();
          ctx.arc(p.x, p.y, sr, 0, Math.PI * 2);
          ctx.fill();
          const glowR = r * 0.75;
          ctx.fillStyle = toCss([255, 255, 255], sparkleIntensity * 0.15);
          ctx.beginPath();
          ctx.arc(p.x, p.y, glowR, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    } else {
      const buckets = new Map<string, { rgb: RGB; logoBoost: boolean; path: Path2D; sparkle: { x: number; y: number; r: number; i: number }[] }>();

      particles.forEach((p, index) => {
        if (p.isGlyph) return;
        const inShape = formationKind(mode) !== "swarm" && p.tx != null;
        const bucketKey = `ember:${colorKey(p)}`;
        let bucket = buckets.get(bucketKey);
        if (!bucket) {
          const rgb = emberFromKey(colorKey(p), 1);
          bucket = { rgb, logoBoost: false, path: new Path2D(), sparkle: [] };
          buckets.set(bucketKey, bucket);
        }
        let r = Math.max(0.4, p.size * (inShape ? 1.2 : 0.85));

        if (enableSwarmSparkles && inShape && shapeSettledAtMs != null) {
          const pHash = ((index * 127) % 1000) / 1000;
          const speed = 0.5 + ((index * 17) % 5) * 0.15;
          const sparkleVal = Math.sin(flowTime * speed + pHash * Math.PI * 2);
          if (sparkleVal > 0.94) {
            const normalized = (sparkleVal - 0.94) / 0.06;
            const intensitySpark = normalized * normalized;
            r *= 1 + intensitySpark * 0.06;
            bucket.sparkle.push({ x: p.x, y: p.y, r, i: intensitySpark });
          }
        }

        bucket.path.arc(p.x, p.y, r, 0, Math.PI * 2);
      });

      for (const [, bucket] of buckets) {
        const alphaMul = bucket.logoBoost ? SHAPE_BOOST : 1;
        ctx.fillStyle = toCss(bucket.rgb, dotAlpha * alphaMul);
        ctx.fill(bucket.path);
        for (const s of bucket.sparkle) {
          const sr = s.r * 0.35;
          ctx.fillStyle = toCss([255, 255, 255], s.i * 0.55);
          ctx.beginPath();
          ctx.arc(s.x, s.y, sr, 0, Math.PI * 2);
          ctx.fill();
          const glowR = s.r * 0.75;
          ctx.fillStyle = toCss([255, 255, 255], s.i * 0.15);
          ctx.beginPath();
          ctx.arc(s.x, s.y, glowR, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }

    ctx.font = "600 12px ui-monospace, Menlo, monospace";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    for (let index = 0; index < particles.length; index++) {
      const p = particles[index]!;
      if (!p.isGlyph) continue;
      const stride = particles.length >= 1000 ? 4 : 3;
      if (index % stride !== 0) continue;
      const key = colorKey(p);
      const rgb = emberFromKey(key, 1);
      ctx.fillStyle = toCss(rgb, dotAlpha * 1.1);
      ctx.fillText(p.glyph, p.x, p.y);
    }
  }

  function renderStaticFrame(): void {
    if (!ctx || !palette) return;
    paintBase(1);
    ensureShapeCaches();
    assignMode("shapeDollar", 0);
    for (let step = 0; step < 120; step++) advanceSim(step * 16, 16, false);
    advanceSim(120 * 16, 16, true);
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
      buildParticles();
      cycleIndex = 0;
      mode = "swarm";
      nextCycleAtMs = effectiveCycleIntervalMs();
      lastAdvanceMs = null;
      assignMode("swarm", 0);
      paintBase(1);
      if (reducedMotion) renderStaticFrame();
      else advanceSim(0, 16, true);
    },

    frame(tMs: number, dtMs: number) {
      if (!ctx || reducedMotion) return;
      const light = palette?.theme === "light";
      paintBase(light ? 0.2 : 0.17);
      advanceSim(tMs, dtMs, true);
    },

    resize(frame: KernelFrameContext) {
      width = frame.width;
      height = frame.height;
      dpr = frame.dpr;
      reducedMotion = frame.reducedMotion;
      palette = frame.palette;
      applyTransform();
      buildParticles();
      assignMode(mode, 0);
      paintBase(1);
      if (reducedMotion) renderStaticFrame();
    },

    setTheme(_theme: ThemeName, next: KernelPalette) {
      palette = next;
      paintBase(1);
      if (reducedMotion) renderStaticFrame();
    },

    pointer(x: number, y: number, active: boolean) {
      pointer = { x, y, active };
    },

    wake(x: number, y: number, _dx: number, _dy: number, radius: number, strength: number) {
      if (!pointer.active) {
        pointer = { x, y, active: true };
      }
      const reach = radius * 2.4;
      for (const p of particles) {
        const dx = p.x - x;
        const dy = p.y - y;
        const d2 = dx * dx + dy * dy;
        if (d2 < reach * reach && d2 > 0) {
          const d = Math.sqrt(d2);
          const f = (1 - d / reach) * strength * 0.15;
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
    },
  };
}
