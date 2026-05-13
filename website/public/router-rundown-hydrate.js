/**
 * Daily Intelligent Router Rundown — client-side hydrator.
 *
 * The page is server-rendered with a build-time fallback fixture. On
 * hydration we fetch the live rundown produced by the production daily
 * Cloud Function (`refreshModelLandscapeBenchmarks` →
 * `buildAndPersistRouterRundown` → `router_rundowns/latest`) and replace
 * the rendered content in place. If the live feed is unreachable or
 * malformed we leave the fallback visible and surface a degraded-state
 * badge — never silently show old data without saying so.
 *
 * Endpoint: `/api/router-rundown/<date>` (same-origin Firebase Hosting
 * rewrite → `latestRouterRundown` Cloud Function).
 */
(function () {
  const ENDPOINT_BASE = "/api/router-rundown/";

  function pct(x) {
    if (x == null || !Number.isFinite(x)) return "—";
    return String(Math.round(x * 100));
  }
  function displayScore(rec) {
    return rec.selectionScore == null ? rec.score : rec.selectionScore;
  }
  function tokens(x) {
    if (x == null) return "—";
    if (x >= 1_000_000) return (x / 1_000_000).toFixed(x % 1_000_000 === 0 ? 0 : 1) + "M";
    return Math.round(x / 1000) + "k";
  }
  function formatAge(hours) {
    if (hours == null || !Number.isFinite(hours) || hours < 0) return "age unknown";
    if (hours < 1) return Math.max(1, Math.round(hours * 60)) + "m old";
    if (hours < 48) return Math.round(hours) + "h old";
    return Math.round(hours / 24) + "d old";
  }
  function freshnessTone(s) {
    switch (s) {
      case "fresh": return "fresh";
      case "stale": case "cached": return "warn";
      case "manual": return "stale";
      default: return "off";
    }
  }
  function el(tag, attrs, kids) {
    const node = document.createElement(tag);
    if (attrs) for (const [k, v] of Object.entries(attrs)) {
      if (v == null) continue;
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else node.setAttribute(k, v);
    }
    if (Array.isArray(kids)) for (const kid of kids) if (kid != null) node.appendChild(kid);
    return node;
  }

  function renderRecommendation(rec) {
    const tone = freshnessTone(rec.freshness);
    const row = el("li", { class: "rankrow rankrow--rank" + rec.rank + " rankrow--" + tone });
    const lead = el("div", { class: "rankrow__lead" }, [
      el("span", { class: "rankrow__num mono", text: "#" + rec.rank }),
      rec.providerLogo ? el("img", { class: "rankrow__logo", src: rec.providerLogo, alt: "", width: "36", height: "36", loading: "lazy" }) : null,
      el("div", { class: "rankrow__id" }, [
        el("strong", { class: "rankrow__model", text: rec.modelDisplay }),
        el("span", { class: "rankrow__provider mono", text: rec.providerDisplay + (rec.providerFamily ? " · " + rec.providerFamily : "") + (rec.tier ? " · " + rec.tier : "") }),
      ]),
    ]);
    const score = el("div", { class: "rankrow__score" }, [
      el("span", { class: "rankrow__scorenum", text: pct(displayScore(rec)) }),
      el("span", { class: "rankrow__scorelab mono", text: "selection / 100" }),
      el("span", { class: "rankrow__cov mono", text: "evidence " + pct(rec.score) + " · coverage " + pct(rec.evidenceCoverage) + "%" }),
    ]);
    const s = rec.signals || {};
    function chip(label, value, tone) {
      const c = el("li", { class: "chip chip--" + (tone || (value != null ? "on" : "off")) });
      c.appendChild(el("span", { class: "chip__k mono", text: label }));
      c.appendChild(el("span", { class: "chip__v", text: String(value == null ? "—" : value) }));
      return c;
    }
    const chips = el("ul", { class: "rankrow__chips" }, [
      chip("bench", pct(s.benchmarkScore)),
      chip("fresh", pct(s.benchmarkFreshness), s.benchmarkFreshness != null ? freshnessTone(rec.freshness) : "off"),
      chip("rel", pct(s.reliability)),
      chip("latency", pct(s.latency)),
      chip("cost", pct(s.cost)),
      chip("ctx", tokens(s.contextWindowTokens)),
      chip("avail", s.availability == null ? "unknown" : s.availability, s.availability === "common" ? "on" : s.availability === "limited" ? "warn" : "off"),
      s.routable === false ? chip("runtime", "not routable", "burn") : null,
      rec.favoriteRank != null ? chip("board", "favorite #" + rec.favoriteRank, "on") : null,
    ].filter(Boolean));
    const body = el("div", { class: "rankrow__body" });
    const rationale = el("div", { class: "rankrow__rationale" }, [
      el("h4", { class: "rankrow__rh mono", text: "Board verdict" }),
      el("ul", { class: "rankrow__rlist" }, [rec.selectionReason].concat(rec.explanation || []).filter(Boolean).map((line) => el("li", { text: line }))),
    ]);
    const cites = el("div", { class: "rankrow__cites" }, [
      el("h4", { class: "rankrow__rh mono", text: "Source citations" }),
      rec.citations && rec.citations.length > 0
        ? el("ul", { class: "cites" }, rec.citations.map((cite) => {
            const tone2 = freshnessTone(cite.freshness);
            const li = el("li", { class: "cite cite--" + tone2 });
            li.appendChild(el("img", { class: "cite__logo", src: cite.logo, alt: "", width: "22", height: "22", loading: "lazy" }));
            const cb = el("div", { class: "cite__body" });
            const a = el("a", { class: "cite__name", href: cite.sourceURL || "/router#sources", target: "_blank", rel: "noopener noreferrer", text: cite.attribution });
            cb.appendChild(a);
            const meta = el("div", { class: "cite__meta mono" });
            if (cite.rank != null) meta.appendChild(el("span", { text: "rank " + cite.rank }));
            if (cite.score != null) meta.appendChild(el("span", { text: "score " + pct(cite.score) }));
            meta.appendChild(el("span", { text: formatAge(cite.ageHours) }));
            meta.appendChild(el("span", { class: "cite__fresh", text: cite.freshness }));
            cb.appendChild(meta);
            li.appendChild(cb);
            return li;
          }))
        : el("p", { class: "rankrow__none mono", text: "No benchmark snapshot from any active source today." }),
    ]);
    body.appendChild(rationale);
    body.appendChild(cites);
    if (rec.limitations && rec.limitations.length > 0) {
      body.appendChild(el("div", { class: "rankrow__lims" }, [
        el("h4", { class: "rankrow__rh mono", text: "Limitations" }),
        el("ul", { class: "rankrow__llist" }, rec.limitations.map((line) => el("li", { text: line }))),
      ]));
    }
    row.appendChild(lead);
    row.appendChild(score);
    row.appendChild(chips);
    row.appendChild(body);
    return row;
  }

  function renderTask(task) {
    const card = el("li", { class: "taskcard", id: "task-" + task.taskID });
    const head = el("header", { class: "taskcard__head" });
    const headline = el("div", { class: "taskcard__headline" }, [
      el("span", { class: "pill pill--" + task.taskID, text: task.taskLabel }),
      el("p", { class: "taskcard__blurb", text: task.taskBlurb }),
    ]);
    head.appendChild(headline);
    if (task.note) head.appendChild(el("p", { class: "taskcard__note mono", text: task.note }));
    card.appendChild(head);
    card.appendChild(el("p", { class: "taskcard__lede", text: task.topPickRationale }));
    card.appendChild(el("ol", { class: "ranks" }, (task.recommendations || []).map(renderRecommendation)));
    if (task.rejectedAlternatives && task.rejectedAlternatives.length > 0) {
      const det = el("details", { class: "rejects" });
      const sum = el("summary");
      sum.appendChild(el("span", { class: "rejects__sum", text: "Why other candidates didn't make the board pick" }));
      sum.appendChild(el("span", { class: "rejects__count mono", text: task.rejectedAlternatives.length + " dropped" }));
      det.appendChild(sum);
      det.appendChild(el("ul", { class: "rejects__list" }, task.rejectedAlternatives.map((r) => {
        const li = el("li", { class: "reject" });
        if (r.providerLogo) li.appendChild(el("img", { class: "reject__logo", src: r.providerLogo, alt: "", width: "22", height: "22", loading: "lazy" }));
        const d = el("div");
        d.appendChild(el("strong", { text: r.modelDisplay }));
        d.appendChild(el("span", { class: "reject__provider mono", text: " · " + r.providerDisplay }));
        d.appendChild(el("p", { class: "reject__reason", text: r.reason }));
        if (r.evidence) d.appendChild(el("p", { class: "reject__ev mono", text: r.evidence }));
        li.appendChild(d);
        return li;
      })));
      card.appendChild(det);
    }
    return card;
  }

  function applyRundown(root, rundown) {
    const titleEl = root.querySelector("[data-rundown-title]");
    const metaEl = root.querySelector("[data-rundown-meta]");
    if (titleEl && !titleEl.textContent.startsWith("Today's recommended")) {
      titleEl.textContent = "Rundown · " + rundown.date;
    }
    if (metaEl) {
      const d = new Date(rundown.generatedAt);
      metaEl.textContent = "Generated " + (isNaN(d.getTime()) ? rundown.generatedAt : d.toUTCString()) + " · schema v" + rundown.schemaVersion + " · model board · runtime constraints win";
    }
    const sources = root.querySelector(".rundown__sources");
    if (sources) {
      sources.innerHTML = "";
      for (const source of rundown.sourceStatuses) {
        const tone = freshnessTone(source.status);
        const li = el("li", { class: "srctag srctag--" + tone });
        li.appendChild(el("img", { class: "srctag__logo", src: source.logo, alt: "", width: "20", height: "20", loading: "lazy" }));
        const body = el("div", { class: "srctag__body" });
        body.appendChild(el("strong", { class: "srctag__name", text: source.attribution }));
        const age = source.status === "fresh"
          ? "fresh"
          : source.status === "stale"
            ? "stale · " + formatAge(source.ageHours)
            : source.status;
        body.appendChild(el("span", { class: "srctag__age mono", text: age }));
        li.appendChild(body);
        li.appendChild(el("span", { class: "srctag__dot srctag__dot--" + tone, "aria-hidden": "true" }));
        sources.appendChild(li);
      }
    }
    const tasks = root.querySelector(".rundown__tasks");
    if (tasks) {
      tasks.innerHTML = "";
      for (const task of rundown.taskRankings) tasks.appendChild(renderTask(task));
    }
    const limsList = root.querySelector(".rundown__lims ul");
    if (limsList) {
      limsList.innerHTML = "";
      for (const line of rundown.globalLimitations) limsList.appendChild(el("li", { text: line }));
    }
  }

  function setState(root, kind, label) {
    const node = root.querySelector("[data-rundown-state]");
    if (!node) return;
    node.className = "rundown__state rundown__state--" + kind + " mono";
    node.textContent = label;
  }

  async function hydrate(root) {
    const livePath = root.getAttribute("data-rundown-live-path") || "latest";
    const fallbackDate = root.getAttribute("data-rundown-fallback-date");
    try {
      const url = ENDPOINT_BASE + encodeURIComponent(livePath);
      const res = await fetch(url, { headers: { Accept: "application/json" }, cache: "no-store" });
      if (!res.ok) {
        setState(root, "fallback", "live feed unavailable · showing build-time fallback (" + (fallbackDate || "—") + ")");
        return;
      }
      const live = await res.json();
      if (!live || !live.date || !Array.isArray(live.taskRankings)) {
        setState(root, "fallback", "live feed malformed · showing build-time fallback (" + (fallbackDate || "—") + ")");
        return;
      }
      applyRundown(root, live);
      setState(root, "live", "live from production daily job · " + live.date);
    } catch (err) {
      setState(root, "fallback", "live feed offline · showing build-time fallback (" + (fallbackDate || "—") + ")");
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      document.querySelectorAll(".rundown[data-rundown-live-path]").forEach((root) => hydrate(root));
    });
  } else {
    document.querySelectorAll(".rundown[data-rundown-live-path]").forEach((root) => hydrate(root));
  }
})();
