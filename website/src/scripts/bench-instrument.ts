/**
 * /bench — client behaviour for the Instrument layout.
 *
 * Everything geometric is authored as data-* attributes at build time and
 * applied here through CSSOM. No inline style attributes ship in the markup,
 * so the hash-locked CSP stays lean.
 *
 * Scope:
 *   - paint bar geometry (value, 95% band, strict tick)
 *   - leaderboard metric switching + filtering
 *   - model-lens dot placement
 *   - scatter hover/focus readout
 *   - synthesis rendering from /data/synthesis.json
 */

import { initFigures } from "./bench-figure";
import { closestFrom } from "./dom.js";

const isReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ── geometry ─────────────────────────────────────────────────────────── */

/**
 * Paint every bar inside `root`. Widths start at 0 and are set on the next
 * frame so the CSS transition runs — one orchestrated entrance, then stillness.
 */
function paintBars(root: ParentNode = document): void {
  const apply = (): void => {
    root.querySelectorAll<HTMLElement>("[data-ins-bar]").forEach((bar) => {
      const fill = bar.querySelector<HTMLElement>(".ins-bar__fill");
      if (fill?.dataset.w) fill.style.width = `${fill.dataset.w}%`;

      const ci = bar.querySelector<HTMLElement>(".ins-bar__ci");
      if (ci?.dataset.l != null && ci.dataset.r != null) {
        ci.style.left = `${ci.dataset.l}%`;
        ci.style.right = `${ci.dataset.r}%`;
      }

      const tick = bar.querySelector<HTMLElement>(".ins-bar__tick");
      if (tick?.dataset.x) tick.style.left = `${tick.dataset.x}%`;
    });

    // Distribution segments paint the same way, from their own data-w.
    root.querySelectorAll<HTMLElement>(".ins-qdist__seg").forEach((seg) => {
      if (seg.dataset.w) seg.style.width = `${seg.dataset.w}%`;
    });
  };
  if (isReduced) apply();
  else requestAnimationFrame(() => requestAnimationFrame(apply));
}

/** Model-lens rows: range band + one dot per harness. */
function paintLens(): void {
  document.querySelectorAll<HTMLElement>("[data-ins-lens-track]").forEach((track) => {
    const range = track.querySelector<HTMLElement>(".ins-lensrow__range");
    if (range?.dataset.l != null && range.dataset.r != null) {
      range.style.left = `${range.dataset.l}%`;
      range.style.right = `${range.dataset.r}%`;
    }
    track.querySelectorAll<HTMLElement>(".ins-lensrow__dot").forEach((dot) => {
      if (dot.dataset.x) dot.style.left = `${dot.dataset.x}%`;
    });
  });
}

/* ── leaderboard ──────────────────────────────────────────────────────── */

type Lens = "solution" | "strict" | "cost" | "speed" | "quality";
const LENSES: readonly Lens[] = ["solution", "strict", "cost", "speed", "quality"];
const asLens = (value: string | undefined): Lens =>
  LENSES.find((lens) => lens === value) ?? "solution";

/** Higher is better for rates and quality; lower is better for cost and time. */
const ASCENDING: Record<Lens, boolean> = {
  solution: false,
  strict: false,
  cost: true,
  speed: true,
  quality: false
};

const UNIT: Record<Lens, "pct" | "usd" | "sec" | "score"> = {
  solution: "pct",
  strict: "pct",
  cost: "usd",
  speed: "sec",
  quality: "score"
};

function readMetric(row: HTMLElement, lens: Lens): number | null {
  const raw = row.dataset[lens];
  if (raw == null || raw === "") return null;
  const v = Number(raw);
  return Number.isFinite(v) ? v : null;
}

function formatMetric(v: number, lens: Lens): string {
  switch (UNIT[lens]) {
    case "pct":
      return `${(v * 100).toFixed(1)}%`;
    case "usd":
      // One precision for the whole column: mixing $0.0083 with $0.01 makes
      // two comparable numbers look like different quantities.
      return v === 0 ? "$0.00" : v < 0.1 ? `$${v.toFixed(4)}` : `$${v.toFixed(2)}`;
    case "sec": {
      if (v < 60) return `${v.toFixed(0)}s`;
      const m = Math.floor(v / 60);
      const s = Math.round(v % 60);
      return `${m}m ${String(s).padStart(2, "0")}s`;
    }
    case "score":
      return v.toFixed(2);
  }
}

