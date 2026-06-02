"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { DATA_DOMAINS, type DataDomain } from "@/lib/domains";
import { usageById } from "@/lib/useDomainUsage";
import type { DataDomainUsageResponse } from "@/lib/api";

/**
 * The Basin — the member's data footprint rendered as swirling mercury. One eddy
 * per registry domain, sized by getDataDomainUsage, tinted by encryption tier.
 * Canvas 2D (radial-gradient eddies + drift); reduced-motion renders a single
 * static frame (no animation loop) so the hero never goes blank.
 */

const TIER_RGB: Record<DataDomain["encryptionTier"], [number, number, number]> = {
  // Read straight off the design tokens so colors never drift.
  server_readable: [253, 196, 44], // --color-tier-server-readable
  zero_access: [139, 148, 168], // --color-tier-zero-access
  end_to_end: [60, 214, 192], // --color-tier-end-to-end
};

interface Eddy {
  domain: DataDomain;
  weight: number; // 0..1 normalized footprint
  baseAngle: number;
  orbit: number; // 0..1 radius fraction
  spin: number;
  phase: number;
}

function buildEddies(usage: DataDomainUsageResponse | null): Eddy[] {
  const byId = usageById(usage);
  // Footprint = count + bytes proxy; log-scaled so one huge domain doesn't swamp.
  const raw = DATA_DOMAINS.map((d) => {
    const u = byId[d.id] ?? { count: 0, bytes: 0 };
    const score = u.count + u.bytes / (64 * 1024); // ~64KB per "unit"
    return Math.log1p(score);
  });
  const max = Math.max(1, ...raw);
  return DATA_DOMAINS.map((domain, i) => ({
    domain,
    weight: 0.18 + 0.82 * (raw[i] / max),
    baseAngle: (i / DATA_DOMAINS.length) * Math.PI * 2,
    orbit: 0.28 + 0.5 * ((i % 4) / 3),
    spin: 0.12 + (i % 3) * 0.05,
    phase: i * 1.37,
  }));
}

export function Basin({
  usage,
  className,
}: {
  usage: DataDomainUsageResponse | null;
  className?: string;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [hovered, setHovered] = useState<Eddy | null>(null);
  const eddies = useMemo(() => buildEddies(usage), [usage]);
  const eddiesRef = useRef(eddies);
  eddiesRef.current = eddies;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const reduced =
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

    let raf = 0;
    let width = 0;
    let height = 0;
    const dpr = Math.min(2, typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1);

    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      width = rect.width;
      height = rect.height;
      canvas.width = Math.max(1, Math.floor(width * dpr));
      canvas.height = Math.max(1, Math.floor(height * dpr));
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };

    const draw = (t: number) => {
      const cx = width / 2;
      const cy = height / 2;
      const R = Math.min(width, height) * 0.42;

      ctx.clearRect(0, 0, width, height);

      // Basin floor — cool mercury wash with a faint furnace glow at center.
      const floor = ctx.createRadialGradient(cx, cy, R * 0.1, cx, cy, R * 1.4);
      floor.addColorStop(0, "rgba(199,207,221,0.05)");
      floor.addColorStop(1, "rgba(5,5,8,0)");
      ctx.fillStyle = floor;
      ctx.fillRect(0, 0, width, height);

      ctx.globalCompositeOperation = "lighter";
      for (const e of eddiesRef.current) {
        const time = reduced ? 0 : t / 1000;
        const angle = e.baseAngle + time * e.spin;
        const wob = reduced ? 0 : Math.sin(time * 0.6 + e.phase) * 0.06;
        const r = R * (e.orbit + wob);
        const x = cx + Math.cos(angle) * r;
        const y = cy + Math.sin(angle) * r * 0.82; // basin is a shallow ellipse
        const radius = R * (0.16 + 0.34 * e.weight);
        const [cr, cg, cb] = TIER_RGB[e.domain.encryptionTier];
        const alpha = 0.1 + 0.34 * e.weight;

        const g = ctx.createRadialGradient(x, y, 0, x, y, radius);
        g.addColorStop(0, `rgba(${cr},${cg},${cb},${alpha})`);
        g.addColorStop(0.5, `rgba(${cr},${cg},${cb},${alpha * 0.4})`);
        g.addColorStop(1, "rgba(5,5,8,0)");
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(x, y, radius, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.globalCompositeOperation = "source-over";

      // Mercury rim — the basin lip.
      ctx.strokeStyle = "rgba(199,207,221,0.18)";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.ellipse(cx, cy, R, R * 0.82, 0, 0, Math.PI * 2);
      ctx.stroke();

      if (!reduced) raf = requestAnimationFrame(draw);
    };

    resize();
    if (reduced) {
      draw(0); // single static frame
    } else {
      raf = requestAnimationFrame(draw);
    }

    const ro = new ResizeObserver(() => {
      resize();
      if (reduced) draw(0);
    });
    ro.observe(canvas);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, []);

  // Hover hit-testing in DOM space (cheap: nearest eddy to pointer).
  const onMove = (ev: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const cx = rect.width / 2;
    const cy = rect.height / 2;
    const R = Math.min(rect.width, rect.height) * 0.42;
    const px = ev.clientX - rect.left;
    const py = ev.clientY - rect.top;
    let best: Eddy | null = null;
    let bestD = Infinity;
    for (const e of eddiesRef.current) {
      const x = cx + Math.cos(e.baseAngle) * R * e.orbit;
      const y = cy + Math.sin(e.baseAngle) * R * e.orbit * 0.82;
      const d = Math.hypot(px - x, py - y);
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    setHovered(bestD < R * 0.4 ? best : null);
  };

  return (
    <div className={className}>
      <div className="relative">
        <canvas
          ref={canvasRef}
          className="block h-[420px] w-full"
          onMouseMove={onMove}
          onMouseLeave={() => setHovered(null)}
          aria-label="Your data footprint, one mercury eddy per data domain, sized by how much data each holds."
          role="img"
        />
        {hovered && (
          <div className="pointer-events-none absolute left-1/2 top-4 -translate-x-1/2 rounded-md bg-glass-bg-elevated px-token-3 py-token-2 text-center backdrop-blur">
            <p className="font-display text-sm text-content-bright">{hovered.domain.title}</p>
            <p className="text-xs text-content-mute">{hovered.domain.summary}</p>
          </div>
        )}
      </div>
    </div>
  );
}
