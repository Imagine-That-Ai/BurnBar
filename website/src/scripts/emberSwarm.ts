// Interactive token ember swarm — canvas background (DARK theme).
// Relocated verbatim from a BaseLayout.astro `is:inline` script so the bytes
// ship once as a hashed immutable /_assets module instead of being re-inlined
// into every page (HTML is no-cache: always revalidated). Pixel parity with the inline original,
// with two intended behavior deltas: (1) prefers-reduced-motion users get a
// single static ember frame (no rAF loop, no cycle timers, no scroll/mouse
// listeners); (2) the rAF loop parks while the LIGHT theme owns the
// background (resumed by a data-theme observer) and element rects refresh at
// most once per painted frame via a dirty flag instead of per scroll event
// plus a permanent 1.2s poll — same pixels, near-zero idle/scroll cost.
// @ts-nocheck — verbatim JS; strict-TS conversion deferred.
(function () {
  const canvas = document.getElementById("bgCanvas");
  if (!canvas) return;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;

  const reduced =
    window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const isHome =
    window.location.pathname === "/" ||
    window.location.pathname === "/index.html" ||
    window.location.pathname.endsWith("/");
  const isRouter = window.location.pathname.includes("/router");

  // Dynamic Pace Settings based on user page preference:
  // - Home page: snappy, energetic, responsive murmuration pace (previous style)
  // - Other pages: slow, elegant, highly viscous cinematic murmuration pace
  const pace = {
    timeStep: isHome ? 0.000018 : 0.000004,
    swarmNoise: isHome ? 0.12 : 0.02,
    swarmDrag: isHome ? 0.985 : 0.97,
    maxSpeedGlyph: isHome ? 1.4 : 0.35,
    maxSpeedPixel: isHome ? 2.4 : 0.6,
    morphAttract: isHome ? 0.6 : 0.12,
    morphNoise: isHome ? 0.045 : 0.008,
    morphDrag: isHome ? 0.88 : 0.9,
    cycleInterval: isHome ? 8000 : 14000,
    mouseForceMultiplier: isHome ? 1.8 : 0.7
  };

  let width, height;
  function resize() {
    width = canvas.width = window.innerWidth;
    height = canvas.height = window.innerHeight;
    updateInteractiveElements();
  }
  window.addEventListener("resize", resize);

  // Tracking UI elements for atmospheric light emission/proximity glow.
  // boxBand* cache the vertical extent of all boxes (incl. the ±30px slop)
  // so the per-particle loop can skip the whole roster with one compare.
  let interactiveBoxes = [];
  let boxBandTop = Infinity;
  let boxBandBottom = -Infinity;
  function updateInteractiveElements() {
    interactiveBoxes = [];
    boxBandTop = Infinity;
    boxBandBottom = -Infinity;
    const elements = document.querySelectorAll(
      ".btn, .eyebrow, .hero__h, .console, .card, .pillar"
    );
    elements.forEach((el) => {
      const rect = el.getBoundingClientRect();
      interactiveBoxes.push({
        x: rect.left,
        y: rect.top,
        w: rect.width,
        h: rect.height,
        center: { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 }
      });
      if (rect.top - 30 < boxBandTop) boxBandTop = rect.top - 30;
      if (rect.top + rect.height + 30 > boxBandBottom) boxBandBottom = rect.top + rect.height + 30;
    });
  }

  // Rects are re-read at most once per painted frame: scroll/transition/poll
  // handlers only flip this flag; animate() does the getBoundingClientRect
  // pass right before the particles consume the boxes. Per-scroll-event reads
  // forced a synchronous layout every tick (they interleave with the header's
  // data-elevated style write on the same scroll stream).
  let boxesDirty = false;
  function markBoxesDirty() {
    boxesDirty = true;
  }

  // Custom Mouse Tracker for ripple repulsion physics (pointless without the loop)
  let mouse = { x: null, y: null, active: false };
  if (!reduced) {
    window.addEventListener("mousemove", (e) => {
      mouse.x = e.clientX;
      mouse.y = e.clientY;
      mouse.active = true;
    });
    window.addEventListener("mouseleave", () => {
      mouse.active = false;
    });
  }

  // Hide offscreen canvas for text point sampling
  const offscreen = document.createElement("canvas");
  const oCtx = offscreen.getContext("2d", { willReadFrequently: true });

  function samplePointsFromText(text, size = 280) {
    if (!oCtx) return [];
    offscreen.width = 400;
    offscreen.height = 400;
    oCtx.fillStyle = "#000";
    oCtx.fillRect(0, 0, 400, 400);
    oCtx.fillStyle = "#fff";
    oCtx.font = `800 ${size}px monospace`;
    oCtx.textAlign = "center";
    oCtx.textBaseline = "middle";
    oCtx.fillText(text, 200, 200);

    const imgData = oCtx.getImageData(0, 0, 400, 400).data;
    const pts = [];
    const gap = 6; // Sampling step to ensure lightweight rendering

    for (let y = 0; y < 400; y += gap) {
      for (let x = 0; x < 400; x += gap) {
        const index = (y * 400 + x) * 4;
        if (imgData[index] > 128) {
          pts.push({
            x: (x - 200) / 200,
            y: (y - 200) / 200
          });
        }
      }
    }
    return pts;
  }

  // Generate quota ring planetary orbit segments
  function generateRingPoints(numRings = 3) {
    const pts = [];
    for (let ring = 0; ring < numRings; ring++) {
      const radius = 0.2 + ring * 0.25;
      const numPts = 80 + ring * 50;
      for (let i = 0; i < numPts; i++) {
        const angle = (i / numPts) * Math.PI * 2;
        pts.push({
          x: Math.cos(angle) * radius,
          y: Math.sin(angle) * radius
        });
      }
    }
    return pts;
  }

  // Generate router failover network flow visual explanation
  function generateRouterFlowPoints() {
    const pts = [];

    // 1. Central Gateway Node (Circle on left-center: -0.45, 0.0)
    const numCenterPts = 100;
    for (let i = 0; i < numCenterPts; i++) {
      const angle = (i / numCenterPts) * Math.PI * 2;
      const r = 0.08;
      pts.push({
        x: -0.45 + Math.cos(angle) * r,
        y: 0.0 + Math.sin(angle) * r,
        role: "gateway"
      });
    }

    // 2. Three Target Account Nodes on the right (Circles at 0.45, -0.28; 0.45, 0.0; 0.45, 0.28)
    const targets = [
      { x: 0.45, y: -0.28, role: "target-1" },
      { x: 0.45, y: 0.0, role: "target-2" },
      { x: 0.45, y: 0.28, role: "target-3" }
    ];

    targets.forEach((tgt) => {
      const numTgtPts = 50;
      for (let i = 0; i < numTgtPts; i++) {
        const angle = (i / numTgtPts) * Math.PI * 2;
        const r = 0.05;
        pts.push({
          x: tgt.x + Math.cos(angle) * r,
          y: tgt.y + Math.sin(angle) * r,
          role: tgt.role
        });
      }
    });

    // 3. Connecting Channels (Bezier S-curves carrying request packet particles)
    targets.forEach((tgt, tIdx) => {
      const numLinePts = 60;
      for (let i = 0; i < numLinePts; i++) {
        const t = i / numLinePts;
        const px = -0.45 + (tgt.x - -0.45) * t;
        const py = 0.0 + (tgt.y - 0.0) * (3 * t * t - 2 * t * t * t);

        pts.push({
          x: px,
          y: py,
          role: `path-${tIdx + 1}`,
          progress: t
        });
      }
    });

    return pts;
  }

  const shapes = {
    swarm: [],
    "shape-dollar": samplePointsFromText("$"),
    "shape-code": samplePointsFromText("</>", 220),
    "shape-rings": generateRingPoints(),
    "shape-router-flow": generateRouterFlowPoints()
  };

  const PARTICLE_COUNT = 1500;
  const GLYPHS = ["$", "{}", "</>", "tok", "ctx", "429", "503", "run", "cache"];
  let particles = [];
  let currentMode = "swarm";
  let flowTime = 0;

  class EmberParticle {
    constructor() {
      this.x = Math.random() * window.innerWidth;
      this.y = Math.random() * window.innerHeight;
      this.vx = (Math.random() - 0.5) * 1.5;
      this.vy = (Math.random() - 0.5) * 1.5;
      this.size = 1 + Math.random() * 2;
      this.type = Math.random() < 0.08 ? "glyph" : "pixel";
      this.text = GLYPHS[Math.floor(Math.random() * GLYPHS.length)];
      this.colorIndex = Math.random();

      this.tx = null;
      this.ty = null;
      this.role = null;
      this.flowProgress = Math.random();

      this.baseOpacity = 0.08 + Math.random() * 0.18;
      this.opacity = this.baseOpacity;
    }

    update() {
      flowTime += pace.timeStep;
      const noiseX = Math.sin(this.y * 0.005 + flowTime * 2) * Math.cos(this.x * 0.003 + flowTime);
      const noiseY =
        Math.cos(this.x * 0.005 + flowTime * 3) * Math.sin(this.y * 0.003 + flowTime * 2);

      // Mouse interactions (repulsion field) - dynamic mouse multiplier based on pace
      let mouseForceX = 0;
      let mouseForceY = 0;
      if (mouse.active) {
        const dx = this.x - mouse.x;
        const dy = this.y - mouse.y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < 140) {
          const force = (140 - dist) / 140;
          mouseForceX = (dx / dist) * force * pace.mouseForceMultiplier;
          mouseForceY = (dy / dist) * force * pace.mouseForceMultiplier;
        }
      }

      if (currentMode === "swarm") {
        this.vx += noiseX * pace.swarmNoise + mouseForceX;
        this.vy += noiseY * pace.swarmNoise + mouseForceY;
        this.vx *= pace.swarmDrag;
        this.vy *= pace.swarmDrag;

        const speed = Math.sqrt(this.vx * this.vx + this.vy * this.vy);
        const maxSpeed = this.type === "glyph" ? pace.maxSpeedGlyph : pace.maxSpeedPixel;
        if (speed > maxSpeed) {
          this.vx = (this.vx / speed) * maxSpeed;
          this.vy = (this.vy / speed) * maxSpeed;
        }

        this.x += this.vx;
        this.y += this.vy;

        if (this.x < 0) this.x = width;
        if (this.x > width) this.x = 0;
        if (this.y < 0) this.y = height;
        if (this.y > height) this.y = 0;
      } else {
        // Morphing shape mode or special Router Flow mode
        if (currentMode === "shape-router-flow" && this.role) {
          // Dynamically re-evaluate coordinates based on resizing bounds to keep flow paths beautiful
          let centerX = width * 0.5;
          let centerY = height * 0.48;
          let scaleFactor = width > 960 ? 0.7 : 0.8;
          const scale = Math.min(width, height) * scaleFactor;

          if (this.role === "gateway") {
            const angle = this.colorIndex * Math.PI * 2 + flowTime * 15;
            const r = 0.08;
            this.tx = centerX + (-0.45 + Math.cos(angle) * r) * scale;
            this.ty = centerY + (0.0 + Math.sin(angle) * r) * scale;
          } else if (this.role.startsWith("target-")) {
            let tgtX = 0.45;
            let tgtY = 0.0;
            if (this.role === "target-1") tgtY = -0.28;
            if (this.role === "target-3") tgtY = 0.28;

            const angle = this.colorIndex * Math.PI * 2 + flowTime * 12;
            const r = 0.05;
            this.tx = centerX + (tgtX + Math.cos(angle) * r) * scale;
            this.ty = centerY + (tgtY + Math.sin(angle) * r) * scale;
          } else if (this.role.startsWith("path-")) {
            let tgtY = 0.0;
            if (this.role === "path-1") tgtY = -0.28;
            if (this.role === "path-3") tgtY = 0.28;

            // Advance flow progress along Bezier path (snappier speed on home, slow cinematic elsewhere)
            this.flowProgress += isHome ? 0.006 : 0.003;
            if (this.flowProgress > 1.0) {
              this.flowProgress = 0.0;
            }

            const t = this.flowProgress;
            const px = -0.45 + (0.45 - -0.45) * t;
            const py = 0.0 + (tgtY - 0.0) * (3 * t * t - 2 * t * t * t);

            this.tx = centerX + px * scale;
            this.ty = centerY + py * scale;
          }
        }

        if (this.tx !== null && this.ty !== null) {
          const dx = this.tx - this.x;
          const dy = this.ty - this.y;
          const dist = Math.sqrt(dx * dx + dy * dy);

          if (dist > 1) {
            this.vx += (dx / dist) * pace.morphAttract;
            this.vy += (dy / dist) * pace.morphAttract;
          }

          this.vx += noiseX * pace.morphNoise + mouseForceX;
          this.vy += noiseY * pace.morphNoise + mouseForceY;
          this.vx *= pace.morphDrag;
          this.vy *= pace.morphDrag;

          this.x += this.vx;
          this.y += this.vy;
        } else {
          // Background swirling for surplus particles (ambient, gentle)
          this.vx += noiseX * (pace.swarmNoise * 0.75) + mouseForceX;
          this.vy += noiseY * (pace.swarmNoise * 0.75) + mouseForceY;
          this.vx *= pace.swarmDrag;
          this.vy *= pace.swarmDrag;
          this.x += this.vx;
          this.y += this.vy;

          if (this.x < 0) this.x = width;
          if (this.x > width) this.x = 0;
          if (this.y < 0) this.y = height;
          if (this.y > height) this.y = 0;
        }
      }

      // Element Proximity Glow Tracker. Band check first: a particle outside
      // the union of all expanded boxes' vertical extent can't be inside any
      // of them, so the per-box loop (and its sqrt) is provably skippable.
      let nearElement = false;
      let glowMultiplier = 1;
      if (this.y >= boxBandTop && this.y <= boxBandBottom) {
        for (let i = 0; i < interactiveBoxes.length; i++) {
          const box = interactiveBoxes[i];
          if (
            this.x >= box.x - 30 &&
            this.x <= box.x + box.w + 30 &&
            this.y >= box.y - 30 &&
            this.y <= box.y + box.h + 30
          ) {
            nearElement = true;
            const distToCenter = Math.sqrt(
              (this.x - box.center.x) * (this.x - box.center.x) +
                (this.y - box.center.y) * (this.y - box.center.y)
            );
            const normalizedDist = Math.max(0, 1 - distToCenter / 200);
            glowMultiplier = 1 + normalizedDist * 2.8;
            break;
          }
        }
      }

      this.opacity = this.baseOpacity * glowMultiplier;
      if (nearElement && this.type === "pixel") {
        this.size = 2 + Math.random();
      } else if (this.type === "pixel") {
        this.size = 1 + Math.random();
      }
    }

    draw() {
      let color;
      if (currentMode === "shape-router-flow") {
        if (this.role === "gateway") {
          color = `rgba(128, 128, 255, ${this.opacity * 1.6})`; // Lavender-Blue (#8080ff) - bright intake gateway
        } else if (this.role === "path-1" || this.role === "target-1") {
          color = `rgba(238, 24, 3, ${this.opacity * 1.5})`; // Deep Red (#EE1803) - throttled failover route
        } else if (this.role === "path-2" || this.role === "target-2") {
          color = `rgba(253, 196, 44, ${this.opacity * 1.5})`; // Glowing Yellow-Gold (#FDC42C) - active backup
        } else if (this.role === "path-3" || this.role === "target-3") {
          color = `rgba(250, 107, 6, ${this.opacity * 1.5})`; // Orange Mid-Tone (#FA6B06) - standby
        } else {
          color = `rgba(238, 24, 3, ${this.opacity * 0.35})`; // Dim swirling background embers
        }
      } else {
        // Regular color selection
        if (this.colorIndex < 0.08) {
          color = `rgba(128, 128, 255, ${this.opacity})`; // Cool Lavender-Blue (#8080ff) - very sparingly
        } else if (this.colorIndex < 0.35) {
          color = `rgba(250, 107, 6, ${this.opacity})`; // Orange Mid-Tone (#FA6B06) - moderate
        } else if (this.colorIndex < 0.62) {
          color = `rgba(253, 196, 44, ${this.opacity})`; // Glowing Yellow-Gold (#FDC42C) - moderate
        } else {
          color = `rgba(238, 24, 3, ${this.opacity})`; // Deep Red (#EE1803) - rich/primary color
        }
      }

      if (this.type === "glyph") {
        ctx.font = `600 9px monospace`;
        ctx.fillStyle = color;
        ctx.fillText(this.text, this.x, this.y);
      } else {
        ctx.beginPath();
        ctx.arc(this.x, this.y, this.size, 0, Math.PI * 2);
        ctx.fillStyle = color;
        ctx.fill();
      }
    }
  }

  // Initialize particles
  for (let i = 0; i < PARTICLE_COUNT; i++) {
    particles.push(new EmberParticle());
  }

  resize();
  updateInteractiveElements();

  function assignShape(shapeName) {
    currentMode = shapeName;
    const shapePts = shapes[shapeName];
    if (!shapePts || shapePts.length === 0) {
      particles.forEach((p) => {
        p.tx = null;
        p.ty = null;
        p.role = null;
      });
      return;
    }

    // Center the shapes beautifully based on their semantic context to keep them from being hidden:
    // - Rings orbit the interactive console card on the right (width * 0.72)
    // - Dollars ($) and Code (</>) land in the sweet spot between the hero copy and the card (width * 0.53)
    // - Specialized S-Curve router flow spans beautifully across the center (width * 0.5)
    let centerX = width * 0.5;
    let centerY = height * 0.45;
    let scaleFactor = 0.35;

    if (width > 960) {
      if (shapeName === "shape-rings") {
        centerX = width * 0.72;
        centerY = height * 0.45;
        scaleFactor = 0.42;
      } else if (shapeName === "shape-router-flow") {
        centerX = width * 0.5;
        centerY = height * 0.48;
        scaleFactor = 0.7; // Spans wider to make a readable, stunning visual dashboard
      } else {
        // shape-dollar & shape-code
        centerX = width * 0.53;
        centerY = height * 0.45;
        scaleFactor = 0.36;
      }
    } else {
      // Mobile positioning overrides
      if (shapeName === "shape-rings") {
        centerY = height * 0.75;
      } else if (shapeName === "shape-router-flow") {
        centerX = width * 0.5;
        centerY = height * 0.5;
        scaleFactor = 0.8;
      } else {
        centerY = height * 0.4;
      }
    }
    const scale = Math.min(width, height) * scaleFactor;

    const shuffled = [...particles].sort(() => Math.random() - 0.5);

    for (let i = 0; i < shuffled.length; i++) {
      const p = shuffled[i];
      if (i < shapePts.length) {
        p.tx = centerX + shapePts[i].x * scale;
        p.ty = centerY + shapePts[i].y * scale;
        p.role = shapePts[i].role || null;
        p.flowProgress = shapePts[i].progress !== undefined ? shapePts[i].progress : Math.random();
      } else {
        p.tx = null;
        p.ty = null;
        p.role = null;
      }
    }
  }

  // Auto cycling engine representing AI computational state cycles
  let cycle = 0;
  const modesList = isRouter
    ? ["swarm", "shape-router-flow", "swarm", "shape-rings", "swarm", "shape-router-flow"]
    : ["swarm", "shape-dollar", "swarm", "shape-code", "swarm", "shape-rings"];

  // Dynamic cycle scheduling based on page interval limits
  function scheduleNextCycle() {
    cycle = (cycle + 1) % modesList.length;
    assignShape(modesList[cycle]);
    setTimeout(scheduleNextCycle, pace.cycleInterval);
  }

  let rafId = null;
  function animate() {
    // In LIGHT theme the dot-logo field owns the background; the ember
    // swarm parks (clear once, drop the loop) instead of waking every vsync
    // to wipe an already-clear canvas. The data-theme observer below resumes
    // it — particle physics never ran in light theme, so freezing here is
    // pixel-identical to the old always-on loop.
    if (document.documentElement.getAttribute("data-theme") === "light") {
      ctx.clearRect(0, 0, width, height);
      rafId = null;
      return;
    }
    if (boxesDirty) {
      boxesDirty = false;
      updateInteractiveElements();
    }
    // Subtle frame decay to preserve trails without layout stutter
    ctx.fillStyle = "rgba(5, 5, 8, 0.12)";
    ctx.fillRect(0, 0, width, height);

    particles.forEach((p) => {
      p.update();
      p.draw();
    });

    rafId = requestAnimationFrame(animate);
  }

  function ensureLoop() {
    if (rafId !== null) return;
    boxesDirty = true; // rects went stale while parked
    rafId = requestAnimationFrame(animate);
  }

  // prefers-reduced-motion: paint one paused-animation frame. The opaque base
  // stands in for the decay fill the live loop accumulates (#050508 — same as
  // the dark --ink-void page background), and a few simulation steps give the
  // embers their short trails so the field reads as a freeze-frame of the
  // swarm rather than bare dots.
  function renderStaticFrame() {
    if (document.documentElement.getAttribute("data-theme") === "light") {
      ctx.clearRect(0, 0, width, height);
      return;
    }
    ctx.fillStyle = "rgb(5, 5, 8)";
    ctx.fillRect(0, 0, width, height);
    for (let step = 0; step < 24; step++) {
      ctx.fillStyle = "rgba(5, 5, 8, 0.12)";
      ctx.fillRect(0, 0, width, height);
      particles.forEach((p) => {
        p.update();
        p.draw();
      });
    }
  }

  if (reduced) {
    // Static background: no rAF loop, no shape-cycle timers, no scroll/mouse
    // listeners. Redraw after resize (resize() resets canvas dims, clearing
    // it) and on theme toggles — dark needs a repaint, light needs a clear.
    renderStaticFrame();
    window.addEventListener("resize", renderStaticFrame);
    new MutationObserver(renderStaticFrame).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"]
    });
  } else {
    setTimeout(scheduleNextCycle, pace.cycleInterval);
    animate();

    // Resume the parked loop when the theme flips back to dark.
    new MutationObserver(() => {
      if (document.documentElement.getAttribute("data-theme") !== "light") ensureLoop();
    }).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"]
    });

    // Dynamically re-evaluate coordinates when content scrolls or windows
    // resize — all flag-only, coalesced into one rect pass per frame inside
    // animate(). The body ResizeObserver covers content reflows (image
    // loads, expanding sections); transitionend/animationend cover
    // transform-driven moves (getBoundingClientRect includes CSS transforms,
    // which no observer reports); the slow interval is the safety net
    // replacing the old unconditional 1.2s poll — its actual rect work is
    // rAF-gated, so hidden tabs and the parked light theme pay nothing.
    window.addEventListener("scroll", markBoxesDirty, { passive: true });
    window.addEventListener("transitionend", markBoxesDirty, { passive: true });
    window.addEventListener("animationend", markBoxesDirty, { passive: true });
    if (typeof ResizeObserver !== "undefined") {
      new ResizeObserver(markBoxesDirty).observe(document.body);
    }
    setInterval(markBoxesDirty, 8000);
  }
})();