/** Re-render a value cell as typeset digits: integer, then a lighter decimal
 *  and unit. Mirrors the Num component so switching metrics doesn't downgrade
 *  the typography. */
function renderNum(host: HTMLElement, text: string): void {
  host.textContent = "";
  const m = /^(\D*)(\d[\d,]*)(\.\d+)?(.*)$/.exec(text);
  if (!m) {
    host.textContent = text;
    return;
  }
  const prefix = m[1] ?? "";
  const int = m[2] ?? "";
  const dec = m[3] ?? "";
  const suffix = m[4] ?? "";
  if (prefix) {
    const el = document.createElement("span");
    el.className = "ins-num__sign";
    el.textContent = prefix;
    host.append(el);
  }
  host.append(document.createTextNode(int));
  if (dec) {
    const el = document.createElement("span");
    el.className = "ins-num__dec";
    el.textContent = dec;
    host.append(el);
  }
  if (suffix) {
    const el = document.createElement("span");
    el.className = "ins-num__unit";
    el.textContent = suffix;
    host.append(el);
  }
}

function initLeaderboard(): void {
  const list = document.querySelector<HTMLElement>("[data-ins-lb]");
  const tabs = document.querySelector<HTMLElement>("[data-ins-lens-tabs]");
  if (!list) return;

  const rows = Array.from(list.querySelectorAll<HTMLElement>(".ins-row"));
  let lens: Lens = "solution";

  const resort = (): void => {
    const asc = ASCENDING[lens];
    const scored = rows.map((row) => ({ row, v: readMetric(row, lens) }));

    // Unmeasured stacks sort last on every lens rather than pretending to be 0.
    scored.sort((a, b) => {
      if (a.v == null && b.v == null) return 0;
      if (a.v == null) return 1;
      if (b.v == null) return -1;
      return asc ? a.v - b.v : b.v - a.v;
    });

    // Rescale bars to the visible metric's observed band, so every lens gets
    // the same "spread is visible" treatment the solution axis gets.
    //
    // Cost spans more than two orders of magnitude ($0.004 to $0.86), so a
    // linear scale pins almost every stack to the cheap end and the bars stop
    // distinguishing anything. Cost is therefore scaled on log10 — which is
    // also how anyone actually reasons about price differences.
    const logScale = lens === "cost";
    const raw = scored.map((s) => s.v).filter((v): v is number => v != null);
    const vals = logScale ? raw.filter((v) => v > 0).map((v) => Math.log10(v)) : raw;
    const lo = vals.length ? Math.min(...vals) : 0;
    const hi = vals.length ? Math.max(...vals) : 1;
    const span = hi - lo || 1;
    const pos = (v: number): number => {
      if (logScale && v <= 0) return 100; // free is as good as it gets
      const scaled = logScale ? Math.log10(v) : v;
      const t = (scaled - lo) / span;
      // Lower-is-better metrics fill from the good end.
      return Math.max(2, Math.min(100, (asc ? 1 - t : t) * 96 + 4));
    };

    let lastVal: number | null = null;
    let lastRank = 0;

    scored.forEach(({ row, v }, i) => {
      list.append(row);

      const rankEl = row.querySelector<HTMLElement>(".ins-row__rank");
      const valEl = row.querySelector<HTMLElement>(".ins-row__num");
      const fill = row.querySelector<HTMLElement>(".ins-bar__fill");
      const ci = row.querySelector<HTMLElement>(".ins-bar__ci");
      const tick = row.querySelector<HTMLElement>(".ins-bar__tick");

      const rank = v != null && v === lastVal ? lastRank : i + 1;
      lastVal = v;
      lastRank = rank;

      if (rankEl) {
        rankEl.textContent = v == null ? "··" : String(rank).padStart(2, "0");
      }
      row.classList.toggle("ins-row--lead", rank === 1 && v != null);

      if (valEl) {
        if (v == null) {
          valEl.textContent = "—";
          valEl.classList.add("ins-num--none");
        } else {
          valEl.classList.remove("ins-num--none");
          renderNum(valEl, formatMetric(v, lens));
        }
      }

      if (fill) fill.style.width = v == null ? "0%" : `${pos(v).toFixed(2)}%`;

      // The interval band and the strict tick only mean something on the two
      // rate lenses. Hide them elsewhere rather than drawing a wrong band.
      const rateLens = lens === "solution" || lens === "strict";
      if (ci) {
        ci.hidden = !rateLens;
        if (rateLens) {
          const cl = Number(row.dataset.ciLo);
          const ch = Number(row.dataset.ciHi);
          if (Number.isFinite(cl) && Number.isFinite(ch)) {
            ci.style.left = `${pos(cl).toFixed(2)}%`;
            ci.style.right = `${(100 - pos(ch)).toFixed(2)}%`;
          }
        }
      }
      if (tick) {
        const showTick = lens === "solution";
        tick.hidden = !showTick;
        if (showTick) {
          const st = Number(row.dataset.strict);
          if (Number.isFinite(st)) tick.style.left = `${pos(st).toFixed(2)}%`;
        }
      }
    });

    // Axis ticks belong to the solution scale; hide them on other lenses
    // rather than mislabelling the track.
    const axis = document.querySelector<HTMLElement>(".ins-lb__axis");
    if (axis) axis.hidden = lens !== "solution";
  };

  tabs?.addEventListener("click", (ev) => {
    const btn = closestFrom(ev.target, "[data-lens]", HTMLElement);
    if (!btn) return;
    lens = asLens(btn.dataset.lens);
    tabs.querySelectorAll<HTMLElement>("[data-lens]").forEach((b) => {
      b.setAttribute("aria-selected", String(b === btn));
    });
    resort();
  });

  const filter = document.querySelector<HTMLInputElement>("[data-ins-lb-filter]");
  filter?.addEventListener("input", () => {
    const q = filter.value.trim().toLowerCase();
    rows.forEach((row) => {
      const hit = q === "" || (row.dataset.name ?? "").includes(q);
      row.hidden = !hit;
    });
  });
}

