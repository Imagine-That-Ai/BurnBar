/**
 * @fileoverview Neural-variant particle field for /bench/arena/vote.
 *
 * Two slow streams of motes — ember entering from the left edge, teal from
 * the right — drift toward the vertical seam at the center of the arena
 * section and link up with thin filaments when neighbours come close. Pure
 * dressing for the "neural" A/B/C skin: the canvas is pointer-events: none,
 * aria-hidden, shown by CSS only under [data-arena-variant="neural"], and
 * animated only when this module is initialized for that variant.
 *
 * Respects prefers-reduced-motion (renders one static constellation and
 * stops), scales for devicePixelRatio, follows container resizes, and idles
 * when the tab is hidden (rAF naturally suspends).
 */

interface Mote {
  x: number;
  y: number;
  vx: number;
  vy: number;
  r: number;
  /** 0 = ember (left stream), 1 = teal (right stream). */
  side: 0 | 1;
  /** 0..1 fade so motes dissolve as they approach the seam. */
  life: number;
}

const LINK_DIST = 120;
const EMBER = "255, 122, 61";
const TEAL = "47, 216, 196";

export function initArenaNet(canvas: HTMLCanvasElement): void {
  const ctx = canvas.getContext("2d");
  const host = canvas.parentElement;
  if (!ctx || !host) return;

  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let w = 0;
  let h = 0;
  let dpr = 1;
  let motes: Mote[] = [];
  let raf = 0;

  const spawn = (side: 0 | 1, anywhere = false): Mote => {
    const fromLeft = side === 0;
    return {
      side,
      x: anywhere ? Math.random() * w : fromLeft ? -8 : w + 8,
      y: Math.random() * h,
      vx: (fromLeft ? 1 : -1) * (0.18 + Math.random() * 0.3),
      vy: (Math.random() - 0.5) * 0.22,
      r: 1.2 + Math.random() * 1.7,
      life: 0
    };
  };

  const resize = (): void => {
    const rect = host.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = Math.max(1, rect.width);
    h = Math.max(1, rect.height);
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    const count = Math.round(Math.min(170, Math.max(72, (w * h) / 9000)));
    motes = Array.from({ length: count }, (_, i) => spawn(i % 2 === 0 ? 0 : 1, true));
  };

  const draw = (advance: boolean): void => {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    const seam = w / 2;

    for (const m of motes) {
      if (advance) {
        m.x += m.vx;
        m.y += m.vy + Math.sin((m.x + m.r * 97) * 0.008) * 0.12;
        // Fade in from the edge, dissolve as the seam nears, then respawn.
        const distToSeam = Math.abs(m.x - seam);
        const entered = Math.min(1, (m.side === 0 ? m.x : w - m.x) / 180);
        m.life = Math.max(0, Math.min(entered, distToSeam / (w * 0.22)));
        if (distToSeam < 6 || m.x < -24 || m.x > w + 24) Object.assign(m, spawn(m.side));
      } else {
        m.life = 0.85;
      }
    }

    // Filaments between close neighbours — the "network" of the skin.
    ctx.lineWidth = 0.8;
    for (let i = 0; i < motes.length; i++) {
      const a = motes[i];
      if (!a) continue;
      for (let j = i + 1; j < motes.length; j++) {
        const b = motes[j];
        if (!b) continue;
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        const d2 = dx * dx + dy * dy;
        if (d2 > LINK_DIST * LINK_DIST) continue;
        const t = 1 - Math.sqrt(d2) / LINK_DIST;
        const rgb = a.side === b.side ? (a.side === 0 ? EMBER : TEAL) : "190, 200, 220";
        ctx.strokeStyle = `rgba(${rgb}, ${(t * 0.3 * Math.min(a.life, b.life)).toFixed(3)})`;
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
        ctx.stroke();
      }
    }

    for (const m of motes) {
      const rgb = m.side === 0 ? EMBER : TEAL;
      ctx.fillStyle = `rgba(${rgb}, ${(0.9 * m.life).toFixed(3)})`;
      ctx.beginPath();
      ctx.arc(m.x, m.y, m.r, 0, Math.PI * 2);
      ctx.fill();
    }
  };

  const tick = (): void => {
    draw(true);
    raf = requestAnimationFrame(tick);
  };

  resize();
  new ResizeObserver(resize).observe(host);
  if (reduced) {
    draw(false); // one static constellation, no motion
  } else {
    raf = requestAnimationFrame(tick);
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        cancelAnimationFrame(raf);
      } else {
        raf = requestAnimationFrame(tick);
      }
    });
  }
}
