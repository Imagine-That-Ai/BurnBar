/**
 * Platform-mockups hydrator — keeps the device renderings alive at runtime.
 *
 *   - Ticks every `[data-platform-clock]` element each second.
 *   - Fetches `/api/router-rundown/latest` once and pushes the live
 *     today's-coding pick into the Nest Hub footer hooks.
 *   - For each `<PixelMatrix>` instance, advances a tick counter every
 *     1500ms and repaints the 32×8 grid using the same layout logic the
 *     SSR component uses (verbatim port of
 *     `PixelClockFramePresenter.swift`).
 *
 * Respects `prefers-reduced-motion`: clock freezes at the SSR value, the
 * pixel matrix holds its initial frame, no intervals fire.
 *
 * No inline scripts (CSP `script-src 'self'` is enforced via firebase.json),
 * no external dependencies. ~6 KB minified.
 */
(function () {
  "use strict";

  // ─────────────────────────── Clocks ────────────────────────────
  function fmtClock(date, mode) {
    var h = date.getHours();
    var m = date.getMinutes();
    var s = date.getSeconds();
    var hh = String(h % 12 || 12);
    var mm = String(m).padStart(2, "0");
    var ss = String(s).padStart(2, "0");
    var ap = h < 12 ? "AM" : "PM";
    if (mode === "24") return String(h).padStart(2, "0") + ":" + mm;
    if (mode === "hms") return hh + ":" + mm + ":" + ss + " " + ap;
    return hh + ":" + mm + " " + ap;
  }
  function fmtDate(date) {
    var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    return days[date.getDay()] + ", " + months[date.getMonth()] + " " + date.getDate();
  }

  function tickClocks() {
    var now = new Date();
    var clocks = document.querySelectorAll("[data-platform-clock]");
    for (var i = 0; i < clocks.length; i++) {
      var el = clocks[i];
      var mode = el.getAttribute("data-platform-clock-format") || "hm";
      el.textContent = fmtClock(now, mode);
    }
    var dates = document.querySelectorAll("[data-platform-date]");
    for (var j = 0; j < dates.length; j++) {
      dates[j].textContent = fmtDate(now);
    }
  }

  // ─────────────────────────── Pixel-clock presenter port ─────────
  // Verbatim subset of scripts/lib/pixel-clock-presenter.mjs. Kept inline
  // because /public assets cannot import ES modules across asset boundaries
  // under the strict same-origin CSP.
  var COLS = 32, ROWS = 8;
  var PALETTE = { primary: "#ff6a1a", secondary: "#d6d3df", hot: "#ff6a1a" };

  var GLYPH_3X5 = {
    "0":[[1,1,1],[1,0,1],[1,0,1],[1,0,1],[1,1,1]],"1":[[0,1,0],[1,1,0],[0,1,0],[0,1,0],[1,1,1]],
    "2":[[1,1,1],[0,0,1],[1,1,1],[1,0,0],[1,1,1]],"3":[[1,1,1],[0,0,1],[1,1,1],[0,0,1],[1,1,1]],
    "4":[[1,0,1],[1,0,1],[1,1,1],[0,0,1],[0,0,1]],"5":[[1,1,1],[1,0,0],[1,1,1],[0,0,1],[1,1,1]],
    "6":[[1,1,1],[1,0,0],[1,1,1],[1,0,1],[1,1,1]],"7":[[1,1,1],[0,0,1],[0,1,0],[0,1,0],[0,1,0]],
    "8":[[1,1,1],[1,0,1],[1,1,1],[1,0,1],[1,1,1]],"9":[[1,1,1],[1,0,1],[1,1,1],[0,0,1],[1,1,1]],
    "%":[[1,0,1],[0,0,1],[0,1,0],[1,0,0],[1,0,1]],"!":[[1,0,0],[1,0,0],[1,0,0],[0,0,0],[1,0,0]],
    "A":[[0,1,0],[1,0,1],[1,1,1],[1,0,1],[1,0,1]],"B":[[1,1,0],[1,0,1],[1,1,0],[1,0,1],[1,1,0]],
    "C":[[0,1,1],[1,0,0],[1,0,0],[1,0,0],[0,1,1]],"D":[[1,1,0],[1,0,1],[1,0,1],[1,0,1],[1,1,0]],
    "E":[[1,1,1],[1,0,0],[1,1,0],[1,0,0],[1,1,1]],"F":[[1,1,1],[1,0,0],[1,1,0],[1,0,0],[1,0,0]],
    "G":[[0,1,1],[1,0,0],[1,0,1],[1,0,1],[0,1,1]],"H":[[1,0,1],[1,0,1],[1,1,1],[1,0,1],[1,0,1]],
    "I":[[1,1,1],[0,1,0],[0,1,0],[0,1,0],[1,1,1]],"J":[[0,0,1],[0,0,1],[0,0,1],[1,0,1],[0,1,0]],
    "K":[[1,0,1],[1,1,0],[1,0,0],[1,1,0],[1,0,1]],"L":[[1,0,0],[1,0,0],[1,0,0],[1,0,0],[1,1,1]],
    "M":[[1,0,1],[1,1,1],[1,1,1],[1,0,1],[1,0,1]],"N":[[1,0,1],[1,1,1],[1,1,1],[1,1,1],[1,0,1]],
    "O":[[0,1,0],[1,0,1],[1,0,1],[1,0,1],[0,1,0]],"P":[[1,1,0],[1,0,1],[1,1,0],[1,0,0],[1,0,0]],
    "Q":[[0,1,0],[1,0,1],[1,0,1],[1,1,1],[0,1,1]],"R":[[1,1,0],[1,0,1],[1,1,0],[1,0,1],[1,0,1]],
    "S":[[0,1,1],[1,0,0],[0,1,0],[0,0,1],[1,1,0]],"T":[[1,1,1],[0,1,0],[0,1,0],[0,1,0],[0,1,0]],
    "U":[[1,0,1],[1,0,1],[1,0,1],[1,0,1],[1,1,1]],"V":[[1,0,1],[1,0,1],[1,0,1],[1,0,1],[0,1,0]],
    "W":[[1,0,1],[1,0,1],[1,1,1],[1,1,1],[1,0,1]],"X":[[1,0,1],[1,0,1],[0,1,0],[1,0,1],[1,0,1]],
    "Y":[[1,0,1],[1,0,1],[0,1,0],[0,1,0],[0,1,0]],"Z":[[1,1,1],[0,0,1],[0,1,0],[1,0,0],[1,1,1]]
  };
  var BLANK_3X5 = [[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0]];
  function glyph3x5(ch) { return GLYPH_3X5[String(ch).toUpperCase()] || BLANK_3X5; }

  var PROVIDER_LOGOS = {
    anthropic: { hex: "#c79a6c", shape: [
      [0,0,1,0,0],[0,1,1,1,0],[0,1,0,1,0],[1,1,1,1,1],[1,0,0,0,1]
    ]},
    openai: { hex: "#f6f1e7", shape: [
      [0,1,1,1,0],[1,0,0,0,1],[1,0,1,0,1],[1,0,0,0,1],[0,1,1,1,0]
    ]},
    google: { hex: "#f6f1e7", shape: [
      [0,1,1,1,1],[1,0,0,0,0],[1,0,1,1,1],[1,0,0,0,1],[0,1,1,1,1]
    ]},
    zai: { hex: "#ffb547", shape: [
      [1,1,1,1,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[1,1,1,1,1]
    ]},
    minimax: { hex: "#ff6a1a", shape: [
      [1,0,0,0,1],[1,1,0,1,1],[1,0,1,0,1],[1,0,0,0,1],[1,0,0,0,1]
    ]},
    kimi: { hex: "#1d75ff", shape: [
      [1,0,0,0,1],[1,0,0,1,0],[1,1,1,0,0],[1,0,0,1,0],[1,0,0,0,1]
    ]},
    deepseek: { hex: "#aeacba", shape: [
      [0,1,1,1,0],[1,0,0,0,1],[1,0,1,0,1],[1,0,0,0,1],[0,1,1,1,0]
    ]},
    "default": { hex: "#d6d3df", shape: [
      [0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]
    ]}
  };

  function logoFor(providerID) {
    var id = String(providerID || "").toLowerCase();
    if (id.indexOf("claude") >= 0 || id.indexOf("anthropic") >= 0) return PROVIDER_LOGOS.anthropic;
    if (id.indexOf("openai") >= 0 || id.indexOf("gpt") >= 0 || id.indexOf("codex") >= 0) return PROVIDER_LOGOS.openai;
    if (id.indexOf("google") >= 0 || id.indexOf("gemini") >= 0) return PROVIDER_LOGOS.google;
    if (id.indexOf("zai") >= 0 || id.indexOf("glm") >= 0 || id.indexOf("z.ai") >= 0) return PROVIDER_LOGOS.zai;
    if (id.indexOf("minimax") >= 0) return PROVIDER_LOGOS.minimax;
    if (id.indexOf("kimi") >= 0 || id.indexOf("moonshot") >= 0) return PROVIDER_LOGOS.kimi;
    if (id.indexOf("deepseek") >= 0) return PROVIDER_LOGOS.deepseek;
    return PROVIDER_LOGOS["default"];
  }

  function blankGrid() {
    var g = new Array(ROWS);
    for (var r = 0; r < ROWS; r++) {
      g[r] = new Array(COLS);
      for (var c = 0; c < COLS; c++) g[r][c] = { isLit: false, color: "transparent" };
    }
    return g;
  }
  function inBounds(r, c) { return r >= 0 && r < ROWS && c >= 0 && c < COLS; }
  function paintGlyph(grid, ch, x, y, color) {
    var g = glyph3x5(ch);
    for (var r = 0; r < g.length; r++) for (var c = 0; c < g[r].length; c++) {
      if (g[r][c] === 1 && inBounds(y + r, x + c)) grid[y + r][x + c] = { isLit: true, color: color };
    }
  }
  function paintProviderLogo(grid, item) {
    var logo = logoFor(item && item.providerID);
    for (var r = 0; r < logo.shape.length; r++) for (var c = 0; c < logo.shape[r].length; c++) {
      if (logo.shape[r][c] === 1 && inBounds(r + 1, c + 1)) {
        grid[r + 1][c + 1] = { isLit: true, color: logo.hex };
      }
    }
  }
  function normalizeWin(label) {
    if (!label) return "";
    var s = String(label).toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (s === "5H" || s === "7D") return s;
    return s.slice(0, 2);
  }

  function buildFrame(layout, items, tick) {
    var grid = blankGrid();
    if (!items || items.length === 0) return grid;
    var item = items[Math.abs(tick) % items.length];
    paintProviderLogo(grid, item);
    if (layout === "quotaCarousel") {
      var remaining = Math.max(0, Math.min(100, 100 - (item.percentUsed || 0)));
      var barWidth = 21;
      var barCols = Math.max(0, Math.min(barWidth, Math.round((remaining / 100) * barWidth)));
      var hot = (item.percentUsed || 0) >= 85;
      var barColor = hot ? "#ff6a1a" : PALETTE.primary;
      for (var c = 0; c < barCols; c++) grid[1][c + 10] = { isLit: true, color: barColor };
      var pct = Math.max(0, Math.min(99, remaining));
      paintGlyph(grid, String(Math.floor(pct / 10)), 17, 3, PALETTE.primary);
      paintGlyph(grid, String(pct % 10), 21, 3, PALETTE.primary);
      paintGlyph(grid, "%", 25, 3, PALETTE.secondary);
      return grid;
    }
    // providerDashboard default
    var win = normalizeWin(item.windowLabel);
    for (var i = 0; i < win.length; i++) {
      paintGlyph(grid, win.charAt(i), Math.max(20, 32 - win.length * 4) + i * 4, 1, PALETTE.primary);
    }
    var rem = Math.max(0, Math.min(100, 100 - (item.percentUsed || 0)));
    var filled = Math.max(0, Math.min(19, Math.round((rem / 100) * 19)));
    for (var k = 0; k < filled; k++) grid[7][k + 12] = { isLit: true, color: PALETTE.primary };
    // small orbit spinner
    var orbit = [[1,0],[3,1],[2,3],[0,2]];
    var active = Math.abs(tick) % orbit.length;
    for (var o = 0; o < orbit.length; o++) {
      var r = 1 + orbit[o][1], col = 10 + orbit[o][0];
      if (!inBounds(r, col)) continue;
      grid[r][col] = { isLit: true, color: o === active ? PALETTE.secondary : PALETTE.primary };
    }
    return grid;
  }

  function paintMatrix(root, grid) {
    var cells = root.querySelectorAll(".px");
    var n = ROWS * COLS;
    for (var i = 0; i < n; i++) {
      var r = Math.floor(i / COLS);
      var c = i % COLS;
      var px = grid[r][c];
      var el = cells[i];
      if (!el) continue;
      if (px.isLit) {
        el.classList.add("px--on");
        el.style.setProperty("--c", px.color);
      } else {
        el.classList.remove("px--on");
        el.style.removeProperty("--c");
      }
    }
  }

  function pickItemsFromRundown(rundown) {
    if (!rundown || !rundown.taskRankings) return null;
    var items = [];
    for (var i = 0; i < rundown.taskRankings.length; i++) {
      var task = rundown.taskRankings[i];
      var top = task.recommendations && task.recommendations[0];
      if (!top) continue;
      items.push({
        providerID: top.providerID || top.modelID || "openburnbar",
        providerName: shortName(top.modelDisplay || top.providerDisplay || "model"),
        percentUsed: Math.max(0, Math.min(100, 100 - Math.round((top.score || 0) * 100))),
        usageText: Math.round((top.score || 0) * 100) + "%",
        windowLabel: shortWindowLabel(task.taskID || ""),
      });
    }
    return items.length > 0 ? items : null;
  }
  function shortName(s) {
    return String(s || "").toUpperCase().replace(/[^A-Z0-9 .-]/g, "").slice(0, 4);
  }
  function shortWindowLabel(taskID) {
    var map = { coding: "CD", terminal: "TM", design: "DS", analysis: "AN", general: "GN", agent: "AG" };
    return map[taskID] || "";
  }

  // ─────────────────────────── Live rundown fetch ────────────────
  function applyRundownToScreens(rundown) {
    if (!rundown) return;
    var coding = (rundown.taskRankings || []).find ? rundown.taskRankings.find(function (t) { return t.taskID === "coding"; }) : null;
    if (!coding) coding = (rundown.taskRankings || [])[0];
    var top = coding && coding.recommendations && coding.recommendations[0];
    if (!top) return;
    var fresh = (rundown.sourceStatuses || []).filter(function (s) { return s.status === "fresh"; }).length;
    var models = document.querySelectorAll("[data-platform-top-pick-model]");
    var scores = document.querySelectorAll("[data-platform-top-pick-score]");
    var sources = document.querySelectorAll("[data-platform-top-pick-sources]");
    for (var i = 0; i < models.length; i++) models[i].textContent = top.modelDisplay;
    for (var j = 0; j < scores.length; j++) scores[j].textContent = Math.round((top.score || 0) * 100) + "/100";
    for (var k = 0; k < sources.length; k++) sources[k].textContent = fresh + " fresh source" + (fresh === 1 ? "" : "s");
  }

  function fetchRundown() {
    return fetch("/api/router-rundown/latest", { headers: { Accept: "application/json" }, cache: "no-store" })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .catch(function () { return null; });
  }

  // ─────────────────────────── Wire it up ────────────────────────
  function init() {
    var reduceMotion = false;
    try { reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) {}

    tickClocks();
    if (!reduceMotion) setInterval(tickClocks, 1000);

    fetchRundown().then(function (rundown) {
      if (rundown) applyRundownToScreens(rundown);

      var matrices = document.querySelectorAll("[data-platform-matrix]");
      for (var i = 0; i < matrices.length; i++) {
        var root = matrices[i];
        var cfg;
        try { cfg = JSON.parse(root.getAttribute("data-matrix-config") || "{}"); } catch (e) { cfg = {}; }
        var items = pickItemsFromRundown(rundown) || cfg.items || [];
        if (items.length === 0) continue;
        var layout = cfg.layout || "providerDashboard";
        var tick = 0;

        // Paint immediately so the live rundown reflects in the first frame.
        paintMatrix(root, buildFrame(layout, items, tick));

        if (!reduceMotion) {
          (function (rootEl, l, its) {
            var t = 0;
            setInterval(function () {
              t = (t + 1) % 1000;
              paintMatrix(rootEl, buildFrame(l, its, t));
            }, 1500);
          })(root, layout, items);
        }
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