/* ── scatter ──────────────────────────────────────────────────────────── */

function initScatter(): void {
  const svg = document.querySelector<SVGSVGElement>(".ins-scatter__svg");
  if (!svg) return;

  const dots = Array.from(svg.querySelectorAll<SVGGElement>(".ins-dot"));

  const focus = (dot: SVGGElement | null): void => {
    svg.classList.toggle("is-focused", dot != null);
    dots.forEach((d) => d.classList.toggle("is-dim", dot != null && d !== dot));
    if (dot) dot.parentNode?.appendChild(dot); // bring to front
  };

  dots.forEach((dot) => {
    dot.addEventListener("pointerenter", () => focus(dot));
    dot.addEventListener("focus", () => focus(dot));
    dot.addEventListener("pointerleave", () => focus(null));
    dot.addEventListener("blur", () => focus(null));
  });
}

/* ── synthesis carousel ───────────────────────────────────────────────── */

/**
 * /data/synthesis.json ships each slice as an object keyed by id — not an
 * array — with a distilled `summary` plus the `observations` behind it.
 *
 * Twenty-five of those in one grid was a wall of text: correct, complete, and
 * genuinely intimidating. Same content, grouped instead: choose an axis
 * (harness or model), pick one by its logo, and read its pairings a few at a
 * time. The detail stays one tap away rather than all on screen at once.
 *
 * Rendered client-side because the analysis job rewrites the file on its own
 * schedule — new synthesis lands without rebuilding the page.
 */
interface SynthSlice {
  summary?: string;
  observations?: string[];
  /** The job emits this as a string on some runs and a number on others. */
  n_tasks?: number | string;
}

type SynthGroup = Record<string, SynthSlice>;

interface SynthDoc {
  combos?: SynthGroup;
  harnesses?: SynthGroup;
  models?: SynthGroup;
}

interface RosterEntry {
  display: string;
  logo: string | null;
  cls: string;
}

interface Roster {
  harnesses: Record<string, RosterEntry>;
  models: Record<string, RosterEntry>;
}

type Axis = "harness" | "model";
const asAxis = (value: string | undefined): Axis => (value === "model" ? "model" : "harness");

interface Pairing {
  harness: string;
  model: string;
  slice: SynthSlice;
}

const FALLBACK: RosterEntry = { display: "", logo: null, cls: "" };

function readRoster(): Roster {
  const el = document.querySelector<HTMLScriptElement>("[data-bench-roster]");
  if (!el?.textContent) return { harnesses: {}, models: {} };
  try {
    const roster: Roster = JSON.parse(el.textContent);
    return roster;
  } catch {
    return { harnesses: {}, models: {} };
  }
}

/** Prettify an id the roster doesn't know (new model mid-campaign, say). */
function prettyId(id: string): string {
  return id.replace(/-/g, " ");
}

function entryFor(roster: Roster, axis: "harnesses" | "models", id: string): RosterEntry {
  return roster[axis][id] ?? { ...FALLBACK, display: prettyId(id) };
}

