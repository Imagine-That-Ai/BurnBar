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

  // Verbatim port of OpenBurnBarCore/PixelClockProviderLogoAssets.generated.swift.
  // 8×8 multi-color pixel arrays — `null` = unlit, hex string = lit pixel of
  // that color. DO NOT hand-edit. Regenerate from the Swift source.
  var PROVIDER_LOGOS = {
    claudeCode: [
      [null,null,null,null,null,null,null,null],
      [null,"#D97757","#D97757","#D97757","#D97757","#D97757","#D97757",null],
      [null,"#D97757","#1A1208","#D97757","#D97757","#1A1208","#D97757",null],
      ["#D97757","#D97757","#D97757","#D97757","#D97757","#D97757","#D97757","#D97757"],
      ["#D97757","#D97757","#D97757","#D97757","#D97757","#D97757","#D97757","#D97757"],
      ["#D97757",null,"#D97757",null,null,"#D97757",null,"#D97757"],
      ["#D97757",null,"#D97757",null,null,"#D97757",null,"#D97757"],
      [null,null,null,null,null,null,null,null]
    ],
    codex: [
      [null,null,"#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF",null,null],
      [null,"#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF",null],
      ["#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF"],
      ["#8EA0FF","#8EA0FF","#FFFFFF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF"],
      ["#8EA0FF","#8EA0FF","#8EA0FF","#FFFFFF","#8EA0FF","#8EA0FF","#8EA0FF","#8EA0FF"],
      ["#8EA0FF","#8EA0FF","#FFFFFF","#8EA0FF","#8EA0FF","#FFFFFF","#FFFFFF","#FFFFFF"],
      [null,"#4258FF","#4258FF","#4258FF","#4258FF","#4258FF","#4258FF",null],
      [null,null,"#4258FF","#4258FF","#4258FF","#4258FF",null,null]
    ],
    copilot: [
      [null,"#0F4E70","#1A80B6","#187DB4","#1050A2","#091F60",null,null],
      ["#05293E","#118BD1","#1397E1","#148FDD","#1558D0","#1652BA","#031121",null],
      ["#1B656E","#2BA1AF","#2EA3A9","#257F90","#172C62","#675CBC","#7350AF","#572E73"],
      ["#529F62","#60B46C","#66B666","#305A32","#381429","#C64FAF","#BB51CC","#B24FCB"],
      ["#A5BB36","#AFC033","#ABB92D","#2A310B","#762D45","#E55898","#D954A7","#BC4A97"],
      ["#6C610A","#AC8D13","#D19422","#75341D","#CD5E5E","#F46A80","#F16187","#963B57"],
      [null,null,"#D26238","#F36544","#F88D61","#F9886D","#E6756A","#452121"],
      [null,null,"#67251B","#B05634","#BA7B40","#BA7445","#72442D",null]
    ],
    miniMax: [
      ["#EC1970",null,null,"#EC1970","#EC1970",null,null,"#EC1970"],
      ["#EC1970","#EC1970",null,"#EC1970","#EC1970",null,"#EC1970","#EC1970"],
      ["#EC1970","#EC1970","#EC1970","#EC1970","#EC1970","#EC1970","#EC1970","#EC1970"],
      ["#EC1970",null,null,"#EC1970","#EC1970",null,null,"#EC1970"],
      ["#FF5B3F",null,null,"#FF5B3F","#FF5B3F",null,null,"#FF5B3F"],
      ["#FF5B3F","#FF5B3F",null,"#FF5B3F","#FF5B3F",null,"#FF5B3F","#FF5B3F"],
      ["#FF5B3F","#FF5B3F","#FF5B3F","#FF5B3F","#FF5B3F","#FF5B3F","#FF5B3F","#FF5B3F"],
      ["#FF5B3F",null,null,"#FF5B3F","#FF5B3F",null,null,"#FF5B3F"]
    ],
    zai: [
      ["#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF",null],
      ["#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF",null],
      [null,null,null,null,"#FFFFFF","#FFFFFF","#FFFFFF",null],
      [null,null,null,"#FFFFFF","#FFFFFF","#FFFFFF",null,null],
      [null,null,"#FFFFFF","#FFFFFF","#FFFFFF",null,null,null],
      [null,"#FFFFFF","#FFFFFF","#FFFFFF",null,null,null,null],
      [null,"#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF","#FFFFFF"],
      [null,"#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF","#C9B6FF"]
    ],
    factory: [
      [null,null,null,"#FFFFFF",null,null,null,null],
      [null,"#FFFFFF",null,"#FFFFFF",null,"#FFFFFF",null,null],
      ["#FFFFFF",null,"#FFFFFF",null,"#FFFFFF",null,"#FFFFFF",null],
      [null,"#FFFFFF","#FFFFFF","#B8B8B8","#FFFFFF","#FFFFFF",null,null],
      ["#FFFFFF",null,"#FFFFFF",null,"#FFFFFF",null,"#FFFFFF",null],
      [null,"#FFFFFF",null,"#FFFFFF",null,"#FFFFFF",null,null],
      [null,null,null,"#FFFFFF",null,null,null,null],
      [null,null,null,null,null,null,null,null]
    ],
    cursor: [
      [null,null,null,null,null,null,null,null],
      [null,null,null,"#FFFFFF","#FFFFFF",null,null,null],
      [null,null,"#FFFFFF","#AEB7C2","#AEB7C2","#FFFFFF",null,null],
      [null,"#FFFFFF","#AEB7C2","#30343A","#7F8790","#FFFFFF",null,null],
      [null,null,"#30343A","#30343A","#7F8790",null,null,null],
      [null,null,null,"#30343A",null,null,null,null],
      [null,null,null,null,null,null,null,null],
      [null,null,null,null,null,null,null,null]
    ],
    warp: [
      ["#FFFFFF","#FBFBFB","#F4F5F6","#F4F5F6","#F5F6F7","#F5F6F7","#FBFBFB","#FFFFFF"],
      ["#FCFCFC","#DCE0E3","#D0D6DA","#CFD5D9","#D0D6DA","#D0D6DA","#DCE0E3","#FBFCFC"],
      ["#F6F7F8","#CCD2D6","#ADB2B6","#A1A6AA","#6E7173","#777A7C","#C4C9CD","#F6F7F8"],
      ["#F5F6F7","#B3B8BC","#3B3C3D","#47494A","#282828","#373838","#B2B7BB","#F5F6F7"],
      ["#F4F5F6","#ACB1B4","#313233","#4B4C4D","#323333","#494A4B","#B4B9BD","#F4F5F6"],
      ["#F4F5F6","#C1C6CA","#787B7D","#8C8F92","#ADB1B5","#BBC0C4","#CFD5D9","#F3F5F5"],
      ["#FBFCFC","#E3E8EB","#D4DADE","#D2D8DC","#D8DEE2","#D6DCE0","#E1E6E9","#FBFCFC"],
      ["#FFFFFF","#FCFCFC","#F5F7F7","#F5F7F7","#F6F7F8","#F6F8F8","#FCFCFD","#FFFFFF"]
    ],
    ollama: [
      [null,null,"#F6F8FF",null,null,null,null,null],
      [null,"#F6F8FF","#F6F8FF","#F6F8FF",null,null,null,null],
      [null,null,"#F6F8FF","#F6F8FF","#F6F8FF","#F6F8FF",null,null],
      [null,null,"#F6F8FF","#1EA7FF","#F6F8FF","#F6F8FF",null,null],
      [null,null,"#F6F8FF","#F6F8FF","#F6F8FF","#0B0B0B",null,null],
      [null,null,null,"#F6F8FF","#F6F8FF","#F6F8FF",null,null],
      [null,null,null,"#F6F8FF","#F6F8FF",null,null,null],
      [null,null,null,"#F6F8FF","#F6F8FF",null,null,null]
    ],
    kimi: [
      [null,null,null,null,null,null,"#0A2E57","#136CD2"],
      [null,"#919191",null,null,"#828282","#858585","#0F1C2B","#052040"],
      ["#252525","#C2C2C2","#2F2F2F","#8B8B8B","#C2C2C2","#2D2D2D",null,null],
      ["#242424","#C9C9C9","#B2B2B2","#D7D7D7","#303030",null,null,null],
      ["#232323","#DFDFDF","#DDDDDD","#D3D3D3","#8D8D8D",null,null,null],
      ["#242424","#CDCDCD","#404040","#313131","#B8B8B8","#C3C3C3","#2F2F2F",null],
      [null,"#7C7C7C",null,null,null,"#6F6F6F","#343434",null],
      [null,null,null,null,null,null,null,null]
    ]
  };

  function logoFor(item) {
    var token = (String((item && item.providerID) || "") + " " + String((item && item.providerName) || "")).toLowerCase();
    if (token.indexOf("claude") >= 0) return PROVIDER_LOGOS.claudeCode;
    if (token.indexOf("codex") >= 0) return PROVIDER_LOGOS.codex;
    if (token.indexOf("factory") >= 0 || token.indexOf("droid") >= 0) return PROVIDER_LOGOS.factory;
    if (token.indexOf("cursor") >= 0) return PROVIDER_LOGOS.cursor;
    if (token.indexOf("warp") >= 0) return PROVIDER_LOGOS.warp;
    if (token.indexOf("copilot") >= 0) return PROVIDER_LOGOS.copilot;
    if (token.indexOf("kimi") >= 0 || token.indexOf("moonshot") >= 0) return PROVIDER_LOGOS.kimi;
    if (token.indexOf("ollama") >= 0) return PROVIDER_LOGOS.ollama;
    if (token.indexOf("minimax") >= 0) return PROVIDER_LOGOS.miniMax;
    if (token.indexOf("z.ai") >= 0 || token.indexOf("zai") >= 0) return PROVIDER_LOGOS.zai;
    return monogramLogoFor(item);
  }
  function shortProviderCode(item) {
    var token = (String((item && item.providerID) || "") + " " + String((item && item.providerName) || "")).toLowerCase();
    if (token.indexOf("claude") >= 0) return "CLD";
    if (token.indexOf("codex") >= 0) return "CDX";
    if (token.indexOf("factory") >= 0 || token.indexOf("droid") >= 0) return "FAC";
    if (token.indexOf("copilot") >= 0) return "COP";
    if (token.indexOf("minimax") >= 0) return "MMX";
    if (token.indexOf("cursor") >= 0) return "CUR";
    if (token.indexOf("warp") >= 0) return "WRP";
    if (token.indexOf("ollama") >= 0) return "OLL";
    if (token.indexOf("kimi") >= 0) return "KIM";
    if (token.indexOf("z.ai") >= 0 || token.indexOf("zai") >= 0) return "ZAI";
    var normalized = String((item && item.providerName) || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    return normalized.slice(0, 3) || "OBB";
  }
  function monogramLogoFor(item) {
    var rows = Array.from({ length: 8 }, function () { return Array.from({ length: 8 }, function () { return null; }); });
    var chars = shortProviderCode(item).toUpperCase().slice(0, 2).split("");
    for (var i = 0; i < chars.length; i++) {
      var glyph = glyph3x5(chars[i]);
      var x = i === 0 ? 0 : 4;
      var color = i === 0 ? "#FAFAFA" : "#A0A0A0";
      for (var row = 0; row < glyph.length; row++) {
        for (var column = 0; column < glyph[row].length; column++) {
          if (glyph[row][column] === 1) rows[row + 1][x + column] = color;
        }
      }
    }
    return rows;
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
    var logo = logoFor(item);
    if (!logo) return;
    for (var r = 0; r < logo.length; r++) for (var c = 0; c < logo[r].length; c++) {
      var color = logo[r][c];
      if (color == null) continue;
      if (!inBounds(r, c)) continue;
      grid[r][c] = { isLit: true, color: color };
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
      var score = top.selectionScore == null ? top.score : top.selectionScore;
      items.push({
        providerID: top.providerID || top.modelID || "openburnbar",
        providerName: shortName(top.modelDisplay || top.providerDisplay || "model"),
        percentUsed: Math.max(0, Math.min(100, 100 - Math.round((score || 0) * 100))),
        usageText: Math.round((score || 0) * 100) + "%",
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
    var score = top.selectionScore == null ? top.score : top.selectionScore;
    for (var i = 0; i < models.length; i++) models[i].textContent = top.modelDisplay;
    for (var j = 0; j < scores.length; j++) scores[j].textContent = Math.round((score || 0) * 100) + "/100";
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
