"use client";

import { useEffect, useRef } from "react";

/**
 * Ambient background: the BurnBar crests and the provider logos rendered as
 * fine, full-colour dot constellations. One materialises somewhere on the page,
 * shimmers and breathes in place, then its dots scatter apart and dissolve — and
 * the next logo resolves into being somewhere new. Slow, organic, alive.
 * Sits at z-index -1, above the paper, behind content.
 */

type Logo = { src: string; scale: number };

// The full provider roster — every AI coding agent OpenBurnBar tracks, mirroring
// the native `AgentProvider.swarmGlyphProviders` order, interleaved with the
// three BurnBar Cloud crests. (Cursor Agent shares Cursor's mark; Anthropic and
// Qwen ride along as recognizable model-family brand moments.)
const LOGOS: Logo[] = [
  { src: "/brand/burnbar_cloud_crest.svg", scale: 0.4 },
  { src: "/brand/logos/openai.png", scale: 0.26 },
  { src: "/brand/logos/claude-code.png", scale: 0.26 },
  { src: "/brand/logos/codex.png", scale: 0.26 },
  { src: "/brand/logos/gemini-cli.png", scale: 0.26 },
  { src: "/brand/logos/cursor.png", scale: 0.26 },
  { src: "/brand/logos/copilot.png", scale: 0.25 },
  { src: "/brand/burnbar_cloud_pro_crest.svg", scale: 0.4 },
  { src: "/brand/logos/deepseek.svg", scale: 0.27 },
  { src: "/brand/logos/kimi.svg", scale: 0.26 },
  { src: "/brand/logos/minimax.png", scale: 0.26 },
  { src: "/brand/logos/zai.png", scale: 0.26 },
  { src: "/brand/logos/xai.png", scale: 0.24 },
  { src: "/brand/logos/mimo.svg", scale: 0.26 },
  { src: "/brand/logos/qwen.svg", scale: 0.26 },
  { src: "/brand/logos/ollama.png", scale: 0.26 },
  { src: "/brand/burnbar_cloud_ultra_crest.svg", scale: 0.4 },
  { src: "/brand/logos/windsurf.png", scale: 0.26 },
  { src: "/brand/logos/warp.png", scale: 0.26 },
  { src: "/brand/logos/factory.png", scale: 0.26 },
  { src: "/brand/logos/antigravity.png", scale: 0.27 },
  { src: "/brand/logos/aider.png", scale: 0.26 },
  { src: "/brand/logos/cline.png", scale: 0.26 },
  { src: "/brand/logos/kilo-code.png", scale: 0.26 },
  { src: "/brand/logos/roo-code.png", scale: 0.26 },
  { src: "/brand/logos/forge.png", scale: 0.26 },
  { src: "/brand/logos/augment.png", scale: 0.26 },
  { src: "/brand/logos/opencode.png", scale: 0.26 },
  { src: "/brand/logos/goose.png", scale: 0.26 },
  { src: "/brand/logos/openclaw.png", scale: 0.27 },
  { src: "/brand/logos/pi-agent.svg", scale: 0.26 },
  { src: "/brand/logos/anthropic.png", scale: 0.25 },
  { src: "/brand/logos/hermes.png", scale: 0.26 },
];

const PERIOD = 9.5; // seconds a logo holds before it dissolves into the next

// Summoned (click-spawned) formations layer on top of the ambient cycle.
const MAX_SUMMONED = 3; // clicks beyond this many active are ignored
const SUMMON_RESOLVE = 0.7; // seconds: dots resolve gracefully into the cloud
const SUMMON_HOLD = 1.5; // seconds: the formation breathes in place
const SUMMON_DISSOLVE = 1.0; // seconds: dots scatter apart and fade
const SUMMON_SCALE = 0.82; // summoned formations sit slightly smaller than ambient

type Dot = {
  x: number;
  y: number;
  r: number;
  g: number;
  b: number;
  a: number;
  sx: number; // scatter direction (outward-ish) for the dissolve
  sy: number;
  phase: number; // per-dot phase for twinkle + micro-jitter
};