/** A logo chip at a size you can actually see and tap. */
function chipEl(entry: RosterEntry, kind: "harness" | "model", size: "md" | "lg"): HTMLElement {
  const chip = document.createElement("span");
  chip.className = `ins-chip ins-chip--${size} ins-chip--${kind === "harness" ? "h" : "m"} ${entry.cls}`;
  if (entry.logo) {
    const img = document.createElement("img");
    img.src = entry.logo;
    img.alt = "";
    img.loading = "lazy";
    img.decoding = "async";
    chip.append(img);
  } else {
    const mono = document.createElement("span");
    mono.className = "ins-mono";
    mono.textContent = (entry.display || "?").slice(0, 2).toUpperCase();
    chip.append(mono);
  }
  return chip;
}

function synthCard(p: Pairing, roster: Roster): HTMLElement {
  const h = entryFor(roster, "harnesses", p.harness);
  const m = entryFor(roster, "models", p.model);

  const card = document.createElement("article");
  card.className = `ins-glass ins-synthcard ${m.cls} ${h.cls}`;

  const head = document.createElement("header");
  head.className = "ins-synthcard__head";

  // Row 1: the marks and the task count. Row 2: the full name across the
  // whole card, so neither half of the pairing gets ellipsised.
  const top = document.createElement("span");
  top.className = "ins-synthcard__top";

  const marks = document.createElement("span");
  marks.className = "ins-synthcard__marks";
  marks.append(chipEl(h, "harness", "lg"), chipEl(m, "model", "lg"));
  top.append(marks);

  const tasks = Number(p.slice.n_tasks);
  if (Number.isFinite(tasks) && tasks > 0) {
    const n = document.createElement("span");
    n.className = "ins-synthcard__n ins-num ins-num--xs";
    n.textContent = `${tasks} tasks`;
    top.append(n);
  }

  const names = document.createElement("span");
  names.className = "ins-synthcard__names";
  const hn = document.createElement("span");
  hn.className = "ins-row__h";
  hn.textContent = h.display;
  const mn = document.createElement("span");
  mn.className = "ins-row__m";
  mn.textContent = m.display;
  // Harness above, model below — the two tracks read as two fields, and the
  // logo pair already says these are a pairing. A dangling "x" at a line
  // break says nothing.
  names.append(hn, mn);

  head.append(top, names);

  const body = document.createElement("p");
  body.className = "ins-synthcard__b";
  body.textContent = (p.slice.summary ?? "").trim();

  card.append(head, body);

  // The observations are the evidence behind the take. One tap away, so the
  // card reads as a takeaway rather than a transcript.
  const obs = (p.slice.observations ?? []).filter((o) => typeof o === "string" && o.trim());
  if (obs.length > 0) {
    const det = document.createElement("details");
    det.className = "ins-disc ins-synthcard__more";

    const sum = document.createElement("summary");
    const label = document.createElement("span");
    label.textContent = `What the judge saw (${obs.length})`;
    const caret = document.createElement("span");
    caret.className = "ins-disc__caret";
    caret.textContent = "⌄";
    sum.append(label, caret);

    const list = document.createElement("ul");
    list.className = "ins-synthcard__obs";
    for (const o of obs) {
      const li = document.createElement("li");
      li.textContent = o.trim();
      list.append(li);
    }

    det.append(sum, list);
    card.append(det);
  }

  return card;
}

