// Dot-logo constellation — canvas background (LIGHT theme). BurnBar crests +
// provider logos sampled into colored dots that resolve into a logo, shimmer,
// scatter/dissolve, and reappear as a different logo elsewhere.
// Relocated from a BaseLayout.astro `is:inline` script (see emberSwarm.ts
// for the delivery rationale). Two deliberate deviations from the inline
// original: the ~1.1 MB of logo fetches + sampling are deferred until the
// light theme is active, since this canvas paints nothing in dark mode; and
// the rAF loop parks in dark theme (resumed by a data-theme observer)
// instead of waking every vsync to early-return. Phase is wall-clock-based
// (rAF timestamp), so pause/resume lands on the identical animation frame.
// @ts-nocheck — verbatim JS; strict-TS conversion deferred.
(function () {
  var canvas = document.getElementById("bgDots");
  if (!canvas) return;
  var ctx = canvas.getContext("2d");
  if (!ctx) return;
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Full provider roster — mirrors the native AgentProvider.swarmGlyphProviders
  // order, interleaved with the three BurnBar Cloud crests. (Cursor Agent
  // shares Cursor's mark; Anthropic + Qwen ride along as brand moments.)
  var LOGOS = [
    { src: "/brand/vector/cloud_crest.svg", scale: 0.4 },
    { src: "/brand/providers/openai.png", scale: 0.26 },
    { src: "/brand/providers/claude-code.png", scale: 0.26 },
    { src: "/brand/providers/codex.png", scale: 0.26 },
    { src: "/brand/providers/gemini-cli.png", scale: 0.26 },
    { src: "/brand/providers/cursor.png", scale: 0.26 },
    { src: "/brand/providers/copilot.png", scale: 0.25 },
    { src: "/brand/vector/cloud_pro_crest.svg", scale: 0.4 },
    { src: "/brand/providers/deepseek.svg", scale: 0.27 },
    { src: "/brand/providers/kimi.svg", scale: 0.26 },
    { src: "/brand/providers/minimax.png", scale: 0.26 },
    { src: "/brand/providers/zai.png", scale: 0.26 },
    { src: "/brand/providers/xai.png", scale: 0.24 },
    { src: "/brand/providers/mimo.svg", scale: 0.26 },
    { src: "/brand/providers/qwen.svg", scale: 0.26 },
    { src: "/brand/providers/ollama.png", scale: 0.26 },
    { src: "/brand/providers/windsurf.png", scale: 0.26 },
    { src: "/brand/providers/warp.png", scale: 0.26 },
    { src: "/brand/providers/factory.png", scale: 0.26 },
    { src: "/brand/providers/antigravity.png", scale: 0.27 },
    { src: "/brand/providers/aider.png", scale: 0.26 },
    { src: "/brand/providers/cline.png", scale: 0.26 },
    { src: "/brand/providers/kilo-code.png", scale: 0.26 },
    { src: "/brand/providers/roo-code.png", scale: 0.26 },
    { src: "/brand/providers/forge.png", scale: 0.26 },
    { src: "/brand/providers/augment.png", scale: 0.26 },
    { src: "/brand/providers/opencode.png", scale: 0.26 },
    { src: "/brand/providers/goose.png", scale: 0.26 },
    { src: "/brand/providers/openclaw.png", scale: 0.27 },
    { src: "/brand/providers/pi-agent.svg", scale: 0.26 },
    { src: "/brand/providers/anthropic.png", scale: 0.25 },
    { src: "/brand/providers/hermes.png", scale: 0.26 }
  ];
  var PERIOD = 9.5,
    S = 200,
    GAP = 4;

  function smoothstep(a, b, x) {
    var t = Math.max(0, Math.min(1, (x - a) / (b - a || 1)));
    return t * t * (3 - 2 * t);
  }
  function hash(n) {
    var v = Math.sin(n * 127.1 + 311.7) * 43758.5453;
    return v - Math.floor(v);
  }
  function pseudo(x, y) {
    var v = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
    return v - Math.floor(v);
  }

  var dpr = Math.min(2, window.devicePixelRatio || 1);
  var W = 0,
    H = 0;
  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.floor(W * dpr);
    canvas.height = Math.floor(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  resize();
  var rt;
  window.addEventListener("resize", function () {
    clearTimeout(rt);
    rt = setTimeout(resize, 150);
  });

  var sampled = LOGOS.map(function () {
    return null;
  });

  function sample(img, ci) {
    try {
      var off = document.createElement("canvas");
      off.width = S;
      off.height = S;
      var octx = off.getContext("2d", { willReadFrequently: true });
      if (!octx) {
        sampled[ci] = [];
        return;
      }
      var ar = img.naturalWidth / img.naturalHeight || 1;
      var dw = S * 0.92,
        dh = S * 0.92;
      if (ar > 1) dh = dw / ar;
      else dw = dh * ar;
      octx.clearRect(0, 0, S, S);
      octx.drawImage(img, (S - dw) / 2, (S - dh) / 2, dw, dh);
      var data = octx.getImageData(0, 0, S, S).data;
      var bgR = data[0],
        bgG = data[1],
        bgB = data[2],
        bgOpaque = data[3] > 200;
      var dots = [];
      for (var y = 0; y < S; y += GAP) {
        for (var x = 0; x < S; x += GAP) {
          var i = (y * S + x) * 4;
          if (data[i + 3] < 48) continue;
          if (bgOpaque) {
            var dr = data[i] - bgR,
              dg = data[i + 1] - bgG,
              db = data[i + 2] - bgB;
            if (dr * dr + dg * dg + db * db < 3000) continue;
          }
          var nx = x / S - 0.5,
            ny = y / S - 0.5;
          var ang = pseudo(x * 1.7, y * 0.7) * Math.PI * 2;
          var rad = Math.hypot(nx, ny) || 0.001;
          dots.push({
            x: nx,
            y: ny,
            r: data[i],
            g: data[i + 1],
            b: data[i + 2],
            a: data[i + 3] / 255,
            sx: (nx / rad) * 0.65 + Math.cos(ang) * 0.6,
            sy: (ny / rad) * 0.65 + Math.sin(ang) * 0.6,
            phase: pseudo(x + 3, y + 7) * Math.PI * 2
          });
        }
      }
      sampled[ci] = dots.length ? dots : [];
    } catch {
      sampled[ci] = [];
    }
  }

  // Deferred logo init: fetching + sampling the 32 logos costs ~1.1 MB of
  // requests and a burst of drawImage/getImageData work, but this canvas only
  // paints under data-theme="light". Light visitors start loading at parse
  // time (same timing as the eager original); dark visitors pay nothing
  // unless they toggle, in which case the per-frame theme check in draw()
  // kicks it off and the sampled[] null guards cover the in-flight window.
  var logosRequested = false;
  function loadLogos() {
    if (logosRequested) return;
    logosRequested = true;
    LOGOS.forEach(function (logo, ci) {
      if (/\.svg(\?|$)/.test(logo.src)) {
        fetch(logo.src)
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
              sample(img, ci);
              URL.revokeObjectURL(url);
            };
            img.onerror = function () {
              sampled[ci] = [];
              URL.revokeObjectURL(url);
            };
            img.src = url;
          })
          .catch(function () {
            sampled[ci] = [];
          });
      } else {
        var img = new Image();
        img.onload = function () {
          sample(img, ci);
        };
        img.onerror = function () {
          sampled[ci] = [];
        };
        img.src = logo.src;
      }
    });
  }
  if (document.documentElement.getAttribute("data-theme") === "light") loadLogos();

  var start = 0,
    lastPaint = 0,
    cleared = false,
    rafId = null;
  function draw(now) {
    if (document.documentElement.getAttribute("data-theme") !== "light") {
      // DARK theme: the ember swarm owns the background. Clear once and
      // park; ensureLoop() (via the data-theme observer) resumes us.
      if (!cleared) {
        ctx.clearRect(0, 0, W, H);
        cleared = true;
      }
      rafId = null;
      return;
    }
    rafId = requestAnimationFrame(draw);
    cleared = false;
    loadLogos();
    if (now - lastPaint < 33) return;
    lastPaint = now;
    if (!start) start = now;
    ctx.clearRect(0, 0, W, H);

    var baseT = (reduced ? 4 : now - start) / 1000;
    var cyc = baseT / PERIOD;
    var cycleNum = Math.floor(cyc);
    var idx = reduced ? 0 : cycleNum % LOGOS.length;
    var ph = reduced ? 0.5 : cyc - cycleNum;
    var dots = sampled[idx];
    if (!dots || !dots.length) return;
    var coh = reduced ? 0.92 : smoothstep(0, 0.22, ph) * (1 - smoothstep(0.78, 1, ph));
    if (coh <= 0.01) return;

    var size = Math.min(W, H) * LOGOS[idx].scale;
    var hx = reduced ? 0.5 : hash(cycleNum * 1.7 + 0.3);
    var hy = reduced ? 0.46 : hash(cycleNum * 2.3 + 7.1);
    var cx = (0.2 + 0.6 * hx) * W + (reduced ? 0 : Math.sin(baseT * 0.5 + cycleNum) * W * 0.02);
    var cy = (0.22 + 0.54 * hy) * H + (reduced ? 0 : Math.cos(baseT * 0.6 + cycleNum) * H * 0.02);
    var scatter = (1 - coh) * size * 0.6;
    var rDot = Math.max(1.2, (size / S) * GAP * 0.5);
    var T = now * 0.0011;

    for (var k = 0; k < dots.length; k++) {
      var d = dots[k];
      var tw = reduced ? 1 : 0.66 + 0.34 * Math.sin(baseT * 1.7 + d.phase);
      var jx = reduced ? 0 : Math.sin(baseT * 2.1 + d.phase) * 0.6;
      var jy = reduced ? 0 : Math.cos(baseT * 1.8 + d.phase * 1.3) * 0.6;
      var sh = reduced ? 0.25 : (Math.sin((d.x - d.y) * 5.5 - T) + 1) / 2;
      var hi = Math.pow(sh, 2.2);
      var r = d.r + (255 - d.r) * hi * 0.5;
      var g = d.g + (255 - d.g) * hi * 0.5;
      var b = d.b + (255 - d.b) * hi * 0.5;
      var alpha = coh * tw * d.a * (0.56 + hi * 0.24);
      if (alpha <= 0.01) continue;
      var px = cx + d.x * size + d.sx * scatter + jx;
      var py = cy + d.y * size + d.sy * scatter + jy;
      ctx.fillStyle = "rgba(" + (r | 0) + "," + (g | 0) + "," + (b | 0) + "," + alpha + ")";
      ctx.beginPath();
      ctx.arc(px, py, rDot * (0.5 + coh * 0.5), 0, Math.PI * 2);
      ctx.fill();
    }
  }
  function ensureLoop() {
    if (rafId == null) rafId = requestAnimationFrame(draw);
  }
  ensureLoop();
  new MutationObserver(function () {
    if (document.documentElement.getAttribute("data-theme") === "light") ensureLoop();
  }).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"]
  });
})();
