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
    const btn = (ev.target as HTMLElement).closest<HTMLElement>("[data-lens]");
    if (!btn) return;
    lens = (btn.dataset.lens ?? "solution") as Lens;
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

/* ── synthesis ────────────────────────────────────────────────────────── */

/**
 * /data/synthesis.json ships each slice as an object keyed by id — not an
 * array — with a distilled `summary` plus the `observations` behind it. The
 * job rewrites the file on its own schedule, so this stays a client fetch:
 * new synthesis lands without rebuilding the page.
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

/** "claude/deepseek-v4-flash-0731" -> "claude × deepseek v4 flash 0731". */
function prettyId(id: string): string {
  return id
    .split("/")
    .map((part) => part.replace(/-/g, " "))
    .join(" × ");
}

/** Alberto's note: only the strongest, most concrete takeaways — so the card
 *  leads with the summary and shows at most two supporting observations. */
const MAX_OBSERVATIONS = 2;

function synthCard(id: string, slice: SynthSlice): HTMLElement | null {
  const summary = (slice.summary ?? "").trim();
  if (!summary) return null;

  const card = document.createElement("article");
  card.className = "ins-glass ins-glass--flush ins-synthcard";

  const head = document.createElement("header");
  head.className = "ins-synthcard__head";

  const title = document.createElement("span");
  title.className = "ins-synthcard__t";
  title.textContent = prettyId(id);
  head.append(title);

  const tasks = Number(slice.n_tasks);
  if (Number.isFinite(tasks) && tasks > 0) {
    const n = document.createElement("span");
    n.className = "ins-synthcard__n ins-num ins-num--xs";
    n.textContent = `${tasks} tasks`;
    head.append(n);
  }

  const body = document.createElement("p");
  body.className = "ins-synthcard__b";
  body.textContent = summary;

  card.append(head, body);

  const obs = (slice.observations ?? []).filter((o) => typeof o === "string" && o.trim());
  if (obs.length > 0) {
    const list = document.createElement("ul");
    list.className = "ins-synthcard__obs";
    for (const o of obs.slice(0, MAX_OBSERVATIONS)) {
      const li = document.createElement("li");
      li.textContent = o.trim();
      list.append(li);
    }
    card.append(list);
  }

  return card;
}

function renderGroup(host: HTMLElement | null, group: SynthGroup | undefined): number {
  if (!host || !group) return 0;
  let n = 0;
  for (const [id, slice] of Object.entries(group)) {
    const card = synthCard(id, slice);
    if (card) {
      host.append(card);
      n++;
    }
  }
  const section = host.closest<HTMLElement>(".ins-synth__group");
  if (section && n === 0) section.hidden = true;
  return n;
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
    const doc = (await res.json()) as SynthDoc;

    const rendered =
      renderGroup(body.querySelector("[data-br-synthesis-harnesses]"), doc.harnesses) +
      renderGroup(body.querySelector("[data-br-synthesis-models]"), doc.models) +
      renderGroup(body.querySelector("[data-br-synthesis-combos]"), doc.combos);

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

/* ── atmosphere ───────────────────────────────────────────────────────── */

/**
 * Fade the ember swarm out as the hero leaves. The canvas is position:fixed,
 * so CSS alone can't tie it to page position — without this it would sit
 * behind the leaderboard, and nothing animates behind a number.
 */
function initAtmosphere(): void {
  if (isReduced) return;
  const root = document.documentElement;
  const PEAK = 0.32;
  let queued = false;

  const update = (): void => {
    queued = false;
    const fade = Math.min(1, window.scrollY / (window.innerHeight * 0.72));
    root.style.setProperty("--ins-atmo", (PEAK * (1 - fade)).toFixed(3));
  };

  window.addEventListener(
    "scroll",
    () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(update);
    },
    { passive: true }
  );
  update();
}

/* ── boot ─────────────────────────────────────────────────────────────── */

function boot(): void {
  initAtmosphere();
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