function initSynthesisCarousel(doc: SynthDoc, roster: Roster, body: HTMLElement): number {
  const rail = body.querySelector<HTMLElement>("[data-syn-rail]");
  const track = body.querySelector<HTMLElement>("[data-syn-track]");
  const dots = body.querySelector<HTMLElement>("[data-syn-dots]");
  const axisTabs = body.querySelector<HTMLElement>("[data-syn-axis]");
  if (!rail || !track) return 0;

  // Combo ids look like "claude/deepseek-v4-flash-0731".
  const pairings: Pairing[] = Object.entries(doc.combos ?? {})
    .map(([id, slice]) => {
      const slash = id.indexOf("/");
      if (slash === -1) return null;
      return { harness: id.slice(0, slash), model: id.slice(slash + 1), slice };
    })
    .filter((p): p is Pairing => p != null && Boolean((p.slice.summary ?? "").trim()));

  if (pairings.length === 0) return 0;

  let axis: Axis = "harness";
  let selected = "";

  const groupsFor = (a: Axis): string[] => {
    const seen: string[] = [];
    for (const p of pairings) {
      const key = a === "harness" ? p.harness : p.model;
      if (!seen.includes(key)) seen.push(key);
    }
    return seen.sort((x, y) => x.localeCompare(y));
  };

  const renderTrack = (): void => {
    track.textContent = "";
    const cards = pairings.filter((p) => (axis === "harness" ? p.harness : p.model) === selected);
    for (const p of cards) track.append(synthCard(p, roster));
    track.scrollTo({ left: 0, behavior: "auto" });
    renderDots();
    updateNav();
  };

  const renderDots = (): void => {
    if (!dots) return;
    dots.textContent = "";
    const n = track.children.length;
    if (n < 2) return;
    for (let i = 0; i < n; i++) {
      const d = document.createElement("span");
      d.className = "ins-carousel__dot";
      dots.append(d);
    }
    syncDots();
  };

  const cardStep = (): number => {
    const first = track.firstElementChild instanceof HTMLElement ? track.firstElementChild : null;
    if (!first) return track.clientWidth;
    const gap = parseFloat(getComputedStyle(track).columnGap || "0") || 0;
    return first.offsetWidth + gap;
  };

  const syncDots = (): void => {
    if (!dots || dots.children.length === 0) return;
    const idx = Math.round(track.scrollLeft / cardStep());
    Array.from(dots.children).forEach((d, i) =>
      d.classList.toggle("is-on", i === Math.max(0, Math.min(dots.children.length - 1, idx)))
    );
  };

  const updateNav = (): void => {
    const prev = body.querySelector<HTMLButtonElement>("[data-syn-prev]");
    const next = body.querySelector<HTMLButtonElement>("[data-syn-next]");
    const max = track.scrollWidth - track.clientWidth - 2;
    if (prev) prev.disabled = track.scrollLeft <= 2;
    if (next) next.disabled = track.scrollLeft >= max;
    const single = track.scrollWidth <= track.clientWidth + 2;
    body.querySelector("[data-syn-carousel]")?.classList.toggle("is-static", single);
  };

  const renderRail = (): void => {
    rail.textContent = "";
    const keys = groupsFor(axis);
    if (!keys.includes(selected)) selected = keys[0] ?? "";
    for (const key of keys) {
      const entry = entryFor(roster, axis === "harness" ? "harnesses" : "models", key);
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `ins-railchip ${entry.cls}`;
      btn.setAttribute("role", "tab");
      btn.setAttribute("aria-selected", String(key === selected));
      btn.append(chipEl(entry, axis, "md"));
      const label = document.createElement("span");
      label.className = "ins-railchip__label";
      label.textContent = entry.display;
      const count = pairings.filter(
        (p) => (axis === "harness" ? p.harness : p.model) === key
      ).length;
      const n = document.createElement("span");
      n.className = "ins-railchip__n";
      n.textContent = String(count);
      btn.append(label, n);
      btn.addEventListener("click", () => {
        selected = key;
        Array.from(rail.children).forEach((c) =>
          c.setAttribute("aria-selected", String(c === btn))
        );
        renderTrack();
      });
      rail.append(btn);
    }
    renderTrack();
  };

  body.querySelector("[data-syn-prev]")?.addEventListener("click", () => {
    track.scrollBy({ left: -cardStep(), behavior: isReduced ? "auto" : "smooth" });
  });
  body.querySelector("[data-syn-next]")?.addEventListener("click", () => {
    track.scrollBy({ left: cardStep(), behavior: isReduced ? "auto" : "smooth" });
  });
  track.addEventListener("scroll", () => {
    syncDots();
    updateNav();
  });

  axisTabs?.addEventListener("click", (ev) => {
    const btn = closestFrom(ev.target, "[data-axis]", HTMLElement);
    if (!btn) return;
    axis = asAxis(btn.dataset.axis);
    axisTabs.querySelectorAll("[data-axis]").forEach((b) => {
      b.setAttribute("aria-selected", String(b === btn));
    });
    selected = "";
    renderRail();
  });

  renderRail();
  return pairings.length;
}

