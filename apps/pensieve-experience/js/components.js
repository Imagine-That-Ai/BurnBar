/* ============================================================================
   Pensieve — reusable components
   Themeable, AA-contrast, keyboard-friendly building blocks. Each returns an
   HTML string; surfaces compose them. Stateful behavior is wired in app.js /
   surfaces.js after mount.
   ========================================================================== */
(function () {
  "use strict";
  const P = window.PENSIEVE;
  const icon = P.icon;

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  const KIND_ICON = { repo_docs: "git", notes: "note", chat_memory: "chat" };

  function tierBadge(tierId, opts) {
    opts = opts || {};
    const t = P.TIERS[tierId];
    if (!t) return "";
    return (
      '<span class="tier ' + t.cls + (opts.sm ? " tier--sm" : "") + '" title="' + esc(t.blurb) + '">' +
      '<span class="tier__gem" aria-hidden="true"></span>' + esc(t.label) + "</span>"
    );
  }

  // Memory strand / recall result.
  function strand(mem, opts) {
    opts = opts || {};
    const kind = mem.sourceKind;
    const src = P.SOURCES[mem.source];
    const matched = opts.matched || [];
    const text = opts.score != null
      ? window.RECALL.snippetAround(mem.body, matched, 200)
      : (mem.body.length > 200 ? mem.body.slice(0, 200) + "…" : mem.body);
    const snip = opts.score != null ? window.RECALL.highlight(text, matched) : esc(text);
    const title = opts.score != null ? window.RECALL.highlight(mem.title, matched) : esc(mem.title);

    const scoreHtml = opts.score != null
      ? '<span class="strand__score" title="client-side cosine relevance">' +
        '<span class="score-bar"><span class="score-bar__fill" style="width:' + Math.round(opts.score * 100) + '%"></span></span>' +
        opts.score.toFixed(3) + "</span>"
      : "";

    return (
      '<button class="strand strand--' + kind + (opts.rise ? " rise" : "") + '" ' +
      'data-mem="' + esc(mem.id) + '" data-strand ' +
      (opts.delay ? 'style="animation-delay:' + opts.delay + 'ms"' : "") +
      ' aria-label="Open memory: ' + esc(mem.title) + '">' +
        '<div class="strand__head">' +
          '<span class="strand__source">' + icon(KIND_ICON[kind]) + esc(src.label) + "</span>" +
          '<span class="strand__kind">' + esc(P.KIND_LABEL[kind]) + "</span>" +
        "</div>" +
        '<div class="strand__snippet"><b class="bright">' + title + "</b> — " + snip + "</div>" +
        '<div class="strand__foot">' +
          '<span class="strand__meta">' + icon("seal") + "sealed</span>" +
          '<span class="strand__meta">' + icon("cloak") + "cloaked</span>" +
          '<span class="strand__meta">' + P.fmtBytes(mem.byteCount) + "</span>" +
          '<span class="strand__meta">recalled ' + timeAgo(mem.lastRecalledAt) + "</span>" +
          scoreHtml +
        "</div>" +
      "</button>"
    );
  }

  function pipeline(steps) {
    return (
      '<div class="pipeline">' +
      steps.map((s) => {
        const cls = s.active ? " is-active" : s.done ? " is-done" : "";
        return (
          '<div class="pipe-step' + cls + '" style="--step-c:' + (s.color || "var(--color-tier-end-to-end)") + '">' +
            '<div class="pipe-step__node">' + icon(s.icon) + "</div>" +
            "<div>" +
              '<div class="pipe-step__title">' + esc(s.title) +
                (s.done ? ' <span class="teal" aria-label="done">' + icon("check") + "</span>" : "") + "</div>" +
              '<div class="pipe-step__desc">' + s.desc + "</div>" +
              (s.where ? '<div class="pipe-step__where">' + s.where + "</div>" : "") +
            "</div>" +
          "</div>"
        );
      }).join("") +
      "</div>"
    );
  }

  function facet(k, v, sealed) {
    return (
      '<div class="facet' + (sealed ? " facet--sealed" : "") + '">' +
      '<span class="facet__k">' + esc(k) + "</span>" +
      '<span class="facet__v">' + esc(v) + "</span>" +
      "</div>"
    );
  }

  function chip(label, opts) {
    opts = opts || {};
    return (
      '<span class="chip ' + (opts.cls || "") + '">' +
      (opts.icon ? icon(opts.icon) : opts.dot ? '<span class="chip__dot"></span>' : "") +
      (opts.mono ? '<span class="mono">' + esc(label) + "</span>" : esc(label)) +
      "</span>"
    );
  }

  function meter(label, used, max, fmt) {
    fmt = fmt || ((n) => n);
    const ratio = max > 0 ? used / max : 0;
    const over = ratio > 1;
    return (
      '<div class="meter' + (over ? " meter--over" : "") + '">' +
        '<div class="meter__row">' +
          '<span class="meter__label">' + esc(label) + "</span>" +
          '<span class="meter__val">' + esc(fmt(used)) + ' <span class="dim">/ ' + esc(fmt(max)) + "</span></span>" +
        "</div>" +
        '<div class="meter__track"><div class="meter__fill" style="width:' + Math.min(100, ratio * 100) + '%"></div></div>' +
      "</div>"
    );
  }

  function stat(value, label, opts) {
    opts = opts || {};
    return (
      '<div class="stat">' +
        '<div class="stat__value">' + value + (opts.unit ? ' <span class="unit">' + esc(opts.unit) + "</span>" : "") + "</div>" +
        '<div class="stat__label">' + esc(label) + "</div>" +
        (opts.delta ? '<div class="stat__delta">' + icon("arrow") + esc(opts.delta) + "</div>" : "") +
      "</div>"
    );
  }

  function domainRow(d) {
    const t = P.TIERS[d.tier];
    return (
      '<button class="domain" data-domain="' + esc(d.id) + '" style="--tier-c:' + t.color +
        ';--tier-bg:rgba(255,255,255,0.04);--tier-line:var(--color-glass-line)" aria-label="' + esc(d.title) + '">' +
        '<span class="domain__icon" style="--tier-c:' + t.color + '">' + icon(d.icon) + "</span>" +
        '<span class="domain__body">' +
          '<span class="domain__title"><span class="domain__name">' + esc(d.title) + "</span>" +
            tierBadge(d.tier, { sm: true }) +
            (d.gate ? '<span class="chip tiny">' + esc(d.gate) + "</span>" : "") + "</span>" +
          '<span class="domain__summary">' + esc(d.summary) + "</span>" +
          '<span class="domain__see">' +
            '<span class="domain__see-col domain__see--server"><span class="domain__see-h">Server sees</span>' +
              d.serverSees.slice(0, 4).map((s) => "<b>" + esc(s) + "</b>").join(" · ") + "</span>" +
            (d.deviceOnly.length
              ? '<span class="domain__see-col domain__see--device"><span class="domain__see-h">Only your devices</span>' +
                d.deviceOnly.map((s) => "<b>" + esc(s) + "</b>").join(" · ") + "</span>"
              : "") +
          "</span>" +
        "</span>" +
        '<span class="domain__aside">' +
          '<span class="mono small bright">' + esc(d.count) + "</span>" +
          '<span class="dim tiny">' + esc(d.retention) + "</span>" +
        "</span>" +
      "</button>"
    );
  }

  function recallLens(mems, opts) {
    opts = opts || {};
    return (
      '<div class="lens">' +
        '<div class="lens__head">' + icon("sparkle") +
          (opts.label || "Agent recall lens — memories pulled for this answer") + "</div>" +
        '<div class="lens__chips">' +
        mems.map((m) => {
          const s = P.SOURCES[m.id ? m.source : m];
          const mem = m.id ? m : P.memById(m);
          return (
            '<button class="provenance" data-mem="' + esc(mem.id) + '" style="--strand-c:' +
            (mem.sourceKind === "repo_docs" ? "var(--color-tier-end-to-end)" : mem.sourceKind === "notes" ? "var(--color-mercury-bright)" : "var(--color-tier-server-readable)") + '">' +
            '<span class="provenance__dot"></span>' + esc(mem.title) +
            (m.score != null ? ' <span class="mono">' + m.score.toFixed(2) + "</span>" : "") +
            "</button>"
          );
        }).join("") +
        "</div>" +
      "</div>"
    );
  }

  function emptyState(title, sub, orbCls) {
    return (
      '<div class="state ' + (orbCls || "") + '">' +
        '<div class="state__orb"></div>' +
        '<div class="state__title">' + esc(title) + "</div>" +
        '<div class="state__sub">' + esc(sub) + "</div>" +
      "</div>"
    );
  }

  function loadingState(label) {
    return (
      '<div class="stack-3" aria-busy="true" aria-label="' + esc(label || "Memories surfacing") + '">' +
      '<div class="skeleton" style="height:72px"></div>' +
      '<div class="skeleton" style="height:72px;animation-delay:.15s"></div>' +
      '<div class="skeleton" style="height:72px;animation-delay:.3s"></div>' +
      "</div>"
    );
  }

  function sectionHead(title, hint) {
    return (
      '<div class="section-head"><div class="section-head__title">' + esc(title) + "</div>" +
      (hint ? '<div class="section-head__hint">' + hint + "</div>" : "") + "</div>"
    );
  }

  function surfaceHero(eyebrow, title, lede) {
    return (
      '<header class="surface-hero">' +
        '<span class="eyebrow">' + esc(eyebrow) + "</span>" +
        '<h1 class="surface-hero__title">' + esc(title) + "</h1>" +
        (lede ? '<p class="surface-hero__lede">' + lede + "</p>" : "") +
      "</header>"
    );
  }

  function timeAgo(iso) {
    const now = Date.parse("2026-06-02T19:10:00Z");
    const d = (now - Date.parse(iso)) / 1000;
    if (d < 60) return "just now";
    if (d < 3600) return Math.floor(d / 60) + "m ago";
    if (d < 86400) return Math.floor(d / 3600) + "h ago";
    const days = Math.floor(d / 86400);
    if (days < 30) return days + "d ago";
    return Math.floor(days / 30) + "mo ago";
  }
  function fmtDate(iso) {
    const d = new Date(iso);
    return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) +
      " · " + d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit" });
  }

  window.C = {
    esc, icon, KIND_ICON, tierBadge, strand, pipeline, facet, chip, meter, stat,
    domainRow, recallLens, emptyState, loadingState, sectionHead, surfaceHero,
    timeAgo, fmtDate,
  };
})();