function smoothstep(a: number, b: number, x: number) {
  const t = Math.max(0, Math.min(1, (x - a) / (b - a || 1)));
  return t * t * (3 - 2 * t);
}
function hash(n: number) {
  const v = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return v - Math.floor(v);
}
function pseudo(x: number, y: number) {
  const v = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
  return v - Math.floor(v);
}

/**
 * A single logo formation on screen. The ambient cycle is one long-lived
 * instance whose logo/position/coherence are recomputed every frame from the
 * clock; summoned (click-spawned) instances each own a finite lifecycle and a
 * fixed logo + position. Both are drawn by the same renderer so the look — dot
 * colour, twinkle, jitter, sheen, scatter-on-dissolve — is identical.
 */
type Instance =
  | { kind: "ambient" }
  | {
      kind: "summoned";
      idx: number; // logo index, fixed for this formation's lifetime
      cx: number; // target screen position (clamped on-screen)
      cy: number;
      bornAt: number; // performance-clock ms when the click happened
    };

export function DotCrestField() {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    let W = 0;
    let H = 0;

    const resize = () => {
      W = window.innerWidth;
      H = window.innerHeight;
      canvas.width = Math.floor(W * dpr);
      canvas.height = Math.floor(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();

    const S = 200;
    const GAP = 4;
    const sampled: (Dot[] | null)[] = LOGOS.map(() => null);

    const sample = (img: HTMLImageElement, ci: number) => {
      try {
        const off = document.createElement("canvas");
        off.width = S;
        off.height = S;
        const octx = off.getContext("2d");
        if (!octx) return void (sampled[ci] = []);
        const ar = img.naturalWidth / img.naturalHeight || 1;
        let dw = S * 0.92;
        let dh = S * 0.92;
        if (ar > 1) dh = dw / ar;
        else dw = dh * ar;
        octx.clearRect(0, 0, S, S);
        octx.drawImage(img, (S - dw) / 2, (S - dh) / 2, dw, dh);
        const data = octx.getImageData(0, 0, S, S).data;

        // detect the logo's own background from the corner so transparent,
        // white-tile and dark-tile logos all extract cleanly.
        const bgR = data[0];
        const bgG = data[1];
        const bgB = data[2];
        const bgOpaque = data[3] > 200;

        const dots: Dot[] = [];
        for (let y = 0; y < S; y += GAP) {
          for (let x = 0; x < S; x += GAP) {
            const i = (y * S + x) * 4;
            if (data[i + 3] < 48) continue;
            if (bgOpaque) {
              const dr = data[i] - bgR;
              const dg = data[i + 1] - bgG;
              const db = data[i + 2] - bgB;
              if (dr * dr + dg * dg + db * db < 3000) continue; // ~bg colour
            }
            const nx = x / S - 0.5;
            const ny = y / S - 0.5;
            const ang = pseudo(x * 1.7, y * 0.7) * Math.PI * 2;
            const rad = Math.hypot(nx, ny) || 0.001;
            dots.push({
              x: nx,
              y: ny,
              r: data[i],
              g: data[i + 1],
              b: data[i + 2],
              a: data[i + 3] / 255,
              sx: (nx / rad) * 0.65 + Math.cos(ang) * 0.6,
              sy: (ny / rad) * 0.65 + Math.sin(ang) * 0.6,
              phase: pseudo(x + 3, y + 7) * Math.PI * 2,
            });
          }
        }
        sampled[ci] = dots.length ? dots : [];
      } catch {
        sampled[ci] = [];
      }
    };

    LOGOS.forEach((logo, ci) => {
      if (logo.src.endsWith(".svg")) {
        // SVGs may carry only a viewBox — inject a size and load via blob.
        fetch(logo.src)
          .then((r) => r.text())
          .then((svg) => {
            const m = svg.match(/viewBox=["']\s*[\d.]+\s+[\d.]+\s+([\d.]+)\s+([\d.]+)/);
            const vbw = m ? parseFloat(m[1]) : 140;
            const vbh = m ? parseFloat(m[2]) : 140;
            const sized = /<svg[^>]*\swidth=/.test(svg)
              ? svg
              : svg.replace("<svg", `<svg width="${vbw}" height="${vbh}"`);
            const url = URL.createObjectURL(new Blob([sized], { type: "image/svg+xml" }));
            const img = new Image();
            img.onload = () => {
              sample(img, ci);
              URL.revokeObjectURL(url);
            };
            img.onerror = () => {
              sampled[ci] = [];
              URL.revokeObjectURL(url);
            };
            img.src = url;
          })
          .catch(() => (sampled[ci] = []));
      } else {
        const img = new Image();
        img.onload = () => sample(img, ci);
        img.onerror = () => (sampled[ci] = []);
        img.src = logo.src;
      }
    });

    let raf = 0;
    let start = 0;
    let lastPaint = 0;

    // The ambient cycle is always present; summoned formations are appended on
    // click and spliced out once they finish dissolving. A single rAF loop
    // iterates this whole array each frame.
    const instances: Instance[] = [{ kind: "ambient" }];

    // Draw one formation's dot cloud. `coh` is the coherence envelope
    // (0 → invisible/scattered, 1 → fully resolved), `scale` lets summoned
    // formations sit a touch smaller than the ambient one. This body is the
    // original ambient inner loop verbatim, parameterised — same colour,
    // twinkle, jitter, sheen and scatter so every formation looks identical.
    const renderDots = (
      dots: Dot[],
      idx: number,
      cx: number,
      cy: number,
      coh: number,
      baseT: number,
      T: number,
      scale: number,
    ) => {
      const size = Math.min(W, H) * LOGOS[idx].scale * scale;
      const scatter = (1 - coh) * size * 0.6; // dots fly apart as it dissolves
      const rDot = Math.max(1.2, (size / S) * GAP * 0.5);

      for (const d of dots) {
        const tw = reduced ? 1 : 0.66 + 0.34 * Math.sin(baseT * 1.7 + d.phase);
        const jx = reduced ? 0 : Math.sin(baseT * 2.1 + d.phase) * 0.6;
        const jy = reduced ? 0 : Math.cos(baseT * 1.8 + d.phase * 1.3) * 0.6;

        const sh = reduced ? 0.25 : (Math.sin((d.x - d.y) * 5.5 - T) + 1) / 2;
        const hi = Math.pow(sh, 2.2);
        const r = d.r + (255 - d.r) * hi * 0.5;
        const g = d.g + (255 - d.g) * hi * 0.5;
        const b = d.b + (255 - d.b) * hi * 0.5;
        const alpha = coh * tw * d.a * (0.56 + hi * 0.24);
        if (alpha <= 0.01) continue;

        const px = cx + d.x * size + d.sx * scatter + jx;
        const py = cy + d.y * size + d.sy * scatter + jy;
        ctx.fillStyle = `rgba(${r | 0},${g | 0},${b | 0},${alpha})`;
        ctx.beginPath();
        ctx.arc(px, py, rDot * (0.5 + coh * 0.5), 0, Math.PI * 2);
        ctx.fill();
      }
    };

    const draw = (now: number) => {
      if (!start) start = now;
      if (now - lastPaint < 33 && !reduced) {
        raf = requestAnimationFrame(draw);
        return;
      }
      lastPaint = now;
      ctx.clearRect(0, 0, W, H);

      const baseT = (reduced ? 4 : now - start) / 1000; // seconds
      const T = now * 0.0011; // shared sheen sweep

      // Iterate backwards so a summoned instance can be spliced out in place
      // the moment its dissolve completes without skipping a neighbour.
      for (let i = instances.length - 1; i >= 0; i--) {
        const inst = instances[i];

        if (inst.kind === "ambient") {
          // Unchanged ambient cycle: same period, hashed positions, envelope.
          const cyc = baseT / PERIOD;
          const cycleNum = Math.floor(cyc);
          const idx = reduced ? 0 : cycleNum % LOGOS.length;
          const ph = reduced ? 0.5 : cyc - cycleNum;
          const dots = sampled[idx];
          if (!dots || !dots.length) continue;

          // resolve in (0–0.22), hold, dissolve out (0.78–1)
          const coh = reduced ? 0.92 : smoothstep(0, 0.22, ph) * (1 - smoothstep(0.78, 1, ph));
          if (coh <= 0.01) continue;

          // a NEW place each cycle (hashed), with a small local breathing wander
          const hx = reduced ? 0.5 : hash(cycleNum * 1.7 + 0.3);
          const hy = reduced ? 0.46 : hash(cycleNum * 2.3 + 7.1);
          const cx =
            (0.2 + 0.6 * hx) * W + (reduced ? 0 : Math.sin(baseT * 0.5 + cycleNum) * W * 0.02);
          const cy =
            (0.22 + 0.54 * hy) * H + (reduced ? 0 : Math.cos(baseT * 0.6 + cycleNum) * H * 0.02);

          renderDots(dots, idx, cx, cy, coh, baseT, T, 1);
        } else {
          // Summoned formation: finite lifecycle measured in real seconds.
          const dots = sampled[inst.idx];
          if (!dots || !dots.length) {
            instances.splice(i, 1); // logo failed to sample — free the slot
            continue;
          }
          const age = (now - inst.bornAt) / 1000;
          const total = SUMMON_RESOLVE + SUMMON_HOLD + SUMMON_DISSOLVE;
          if (age >= total) {
            instances.splice(i, 1); // dissolve finished — free the slot
            continue;
          }
          // resolve gracefully -> hold -> dissolve + scatter
          const coh =
            smoothstep(0, SUMMON_RESOLVE, age) *
            (1 - smoothstep(total - SUMMON_DISSOLVE, total, age));
          if (coh <= 0.01) continue;

          renderDots(dots, inst.idx, inst.cx, inst.cy, coh, baseT, T, SUMMON_SCALE);
        }
      }

      if (!reduced) raf = requestAnimationFrame(draw);
    };

    raf = requestAnimationFrame(draw);

    // Click anywhere to summon an extra formation near the pointer. Reduced
    // motion keeps the page calm, so no summoning there.
    let summonCounter = 0; // deterministic rotation through the logo pool
    const onPointer = (e: PointerEvent) => {
      if (reduced) return;
      const active = instances.reduce((n, inst) => n + (inst.kind === "summoned" ? 1 : 0), 0);
      if (active >= MAX_SUMMONED) return; // cap reached — ignore the click

      const idx = summonCounter++ % LOGOS.length;
      const dots = sampled[idx];
      if (!dots || !dots.length) return; // not sampled yet — nothing to show

      // Clamp so the formation stays fully on-screen around the pointer.
      const size = Math.min(W, H) * LOGOS[idx].scale * SUMMON_SCALE;
      const half = size / 2;
      const cx = Math.max(half, Math.min(W - half, e.clientX));
      const cy = Math.max(half, Math.min(H - half, e.clientY));

      instances.push({ kind: "summoned", idx, cx, cy, bornAt: performance.now() });
    };
    window.addEventListener("pointerdown", onPointer);

    let resizeTimer: number | undefined;
    const onResize = () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(resize, 150);
    };
    window.addEventListener("resize", onResize);

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", onResize);
      window.removeEventListener("pointerdown", onPointer);
      window.clearTimeout(resizeTimer);
    };
  }, []);

  return (
    <canvas
      ref={ref}
      aria-hidden
      style={{
        position: "fixed",
        inset: 0,
        width: "100%",
        height: "100%",
        zIndex: -1,
        pointerEvents: "none",
      }}
    />
  );
}