async function initSynthesis(): Promise<void> {
  const section = document.querySelector<HTMLElement>("[data-br-synthesis]");
  if (!section) return;

  const status = section.querySelector<HTMLElement>("[data-br-synthesis-status]");
  const body = section.querySelector<HTMLElement>("[data-br-synthesis-body]");
  if (!status || !body) return;

  try {
    const res = await fetch("/data/synthesis.json", { cache: "no-cache" });
    if (!res.ok) throw new Error(`synthesis ${res.status}`);
    const doc: SynthDoc = await res.json();

    const rendered = initSynthesisCarousel(doc, readRoster(), body);
    if (rendered === 0) throw new Error("synthesis empty");

    status.hidden = true;
    body.hidden = false;
  } catch {
    // The job may still be running. Say so plainly rather than leaving a
    // spinner that never resolves.
    status.textContent = "";
    const note = document.createElement("div");
    note.className = "ins-glass ins-glass--flush ins-synth__pending";
    note.textContent =
      "Synthesis isn't available yet — the cross-cutting analysis job publishes it on the next run.";
    status.append(note);
  }
}

/* ── hover stats ──────────────────────────────────────────────────────── */

/**
 * One tooltip, shared by every mark on the page — leaderboard rows, model-lens
 * dots, scatter points. Native `title` tooltips are slow to appear, unstyled,
 * and invisible on touch; this is instant, carries the logos, and sets its
 * figures in the same tabular grammar as the rest of the page.
 *
 * Marks opt in with:
 *   data-tip
 *   data-tip-h / data-tip-m     harness + model ids (for the logos)
 *   data-tip-lead               the headline figure
 *   data-tip-lead-label         what it measures
 *   data-tip-rows               "label|value;label|value"
 *   data-tip-note               optional footnote
 */
function initTooltips(): void {
  const marks = document.querySelectorAll<HTMLElement>("[data-tip]");
  if (marks.length === 0) return;

  const roster = readRoster();

  const tip = document.createElement("div");
  tip.className = "ins-tip ins-glass ins-glass--flush";
  tip.setAttribute("role", "tooltip");
  tip.hidden = true;
  // Mount inside .ins, not <body>: every design token lives on that element,
  // and a tooltip parented outside it renders as an unstyled transparent box.
  // .ins carries no transform or filter, so position: fixed stays
  // viewport-relative.
  (document.querySelector<HTMLElement>(".ins") ?? document.body).append(tip);

  const build = (el: HTMLElement): void => {
    tip.textContent = "";
    tip.className = "ins-tip ins-glass ins-glass--flush";

    const hId = el.dataset.tipH ?? "";
    const mId = el.dataset.tipM ?? "";
    const h = entryFor(roster, "harnesses", hId);
    const m = entryFor(roster, "models", mId);
    if (m.cls) tip.classList.add(m.cls);
    if (h.cls) tip.classList.add(h.cls);

    const head = document.createElement("div");
    head.className = "ins-tip__head";
    const marksEl = document.createElement("span");
    marksEl.className = "ins-tip__marks";
    marksEl.append(chipEl(h, "harness", "md"), chipEl(m, "model", "md"));
    const names = document.createElement("span");
    names.className = "ins-tip__names";
    const hn = document.createElement("span");
    hn.className = "ins-row__h";
    hn.textContent = h.display;
    const mn = document.createElement("span");
    mn.className = "ins-row__m";
    mn.textContent = m.display;
    names.append(hn, mn);
    head.append(marksEl, names);
    tip.append(head);

    const lead = el.dataset.tipLead;
    if (lead) {
      const box = document.createElement("div");
      box.className = "ins-tip__lead";
      const v = document.createElement("span");
      v.className = "ins-num ins-num--xl";
      renderNum(v, lead);
      const l = document.createElement("span");
      l.className = "ins-tip__leadlabel";
      l.textContent = el.dataset.tipLeadLabel ?? "";
      box.append(v, l);
      tip.append(box);
    }

    const rows = (el.dataset.tipRows ?? "").split(";").filter(Boolean);
    if (rows.length > 0) {
      const dl = document.createElement("dl");
      dl.className = "ins-ledger ins-tip__rows";
      for (const row of rows) {
        const sep = row.indexOf("|");
        if (sep === -1) continue;
        const wrap = document.createElement("div");
        wrap.className = "ins-ledger__row";
        const dt = document.createElement("dt");
        dt.className = "ins-ledger__k";
        dt.textContent = row.slice(0, sep);
        const dd = document.createElement("dd");
        dd.className = "ins-ledger__v";
        dd.textContent = row.slice(sep + 1);
        wrap.append(dt, dd);
        dl.append(wrap);
      }
      tip.append(dl);
    }

    const note = el.dataset.tipNote;
    if (note) {
      const n = document.createElement("p");
      n.className = "ins-tip__note";
      n.textContent = note;
      tip.append(n);
    }
  };

  /** Anchor above the mark, flipping below and nudging inside the viewport. */
  const place = (el: HTMLElement): void => {
    const r = el.getBoundingClientRect();
    const t = tip.getBoundingClientRect();
    const pad = 10;

    let left = r.left + r.width / 2 - t.width / 2;
    left = Math.max(pad, Math.min(window.innerWidth - t.width - pad, left));

    let top = r.top - t.height - pad;
    if (top < pad) top = r.bottom + pad;

    tip.style.left = `${Math.round(left)}px`;
    tip.style.top = `${Math.round(top)}px`;
  };

  let current: HTMLElement | null = null;

  const show = (el: HTMLElement): void => {
    current = el;
    build(el);
    tip.hidden = false;
    // Measure after paint so the flip logic sees the real height.
    requestAnimationFrame(() => {
      if (current === el) place(el);
    });
  };

  const hide = (): void => {
    current = null;
    tip.hidden = true;
  };

  marks.forEach((el) => {
    el.addEventListener("pointerenter", () => show(el));
    el.addEventListener("pointerleave", hide);
    el.addEventListener("focus", () => show(el));
    el.addEventListener("blur", hide);
  });

  // Touch: a tap shows the stats, a tap elsewhere dismisses them.
  document.addEventListener(
    "pointerdown",
    (ev) => {
      const el = closestFrom(ev.target, "[data-tip]", HTMLElement);
      if (el) {
        if (ev.pointerType === "touch") show(el);
      } else if (current) {
        hide();
      }
    },
    { passive: true }
  );

  window.addEventListener("scroll", () => current && place(current), { passive: true });
  window.addEventListener("resize", hide, { passive: true });
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") hide();
  });
}

