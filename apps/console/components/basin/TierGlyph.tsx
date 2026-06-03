"use client";

import { useEffect, useRef } from "react";

/**
 * A tier crest "formed by the dots" — the website's PixelMatrix dot-grid wedded
 * to its holographic tier sheen, dialed down for the light editorial page. The
 * glyph (shield / lock / eye) is lit in the tier's hue; a slow iridescent band
 * sweeps the lit dots so it whispers rather than shouts.
 */

type GlyphName = "shield" | "lock" | "eye";

// 11×11 bitmaps — 1 = lit dot, 0 = faint dot. Hand-set so each reads cleanly
// at ~34px (encryption semantics: shield = end-to-end, lock = zero-access,
// eye = server-readable).
const GLYPHS: Record<GlyphName, string[]> = {
  shield: [
    "00011111000",
    "00111111100",
    "01111111110",
    "11111111111",
    "11111111111",
    "11111111111",
    "01111111110",
    "01111111110",
    "00111111100",
    "00011111000",
    "00000100000",
  ],
  lock: [
    "00011111000",
    "00110001100",
    "00100000100",
    "01111111110",
    "11111111111",
    "11110111111",
    "11100011111",
    "11110111111",
    "11111111111",
    "01111111110",
    "00000000000",
  ],
  eye: [
    "00000000000",
    "00001110000",
    "00111111100",
    "01111111110",
    "11110111111",
    "11100011111",
    "11110111111",
    "01111111110",
    "00111111100",
    "00001110000",
    "00000000000",
  ],
};

function readRgb(cssVar: string): [number, number, number] {
  if (typeof window === "undefined") return [120, 120, 120];
  const raw = getComputedStyle(document.documentElement).getPropertyValue(cssVar).trim();
  const hex = raw.replace("#", "");
  if (hex.length >= 6) {
    return [
      parseInt(hex.slice(0, 2), 16),
      parseInt(hex.slice(2, 4), 16),
      parseInt(hex.slice(4, 6), 16),
    ];
  }
  const m = raw.match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
  return m ? [+m[1], +m[2], +m[3]] : [120, 120, 120];
}

const mix = (a: number, b: number, t: number) => Math.round(a + (b - a) * t);

export function TierGlyph({
  glyph,
  colorVar,
  size = 34,
  label,
}: {
  glyph: GlyphName;
  colorVar: string;
  size?: number;
  label?: string;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const N = 11;
    const cell = size / N;
    const rLit = cell * 0.4;
    const rDim = cell * 0.28;
    const rows = GLYPHS[glyph];
    const base = readRgb(colorVar);
    const sheen: [number, number, number] = [240, 248, 255];

    canvas.width = Math.round(size * dpr);
    canvas.height = Math.round(size * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    let raf = 0;
    const draw = (now: number) => {
      const t = reduced ? 1700 : now;
      ctx.clearRect(0, 0, size, size);
      for (let r = 0; r < N; r++) {
        for (let c = 0; c < N; c++) {
          const x = c * cell + cell / 2;
          const y = r * cell + cell / 2;
          if (rows[r][c] === "1") {
            const wave = Math.sin(((c + (N - r)) / N) * Math.PI * 2 - t * 0.0015);
            const hi = Math.pow((wave + 1) / 2, 1.7);
            const col: [number, number, number] = [
              mix(base[0], sheen[0], hi * 0.62),
              mix(base[1], sheen[1], hi * 0.62),
              mix(base[2], sheen[2], hi * 0.62),
            ];
            ctx.shadowBlur = 2 + hi * 5;
            ctx.shadowColor = `rgba(${base[0]},${base[1]},${base[2]},0.7)`;
            ctx.fillStyle = `rgba(${col[0]},${col[1]},${col[2]},0.96)`;
            ctx.beginPath();
            ctx.arc(x, y, rLit, 0, Math.PI * 2);
            ctx.fill();
          } else {
            ctx.shadowBlur = 0;
            ctx.fillStyle = "rgba(22,20,15,0.06)";
            ctx.beginPath();
            ctx.arc(x, y, rDim, 0, Math.PI * 2);
            ctx.fill();
          }
        }
      }
      ctx.shadowBlur = 0;
      if (!reduced) raf = requestAnimationFrame(draw);
    };

    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, [glyph, colorVar, size]);

  return (
    <canvas
      ref={ref}
      role="img"
      aria-label={label ?? `${glyph} tier mark`}
      style={{ width: size, height: size, display: "block", flex: "none" }}
    />
  );
}
