/* ============================================================================
   Pensieve — application shell
   Hash router, navigation, the global recall palette, confirmation-with-gravity,
   and toasts. Keeps the basin's mood in step with the surface you're on.
   ========================================================================== */
(function () {
  "use strict";
  const P = window.PENSIEVE;
  const R = window.RECALL;
  const icon = P.icon;
  const S = window.SURFACES;

  const NAV = [
    { group: "Memory", items: [
      { id: "basin", label: "The Basin", icon: "basin" },
      { id: "recall", label: "Recall", icon: "recall" },
      { id: "library", label: "Library", icon: "library" },
      { id: "remember", label: "Remember", icon: "quill" },
    ]},
    { group: "Trust", items: [
      { id: "cloak", label: "The Cloak", icon: "cloak" },
      { id: "privacy", label: "Data & Privacy", icon: "shield" },
      { id: "audit", label: "Audit", icon: "audit" },
      { id: "vault", label: "Vault & Devices", icon: "vault" },
    ]},
    { group: "Understand", items: [
      { id: "engine", label: "Engine", icon: "engine" },
      { id: "constellation", label: "Constellation", icon: "constellation", badge: "beta" },
      { id: "analytics", label: "Recall Analytics", icon: "analytics", badge: "beta" },
    ]},
    { group: "Workspace", items: [
      { id: "teams", label: "Shared Pensieve", icon: "teams", badge: "soon" },
      { id: "settings", label: "Settings", icon: "settings" },
    ]},
  ];

  const surfaceEl = document.getElementById("surface");
  const navEl = document.getElementById("rail-nav");
  let cleanup = null;

  /* ---- nav -------------------------------------------------------------- */
  function buildNav() {
    navEl.innerHTML = NAV.map((g) =>
      '<div class="rail__group-label">' + g.group + "</div>" +
      g.items.map((it) =>
        '<a class="nav-item" href="#/' + it.id + '" data-route="' + it.id + '">' +
          '<span class="nav-item__icon">' + icon(it.icon) + "</span>" +
          '<span class="nav-item__label">' + it.label + "</span>" +
          (it.badge ? '<span class="nav-item__badge nav-item__badge--' + it.badge + '">' + it.badge + "</span>" : "") +
        "</a>"
      ).join("")
    ).join("");
  }
  function setActive(route) {
    Array.from(navEl.querySelectorAll(".nav-item")).forEach((a) =>
      a.classList.toggle("is-active", a.dataset.route === route)
    );
  }

  /* ---- router ----------------------------------------------------------- */
  function parseHash() {
    const h = (location.hash || "#/basin").replace(/^#\//, "");
    const [route, param] = h.split("/");
    return { route: route || "basin", param: param || null };
  }

  function render() {
    const { route, param } = parseHash();
    const surface = S[route] || S.basin;
    if (typeof cleanup === "function") { try { cleanup(); } catch (e) {} cleanup = null; }

    surfaceEl.innerHTML = surface.render({ param });
    if (window.Basin) window.Basin.setMood(route);
    setActive(S[route] ? route : "basin");

    if (typeof surface.mount === "function") cleanup = surface.mount(surfaceEl, { param });
    surfaceEl.scrollTop = 0;
    window.scrollTo(0, 0);
    // move focus for a11y without yanking on hash-equal re-render
    surfaceEl.focus({ preventScroll: true });
    closeRail();
    document.title = (surface.title || "Pensieve") + " · Pensieve";
  }

  function go(route) {
    if (location.hash === "#/" + route) render();
    else location.hash = "#/" + route;
  }

  /* ---- recall palette --------------------------------------------------- */
  const palette = document.getElementById("palette");
  const pInput = document.getElementById("palette-input");
  const pResults = document.getElementById("palette-results");
  let pActive = -1, pRanked = [];

  function openPalette() {
    document.getElementById("palette-count").textContent = P.MEMORIES.length;
    palette.hidden = false;
    pInput.value = "";
    pResults.innerHTML = "";
    runPalette();
    setTimeout(() => pInput.focus(), 30);
  }
  function closePalette() { palette.hidden = true; }
  function runPalette() {
    const q = pInput.value.trim();
    pRanked = q ? R.rank(q, P.MEMORIES, 6) : P.MEMORIES.slice().sort((a, b) => b.recallCount - a.recallCount).slice(0, 6).map((m) => ({ mem: m, score: null, matched: [] }));
    pActive = pRanked.length ? 0 : -1;
    pResults.innerHTML = pRanked.map((r, i) => {
      const src = P.SOURCES[r.mem.source];
      const title = r.score != null ? R.highlight(r.mem.title, r.matched) : window.C.esc(r.mem.title);
      return (
        '<button class="palette-result' + (i === 0 ? " is-active" : "") + '" data-i="' + i + '" role="option">' +
          '<span><span class="palette-result__snip">' + title + "</span>" +
            '<span class="palette-result__src">' + icon(window.C.KIND_ICON[r.mem.sourceKind]) + " " + window.C.esc(src.label) + "</span></span>" +
          (r.score != null ? '<span class="palette-result__score">' + r.score.toFixed(3) + "</span>" : '<span class="palette-result__score dim">★ ' + r.mem.recallCount + "</span>") +
        "</button>"
      );
    }).join("") || ('<div class="state" style="padding:32px"><div class="state__title">Nothing surfaced</div><div class="state__sub">Try other words.</div></div>');
    pResults.querySelectorAll(".palette-result").forEach((b) =>
      b.addEventListener("click", () => choosePalette(parseInt(b.dataset.i, 10)))
    );
  }
  function moveActive(d) {
    if (!pRanked.length) return;
    pActive = (pActive + d + pRanked.length) % pRanked.length;
    pResults.querySelectorAll(".palette-result").forEach((b, i) => {
      b.classList.toggle("is-active", i === pActive);
      if (i === pActive) b.scrollIntoView({ block: "nearest" });
    });
  }
  function choosePalette(i) {
    const r = pRanked[i];
    if (!r) return;
    closePalette();
    if (window.Basin) window.Basin.ripple(window.innerWidth / 2, window.innerHeight * 0.18);
    go("memory/" + r.mem.id);
  }

  pInput.addEventListener("input", runPalette);
  pInput.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); moveActive(1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); moveActive(-1); }
    else if (e.key === "Enter") { e.preventDefault(); choosePalette(pActive); }
    else if (e.key === "Escape") closePalette();
  });

  /* ---- confirmation with gravity --------------------------------------- */
  const confirmEl = document.getElementById("confirm");
  const cTitle = document.getElementById("confirm-title");
  const cBody = document.getElementById("confirm-body");
  const cOk = document.getElementById("confirm-ok");
  const cCancel = document.getElementById("confirm-cancel");
  const cSeal = document.getElementById("confirm-seal");
  const cTypeWrap = document.getElementById("confirm-typewrap");
  const cTypeInput = document.getElementById("confirm-typeinput");
  const cTypeLabel = document.getElementById("confirm-typelabel");
  let confirmCb = null;

  function showConfirm(opts) {
    cTitle.textContent = opts.title || "Are you sure?";
    cBody.textContent = opts.body || "";
    cOk.textContent = opts.okLabel || "Confirm";
    cSeal.innerHTML = icon(opts.icon || "alert");
    confirmCb = opts.onOk || null;

    // tone: default crimson (destructive); ember for trust actions
    const ember = opts.tone === "ember";
    confirmEl.querySelector(".confirm__panel").style.borderColor = ember ? "rgba(250,107,6,0.45)" : "rgba(197,34,31,0.4)";
    cSeal.style.background = ember
      ? "radial-gradient(circle at 45% 35%, rgba(250,107,6,0.5), rgba(24,8,5,0.6))"
      : "radial-gradient(circle at 45% 35%, rgba(197,34,31,0.5), rgba(24,8,5,0.6))";
    cOk.className = "btn " + (ember ? "btn--ember" : "btn--seal");

    if (opts.requireType) {
      cTypeWrap.hidden = false;
      cTypeLabel.textContent = "Type " + opts.requireType + " to confirm";
      cTypeInput.value = "";
      cOk.disabled = true;
      cTypeInput.oninput = () => (cOk.disabled = cTypeInput.value.trim() !== opts.requireType);
    } else {
      cTypeWrap.hidden = true;
      cOk.disabled = false;
    }
    confirmEl.hidden = false;
    setTimeout(() => (opts.requireType ? cTypeInput : cCancel).focus(), 30);
  }
  function closeConfirm() { confirmEl.hidden = true; confirmCb = null; }
  cOk.addEventListener("click", () => { const cb = confirmCb; closeConfirm(); if (cb) cb(); });
  cCancel.addEventListener("click", closeConfirm);

  /* ---- toasts ----------------------------------------------------------- */
  const toastWrap = document.getElementById("toasts");
  function toast(msg, tone) {
    const t = document.createElement("div");
    t.className = "toast" + (tone === "seal" ? " toast--seal" : tone === "ember" ? " toast--ember" : "");
    t.setAttribute("role", "status");
    t.innerHTML = '<span class="toast__icon">' + icon(tone === "seal" ? "alert" : tone === "ember" ? "key" : "check") + "</span><span>" + window.C.esc(msg) + "</span>";
    toastWrap.appendChild(t);
    setTimeout(() => { t.classList.add("out"); setTimeout(() => t.remove(), 260); }, 4200);
  }

  /* ---- overlays close handlers ----------------------------------------- */
  document.querySelectorAll("[data-close]").forEach((el) =>
    el.addEventListener("click", () => {
      const which = el.dataset.close;
      if (which === "palette") closePalette();
      if (which === "confirm") closeConfirm();
    })
  );
  document.addEventListener("keydown", (e) => {
    if ((e.key === "k" || e.key === "K") && (e.metaKey || e.ctrlKey)) { e.preventDefault(); palette.hidden ? openPalette() : closePalette(); }
    else if (e.key === "Escape") { if (!palette.hidden) closePalette(); else if (!confirmEl.hidden) closeConfirm(); else closeRail(); }
    else if (e.key === "/" && palette.hidden && confirmEl.hidden && document.activeElement.tagName !== "INPUT" && document.activeElement.tagName !== "TEXTAREA") {
      e.preventDefault(); openPalette();
    }
  });
  document.getElementById("open-recall").addEventListener("click", openPalette);
  document.getElementById("open-recall-mobile").addEventListener("click", openPalette);

  /* ---- mobile rail ------------------------------------------------------ */
  const shell = document.querySelector(".app-shell");
  const scrim = document.getElementById("rail-scrim");
  const toggleBtn = document.getElementById("toggle-rail");
  function openRail() { shell.classList.add("rail-open"); scrim.hidden = false; toggleBtn.setAttribute("aria-expanded", "true"); }
  function closeRail() { shell.classList.remove("rail-open"); scrim.hidden = true; toggleBtn.setAttribute("aria-expanded", "false"); }
  toggleBtn.addEventListener("click", () => (shell.classList.contains("rail-open") ? closeRail() : openRail()));
  scrim.addEventListener("click", closeRail);

  /* ---- public API ------------------------------------------------------- */
  window.App = { go, toast, confirm: showConfirm, openPalette };

  // Delegated intra-surface navigation — survives dynamically rendered content
  // (live recall results, refiltered library lists, the recall lens).
  surfaceEl.addEventListener("click", (e) => {
    const goEl = e.target.closest("[data-go]");
    if (goEl && surfaceEl.contains(goEl)) { go(goEl.dataset.go); return; }
    const memEl = e.target.closest("[data-mem]");
    if (memEl && surfaceEl.contains(memEl)) go("memory/" + memEl.dataset.mem);
  });

  /* ---- boot ------------------------------------------------------------- */
  buildNav();
  window.addEventListener("hashchange", render);
  if (!location.hash) location.hash = "#/basin";
  render();
})();