/* ── live human verdict ───────────────────────────────────────────────── */

/**
 * The Arena's Bradley-Terry ratings ship inside bench.json, which is baked at
 * build time — so a vote cast today wouldn't show until the next deploy.
 * This reads /data/arena-live.json instead, which the ratings pipeline can
 * rewrite on its own cadence, and falls back to the baked numbers.
 *
 * The honest case matters here: ratings are only published once a stack has
 * enough votes to mean anything. Until then this panel says how far off that
 * is rather than rendering a leaderboard built on four votes.
 */
interface ArenaRating {
  harness: string;
  model: string;
  bt: number;
  ci95?: [number, number];
  votes: number;
}
interface ArenaLive {
  votes?: number;
  min_votes_per_stack?: number;
  ratings?: ArenaRating[];
}

const ARENA_MIN_VOTES = 30;

function arenaEmpty(votes: number, needed: number): HTMLElement {
  const box = document.createElement("div");
  box.className = "ins-glass ins-arena__empty";

  const lead = document.createElement("div");
  lead.className = "ins-arena__lead";
  const n = document.createElement("span");
  n.className = "ins-num ins-num--xl";
  renderNum(n, String(votes));
  const label = document.createElement("span");
  label.className = "ins-tip__leadlabel";
  label.textContent = votes === 1 ? "vote so far" : "votes so far";
  lead.append(n, label);

  const bar = document.createElement("div");
  bar.className = "ins-bar ins-bar--lg ins-arena__bar";
  const fill = document.createElement("span");
  fill.className = "ins-bar__fill";
  fill.style.width = `${Math.min(100, (votes / Math.max(1, needed)) * 100).toFixed(1)}%`;
  bar.append(fill);

  const note = document.createElement("p");
  note.className = "ins-key ins-arena__note";
  note.textContent =
    votes === 0
      ? `No blind votes have been cast yet. Ratings publish once a stack clears ${needed} votes — until then there is nothing here worth ranking, so nothing is shown.`
      : `Ratings publish at ${needed} votes per stack. ${Math.max(0, needed - votes)} to go.`;

  const cta = document.createElement("a");
  cta.className = "ins-cta ins-cta--primary ins-arena__cta";
  cta.href = "/bench/arena";
  cta.textContent = "Judge a pair →";

  box.append(lead, bar, note, cta);
  return box;
}

