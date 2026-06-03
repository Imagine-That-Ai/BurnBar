/* ============================================================================
   Pensieve — the basin
   A single liquid-silver pool rendered behind every surface. Memories live as
   strands of light in the depths: they drift at rest and rise when recalled.
   Motion is meaning, never decoration — and under prefers-reduced-motion the
   pool holds a single calm frame.
   ========================================================================== */
(function () {
  "use strict";

  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const canvas = document.getElementById("basin-canvas");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");

  let W = 0, H = 0, DPR = 1;
  let strands = [];
  let caustics = [];
  let ripples = [];
  let descents = [];
  let mood = { tint: [60, 214, 192], strength: 0.5 };
  let running = false;
  let t0 = 0;

  function rand(a, b) { return a + Math.random() * (b - a); }

  function resize() {
    DPR = Math.min(2, window.devicePixelRatio || 1);
    W = canvas.clientWidth = window.innerWidth;
    H = canvas.clientHeight = window.innerHeight;
    canvas.width = Math.floor(W * DPR);
    canvas.height = Math.floor(H * DPR);
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  }

  function seed() {
    strands = [];
    const n = Math.max(18, Math.min(46, Math.round((W * H) / 42000)));
    for (let i = 0; i < n; i++) {
      const teal = Math.random() < 0.22;
      strands.push({
        x: rand(0, W),
        depth: rand(0.15, 1), // 1 = deep/dim, 0.15 = near surface
        len: rand(40, 150),
        sway: rand(0.2, 0.8),
        phase: rand(0, Math.PI * 2),
        speed: rand(0.04, 0.12),
        drift: rand(-0.05, 0.05),
        teal,
        rise: 0, // 0..1 transient brightness when recalled
      });
    }
    caustics = [];
    for (let i = 0; i < 6; i++) {
      caustics.push({
        x: rand(0, W), y: rand(0, H),
        r: rand(200, 460),
        a: rand(0.02, 0.06),
        sp: rand(0.5, 1.4) * (Math.random() < 0.5 ? -1 : 1),
        ph: rand(0, Math.PI * 2),
      });
    }
  }

  function drawBase() {
    // deep vertical gradient — ink void at the rim, a touch of life mid-depth
    const g = ctx.createLinearGradient(0, 0, 0, H);
    g.addColorStop(0, "#08080c");
    g.addColorStop(0.55, "#070709");
    g.addColorStop(1, "#050507");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);

    // a single brand-warm furnace ember far in the lower depths
    const fg = ctx.createRadialGradient(W * 0.5, H * 1.15, 0, W * 0.5, H * 1.15, H * 0.9);
    fg.addColorStop(0, "rgba(24,8,5,0.5)");
    fg.addColorStop(1, "rgba(24,8,5,0)");
    ctx.fillStyle = fg;
    ctx.fillRect(0, 0, W, H);
  }

  function drawCaustics(time) {
    ctx.globalCompositeOperation = "lighter";
    for (const c of caustics) {
      const x = c.x + Math.cos(time * 0.00008 * c.sp + c.ph) * 80;
      const y = c.y + Math.sin(time * 0.00006 * c.sp + c.ph) * 60;
      const grad = ctx.createRadialGradient(x, y, 0, x, y, c.r);
      const [r, gg, b] = mood.tint;
      grad.addColorStop(0, "rgba(" + r + "," + gg + "," + b + "," + c.a * mood.strength + ")");
      grad.addColorStop(1, "rgba(" + r + "," + gg + "," + b + ",0)");
      ctx.fillStyle = grad;
      ctx.fillRect(0, 0, W, H);
    }
    ctx.globalCompositeOperation = "source-over";
  }

  function drawStrand(s, time) {
    const surfaceY = H * (0.12 + s.depth * 0.78);
    const sway = Math.sin(time * 0.001 * s.speed * 6 + s.phase) * s.sway * 26 * (1 - s.depth * 0.5);
    const x = s.x + sway;
    const baseAlpha = (1 - s.depth) * 0.5 + 0.06;
    const alpha = Math.min(0.95, baseAlpha + s.rise * 0.7);
    const len = s.len * (1 + s.rise * 0.5);
    const top = surfaceY - len / 2 - s.rise * 60;
    const bot = surfaceY + len / 2;

    const grad = ctx.createLinearGradient(x, top, x, bot);
    const col = s.teal ? "60,214,192" : "199,207,221";
    grad.addColorStop(0, "rgba(" + col + ",0)");
    grad.addColorStop(0.5, "rgba(" + col + "," + alpha + ")");
    grad.addColorStop(1, "rgba(" + col + ",0)");

    ctx.globalCompositeOperation = "lighter";
    ctx.strokeStyle = grad;
    ctx.lineWidth = 1 + (1 - s.depth) * 1.6 + s.rise * 1.5;
    ctx.lineCap = "round";
    ctx.shadowBlur = (6 + s.rise * 18) * (1 - s.depth * 0.4);
    ctx.shadowColor = "rgba(" + col + "," + (0.4 + s.rise * 0.4) + ")";
    ctx.beginPath();
    ctx.moveTo(x, top);
    ctx.quadraticCurveTo(x + sway * 0.3, surfaceY, x, bot);
    ctx.stroke();
    ctx.shadowBlur = 0;
    ctx.globalCompositeOperation = "source-over";
  }

  function drawRipples() {
    ctx.globalCompositeOperation = "lighter";
    for (const rp of ripples) {
      const p = rp.t / rp.life;
      const r = p * rp.max;
      ctx.beginPath();
      ctx.arc(rp.x, rp.y, r, 0, Math.PI * 2);
      ctx.strokeStyle = "rgba(60,214,192," + (1 - p) * 0.5 + ")";
      ctx.lineWidth = 2 * (1 - p) + 0.5;
      ctx.stroke();
    }
    ctx.globalCompositeOperation = "source-over";
  }

  function drawDescents() {
    ctx.globalCompositeOperation = "lighter";
    for (const d of descents) {
      const p = d.t / d.life;
      const y = d.y0 + p * (H * (0.55) - d.y0);
      const alpha = (1 - p) * 0.9;
      const len = 70 * (1 - p * 0.6);
      const grad = ctx.createLinearGradient(d.x, y - len / 2, d.x, y + len / 2);
      grad.addColorStop(0, "rgba(60,214,192,0)");
      grad.addColorStop(0.5, "rgba(180,243,234," + alpha + ")");
      grad.addColorStop(1, "rgba(60,214,192,0)");
      ctx.strokeStyle = grad;
      ctx.lineWidth = 2.4 * (1 - p) + 0.6;
      ctx.shadowBlur = 16 * (1 - p);
      ctx.shadowColor = "rgba(60,214,192,0.6)";
      ctx.beginPath();
      ctx.moveTo(d.x, y - len / 2);
      ctx.lineTo(d.x + Math.sin(p * 6) * 4, y + len / 2);
      ctx.stroke();
      ctx.shadowBlur = 0;
      // dissolve ring at the end
      if (p > 0.8) {
        ctx.beginPath();
        ctx.arc(d.x, H * 0.55, (p - 0.8) * 120, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(60,214,192," + (1 - p) * 1.2 + ")";
        ctx.lineWidth = 1;
        ctx.stroke();
      }
    }
    ctx.globalCompositeOperation = "source-over";
  }

  function frame(now) {
    if (!running) return;
    if (!t0) t0 = now;
    const time = now - t0;

    drawBase();
    drawCaustics(time);
    for (const s of strands) {
      drawStrand(s, time);
      if (s.rise > 0) s.rise = Math.max(0, s.rise - 0.01);
      s.x += s.drift;
      if (s.x < -60) s.x = W + 60;
      if (s.x > W + 60) s.x = -60;
    }
    // ripples
    ripples = ripples.filter((rp) => { rp.t += 16; return rp.t < rp.life; });
    drawRipples();
    descents = descents.filter((d) => { d.t += 16; return d.t < d.life; });
    drawDescents();

    requestAnimationFrame(frame);
  }

  function renderStill() {
    // one calm frame for reduced-motion
    drawBase();
    const time = 4000;
    for (const c of caustics) c.a *= 0.7;
    drawCaustics(time);
    for (const s of strands) { s.sway = 0; drawStrand(s, time); }
  }

  /* ---- public API ------------------------------------------------------- */
  const Basin = {
    // Trigger an expanding ripple at viewport coords, and nudge nearby strands
    // to rise — the recall "dip into the pool".
    ripple(x, y) {
      if (reduce) return;
      ripples.push({ x, y, t: 0, life: 800, max: Math.max(W, H) * 0.5 });
      const order = strands.slice().sort(() => Math.random() - 0.5).slice(0, 8);
      order.forEach((s, i) => setTimeout(() => { s.rise = 0.9; }, i * 60));
    },
    // A memory descends from the form and dissolves into the surface (commit).
    commit(x) {
      if (reduce) return;
      descents.push({ x: x || W * 0.5, y0: H * 0.18, t: 0, life: 1100 });
    },
    // Subtly retint the pool per surface.
    setMood(name) {
      const moods = {
        basin: [60, 214, 192], recall: [60, 214, 192], cloak: [139, 148, 168],
        remember: [250, 107, 6], privacy: [199, 207, 221], audit: [253, 196, 44],
        vault: [60, 214, 192], engine: [199, 207, 221], constellation: [60, 214, 192],
      };
      mood.tint = moods[name] || [60, 214, 192];
      mood.strength = name === "cloak" ? 0.4 : 0.55;
    },
    pause() { running = false; },
    resume() { if (!running && !reduce) { running = true; t0 = 0; requestAnimationFrame(frame); } },
  };

  function boot() {
    resize();
    seed();
    if (reduce) {
      renderStill();
    } else {
      running = true;
      requestAnimationFrame(frame);
    }
  }

  let resizeTimer;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { resize(); seed(); if (reduce) renderStill(); }, 150);
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) Basin.pause();
    else Basin.resume();
  });

  window.Basin = Basin;
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
