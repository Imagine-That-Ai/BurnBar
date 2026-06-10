// Easter-egg FX overlay: jiggle the scroll (rapid up/down) to summon a
// 5-second takeover. DARK = LOGO STORM, LIGHT = CLOUD TOKEN RAIN; the very
// top/bottom bounce "you've reached the end" tokens. Idles until summoned.
// Relocated from a BaseLayout.astro `is:inline` script (see emberSwarm.ts
// for the delivery rationale). One deliberate deviation from the inline
// original: the ~1.1 MB of logo/crest fetches are deferred until the first
// scroll-direction event instead of running at page load.
// @ts-nocheck — verbatim JS; strict-TS conversion deferred.
(function () {
  var canvas = document.getElementById("bgFx");
  if (!canvas) return;
  var ctx = canvas.getContext("2d");
  if (!ctx) return;
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var LOGO_SRCS = [
    "/brand/vector/cloud_crest.svg",
    "/brand/vector/cloud_pro_crest.svg",
    "/brand/providers/openai.png",
    "/brand/providers/claude-code.png",
    "/brand/providers/codex.png",
    "/brand/providers/antigravity.png",
    "/brand/providers/hermes.png",
    "/brand/providers/openclaw.png",
    "/brand/providers/anthropic.png",
    "/brand/providers/cursor.png",
    "/brand/providers/gemini-cli.png",
    "/brand/providers/xai.png",
    "/brand/providers/windsurf.png",
    "/brand/providers/copilot.png",
    "/brand/providers/factory.png",
    "/brand/providers/warp.png",
    "/brand/providers/deepseek.svg",
    "/brand/providers/kimi.svg",
    "/brand/providers/minimax.png",
    "/brand/providers/zai.png",
    "/brand/providers/mimo.svg",
    "/brand/providers/qwen.svg",
    "/brand/providers/ollama.png",
    "/brand/providers/aider.png",
    "/brand/providers/cline.png",
    "/brand/providers/kilo-code.png",
    "/brand/providers/roo-code.png",
    "/brand/providers/forge.png",
    "/brand/providers/augment.png",
    "/brand/providers/opencode.png",
    "/brand/providers/goose.png",
    "/brand/providers/pi-agent.svg"
  ];
  var CREST_SRCS = ["/brand/vector/cloud_crest.svg", "/brand/vector/cloud_pro_crest.svg"];

  function loadImg(src, into, i) {
    if (/\.svg(\?|$)/.test(src)) {
      fetch(src)
        .then(function (r) {
          return r.text();
        })
        .then(function (svg) {
          var m = svg.match(/viewBox=["']\s*[\d.]+\s+[\d.]+\s+([\d.]+)\s+([\d.]+)/);
          var vbw = m ? parseFloat(m[1]) : 140,
            vbh = m ? parseFloat(m[2]) : 140;
          var sized = /<svg[^>]*\swidth=/.test(svg)
            ? svg
            : svg.replace("<svg", '<svg width="' + vbw + '" height="' + vbh + '"');
          var url = URL.createObjectURL(new Blob([sized], { type: "image/svg+xml" }));
          var img = new Image();
          img.onload = function () {
            into[i] = img;
            URL.revokeObjectURL(url);
          };
          img.onerror = function () {
            URL.revokeObjectURL(url);
          };
          img.src = url;
        })
        .catch(function () {});
    } else {
      var img = new Image();
      img.onload = function () {
        into[i] = img;
      };
      img.src = src;
    }
  }
  var logos = [];
  var crests = [];
  // Deferred asset init: the storm/rain need ~1.1 MB of logos/crests, but
  // they only fire after 5 scroll reversals inside 1.5s — so loading starts
  // on the FIRST direction event in onDir() (well before the summon
  // threshold) instead of at page load. drawImgP/drawCloud null-guard
  // not-yet-loaded images, and the boundary token bounce is pure canvas
  // gradients, so nothing here needs the images at first paint.
  var fxAssetsRequested = false;
  function loadFxAssets() {
    if (fxAssetsRequested) return;
    fxAssetsRequested = true;
    LOGO_SRCS.forEach(function (s, i) {
      loadImg(s, logos, i);
    });
    CREST_SRCS.forEach(function (s, i) {
      loadImg(s, crests, i);
    });
  }
  function loadedLogos() {
    return logos.filter(Boolean);
  }

  var dpr = Math.min(2, window.devicePixelRatio || 1),
    W = 0,
    H = 0;
  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.floor(W * dpr);
    canvas.height = Math.floor(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  resize();
  window.addEventListener("resize", resize);

  function rand(a, b) {
    return a + Math.random() * (b - a);
  }
  function clamp01(x) {
    return x < 0 ? 0 : x > 1 ? 1 : x;
  }
  function theme() {
    return document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark";
  }

  /* shape sampling for the storm */
  var offc = document.createElement("canvas");
  var octx = offc.getContext("2d", { willReadFrequently: true });
  var shapeCache = {};
  function samplePoints(text) {
    if (shapeCache[text]) return shapeCache[text];
    offc.width = 300;
    offc.height = 300;
    octx.clearRect(0, 0, 300, 300);
    octx.fillStyle = "#fff";
    octx.font = "800 170px ui-monospace, 'SFMono-Regular', Menlo, monospace";
    octx.textAlign = "center";
    octx.textBaseline = "middle";
    octx.fillText(text, 150, 150);
    var d = octx.getImageData(0, 0, 300, 300).data,
      pts = [];
    for (var y = 0; y < 300; y += 7) {
      for (var x = 0; x < 300; x += 7) {
        if (d[(y * 300 + x) * 4 + 3] > 128) pts.push({ x: (x - 150) / 300, y: (y - 150) / 300 });
      }
    }
    shapeCache[text] = pts;
    return pts;
  }

  var mode = "idle",
    fxStart = 0,
    FXDUR = 5000,
    nextEmit = 0;
  var sparks = [],
    phases = [],
    phaseI = 0;
  var clouds = [],
    tokens = [],
    rects = [],
    edge = [];
  var rafId = null,
    last = 0;
  function ensureLoop() {
    if (rafId == null) {
      last = 0;
      rafId = requestAnimationFrame(loop);
    }
  }

  /* ---------- LOGO STORM (dark) ---------- */
  function pickShape() {
    return ["$", ":)", "</>", "{ }"][(Math.random() * 4) | 0];
  }
  function burstAll() {
    var cx = rand(W * 0.2, W * 0.8),
      cy = rand(H * 0.2, H * 0.62);
    for (var i = 0; i < sparks.length; i++) {
      var p = sparks[i];
      p.target = null;
      var ang = Math.atan2(p.y - cy, p.x - cx) + rand(-0.5, 0.5),
        sp = rand(140, 460);
      p.vx = Math.cos(ang) * sp;
      p.vy = Math.sin(ang) * sp - rand(20, 140);
      p.vr = rand(-3, 3);
    }
  }
  function toShape(text) {
    var pts = samplePoints(text);
    if (!pts.length) {
      burstAll();
      return;
    }
    var N = sparks.length,
      use = pts;
    if (pts.length > N) {
      use = [];
      var stride = pts.length / N;
      for (var i = 0; i < N; i++) use.push(pts[Math.floor(i * stride)]);
    }
    var cx = W * 0.5,
      cy = H * 0.42,
      sc = Math.min(W, H) * 0.62;
    for (var j = 0; j < sparks.length; j++) {
      var q = use[j % use.length];
      sparks[j].target = j < use.length ? { x: cx + q.x * sc, y: cy + q.y * sc } : null;
    }
  }
  function startStorm(now) {
    mode = "storm";
    fxStart = now;
    sparks = [];
    phaseI = 0;
    var pool = loadedLogos();
    if (!pool.length) pool = logos;
    var N = 96;
    for (var i = 0; i < N; i++) {
      sparks.push({
        // Pick from the loaded pool (indexing the sparse raw array left the
        // fallback dead); drawImgP guards undefined while images stream in.
        img: pool[(Math.random() * pool.length) | 0],
        x: rand(0, W),
        y: rand(0, H),
        vx: 0,
        vy: 0,
        size: rand(22, 48),
        rot: rand(-0.5, 0.5),
        vr: rand(-2, 2),
        tw: rand(0, 6.28),
        target: null
      });
    }
    phases = [
      { at: now + 0, fn: burstAll },
      {
        at: now + 1050,
        fn: function () {
          toShape(pickShape());
        }
      },
      { at: now + 2250, fn: burstAll },
      {
        at: now + 3050,
        fn: function () {
          toShape(pickShape());
        }
      },
      { at: now + 4200, fn: burstAll }
    ];
    ensureLoop();
  }
  function updateStorm(now, dt) {
    while (phaseI < phases.length && now >= phases[phaseI].at) {
      phases[phaseI].fn();
      phaseI++;
    }
    var env = clamp01((now - fxStart) / 350) * clamp01((fxStart + FXDUR - now) / 650);
    for (var i = 0; i < sparks.length; i++) {
      var p = sparks[i];
      if (p.target) {
        var dx = p.target.x - p.x,
          dy = p.target.y - p.y;
        p.vx += (dx * 150 - p.vx * 24) * dt;
        p.vy += (dy * 150 - p.vy * 24) * dt;
      } else {
        p.vx = p.vx * Math.pow(0.5, dt) + Math.sin(now * 0.001 + p.tw) * 7 * dt;
        p.vy = p.vy * Math.pow(0.5, dt) + 14 * dt;
      }
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.rot += p.vr * dt;
      var a = env * (0.85 + 0.15 * Math.sin(now * 0.012 + p.tw));
      drawImgP(p.img, p.x, p.y, p.size, p.rot, a);
    }
    if (now > fxStart + FXDUR) {
      mode = "idle";
      sparks = [];
    }
  }

  /* ---------- CLOUD TOKEN RAIN (light) ---------- */
  function startRain(now) {
    mode = "rain";
    fxStart = now;
    tokens = [];
    clouds = [];
    nextEmit = now + 150;
    rects = [];
    document
      .querySelectorAll(".btn, .hero__h, .hero__copy .lead, .card, .pillar, h1, h2, h3, .console")
      .forEach(function (el) {
        var r = el.getBoundingClientRect();
        if (r.width > 40 && r.top > -60 && r.top < H + 60)
          rects.push({ l: r.left, r: r.right, t: r.top });
      });
    var nc = 7;
    for (var i = 0; i < nc; i++) {
      clouds.push({
        x: ((i + 0.5) / nc) * W + rand(-30, 30),
        y: rand(26, 120),
        w: rand(210, 360),
        vx: rand(-10, 10),
        crest: i % Math.max(1, crests.length),
        seed: rand(0, 99)
      });
    }
    ensureLoop();
  }
  function emit(_now) {
    for (var c = 0; c < clouds.length; c++) {
      var cl = clouds[c],
        n = 2 + ((Math.random() * 3) | 0);
      for (var j = 0; j < n; j++) {
        var gold = Math.random() < 0.5;
        tokens.push({
          x: cl.x + rand(-cl.w * 0.42, cl.w * 0.42),
          y: cl.y + cl.w * 0.18,
          vx: rand(-40, 40),
          vy: rand(20, 90),
          r: rand(5, 11),
          gold: gold,
          flip: rand(0, 6.28),
          vflip: rand(5, 11) * (Math.random() < 0.5 ? 1 : -1),
          tilt: rand(0, 6.28),
          vtilt: rand(-3, 3),
          rest: 0
        });
      }
    }
  }
  function updateRain(now, dt) {
    for (var c = 0; c < clouds.length; c++) {
      var cl = clouds[c];
      cl.x += cl.vx * dt;
      if (cl.x < -cl.w) cl.x = W + cl.w;
      if (cl.x > W + cl.w) cl.x = -cl.w;
      drawCloud(cl, now);
    }
    if (now >= nextEmit && now < fxStart + 4000) {
      emit(now);
      nextEmit = now + rand(85, 165);
    }
    var fade = now > fxStart + 4300 ? clamp01((fxStart + FXDUR + 700 - now) / 1000) : 1;
    for (var k = tokens.length - 1; k >= 0; k--) {
      var t = tokens[k];
      t.vy += 980 * dt;
      t.vx *= Math.pow(0.55, dt);
      t.x += t.vx * dt;
      t.y += t.vy * dt;
      t.flip += t.vflip * dt;
      t.tilt += t.vtilt * dt;
      if (t.x < t.r) {
        t.x = t.r;
        t.vx = Math.abs(t.vx) * 0.5;
        t.vflip *= 0.85;
      }
      if (t.x > W - t.r) {
        t.x = W - t.r;
        t.vx = -Math.abs(t.vx) * 0.5;
        t.vflip *= 0.85;
      }
      for (var ri = 0; ri < rects.length; ri++) {
        var R = rects[ri];
        if (t.vy > 0 && t.x > R.l - t.r && t.x < R.r + t.r && t.y > R.t - t.r && t.y < R.t + 12) {
          t.y = R.t - t.r;
          t.vy = -t.vy * 0.5;
          t.vx += rand(-30, 30);
          t.vflip *= 0.85;
        }
      }
      if (t.y > H - t.r) {
        t.y = H - t.r;
        if (Math.abs(t.vy) > 55) {
          t.vy = -Math.abs(t.vy) * 0.48;
          t.vx *= 0.7;
          t.vflip *= 0.7;
        } else {
          t.vy = 0;
          t.vx *= 0.82;
          t.vflip *= 0.86;
          t.rest++;
        }
      }
      drawToken(t, fade);
      if (now > fxStart + FXDUR + 800 || t.rest > 26) tokens.splice(k, 1);
    }
    if (now > fxStart + FXDUR && tokens.length === 0) {
      mode = "idle";
      clouds = [];
    }
  }

  /* ---------- drawing ---------- */
  function drawImgP(img, x, y, size, rot, a) {
    if (!img || a <= 0) return;
    var ratio = img.naturalHeight / img.naturalWidth || 1,
      w = size,
      h = size * ratio;
    ctx.save();
    ctx.globalAlpha = clamp01(a);
    ctx.translate(x, y);
    ctx.rotate(rot);
    ctx.drawImage(img, -w / 2, -h / 2, w, h);
    ctx.restore();
  }
  function drawToken(t, a) {
    if (a <= 0) return;
    var flip = Math.abs(Math.cos(t.flip));
    ctx.save();
    ctx.globalAlpha = clamp01(a);
    ctx.translate(t.x, t.y);
    ctx.rotate(t.tilt);
    ctx.scale(Math.max(0.12, flip), 1);
    var rr = t.r;
    if (flip < 0.16) {
      ctx.fillStyle = t.gold ? "#b8860b" : "#9aa3ad";
      ctx.fillRect(-rr * 0.22, -rr, rr * 0.44, rr * 2);
    } else {
      var g = ctx.createRadialGradient(-rr * 0.35, -rr * 0.4, rr * 0.1, 0, 0, rr);
      if (t.gold) {
        g.addColorStop(0, "#fff6d8");
        g.addColorStop(0.45, "#fdc42c");
        g.addColorStop(1, "#9a6b0a");
      } else {
        g.addColorStop(0, "#ffffff");
        g.addColorStop(0.45, "#e3e9ee");
        g.addColorStop(1, "#929aa6");
      }
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(0, 0, rr, 0, 6.283);
      ctx.fill();
      ctx.globalAlpha = clamp01(a) * 0.6;
      ctx.lineWidth = Math.max(1, rr * 0.13);
      ctx.strokeStyle = t.gold ? "#7c5208" : "#7d858f";
      ctx.beginPath();
      ctx.arc(0, 0, rr * 0.82, 0, 6.283);
      ctx.stroke();
      ctx.globalAlpha = clamp01(a) * 0.85;
      ctx.fillStyle = "rgba(255,255,255,0.75)";
      ctx.beginPath();
      ctx.arc(-rr * 0.32, -rr * 0.34, rr * 0.22, 0, 6.283);
      ctx.fill();
    }
    ctx.restore();
  }
  function puffPath(x, y, w, h) {
    ctx.beginPath();
    ctx.arc(x - w * 0.34, y + h * 0.05, h * 0.5, 0, 6.283);
    ctx.arc(x - w * 0.12, y - h * 0.12, h * 0.64, 0, 6.283);
    ctx.arc(x + w * 0.12, y - h * 0.16, h * 0.68, 0, 6.283);
    ctx.arc(x + w * 0.34, y + h * 0.02, h * 0.54, 0, 6.283);
    ctx.rect(x - w * 0.46, y - 2, w * 0.92, h * 0.56);
    ctx.closePath();
  }
  function drawCloud(cl, now) {
    var x = cl.x,
      y = cl.y + Math.sin(now * 0.0008 + cl.seed) * 4,
      w = cl.w,
      h = w * 0.46;
    ctx.save();
    ctx.fillStyle = "rgba(44,48,56,0.10)";
    puffPath(x, y + h * 0.3, w * 0.9, h * 0.7);
    ctx.fill();
    var g = ctx.createLinearGradient(x, y - h * 0.7, x, y + h * 0.7);
    g.addColorStop(0, "rgba(216,220,226,0.94)");
    g.addColorStop(0.55, "rgba(178,184,192,0.92)");
    g.addColorStop(1, "rgba(150,156,165,0.9)");
    ctx.fillStyle = g;
    puffPath(x, y, w, h);
    ctx.fill();
    ctx.fillStyle = "rgba(255,255,255,0.34)";
    puffPath(x, y - h * 0.2, w * 0.66, h * 0.5);
    ctx.fill();
    var img = crests[cl.crest];
    if (img) {
      ctx.globalAlpha = 0.92;
      var s = h * 1.05,
        ratio = img.naturalHeight / img.naturalWidth || 1;
      ctx.drawImage(img, x - s / 2, y - s * 0.96, s, s * ratio);
    }
    ctx.restore();
  }

  /* ---------- boundary "end of page" ---------- */
  function boundary(which, _now) {
    var y0 = which === "top" ? 8 : H - 8,
      dir = which === "top" ? 1 : -1,
      n = 10;
    for (var i = 0; i < n; i++) {
      edge.push({
        x: ((i + 0.5) / n) * W + rand(-14, 14),
        y: y0,
        vy: dir * rand(280, 460),
        g: -dir * 1150,
        r: rand(5, 9),
        gold: Math.random() < 0.5,
        flip: rand(0, 6.28),
        vflip: rand(6, 12),
        tilt: rand(0, 6.28),
        vtilt: rand(-2, 2),
        t: 0
      });
    }
    ensureLoop();
  }

  function loop(now) {
    rafId = null;
    var dt = last ? Math.min(0.05, (now - last) / 1000) : 0.016;
    last = now;
    ctx.clearRect(0, 0, W, H);
    if (mode === "storm") updateStorm(now, dt);
    else if (mode === "rain") updateRain(now, dt);
    for (var e = edge.length - 1; e >= 0; e--) {
      var et = edge[e];
      et.t += dt;
      et.vy += et.g * dt;
      et.y += et.vy * dt;
      et.flip += et.vflip * dt;
      et.tilt += et.vtilt * dt;
      var fa = et.t > 0.55 ? clamp01((0.95 - et.t) / 0.4) : 1;
      if (et.t > 0.95) {
        edge.splice(e, 1);
        continue;
      }
      drawToken(et, fa);
    }
    if (mode !== "idle" || edge.length) rafId = requestAnimationFrame(loop);
    else {
      ctx.clearRect(0, 0, W, H);
      last = 0;
    }
  }

  /* ---------- triggers ---------- */
  var revTimes = [],
    lastDir = 0,
    cooldownUntil = 0,
    lastBoundary = 0;
  function onDir(dir, now) {
    if (!dir) return;
    if (dir !== lastDir) {
      lastDir = dir;
      revTimes.push(now);
      loadFxAssets();
    }
    while (revTimes.length && now - revTimes[0] > 1500) revTimes.shift();
    if (revTimes.length >= 5 && now > cooldownUntil && mode === "idle") {
      cooldownUntil = now + 9000;
      revTimes = [];
      if (reduced) return;
      if (theme() === "light") startRain(now);
      else startStorm(now);
    }
  }
  function atTop() {
    return (window.scrollY || 0) <= 0;
  }
  function atBottom() {
    return window.innerHeight + (window.scrollY || 0) >= document.documentElement.scrollHeight - 1;
  }
  var lastY = window.scrollY || 0;
  window.addEventListener(
    "scroll",
    function () {
      var y = window.scrollY || 0,
        d = y - lastY;
      lastY = y;
      if (Math.abs(d) > 2) onDir(d > 0 ? 1 : -1, performance.now());
    },
    { passive: true }
  );
  window.addEventListener(
    "wheel",
    function (ev) {
      var now = performance.now();
      if (Math.abs(ev.deltaY) > 1) onDir(ev.deltaY > 0 ? 1 : -1, now);
      if (!reduced && now > lastBoundary + 1200) {
        if (atTop() && ev.deltaY < 0) {
          lastBoundary = now;
          boundary("top", now);
        } else if (atBottom() && ev.deltaY > 0) {
          lastBoundary = now;
          boundary("bottom", now);
        }
      }
    },
    { passive: true }
  );
  var tY = 0;
  window.addEventListener(
    "touchstart",
    function (e) {
      tY = e.touches[0].clientY;
    },
    { passive: true }
  );
  window.addEventListener(
    "touchmove",
    function (e) {
      var y = e.touches[0].clientY,
        dy = y - tY;
      tY = y;
      var now = performance.now();
      if (Math.abs(dy) > 4) onDir(dy < 0 ? 1 : -1, now);
      if (!reduced && now > lastBoundary + 1200) {
        if (atTop() && dy > 0) {
          lastBoundary = now;
          boundary("top", now);
        } else if (atBottom() && dy < 0) {
          lastBoundary = now;
          boundary("bottom", now);
        }
      }
    },
    { passive: true }
  );
})();