function arenaTable(ratings: ArenaRating[], roster: Roster, total: number): HTMLElement {
  const box = document.createElement("div");
  box.className = "ins-glass ins-arena";

  const head = document.createElement("p");
  head.className = "ins-key ins-arena__head";
  head.textContent = `${total.toLocaleString("en-US")} blind votes · Bradley–Terry rating, higher is preferred`;
  box.append(head);

  const max = Math.max(...ratings.map((r) => r.bt), 1);
  const min = Math.min(...ratings.map((r) => r.bt), 0);
  const span = max - min || 1;

  const list = document.createElement("div");
  list.className = "ins-rows";

  ratings
    .slice()
    .sort((a, b) => b.bt - a.bt)
    .forEach((r, i) => {
      const h = entryFor(roster, "harnesses", r.harness);
      const m = entryFor(roster, "models", r.model);

      const row = document.createElement("div");
      row.className = `ins-row ${m.cls} ${h.cls}`;
      row.dataset.tip = "";
      row.dataset.tipH = r.harness;
      row.dataset.tipM = r.model;
      row.dataset.tipLead = r.bt.toFixed(2);
      row.dataset.tipLeadLabel = "Bradley-Terry rating";
      row.dataset.tipRows = [
        `votes|${r.votes}`,
        r.ci95 ? `95% CI|${r.ci95[0].toFixed(2)}-${r.ci95[1].toFixed(2)}` : ""
      ]
        .filter(Boolean)
        .join(";");

      const rank = document.createElement("span");
      rank.className = "ins-row__rank ins-num";
      rank.textContent = String(i + 1).padStart(2, "0");

      const id = document.createElement("span");
      id.className = "ins-row__id";
      id.append(chipEl(h, "harness", "md"), chipEl(m, "model", "md"));
      const text = document.createElement("span");
      text.className = "ins-row__text";
      const name = document.createElement("span");
      name.className = "ins-row__name";
      const hn = document.createElement("span");
      hn.className = "ins-row__h";
      hn.textContent = h.display;
      const mn = document.createElement("span");
      mn.className = "ins-row__m";
      mn.textContent = m.display;
      name.append(hn, mn);
      const meta = document.createElement("span");
      meta.className = "ins-row__meta";
      meta.textContent = `${r.votes} votes`;
      text.append(name, meta);
      id.append(text);

      const plot = document.createElement("span");
      plot.className = "ins-row__plot";
      const bar = document.createElement("span");
      bar.className = "ins-bar";
      const fill = document.createElement("span");
      fill.className = "ins-bar__fill";
      fill.style.width = `${(((r.bt - min) / span) * 92 + 8).toFixed(1)}%`;
      bar.append(fill);
      plot.append(bar);

      const val = document.createElement("span");
      val.className = "ins-row__val";
      const num = document.createElement("span");
      num.className = "ins-num ins-num--lg";
      renderNum(num, r.bt.toFixed(2));
      val.append(num);

      row.append(rank, id, plot, val);
      list.append(row);
    });

  box.append(list);
  return box;
}

async function initArenaLive(): Promise<void> {
  const section = document.querySelector<HTMLElement>("[data-arena-live]");
  const body = section?.querySelector<HTMLElement>("[data-arena-live-body]");
  if (!section || !body) return;

  let doc: ArenaLive = {};
  try {
    const res = await fetch("/data/arena-live.json", { cache: "no-cache" });
    if (res.ok) {
      const live: ArenaLive = await res.json();
      doc = live;
    }
  } catch {
    // No live file yet — fall through to the baked numbers below.
  }

  // Fall back to whatever the build baked in.
  if (doc.votes == null) {
    const baked = document.querySelector<HTMLElement>("[data-arena-baked]");
    doc = {
      votes: Number(baked?.dataset.votes ?? 0),
      ratings: []
    };
  }

  const needed = doc.min_votes_per_stack ?? ARENA_MIN_VOTES;
  const ratings = (doc.ratings ?? []).filter((r) => r.votes >= needed);

  body.textContent = "";
  body.append(
    ratings.length > 0
      ? arenaTable(ratings, readRoster(), doc.votes ?? 0)
      : arenaEmpty(doc.votes ?? 0, needed)
  );
}

/* Atmosphere — fading the background field out as the hero leaves — used to
   live here as initAtmosphere(). It is now scripts/atmosphere.ts, loaded by
   BaseLayout on every page: what this page needed turned out to be what every
   page needed. */

/* ── boot ─────────────────────────────────────────────────────────────── */

function boot(): void {
  initFigures();
  initTooltips();
  void initArenaLive();
  paintBars();
  paintLens();
  initLeaderboard();
  initScatter();
  void initSynthesis();

  // Disclosure panels paint their dimension bars the first time they open.
  document.querySelectorAll<HTMLDetailsElement>(".ins-disc").forEach((d) => {
    d.addEventListener(
      "toggle",
      () => {
        if (d.open) paintBars(d);
      },
      { once: false }
    );
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot, { once: true });
} else {
  boot();
}
