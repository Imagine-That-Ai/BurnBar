/**
 * @fileoverview BurnBench command-center client module.
 *
 * Progressive enhancement for /bench: the page is fully meaningful as SSR
 * HTML; this module adds (1) leaderboard metric tabs with live re-sorting,
 * (2) the match tuner (weighted quality/cost/speed picks), (3) the family
 * heatmap lens toggle, and (4) the "Ask the data" AI panel, whose charts
 * render from a closed, server-validated spec — no model-generated code
 * ever executes.
 *
 * All data comes from /data/bench-dashboard.json, a prerendered projection
 * of the export (no inline data island — the page keeps its zero-inline-JS
 * budget). Everything rendered via innerHTML is built from whitelisted ids
 * and numbers; model answer text is only ever assigned through textContent.
 */

interface StackRow {
  h: string;
  m: string;
  hd: string;
  md: string;
  mds: string;
  mc: string;
  hc: string;
  hl: string | null;
  ml: string | null;
  hm: string;
  mm: string;
  sol: number;
  str: number;
  ci: [number, number];
  cost: number | null;
  cin: number | null;
  cout: number | null;
  cstd: number | null;
  wall: number | null;
  tok: number | null;
  n: number;
  /** Tasks behind the overall row (coverage block, else evidence cells). */
  nt?: number;
  /** No-op runs (zero source edits) across the stack's cells; absent when 0. */
  no?: number;
  conf: "high" | "medium" | "low";
  ev: "measured" | "inferred";
}

interface HeatCellData {
  r: number;
  s: number;
  c: number | null;
  w: number | null;
  t: number | null;
  n: number;
}

interface ScopeMean {
  key: string;
  sol: number | null;
  str: number | null;
  cost: number | null;
  wall: number | null;
  tok: number | null;
  n: number;
}

interface Dataset {
  generated: string;
  byLanguage: ScopeMean[];
  byPlatform: ScopeMean[];
  /** Per-model measured task counts — drives the suite-mismatch chip. */
  modelTasks?: Record<string, number>;
  stacks: StackRow[];
  families: string[];
  heatDomains: { rate: [number, number]; strict: [number, number]; cost: [number, number] };
  heat: { h: string; m: string; cells: (HeatCellData | null)[] }[];
}

/* ---------- dataset ---------- */

async function loadDataset(): Promise<Dataset | null> {
  try {
    const res = await fetch("/data/bench-dashboard.json");
    if (!res.ok) return null;
    const dataset: Dataset = await res.json();
    return dataset;
  } catch {
    return null;
  }
}

/* ---------- shared formatting (mirrors bench.ts) ---------- */

const fmtPct = (v: number, digits = 1): string => `${(v * 100).toFixed(digits)}%`;

const fmtCost = (v: number | null): string => {
  if (v == null) return "—";
  if (v === 0) return "$0.00";
  if (v < 0.01) return `$${v.toFixed(4)}`;
  return `$${v.toFixed(2)}`;
};

const fmtWall = (seconds: number | null): string => {
  if (seconds == null) return "—";
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  return s > 0 ? `${m}m ${s}s` : `${m}m`;
};

const fmtTokens = (v: number | null): string =>
  v == null
    ? "—"
    : v >= 1e6
      ? `${+(v / 1e6).toFixed(1)}M`
      : v >= 1000
        ? `${Math.round(v / 1000)}k`
        : `${v}`;

const esc = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/* ---------- 1 · leaderboard metric tabs ---------- */

type Metric = "sol" | "str" | "cost" | "wall" | "tok";

type Band = { lo: number; hi: number };

const niceBand = (values: number[]): Band => {
  const lo = Math.max(0, Math.floor((Math.min(...values) - 0.03) * 20) / 20);
  const hi = Math.min(1, Math.ceil((Math.max(...values) + 0.01) * 20) / 20);
  return hi > lo ? { lo, hi } : { lo: 0, hi: 1 };
};

const bandPct = (v: number, band: Band): number => {
  const span = band.hi - band.lo;
  return Math.min(100, Math.max(0, ((v - band.lo) / span) * 100));
};

const METRIC_SORT: Record<Metric, (a: StackRow, b: StackRow) => number> = {
  sol: (a, b) => b.sol - a.sol,
  str: (a, b) => b.str - a.str,
  cost: (a, b) => (a.cost ?? Infinity) - (b.cost ?? Infinity),
  wall: (a, b) => (a.wall ?? Infinity) - (b.wall ?? Infinity),
  tok: (a, b) => (a.tok ?? Infinity) - (b.tok ?? Infinity)
};

function barSvg(
  s: StackRow,
  metric: Metric,
  maxima: { cost: number; wall: number; tok: number },
  bands: { sol: Band; str: Band }
): string {
  const track = `<rect class="lb-bar__track" x="0" y="7" width="100%" height="12" rx="6"></rect>`;
  if (metric === "sol") {
    const p = (v: number) => `${bandPct(v, bands.sol).toFixed(2)}%`;
    return (
      track +
      `<rect class="lb-bar__fill" fill="${s.mc}" x="0" y="7" width="${p(s.sol)}" height="12" rx="6"></rect>` +
      `<line class="lb-bar__ci" x1="${p(s.ci[0])}" x2="${p(s.ci[1])}" y1="13" y2="13"></line>` +
      `<line class="lb-bar__ci" x1="${p(s.ci[0])}" x2="${p(s.ci[0])}" y1="8" y2="18"></line>` +
      `<line class="lb-bar__ci" x1="${p(s.ci[1])}" x2="${p(s.ci[1])}" y1="8" y2="18"></line>` +
      `<line class="lb-bar__strict" x1="${p(s.str)}" x2="${p(s.str)}" y1="4" y2="22"></line>`
    );
  }
  if (metric === "cost") {
    if (s.cost == null) return track;
    const inW = ((s.cin ?? 0) / maxima.cost) * 100;
    const outW = ((s.cout ?? s.cost) / maxima.cost) * 100;
    return (
      track +
      `<rect class="lb-bar__seg lb-bar__seg--in" x="0" y="7" width="${inW.toFixed(2)}%" height="12" rx="6"></rect>` +
      `<rect class="lb-bar__seg lb-bar__seg--out" x="${inW.toFixed(2)}%" y="7" width="${outW.toFixed(2)}%" height="12"></rect>`
    );
  }
  if (metric === "str") {
    const w = bandPct(s.str, bands.str);
    return (
      track +
      `<rect class="lb-bar__fill" fill="${s.mc}" x="0" y="7" width="${w.toFixed(2)}%" height="12" rx="6"></rect>`
    );
  }
  const value = metric === "wall" ? s.wall : s.tok;
  const max = metric === "wall" ? maxima.wall : maxima.tok;
  const w = value == null ? 0 : Math.min(100, (value / max) * 100);
  return (
    track +
    `<rect class="lb-bar__fill" fill="${s.mc}" x="0" y="7" width="${w.toFixed(2)}%" height="12" rx="6"></rect>`
  );
}

function headline(s: StackRow, metric: Metric): string {
  switch (metric) {
    case "sol":
      return fmtPct(s.sol);
    case "str":
      return fmtPct(s.str);
    case "cost":
      return s.cost == null ? "—" : `${fmtCost(s.cost)}`;
    case "wall":
      return fmtWall(s.wall);
    case "tok":
      return fmtTokens(s.tok);
  }
}

function subline(s: StackRow, metric: Metric): string {
  const std = s.cstd != null ? ` · std ${fmtCost(s.cstd)}` : "";
  // Suite-size disclosure: overall rows pool different task sets per stack.
  const tasks = s.nt ? ` · ${s.nt} tasks` : "";
  switch (metric) {
    case "sol":
      return `strict ${fmtPct(s.str)} · n ${s.n}${tasks} · ${fmtCost(s.cost)}/task${std}`;
    case "str":
      return `solution ${fmtPct(s.sol)} · n ${s.n}${tasks}`;
    case "cost":
      return s.cost == null
        ? "no cost evidence"
        : `in ${fmtCost(s.cin)} · out ${fmtCost(s.cout)}${std} · n ${s.n}${tasks}`;
    case "wall":
      return `solution ${fmtPct(s.sol)} · n ${s.n}${tasks}`;
    case "tok":
      return `solution ${fmtPct(s.sol)} · n ${s.n}${tasks}`;
  }
}

function initTabs(data: Dataset): void {
  const tabBar = document.querySelector<HTMLElement>("[data-bb-tabs]");
  const list = document.querySelector<HTMLElement>("[data-bb-lb]");
  if (!tabBar || !list) return;
  const scaleNote = document.querySelector<HTMLElement>("[data-bb-lb-scale]");
  const maxima = {
    cost: Math.max(...data.stacks.map((s) => s.cost ?? 0), 0.01),
    wall: Math.max(...data.stacks.map((s) => s.wall ?? 0), 1),
    tok: Math.max(...data.stacks.map((s) => s.tok ?? 0), 1)
  };
  const bands = {
    sol: niceBand(data.stacks.map((s) => s.sol)),
    str: niceBand(data.stacks.map((s) => s.str))
  };
  const stackById = new Map(data.stacks.map((s) => [`${s.h}|${s.m}`, s]));
  const scaleText = (metric: Metric): string => {
    if (metric === "sol" || metric === "str") {
      const b = bands[metric];
      return `${metric === "sol" ? "Solution" : "Strict"} bars use the observed ${Math.round(b.lo * 100)}% → ${Math.round(b.hi * 100)}% scale so real separation is visible.`;
    }
    if (metric === "cost") return `Cost bars use a 0 → ${fmtCost(maxima.cost)} per-task scale.`;
    if (metric === "wall") return `Wall-time bars use a 0 → ${fmtWall(maxima.wall)} scale.`;
    return `Token bars use a 0 → ${fmtTokens(maxima.tok)} scale.`;
  };

  const logoHtml = (url: string | null, mono: string, extra: string): string =>
    url
      ? `<img class="lb-logo ${extra}" src="${esc(url)}" alt="" width="24" height="24" loading="lazy" decoding="async">`
      : `<span class="lb-mono ${extra}">${esc(mono)}</span>`;

  const rowHtml = (s: StackRow, metric: Metric, rank: number, tie: boolean): string => {
    const head =
      metric === "cost" && s.cost != null ? `${headline(s, metric)}/task` : headline(s, metric);
    const tags: string[] = [];
    if (s.ev === "inferred") tags.push('<span class="tag tag--estimated">inferred</span>');
    if (s.conf === "low") tags.push('<span class="tag tag--unavailable">low conf</span>');
    const hc = `h--${s.h.replace(/[^a-z0-9-]/g, "")}`;
    const mc = `m--${s.m.includes("deepseek") ? "deepseek" : s.m.includes("glm") ? "glm" : s.m.includes("gpt-5-6") ? "gpt" : s.m.includes("spark") ? "spark" : s.m.includes("opus") ? "opus" : s.m.includes("gpt5") ? "gpt5" : "gemini"}`;
    return (
      `<div class="lb-row ${hc} ${mc}${tie ? " lb-row--tie" : ""}${s.ev === "inferred" ? " lb-row--inferred" : ""}"` +
      ` data-h="${esc(s.h)}" data-m="${esc(s.m)}">` +
      `<span class="lb-rank">${String(rank).padStart(2, "0")}</span>` +
      `<span class="lb-logos">${logoHtml(s.hl, s.hm, "lb-logo--h")}${logoHtml(s.ml, s.mm, "lb-logo--m")}</span>` +
      `<span class="lb-names"><strong>${esc(s.hd)} × ${esc(s.mds)}</strong>` +
      `<span class="lb-sub">${esc(subline(s, metric))}</span></span>` +
      `<svg class="lb-bar" viewBox="0 0 100 26" preserveAspectRatio="none" aria-hidden="true">${barSvg(s, metric, maxima, bands)}</svg>` +
      `<span class="lb-nums"><span class="lb-head">${esc(head)}</span>` +
      (tags.length ? `<span class="lb-tags">${tags.join("")}</span>` : "") +
      `</span></div>`
    );
  };

  const render = (metric: Metric): void => {
    if (scaleNote) scaleNote.textContent = scaleText(metric);
    const sorted = [...data.stacks].sort(METRIC_SORT[metric]);
    // Tie groups: consecutive stacks whose visible headline is identical
    // share one competition rank; the group expands on hover/click.
    const groups: { rank: number; members: StackRow[] }[] = [];
    sorted.forEach((s, i) => {
      const head = headline(s, metric);
      const prev = groups[groups.length - 1];
      const prevHead = prev?.members[0] ? headline(prev.members[0] as StackRow, metric) : null;
      if (prev && i > 0 && prevHead === head) {
        prev.members.push(s);
      } else {
        groups.push({ rank: i + 1, members: [s] });
      }
    });
    list.innerHTML = groups
      .map((g) => {
        const first = g.members[0] as StackRow;
        const rest = g.members.slice(1) as StackRow[];
        const tieBtn =
          rest.length > 0
            ? `<button class="lb-tiebtn" aria-expanded="false" title="${rest.length + 1} stacks share this ${metric === "cost" ? "cost" : "score"} — hover or tap to expand">×${rest.length + 1}</button>`
            : "";
        const ties =
          rest.length > 0
            ? `<ul class="lb-ties">${rest.map((s) => `<li>${rowHtml(s, metric, g.rank, true)}</li>`).join("")}</ul>`
            : "";
        return (
          `<li class="lb-group${rest.length ? " lb-group--tied" : ""}">` +
          rowHtml(first, metric, g.rank, false).replace("</div>", `${tieBtn}</div>`) +
          ties +
          `</li>`
        );
      })
      .join("");
    list.querySelectorAll<HTMLElement>(".lb-row[data-h][data-m]").forEach((row) => {
      const s = stackById.get(`${row.dataset.h}|${row.dataset.m}`);
      if (!s) return;
      row.style.setProperty("--hc", s.hc);
      row.style.setProperty("--mc", s.mc);
    });
    applyLbFilter();
  };

  // Stack search: hides non-matching rows (ranks stay global — filtering
  // never renumbers the board). Re-applied after every lens re-render.
  const lbSearch = document.querySelector<HTMLInputElement>("[data-bb-lb-q]");
  const applyLbFilter = (): void => {
    const q = (lbSearch?.value ?? "").trim().toLowerCase();
    list.querySelectorAll<HTMLElement>(".lb-group").forEach((group) => {
      if (!q) {
        group.classList.remove("lb-hidden");
        group.querySelectorAll(".lb-row").forEach((r) => r.classList.remove("lb-hidden"));
        return;
      }
      let anyVisible = false;
      group.querySelectorAll<HTMLElement>(".lb-row[data-h][data-m]").forEach((row) => {
        const s = stackById.get(`${row.dataset.h}|${row.dataset.m}`);
        const hay =
          `${row.dataset.h ?? ""} ${row.dataset.m ?? ""} ${s?.hd ?? ""} ${s?.mds ?? ""}`.toLowerCase();
        const show = hay.includes(q);
        row.classList.toggle("lb-hidden", !show);
        if (show) anyVisible = true;
      });
      group.classList.toggle("lb-hidden", !anyVisible);
    });
  };
  lbSearch?.addEventListener("input", applyLbFilter);

  tabBar.addEventListener("click", (ev) => {
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>("[data-metric]");
    if (!btn) return;
    const metric = btn.dataset.metric as Metric;
    tabBar.querySelectorAll(".bb-tab").forEach((t) => {
      const active = t === btn;
      t.classList.toggle("is-active", active);
      t.setAttribute("aria-selected", String(active));
    });
    render(metric);
  });

  // Tie chips pin open on click (hover opens via CSS :has).
  list.addEventListener("click", (ev) => {
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>(".lb-tiebtn");
    if (!btn) return;
    const group = btn.closest(".lb-group");
    if (!group) return;
    const open = group.classList.toggle("is-open");
    btn.setAttribute("aria-expanded", String(open));
  });

  render("sol");
}

/* ---------- 2 · match tuner ---------- */

function initTuner(data: Dataset): void {
  const root = document.querySelector<HTMLElement>("[data-bb-tuner]");
  const picksEl = root?.querySelector<HTMLElement>("[data-bb-picks]");
  if (!root || !picksEl) return;

  const noteEl = root.querySelector<HTMLElement>("[data-bb-tunernote]");
  const famIdx = (fam: string) => data.families.indexOf(fam);
  const heatFor = (s: StackRow, fi: number): HeatCellData | null =>
    data.heat.find((r) => r.h === s.h && r.m === s.m)?.cells[fi] ?? null;

  const render = () => {
    const wq = Number(root.querySelector<HTMLInputElement>('[data-w="wq"]')?.value ?? 60);
    const wc = Number(root.querySelector<HTMLInputElement>('[data-w="wc"]')?.value ?? 25);
    const ws = Number(root.querySelector<HTMLInputElement>('[data-w="ws"]')?.value ?? 15);
    root.querySelectorAll("output").forEach((o) => {
      const key = (o as HTMLOutputElement).dataset.out;
      const v = key === "wq" ? wq : key === "wc" ? wc : ws;
      o.textContent = `${v}%`;
    });
    const fam = root.querySelector<HTMLSelectElement>('[data-scope="family"]')?.value ?? "";
    const budgetRaw = root.querySelector<HTMLSelectElement>('[data-scope="budget"]')?.value ?? "";
    const budget = budgetRaw === "" ? null : Number(budgetRaw);
    const hideLow = root.querySelector<HTMLInputElement>('[data-scope="lowconf"]')?.checked ?? true;
    const fi = fam ? famIdx(fam) : -1;

    // Scope the metric picks: family cells override overall stats when set.
    const qualityOf = (s: StackRow): number | null =>
      fi >= 0 ? (heatFor(s, fi)?.r ?? null) : s.sol;
    const costOf = (s: StackRow): number | null => (fi >= 0 ? (heatFor(s, fi)?.c ?? null) : s.cost);

    let excludedScope = 0;
    let excludedBudget = 0;
    let excludedConf = 0;
    const pool = data.stacks.filter((s) => {
      if (fi >= 0 && qualityOf(s) == null) {
        excludedScope++;
        return false;
      }
      const c = costOf(s);
      if (budget != null && (c == null || c > budget)) {
        excludedBudget++;
        return false;
      }
      if (hideLow && s.conf === "low") {
        excludedConf++;
        return false;
      }
      return true;
    });

    // Normalize within the scoped pool so the spread is real.
    const norm = (pick: (s: StackRow) => number | null) => {
      const vals = pool.map(pick).filter((v): v is number => v != null);
      if (vals.length === 0) return () => 0.5;
      const lo = Math.min(...vals);
      const hi = Math.max(...vals);
      const span = hi - lo;
      return (s: StackRow): number => {
        const v = pick(s);
        if (v == null) return 0.5;
        return span <= 0 ? 1 : (v - lo) / span;
      };
    };
    const solN = norm(qualityOf);
    const costN = norm(costOf);
    const wallN = norm((s) => s.wall);

    const sum = wq + wc + ws || 1;
    const scored = pool
      .map((s) => {
        const q = (wq * solN(s)) / sum;
        const c = (wc * (1 - costN(s))) / sum;
        const sp = (ws * (1 - wallN(s))) / sum;
        return { s, score: q + c + sp, parts: { q, c, sp } };
      })
      .sort((a, b) => b.score - a.score);
    // Contract rule: low-confidence stacks may not take first place.
    const eligible = scored.filter((x) => x.s.conf !== "low");
    const first = eligible[0] ?? scored[0];
    if (!first) {
      picksEl.innerHTML = "";
      if (noteEl)
        noteEl.textContent = "No stack survives those filters — loosen the budget or scope.";
      return;
    }
    const top: { s: StackRow; score: number; parts: { q: number; c: number; sp: number } }[] = [
      first
    ];
    for (const x of scored) {
      if (top.length >= 3) break;
      if (!top.includes(x)) top.push(x);
    }
    picksEl.innerHTML = top
      .map(({ s, score, parts }, i) => {
        const q = qualityOf(s);
        const c = costOf(s);
        const tags: string[] = [];
        if (s.conf === "low") tags.push("low confidence");
        if (s.ev === "inferred") tags.push("inferred");
        if (c === 0) tags.push("free tier");
        const dom =
          parts.q >= parts.c && parts.q >= parts.sp
            ? "quality"
            : parts.c >= parts.sp
              ? "cost"
              : "speed";
        const why = `wins on ${dom} — ${fmtPct(q ?? 0)}${fam ? ` on ${fam}` : ""} · ${fmtCost(c)}/task · ${fmtWall(s.wall)}`;
        const logo = (url: string | null, mono: string, cls: string): string =>
          url
            ? `<img class="bb-pick__logo ${cls}" src="${esc(url)}" alt="" width="22" height="22" loading="lazy" decoding="async">`
            : `<span class="bb-pick__mono ${cls}">${esc(mono)}</span>`;
        const bar = (v: number, cls: string): string =>
          `<span class="bb-pick__seg ${cls}" data-w="${(v * 100).toFixed(1)}"></span>`;
        return (
          `<li class="bb-pick${i === 0 ? " bb-pick--top" : ""}">` +
          `<span class="bb-pick__rank">${i + 1}</span>` +
          `<span class="bb-pick__logos">${logo(s.hl, s.hm, "bb-pick__logo--h")}${logo(s.ml, s.mm, "bb-pick__logo--m")}</span>` +
          `<span class="bb-pick__names"><strong>${esc(s.hd)} × ${esc(s.md)}</strong>` +
          `<span class="bb-pick__why">${esc(why)} · n ${s.n}${tags.length ? ` · ${esc(tags.join(" · "))}` : ""}</span>` +
          `<span class="bb-pick__bar" aria-hidden="true">${bar(parts.q, "bb-pick__seg--q")}${bar(parts.c, "bb-pick__seg--c")}${bar(parts.sp, "bb-pick__seg--s")}</span></span>` +
          `<span class="bb-pick__score mono">${(score * 100).toFixed(1)}</span>` +
          `</li>`
        );
      })
      .join("");
    // Widths via CSSOM — inline style attributes inserted by innerHTML are
    // stripped by the production CSP (style-src-attr is hash-locked).
    picksEl.querySelectorAll<HTMLElement>(".bb-pick__seg").forEach((el) => {
      el.style.width = `${el.dataset.w}%`;
    });
    if (noteEl) {
      const bits: string[] = [];
      if (fam) bits.push(`scored on ${fam} cells`);
      if (budget != null)
        bits.push(`budget ≤ ${budget === 0 ? "$0" : `$${budget.toFixed(2)}`}/task`);
      const ex: string[] = [];
      if (excludedScope) ex.push(`${excludedScope} unmeasured in ${fam}`);
      if (excludedBudget) ex.push(`${excludedBudget} over budget`);
      if (excludedConf) ex.push(`${excludedConf} low-confidence`);
      noteEl.textContent =
        (bits.length ? bits.join(" · ") : "scored on the overall suite") +
        (ex.length ? ` — excluded: ${ex.join(", ")}` : "");
    }
  };

  root.querySelectorAll('input[type="range"]').forEach((r) =>
    r.addEventListener("input", () => {
      root.querySelectorAll("[data-preset]").forEach((b) => b.classList.remove("is-active"));
      render();
    })
  );
  root.querySelectorAll("[data-preset]").forEach((b) =>
    b.addEventListener("click", () => {
      const parts = (b as HTMLElement).dataset.preset!.split(",");
      const set = (k: string, v: string | undefined) => {
        const input = root.querySelector<HTMLInputElement>(`[data-w="${k}"]`);
        if (input && v != null) input.value = v;
      };
      set("wq", parts[0]);
      set("wc", parts[1]);
      set("ws", parts[2]);
      root.querySelectorAll("[data-preset]").forEach((x) => x.classList.remove("is-active"));
      b.classList.add("is-active");
      render();
    })
  );
  root.querySelectorAll("[data-scope]").forEach((el) => el.addEventListener("change", render));
  render();
}

/* ---------- 3 · heatmap lens + liquid-glass focus ----------
   Colors live in CSS (data-bucket scales) so the hash-locked CSP never sees
   a per-cell style attribute; JS only moves cells between buckets and toggles
   focus classes that make one row or column lead the eye. */

function attachZoom(
  wrap: HTMLElement,
  zoomEl: HTMLElement,
  opts: { min: number; max: number; step: number; onChange?: (scale: number) => void }
): () => number {
  let scale = 1;
  const clamp = (v: number) => Math.max(opts.min, Math.min(opts.max, v));
  const apply = (next: number, _origin?: { x: number; y: number }) => {
    scale = clamp(next);
    zoomEl.style.transform = `scale(${scale})`;
    wrap.style.overflow = scale > 1 ? "auto" : "";
    opts.onChange?.(scale);
    return scale;
  };
  const fromWheel = (ev: WheelEvent) => {
    if (!(ev.ctrlKey || ev.metaKey)) return;
    ev.preventDefault();
    const delta = -ev.deltaY * 0.0012;
    const next = scale * (1 + delta);
    apply(next);
  };
  wrap.addEventListener("wheel", fromWheel, { passive: false });
  let startDist = 0;
  let startScale = 1;
  const dist = (a: Touch, b: Touch) => Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
  wrap.addEventListener(
    "touchstart",
    (ev) => {
      if (ev.touches.length !== 2) return;
      startDist = dist(ev.touches[0]!, ev.touches[1]!);
      startScale = scale;
    },
    { passive: true }
  );
  wrap.addEventListener(
    "touchmove",
    (ev) => {
      if (ev.touches.length !== 2 || startDist <= 0) return;
      ev.preventDefault();
      const next = startScale * (dist(ev.touches[0]!, ev.touches[1]!) / startDist);
      apply(next);
    },
    { passive: false }
  );
  wrap.addEventListener(
    "touchend",
    () => {
      startDist = 0;
    },
    { passive: true }
  );
  return () => scale;
}

function initHeatLens(data: Dataset): void {
  const bar = document.querySelector<HTMLElement>("[data-bb-heatlens]");
  const grid = document.querySelector<HTMLElement>("[data-bb-heat]");
  const frame = document.querySelector<HTMLElement>("[data-bb-heatframe]");
  const tip = document.querySelector<HTMLElement>("[data-bb-heattip]");
  const detail = document.querySelector<HTMLElement>("[data-bb-heat-detail]");
  const heatWrap = document.querySelector<HTMLElement>("[data-bb-heat-wrap]");
  const heatZoom = document.querySelector<HTMLElement>("[data-bb-heat-zoom]");
  if (!bar || !grid) return;

  // zoom wiring (guard missing wrap/zoom during SSR preview)
  const zoombar = document.querySelector<HTMLElement>("[data-bb-heat-zoombar]");
  let getHeatScale = () => 1;
  let setHeatScale = (_v: number): number => 1;
  if (heatWrap && heatZoom) {
    let heatScale = 1;
    const applyHeat = (next: number) => {
      heatScale = Math.max(1, Math.min(2.2, next));
      heatZoom.style.transform = `scale(${heatScale})`;
      heatWrap.style.overflow = heatScale > 1 ? "auto" : "";
      if (zoombar) {
        const out = zoombar.querySelector<HTMLButtonElement>("[data-heat-zoom-out]");
        const rst = zoombar.querySelector<HTMLButtonElement>("[data-heat-zoom-reset]");
        if (out) out.disabled = heatScale <= 1.01;
        if (rst) rst.disabled = heatScale <= 1.01;
      }
      return heatScale;
    };
    getHeatScale = () => heatScale;
    setHeatScale = applyHeat;
    // wheel + pinch via helper
    attachZoom(heatWrap, heatZoom, {
      min: 1,
      max: 2.2,
      step: 0.12,
      onChange: (s) => {
        heatScale = s;
      }
    });
    // also keep zoombar buttons in sync on pinch
    const syncBtns = () => {
      const out = zoombar?.querySelector<HTMLButtonElement>("[data-heat-zoom-out]");
      const rst = zoombar?.querySelector<HTMLButtonElement>("[data-heat-zoom-reset]");
      if (out) out.disabled = heatScale <= 1.01;
      if (rst) rst.disabled = heatScale <= 1.01;
    };
    heatWrap.addEventListener("wheel", () => syncBtns(), { passive: true });
    zoombar
      ?.querySelector<HTMLButtonElement>("[data-heat-zoom-in]")
      ?.addEventListener("click", () => {
        applyHeat(heatScale + 0.18);
      });
    zoombar
      ?.querySelector<HTMLButtonElement>("[data-heat-zoom-out]")
      ?.addEventListener("click", () => {
        applyHeat(heatScale - 0.18);
      });
    zoombar
      ?.querySelector<HTMLButtonElement>("[data-heat-zoom-reset]")
      ?.addEventListener("click", () => {
        applyHeat(1);
      });
  }
  void getHeatScale;
  void setHeatScale;

  const bucket = (v: number | null, domain: [number, number], invert: boolean): string => {
    if (v == null) return "";
    const [lo, hi] = domain;
    const span = hi - lo;
    const t = span <= 0 ? 1 : (v - lo) / span;
    const clamped = Math.max(0, Math.min(1, invert ? 1 - t : t));
    return String(Math.round(clamped * 10));
  };

  let activeRow: string | null = null;
  let activeCol: string | null = null;
  let activeLens: "rate" | "strict" | "cost" = "rate";

  const cells = (): HTMLElement[] => [...grid.querySelectorAll<HTMLElement>(".bb-heat__cell")];

  const applyFocus = (): void => {
    const hasFocus = activeRow != null || activeCol != null;
    grid.classList.toggle("has-focus", hasFocus);
    const rowHeads = [...grid.querySelectorAll<HTMLElement>("[data-heatrow]")];
    const colHeads = [...grid.querySelectorAll<HTMLElement>("[data-heatcol]")];
    rowHeads.forEach((el) => {
      const on = el.dataset.heatrow === activeRow;
      el.classList.toggle("is-active", on);
      el.setAttribute("aria-pressed", String(on));
      el.classList.toggle("is-dimmed", hasFocus && !on);
    });
    colHeads.forEach((el) => {
      const on = el.dataset.heatcol === activeCol;
      el.classList.toggle("is-active", on);
      el.setAttribute("aria-pressed", String(on));
      el.classList.toggle("is-dimmed", hasFocus && !on);
    });
    for (const c of cells()) {
      const key = c.dataset.heatcell ?? "";
      const [h, m, fam] = key.split("|");
      const rowKey = `${h}|${m}`;
      const onRow = activeRow != null && rowKey === activeRow;
      const onCol = activeCol != null && fam === activeCol;
      c.classList.toggle("is-row-focus", onRow && activeCol == null);
      c.classList.toggle("is-col-focus", onCol && activeRow == null);
      c.classList.toggle("is-pinned", onRow && onCol);
      c.classList.toggle("is-dimmed", hasFocus && !onRow && !onCol);
    }
    if (tip) {
      if (!hasFocus) {
        tip.hidden = true;
      } else {
        const label =
          activeRow && activeCol
            ? `${activeRow.replace("|", " × ")} · ${activeCol}`
            : activeRow
              ? `${activeRow.replace("|", " × ")} — every family`
              : `${activeCol} — every stack`;
        const count = cells().filter((c) => {
          const k = c.dataset.heatcell ?? "";
          const [h, m, fam] = k.split("|");
          if (activeRow && activeCol) return `${h}|${m}` === activeRow && fam === activeCol;
          if (activeRow) return `${h}|${m}` === activeRow && c.dataset.bucket !== "";
          if (activeCol) return fam === activeCol && c.dataset.bucket !== "";
          return false;
        }).length;
        tip.innerHTML =
          `<span><strong>${esc(label)}</strong> · <em>${count} measured</em></span>` +
          `<button class="bb-heat-tip__x" type="button" aria-label="Clear focus">×</button>`;
        tip.hidden = false;
        const x = tip.querySelector<HTMLButtonElement>(".bb-heat-tip__x");
        x?.addEventListener(
          "click",
          () => {
            activeRow = null;
            activeCol = null;
            applyFocus();
          },
          { once: true }
        );
      }
    }
  };

  const setLens = (lens: "rate" | "strict" | "cost"): void => {
    activeLens = lens;
    bar.querySelectorAll(".bb-tab[data-lens]").forEach((t) => {
      const active = (t as HTMLElement).dataset.lens === lens;
      t.classList.toggle("is-active", active);
      t.setAttribute("aria-selected", String(active));
    });
    grid.classList.toggle("bb-heat--cost", lens === "cost");
    const domain =
      lens === "cost"
        ? data.heatDomains.cost
        : lens === "strict"
          ? data.heatDomains.strict
          : data.heatDomains.rate;
    const invert = lens === "cost";
    for (const cell of cells()) {
      const read = (k: string): number | null => {
        const raw = cell.dataset[k];
        return raw === "" || raw == null ? null : Number(raw);
      };
      const label = cell.querySelector(".bb-heat__v");
      if (lens === "cost") {
        const cost = read("cost");
        cell.dataset.bucket = bucket(cost, domain, invert);
        if (label)
          label.textContent = cost == null ? "" : cost < 0.01 ? "<1¢" : `$${cost.toFixed(2)}`;
      } else {
        const v = lens === "strict" ? read("strict") : read("rate");
        cell.dataset.bucket = bucket(v, domain, invert);
        if (label) label.textContent = v == null ? "" : String(Math.round(v * 100));
      }
    }
  };

  bar.addEventListener("click", (ev) => {
    const famToggle = (ev.target as HTMLElement).closest<HTMLButtonElement>("[data-bb-emptyfam]");
    if (famToggle) {
      const show = grid.classList.toggle("show-all");
      famToggle.setAttribute("aria-pressed", String(show));
      return;
    }
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>("[data-lens]");
    if (btn?.dataset.lens) setLens(btn.dataset.lens as "rate" | "strict" | "cost");
  });

  type CellTip = {
    h: string;
    m: string;
    fam: string;
    rate: number | null;
    strict: number | null;
    cost: number | null;
    wall: number | null;
    tok: number | null;
    n: number;
  };

  const renderDetail = (cell: HTMLElement | null): void => {
    if (!detail) return;
    if (!cell || cell.dataset.bucket === "") {
      const empty = cell != null;
      if (empty) {
        const [h, m, fam] = (cell.dataset.heatcell ?? "").split("|");
        const s = data.stacks.find((x) => x.h === h && x.m === m);
        detail.innerHTML =
          `<div class="bb-heat-detail__head">` +
          `<span class="bb-heat-detail__titles"><span class="bb-heat-detail__fam">${esc(fam ?? "")} · not yet measured</span><span class="bb-heat-detail__stack">${esc(s?.hd ?? h ?? "")} × ${esc(s?.mds ?? s?.md ?? m ?? "")}</span></span>` +
          `<button class="bb-heat-detail__close" type="button" aria-label="Close">×</button></div>` +
          `<p class="bb-heat-detail__cta">Experiential families stay dashed until Arena judgment lands. This cell has no measured n for the current export.</p>`;
        detail.hidden = false;
      } else {
        detail.hidden = true;
        detail.innerHTML = "";
      }
      return;
    }
    const [h, m, fam] = (cell.dataset.heatcell ?? "").split("|");
    const s = data.stacks.find((x) => x.h === h && x.m === m);
    const raw = (k: string): number | null => {
      const v = cell.dataset[k];
      return v == null || v === "" ? null : Number(v);
    };
    const rate = raw("rate");
    const strict = raw("strict");
    const cost = raw("cost");
    const wall = raw("wall");
    const tok = raw("tokens");
    const n = Number(cell.dataset.n ?? "0");
    const noop = raw("noop");
    const lensLabel =
      activeLens === "cost"
        ? "Cost lens"
        : activeLens === "strict"
          ? "Strict lens"
          : "Solution lens";
    detail.innerHTML =
      `<div class="bb-heat-detail__head">` +
      `<span class="bb-heat__rowbadges" aria-hidden="true">` +
      (s?.hl
        ? `<span class="bb-heat__badge bb-heat__badge--h"><img src="${esc(s.hl)}" alt="" width="16" height="16"></span><span class="bb-heat__x">×</span>`
        : "") +
      (s?.ml
        ? `<span class="bb-heat__badge bb-heat__badge--m"><img src="${esc(s.ml)}" alt="" width="16" height="16"></span>`
        : `<span class="bb-heat__badge"><span class="bb-badge__mono">${esc(s?.mm ?? "")}</span></span>`) +
      `</span>` +
      `<span class="bb-heat-detail__titles"><span class="bb-heat-detail__fam">${esc(fam ?? "")} · ${esc(lensLabel)} · ${esc(s?.hd ?? h ?? "")} × ${esc(s?.mds ?? s?.md ?? m ?? "")}</span><span class="bb-heat-detail__stack">${rate != null ? fmtPct(rate) : "—"} solution · strict ${strict != null ? fmtPct(strict) : "—"}</span></span>` +
      `<button class="bb-heat-detail__close" type="button" aria-label="Close">×</button></div>` +
      `<div class="bb-heat-detail__grid">` +
      `<span class="bb-heat-detail__stat"><span class="bb-heat-detail__k">Solution</span><span class="bb-heat-detail__v bb-heat-detail__v--hi">${rate != null ? fmtPct(rate) : "—"}</span></span>` +
      `<span class="bb-heat-detail__stat"><span class="bb-heat-detail__k">Strict</span><span class="bb-heat-detail__v">${strict != null ? fmtPct(strict) : "—"}</span></span>` +
      `<span class="bb-heat-detail__stat"><span class="bb-heat-detail__k">Cost / task</span><span class="bb-heat-detail__v">${cost != null ? fmtCost(cost) : "—"}</span></span>` +
      `<span class="bb-heat-detail__stat"><span class="bb-heat-detail__k">Tokens (prompt+output)</span><span class="bb-heat-detail__v">${tok != null ? fmtTokens(tok) : "—"}</span></span>` +
      `<span class="bb-heat-detail__stat"><span class="bb-heat-detail__k">Wall</span><span class="bb-heat-detail__v">${wall != null ? fmtWall(wall) : "—"}</span></span>` +
      `<span class="bb-heat-detail__stat"><span class="bb-heat-detail__k">Tokens / wall</span><span class="bb-heat-detail__v" title="Billed throughput — prompt+cache+output over harness wall, not model decode speed">throughput</span></span>` +
      `</div>` +
      `<div class="bb-heat-detail__meta"><span>n ${n} cells</span>` +
      (noop != null && noop > 0
        ? `<span class="bb-noop" title="No-op runs ended with no source edits, so they count against the rate">${noop}/${n} no-op runs</span>`
        : "") +
      `<span>${esc(s?.hd ?? "")} harness</span><span>${esc(s?.md ?? "")} provider</span><span>${cost != null && cost < 0.01 ? "free-tier slice" : (s?.ev ?? "")}</span></div>`;
    detail.hidden = false;
  };
  void ((): CellTip | null => null)();

  // provider-aware hover: show family + provider quickly, full card on click
  const hoverTip = document.createElement("div");
  hoverTip.className = "bb-heat-tip";
  hoverTip.hidden = true;
  hoverTip.setAttribute("role", "status");
  hoverTip.setAttribute("aria-live", "polite");
  hoverTip.style.pointerEvents = "none";
  frame?.appendChild(hoverTip);
  grid.addEventListener("pointerover", (ev) => {
    const cell = (ev.target as HTMLElement).closest<HTMLElement>("[data-heatcell]");
    if (!cell || cell.dataset.bucket === "") return;
    const [h, m, fam] = (cell.dataset.heatcell ?? "").split("|");
    const s = data.stacks.find((x) => x.h === h && x.m === m);
    const rate = cell.dataset.rate ? fmtPct(Number(cell.dataset.rate)) : "—";
    hoverTip.textContent = `${fam} · ${s?.hd ?? h} × ${s?.mds ?? m} · ${rate}`;
    hoverTip.hidden = false;
  });
  grid.addEventListener("pointerout", (ev) => {
    const rel = ev.relatedTarget as HTMLElement | null;
    if (rel?.closest?.("[data-heatcell]")) return;
    hoverTip.hidden = true;
  });
  detail?.querySelector(".bb-heat-detail__close")?.addEventListener("click", () => {
    if (detail) {
      detail.hidden = true;
    }
  });
  frame?.addEventListener("click", (ev) => {
    const close = (ev.target as HTMLElement).closest<HTMLButtonElement>(".bb-heat-detail__close");
    if (close && detail) {
      detail.hidden = true;
      return;
    }
  });

  grid.addEventListener("click", (ev) => {
    const col = (ev.target as HTMLElement).closest<HTMLElement>("[data-heatcol]");
    if (col?.dataset.heatcol) {
      const key = col.dataset.heatcol;
      activeCol = activeCol === key ? null : key;
      // keep row if both were set, otherwise single-focus semantics: pick this column alone
      if (activeRow && activeCol == null) {
        /* row stays */
      } else if (activeCol && activeRow) {
        /* both */
      }
      applyFocus();
      return;
    }
    const row = (ev.target as HTMLElement).closest<HTMLElement>("[data-heatrow]");
    if (row?.dataset.heatrow) {
      const key = row.dataset.heatrow;
      activeRow = activeRow === key ? null : key;
      applyFocus();
      return;
    }
    const cell = (ev.target as HTMLElement).closest<HTMLElement>("[data-heatcell]");
    if (cell?.dataset.heatcell) {
      const [h, m, fam] = (cell.dataset.heatcell ?? "").split("|");
      const rowKey = `${h}|${m}`;
      // clicking a cell pins that intersection: row + col + opens detail card
      if (activeRow === rowKey && activeCol === fam && detail && !detail.hidden) {
        activeRow = null;
        activeCol = null;
        detail.hidden = true;
      } else {
        activeRow = rowKey;
        activeCol = fam ?? null;
        renderDetail(cell);
      }
      applyFocus();
    }
  });

  // ESC clears focus + detail
  frame?.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && (activeRow || activeCol || (detail && !detail.hidden))) {
      activeRow = null;
      activeCol = null;
      if (detail) detail.hidden = true;
      hoverTip.hidden = true;
      applyFocus();
    }
  });
  // click on frame background clears
  frame?.addEventListener("click", (ev) => {
    if (ev.target === frame) {
      activeRow = null;
      activeCol = null;
      if (detail) detail.hidden = true;
      hoverTip.hidden = true;
      applyFocus();
    }
  });
}

/* ---------- 4 · model lens detail (interactive) ---------- */

function initLens(data: Dataset): void {
  const root = document.querySelector<HTMLElement>("[data-bb-lens]");
  if (!root) return;
  const picks = [...root.querySelectorAll<HTMLButtonElement>("[data-lenspick]")];
  const rowsEl = root.querySelector<HTMLElement>("[data-bb-lensrows]");
  const detail = root.querySelector<HTMLElement>("[data-bb-lensdetail]");
  if (!rowsEl || !detail) return;
  const rows = [...rowsEl.querySelectorAll<HTMLElement>("[data-lensrow]")];

  const select = (id: string): void => {
    picks.forEach((b) => {
      const on = b.dataset.lenspick === id;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-selected", String(on));
    });
    rows.forEach((r) => {
      const on = id !== "all" && r.dataset.lensrow === id;
      r.classList.toggle("is-active", on);
      r.classList.toggle("is-dimmed", id !== "all" && !on);
    });
    if (id === "all") {
      detail.hidden = true;
      detail.innerHTML = "";
      return;
    }
    const stacks = data.stacks.filter((s) => s.m === id).sort((a, b) => b.sol - a.sol);
    if (stacks.length === 0) {
      detail.hidden = true;
      return;
    }
    const m = stacks[0]!;
    // Stretch bars to the observed band so they actually fill (86-99% on 0-100 crushes to slivers)
    const rates = stacks.map((s) => s.sol);
    const band = niceBand(rates);
    // Suite-mismatch chip: this model's measured task set vs the rest of the
    // field — overall rates pool different suites when counts differ.
    const suiteCounts = Object.values(data.modelTasks ?? {});
    const myTasks = data.modelTasks?.[id];
    let suiteChip = "";
    if (myTasks != null && suiteCounts.length > 1) {
      const lo = Math.min(...suiteCounts);
      const hi = Math.max(...suiteCounts);
      if (lo !== hi) {
        const other = myTasks === hi ? lo : hi;
        suiteChip =
          `<span class="bb-suitewarn bb-suitewarn--sm" title="Overall rates pool different task suites per model">` +
          `Suites differ (${myTasks} vs ${other} tasks) — compare within the Systems family for like-for-like.</span>`;
      }
    }
    const head =
      `<div class="bb-lens__detailhead">` +
      (m.ml
        ? `<img src="${esc(m.ml)}" alt="" width="22" height="22" loading="lazy" decoding="async">`
        : `<span class="bb-badge__mono">${esc(m.mm)}</span>`) +
      `<strong>${esc(m.md)}</strong><span>${stacks.length} harnesses · mean ${fmtPct(stacks.reduce((a, s) => a + s.sol, 0) / stacks.length)} · axis ${Math.round(band.lo * 100)}% → ${Math.round(band.hi * 100)}%</span>` +
      `<span class="bb-lens__detailhint">tap a row to clear</span>${suiteChip}</div>`;
    const harnessRows = stacks
      .map((s) => {
        const barW = `${bandPct(s.sol, band).toFixed(1)}%`;
        return (
          `<div class="bb-lens__hrow h--${esc(s.h.replace(/[^a-z0-9-]/g, ""))}" data-h="${esc(s.h)}">` +
          `<span style="display:inline-flex;align-items:center;gap:8px;min-width:0">` +
          (s.hl
            ? `<img class="bb-badge" src="${esc(s.hl)}" alt="" width="22" height="22" style="padding:2px">`
            : `<span class="bb-badge"><span class="bb-badge__mono">${esc(s.hm)}</span></span>`) +
          `<span style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(s.hd)}</span></span>` +
          `<span class="bb-lens__hbar"><span class="bb-lens__hfill" data-w="${barW}"></span></span>` +
          `<span class="bb-lens__hmeta"><strong>${fmtPct(s.sol)}</strong><br>strict ${fmtPct(s.str)}</span>` +
          `<span class="bb-lens__hmeta">${fmtCost(s.cost)}/task<br>n ${s.n}` +
          (s.no
            ? `<br><span class="bb-noop" title="No-op runs ended with no source edits, so they count against the rate">${s.no}/${s.n} no-op runs</span>`
            : "") +
          `</span>` +
          `</div>`
        );
      })
      .join("");
    detail.innerHTML = head + `<div class="bb-lens__harnesses">${harnessRows}</div>`;
    detail.hidden = false;
    detail.querySelectorAll<HTMLElement>(".bb-lens__hrow[data-h]").forEach((row) => {
      const s = stacks.find((stack) => stack.h === row.dataset.h);
      if (s) row.style.setProperty("--hc", s.hc);
    });
    detail.querySelectorAll<HTMLElement>("[data-w]").forEach((el) => {
      (el as HTMLElement).style.width = el.dataset.w ?? "0%";
    });
    detail.scrollIntoView({ behavior: "smooth", block: "nearest" });
  };

  root.addEventListener("click", (ev) => {
    const pick = (ev.target as HTMLElement).closest<HTMLButtonElement>("[data-lenspick]");
    if (pick?.dataset.lenspick) {
      select(pick.dataset.lenspick);
      return;
    }
    const row = (ev.target as HTMLElement).closest<HTMLElement>("[data-lensrow]");
    if (row?.dataset.lensrow) select(row.dataset.lensrow);
  });
}

/* ---------- 5 · ask the data (AI panel) ---------- */

/* The function's closed chart vocabulary (functions/src/benchAssistant.ts);
   the renderer maps it onto the dashboard dataset. */
const CHART_TYPES = new Set(["bar", "scatter", "line", "heatmap"]);
const CHART_DIMS = new Set(["stack", "model", "harness", "family", "language", "platform"]);
const CHART_METRICS = new Set([
  "solution_rate",
  "strict_rate",
  "cost_usd",
  "wall_seconds",
  "tokens"
]);

interface ChartSpec {
  type: string;
  title?: string;
  dimension: string;
  metric: string;
  filter?: { harness?: string; model?: string; family?: string };
}

type MetricKey = "sol" | "str" | "cost" | "wall" | "tok";

const METRIC_MAP: Record<string, MetricKey> = {
  solution_rate: "sol",
  strict_rate: "str",
  cost_usd: "cost",
  wall_seconds: "wall",
  tokens: "tok"
};

function metricOf(s: StackRow, metric: MetricKey): number | null {
  switch (metric) {
    case "sol":
      return s.sol;
    case "str":
      return s.str;
    case "cost":
      return s.cost;
    case "wall":
      return s.wall;
    case "tok":
      return s.tok;
  }
}

const METRIC_LABEL: Record<MetricKey, string> = {
  sol: "solution rate",
  str: "strict rate",
  cost: "median cost / task",
  wall: "median wall time",
  tok: "median tokens"
};

function fmtMetric(v: number | null, metric: MetricKey): string {
  if (v == null) return "—";
  if (metric === "sol" || metric === "str") return fmtPct(v);
  if (metric === "cost") return fmtCost(v);
  if (metric === "wall") return fmtWall(v);
  return fmtTokens(v);
}

/** Render a server-validated chart spec to SVG. Never executes model code. */
function renderChart(spec: ChartSpec, data: Dataset): { svg: string; title: string } | null {
  if (
    !CHART_TYPES.has(spec.type) ||
    !CHART_DIMS.has(spec.dimension) ||
    !CHART_METRICS.has(spec.metric)
  ) {
    return null;
  }
  const mkey = METRIC_MAP[spec.metric];
  if (!mkey) return null;
  let rows = data.stacks;
  if (spec.filter?.harness) rows = rows.filter((r) => r.h === spec.filter!.harness);
  if (spec.filter?.model) rows = rows.filter((r) => r.m === spec.filter!.model);

  const title = spec.title ?? `${METRIC_LABEL[mkey]} by ${spec.dimension}`;

  if (spec.dimension === "language" || spec.dimension === "platform") {
    const scopeRows = spec.dimension === "language" ? data.byLanguage : data.byPlatform;
    const items = scopeRows
      .map((r) => ({ label: r.key, value: r[mkey] }))
      .filter((x): x is { label: string; value: number } => x.value != null)
      .sort((a, b) => (mkey === "sol" || mkey === "str" ? b.value - a.value : a.value - b.value))
      .slice(0, 12);
    if (items.length === 0) return null;
    return { svg: hbarSvg(items, mkey, "#ff6d3f"), title };
  }

  if (spec.type === "heatmap" || spec.dimension === "family") {
    // family lens: mean metric per family across (filtered) stacks
    const famAgg = new Map<string, { sum: number; n: number }>();
    for (const row of data.heat) {
      if (spec.filter?.harness && row.h !== spec.filter.harness) continue;
      if (spec.filter?.model && row.m !== spec.filter.model) continue;
      row.cells.forEach((c, i) => {
        if (!c) return;
        const v = mkey === "sol" ? c.r : mkey === "str" ? c.s : c.c;
        if (v == null) return;
        const fam = data.families[i] ?? "";
        const agg = famAgg.get(fam) ?? { sum: 0, n: 0 };
        agg.sum += v;
        agg.n += 1;
        famAgg.set(fam, agg);
      });
    }
    const items = [...famAgg.entries()]
      .map(([label, a]) => ({ label, value: a.sum / a.n }))
      .sort((x, y) => y.value - x.value)
      .slice(0, 14);
    if (items.length === 0) return null;
    return { svg: hbarSvg(items, mkey, "#ff6d3f"), title };
  }

  if (spec.type === "scatter") {
    return { svg: scatterSvg(rows), title: spec.title ?? "cost vs solution rate" };
  }

  // aggregate to the requested dimension
  let items: { label: string; value: number; color?: string }[];
  if (spec.dimension === "stack") {
    items = rows
      .map((s) => ({ label: `${s.hd} × ${s.md}`, value: metricOf(s, mkey), color: s.mc }))
      .filter((x): x is { label: string; value: number; color: string } => x.value != null);
  } else {
    const key = spec.dimension === "model" ? "md" : "hd";
    const colorKey = spec.dimension === "model" ? "mc" : "hc";
    const agg = new Map<string, { sum: number; n: number; color: string }>();
    for (const s of rows) {
      const v = metricOf(s, mkey);
      if (v == null) continue;
      const k = s[key];
      const a = agg.get(k) ?? { sum: 0, n: 0, color: s[colorKey] };
      a.sum += v;
      a.n += 1;
      agg.set(k, a);
    }
    items = [...agg.entries()].map(([label, a]) => ({
      label,
      value: a.sum / a.n,
      color: a.color
    }));
  }
  const ascending = mkey === "cost" || mkey === "wall" || mkey === "tok";
  items.sort((a, b) => (ascending ? a.value - b.value : b.value - a.value));
  items = items.slice(0, 12);
  if (items.length === 0) return null;

  if (spec.type === "line") {
    return { svg: lineSvg(items, mkey), title };
  }
  return { svg: hbarSvg(items, mkey), title };
}

function hbarSvg(
  items: { label: string; value: number; color?: string }[],
  metric: MetricKey,
  fallbackColor = "#8a8f98"
): string {
  const W = 560;
  const H = Math.max(120, items.length * 30 + 16);
  const max = Math.max(...items.map((i) => i.value), 1e-9);
  const rows = items
    .map((it, i) => {
      const y = 8 + i * 30;
      const w = Math.max(2, (it.value / max) * (W - 220));
      return (
        `<text x="0" y="${y + 13}" class="bb-c__label">${esc(it.label.length > 26 ? it.label.slice(0, 25) + "…" : it.label)}</text>` +
        `<rect x="190" y="${y}" width="${w.toFixed(1)}" height="16" rx="4" fill="${it.color ?? fallbackColor}"></rect>` +
        `<text x="${(196 + w).toFixed(1)}" y="${y + 13}" class="bb-c__val">${esc(fmtMetric(it.value, metric))}</text>`
      );
    })
    .join("");
  return `<svg viewBox="0 0 ${W} ${H}" class="bb-c__svg" role="img">${rows}</svg>`;
}

function scatterSvg(rows: StackRow[]): string {
  const pts = rows.filter((r) => r.cost != null);
  if (pts.length === 0) return "";
  const W = 560;
  const H = 320;
  const ml = 44;
  const mb = 34;
  const maxC = Math.max(...pts.map((p) => p.cost ?? 0), 0.01);
  const x = (c: number) => ml + (c / maxC) * (W - ml - 16);
  const y = (r: number) => 12 + (1 - r) * (H - 12 - mb);
  const dots = pts
    .map(
      (p) =>
        `<circle cx="${x(p.cost ?? 0).toFixed(1)}" cy="${y(p.sol).toFixed(1)}" r="6" fill="${p.mc}" stroke="${p.hc}" stroke-width="2"><title>${esc(`${p.hd} × ${p.md} — ${fmtPct(p.sol)} · ${fmtCost(p.cost)}`)}</title></circle>`
    )
    .join("");
  return (
    `<svg viewBox="0 0 ${W} ${H}" class="bb-c__svg" role="img">` +
    `<line x1="${ml}" y1="${H - mb}" x2="${W - 16}" y2="${H - mb}" class="bb-c__axis"></line>` +
    `<line x1="${ml}" y1="12" x2="${ml}" y2="${H - mb}" class="bb-c__axis"></line>` +
    `<text x="${(ml + W) / 2}" y="${H - 6}" class="bb-c__axistitle">median cost / task</text>` +
    dots +
    `</svg>`
  );
}

function lineSvg(items: { label: string; value: number }[], metric: MetricKey): string {
  if (items.length < 2) return hbarSvg(items, metric);
  const W = 560;
  const H = 260;
  const max = Math.max(...items.map((i) => i.value), 1e-9);
  const min = Math.min(...items.map((i) => i.value), 0);
  const span = max - min || 1;
  const px = (i: number) => 24 + (i / (items.length - 1)) * (W - 48);
  const py = (v: number) => 16 + (1 - (v - min) / span) * (H - 56);
  const points = items.map((it, i) => `${px(i).toFixed(1)},${py(it.value).toFixed(1)}`).join(" ");
  const dots = items
    .map(
      (it, i) =>
        `<circle cx="${px(i).toFixed(1)}" cy="${py(it.value).toFixed(1)}" r="4" fill="#ff6d3f"><title>${esc(`${it.label}: ${fmtMetric(it.value, metric)}`)}</title></circle>`
    )
    .join("");
  return (
    `<svg viewBox="0 0 ${W} ${H}" class="bb-c__svg" role="img">` +
    `<polyline points="${points}" fill="none" stroke="#ff6d3f" stroke-width="2"></polyline>` +
    dots +
    `</svg>`
  );
}

/**
 * Compact digest of the export for the assistant (its contract: caller
 * supplies the digest, ≤ 24000 chars). Overall stack rows always; per-family
 * detail while the budget allows, falling back to family bests.
 */
function buildDigest(data: Dataset): string {
  const r3 = (v: number | null): number | null => (v == null ? null : Math.round(v * 1000) / 1000);
  const r5 = (v: number | null): number | null =>
    v == null ? null : Math.round(v * 100000) / 100000;
  const r1 = (v: number | null): number | null => (v == null ? null : Math.round(v * 10) / 10);
  const overall = data.stacks.map((s) => ({
    id: `${s.h} × ${s.m}`,
    scope: "overall",
    solution_rate: r3(s.sol),
    strict_rate: r3(s.str),
    ci95: [r3(s.ci[0]), r3(s.ci[1])],
    n: s.n,
    cost_usd_median: r5(s.cost),
    wall_seconds_median: r1(s.wall),
    tokens_median: s.tok == null ? null : Math.round(s.tok),
    confidence: s.conf,
    evidence: s.ev
  }));
  // Packed family rows (self-documented via family_schema): rate + n are
  // what family questions turn on, and the packed form keeps the full 224-row
  // detail inside the function's 24000-char digest budget.
  const familyRows: unknown[] = [];
  for (const row of data.heat) {
    row.cells.forEach((c, i) => {
      if (!c) return;
      familyRows.push([`${row.h} × ${row.m}`, data.families[i], r3(c.r), r3(c.s), c.n]);
    });
  }
  const base = {
    generated: data.generated,
    note: "BurnBench export digest. Rates are solution-quality estimands with Wilson ci95; costs are per-task medians at list prices.",
    overall,
    byLanguage: data.byLanguage,
    byPlatform: data.byPlatform
  };
  const full = JSON.stringify({
    ...base,
    family_schema: "[stack_id, family, solution_rate, strict_rate, n]",
    family: familyRows
  });
  if (full.length <= 23_500) return full;
  // Budget fallback: per-family best stack only.
  const best = new Map<string, { id: string; family: string; solution_rate: number; n: number }>();
  for (const row of data.heat) {
    row.cells.forEach((c, i) => {
      if (!c) return;
      const fam = data.families[i] ?? "";
      const cur = best.get(fam);
      if (!cur || c.r > cur.solution_rate) {
        best.set(fam, {
          id: `${row.h} × ${row.m}`,
          family: fam,
          solution_rate: r3(c.r) ?? 0,
          n: c.n
        });
      }
    });
  }
  return JSON.stringify({ ...base, familyBest: [...best.values()] });
}

function initAsk(data: Dataset): void {
  const root = document.querySelector<HTMLElement>("[data-bb-ask]");
  if (!root) return;
  const log = root.querySelector<HTMLElement>("[data-bb-log]");
  const form = root.querySelector<HTMLFormElement>("[data-bb-form]");
  const input = form?.querySelector<HTMLInputElement>('input[name="q"]');
  const status = root.querySelector<HTMLElement>("[data-bb-status]");
  const chartBox = root.querySelector<HTMLElement>("[data-bb-chart]");
  const chartTitle = root.querySelector<HTMLElement>("[data-bb-charttitle]");
  const chartSvg = root.querySelector<HTMLElement>("[data-bb-chartsvg]");
  if (!log || !form || !input || !status) return;

  let digest: string | null = null;
  const getDigest = (): string => {
    if (digest == null) digest = buildDigest(data);
    return digest;
  };

  const addMsg = (kind: "user" | "ai", text: string): HTMLElement => {
    const div = document.createElement("div");
    div.className = `bb-ask__msg bb-ask__msg--${kind}`;
    const p = document.createElement("p");
    p.textContent = text; // never innerHTML: model output is untrusted
    div.appendChild(p);
    log.appendChild(div);
    div.scrollIntoView({ block: "nearest", behavior: "smooth" });
    return div;
  };

  const ask = async (question: string) => {
    addMsg("user", question);
    const pending = addMsg("ai", "Thinking…");
    pending.classList.add("is-pending");
    status.textContent = "querying the export…";
    try {
      // Firebase callable protocol: {data: …} in, {result: …} | {error: …} out.
      const res = await fetch("/api/bench/assistant", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          data: {
            schemaVersion: 1,
            question,
            digest: getDigest(),
            view: "bench command center"
          }
        })
      });
      const body = (await res.json()) as {
        result?: {
          answer?: string;
          chart?: ChartSpec | null;
          rowsUsed?: string[];
          modelSlug?: string;
        };
        error?: { message?: string; status?: string };
      };
      if (!res.ok || body.error) {
        const msg = body.error?.message ?? `HTTP ${res.status}`;
        throw new Error(msg);
      }
      const payload = body.result ?? {};
      pending.classList.remove("is-pending");
      pending.querySelector("p")!.textContent = payload.answer ?? "No answer came back.";
      const cited = payload.rowsUsed?.length ?? 0;
      status.textContent = cited > 0 ? `${cited} rows cited · 10/min · 60/day` : "10/min · 60/day";
      if (payload.chart && chartBox && chartSvg && chartTitle) {
        const rendered = renderChart(payload.chart, data);
        if (rendered) {
          chartTitle.textContent = rendered.title;
          chartSvg.innerHTML = rendered.svg; // whitelisted numbers/labels only
          chartBox.hidden = false;
        }
      }
    } catch (err) {
      pending.classList.remove("is-pending");
      const message = err instanceof Error ? err.message : "";
      pending.querySelector("p")!.textContent = /resource-exhausted|rate/i.test(message)
        ? "You've hit the assistant's rate limit — give it a minute. The numbers on this page are the same export it reads."
        : "The analyst is unavailable right now — the numbers on this page are the same export it reads, so the leaderboard above still has you covered.";
      status.textContent = "assistant offline · page data unaffected";
    }
  };

  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    const q = input.value.trim();
    if (!q) return;
    input.value = "";
    void ask(q);
  });
  root.querySelectorAll<HTMLButtonElement>(".bb-chip").forEach((chip) => {
    chip.addEventListener("click", () => {
      const q = chip.dataset.q ?? chip.textContent ?? "";
      void ask(q);
    });
  });
}

/* ---------- 6 · Pareto — interactive (hover, pin, filter, round-up) ---------- */

function initPareto(data: Dataset): void {
  const root = document.querySelector<HTMLElement>("[data-bb-pareto]");
  const svg = root?.querySelector<HTMLElement>("[data-bb-pareto-svg]");
  const stage = root?.querySelector<HTMLElement>("[data-bb-pareto-stage]");
  const tip = root?.querySelector<HTMLElement>("[data-bb-pareto-tip]");
  const compare = root?.querySelector<HTMLElement>("[data-bb-pareto-compare]");
  const cards = root?.querySelector<HTMLElement>("[data-bb-pareto-cards]");
  const count = root?.querySelector<HTMLElement>("[data-bb-pareto-count]");
  const clearBtn = root?.querySelector<HTMLButtonElement>("[data-bb-pareto-clear]");
  const resetBtn = root?.querySelector<HTMLButtonElement>("[data-bb-pareto-reset]");
  if (!root || !svg || !tip || !compare || !cards) return;
  // zoom: stage is scroll container so transform doesn't clip the glass tip
  let paretoScale = 1;
  const setParetoScale = (next: number) => {
    paretoScale = Math.max(1, Math.min(2.4, next));
    svg.style.transform = `scale(${paretoScale})`;
    if (stage) stage.style.overflow = paretoScale > 1 ? "auto" : "";
    root.classList.toggle("is-zoomed", paretoScale > 1.02);
    const out = root.querySelector<HTMLButtonElement>("[data-pareto-zoom-out]");
    const rst = root.querySelector<HTMLButtonElement>("[data-pareto-zoom-reset]");
    if (out) out.disabled = paretoScale <= 1.01;
    if (rst) rst.disabled = paretoScale <= 1.01;
  };
  if (stage)
    attachZoom(stage, svg, {
      min: 1,
      max: 2.4,
      step: 0.14,
      onChange: (s) => {
        paretoScale = s;
        root.classList.toggle("is-zoomed", s > 1.02);
      }
    });
  root
    .querySelector<HTMLButtonElement>("[data-pareto-zoom-in]")
    ?.addEventListener("click", () => setParetoScale(paretoScale + 0.18));
  root
    .querySelector<HTMLButtonElement>("[data-pareto-zoom-out]")
    ?.addEventListener("click", () => setParetoScale(paretoScale - 0.18));
  root
    .querySelector<HTMLButtonElement>("[data-pareto-zoom-reset]")
    ?.addEventListener("click", () => setParetoScale(1));

  const byKey = new Map(data.stacks.map((s) => [`${s.h}|${s.m}`, s]));
  const pinned = new Set<string>();
  const onH = new Set(data.stacks.map((s) => s.h));
  const onM = new Set(data.stacks.map((s) => s.m));

  const pts = (): HTMLElement[] => [...svg.querySelectorAll<HTMLElement>("[data-pareto-pt]")];

  /* ---------- Pareto — switchable axes: per-point metrics from the SSR
     data attributes (quality_mean never reaches the JSON dataset, so the
     DOM is the source of truth for all six metrics). ---------- */
  type AxisX = "cost" | "wall" | "tok";
  type AxisY = "sol" | "str" | "qual";
  const parseMetric = (v: string | undefined): number | null => {
    if (v == null || v === "") return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  };
  interface PtMetrics {
    el: HTMLElement;
    key: string;
    cost: number | null;
    wall: number | null;
    tok: number | null;
    sol: number | null;
    str: number | null;
    qual: number | null;
  }
  const pmetrics: PtMetrics[] = pts().map((el) => ({
    el,
    key: el.dataset.paretoPt ?? "",
    cost: parseMetric(el.dataset.cost),
    wall: parseMetric(el.dataset.wall),
    tok: parseMetric(el.dataset.tok),
    sol: parseMetric(el.dataset.sol),
    str: parseMetric(el.dataset.str),
    qual: parseMetric(el.dataset.qual)
  }));
  const qualByKey = new Map(pmetrics.map((p) => [p.key, p.qual]));
  /** Keys hidden because the active axes lack a value for them. */
  const missingAxis = new Set<string>();

  const applyFilters = (): void => {
    for (const el of pts()) {
      const h = el.dataset.h ?? "";
      const m = el.dataset.m ?? "";
      const visible = onH.has(h) && onM.has(m) && !missingAxis.has(el.dataset.paretoPt ?? "");
      el.classList.toggle("is-dimmed", !visible);
      el.setAttribute("aria-hidden", String(!visible));
    }
    // frontier line dims when most of the field is hidden (keep our round-up honest)
    const visCount = pts().filter((p) => !p.classList.contains("is-dimmed")).length;
    const frontier = root.querySelector<HTMLElement>("[data-bb-pareto-frontier]");
    if (frontier) frontier.style.opacity = visCount < 4 ? "0.22" : "0.75";
  };

  const showTip = (key: string | null): void => {
    if (!key || !byKey.has(key)) {
      tip.hidden = true;
      return;
    }
    const s = byKey.get(key)!;
    const wall = s.wall;
    const tok = s.tok;
    const qual = qualByKey.get(key) ?? null;
    // Rich identity row: both logos large so the hovered stack is obvious
    // at a glance, then the metric strip.
    const logos =
      (s.hl
        ? `<img class="bb-pareto__tiplogo" src="${esc(s.hl)}" alt="" width="30" height="30">`
        : "") +
      (s.ml
        ? `<img class="bb-pareto__tiplogo bb-pareto__tiplogo--m" src="${esc(s.ml)}" alt="" width="30" height="30">`
        : "");
    tip.innerHTML =
      `<span class="bb-pareto__tipid">${logos}<span class="bb-pareto__tipname">${esc(s.hd)} <em>×</em> ${esc(s.mds)}</span></span>` +
      `<span class="bb-pareto__tiprow"><em>${fmtPct(s.sol)}</em> sol · strict ${fmtPct(s.str)} · <em>${fmtCost(s.cost)}/task</em></span>` +
      `<span class="bb-pareto__tiprow mono">${fmtWall(wall)} · ${fmtTokens(tok)} tok · ${qual != null ? `quality ${qual.toFixed(1)}/5 · ` : ""}n ${s.n} · ${s.ev === "inferred" ? "inferred" : "measured"}${s.conf === "low" ? " · low conf" : ""}</span>`;
    tip.hidden = false;
  };

  const renderCompare = (): void => {
    const list = [...pinned].map((k) => byKey.get(k)).filter((s): s is StackRow => s != null);
    if (count) count.textContent = `${list.length} stack${list.length === 1 ? "" : "s"}`;
    if (clearBtn) clearBtn.hidden = list.length === 0;
    if (list.length === 0) {
      compare.hidden = true;
      cards.innerHTML = "";
      return;
    }
    compare.hidden = false;
    // Suite-mismatch chip: pinned stacks whose models measured different
    // task suites aren't like-for-like on overall rates.
    const mtMap = data.modelTasks ?? {};
    const pinnedCounts = [
      ...new Set(list.map((s) => mtMap[s.m]).filter((v): v is number => v != null))
    ];
    const suiteNote =
      pinnedCounts.length > 1
        ? `<div class="bb-pareto__suitenote"><span class="bb-suitewarn bb-suitewarn--sm" title="Overall rates pool different task suites per model">` +
          `Suites differ (${Math.min(...pinnedCounts)} vs ${Math.max(...pinnedCounts)} tasks) — compare within the Systems family for like-for-like.</span></div>`
        : "";
    cards.innerHTML =
      suiteNote +
      list
        .map((s) => {
          const logo = s.hl ?? s.ml;
          return (
            `<div class="bb-pareto__card m--${esc(s.m.replace(/[^a-z0-9-]/g, ""))}" style="--mc:${esc(s.mc)}">` +
            `<button class="bb-pareto__cardx" type="button" data-pareto-unpin="${esc(`${s.h}|${s.m}`)}" aria-label="Remove ${esc(s.hd)} × ${esc(s.mds)}">×</button>` +
            `<div class="bb-pareto__cardhead">${logo ? `<img src="${esc(logo)}" alt="" width="18" height="18" loading="lazy" decoding="async">` : ""}${esc(s.hd)} × ${esc(s.mds)}</div>` +
            `<div class="bb-pareto__cardmeta">` +
            `<span><strong>${fmtPct(s.sol)}</strong> sol · strict ${fmtPct(s.str)}</span>` +
            `<span><strong>${fmtCost(s.cost)}/task</strong>${s.cstd != null ? ` · std ${fmtCost(s.cstd)}` : ""} · n ${s.n}</span>` +
            `<span>${fmtTokens(s.tok)} tok · ${fmtWall(s.wall)} · ${s.ev}${s.conf === "low" ? " · low conf" : ""}</span>` +
            `</div></div>`
          );
        })
        .join("");
  };

  // hover — glass card
  svg.addEventListener("pointerover", (ev) => {
    const pt = (ev.target as HTMLElement).closest<HTMLElement>("[data-pareto-pt]");
    if (!pt?.dataset.paretoPt) return;
    pt.classList.add("is-hover");
    showTip(pt.dataset.paretoPt);
  });
  svg.addEventListener("pointerout", (ev) => {
    const pt = (ev.target as HTMLElement).closest<HTMLElement>("[data-pareto-pt]");
    if (!pt) {
      tip.hidden = true;
      return;
    }
    pt.classList.remove("is-hover");
    // keep tip if we have pins, otherwise hide
    if (pinned.size === 0) tip.hidden = true;
  });
  svg.addEventListener("focusin", (ev) => {
    const pt = (ev.target as HTMLElement).closest<HTMLElement>("[data-pareto-pt]");
    if (pt?.dataset.paretoPt) showTip(pt.dataset.paretoPt);
  });
  svg.addEventListener("focusout", () => {
    if (pinned.size === 0) tip.hidden = true;
  });

  // click / keyboard — pin
  const togglePin = (key: string): void => {
    if (pinned.has(key)) pinned.delete(key);
    else pinned.add(key);
    for (const el of pts()) {
      el.classList.toggle("is-pinned", pinned.has(el.dataset.paretoPt ?? ""));
    }
    renderCompare();
  };
  svg.addEventListener("click", (ev) => {
    const pt = (ev.target as HTMLElement).closest<HTMLElement>("[data-pareto-pt]");
    if (!pt?.dataset.paretoPt) return;
    togglePin(pt.dataset.paretoPt);
  });
  svg.addEventListener("keydown", (ev) => {
    if (ev.key !== "Enter" && ev.key !== " ") return;
    const pt = (ev.target as HTMLElement).closest<HTMLElement>("[data-pareto-pt]");
    if (!pt?.dataset.paretoPt) return;
    ev.preventDefault();
    togglePin(pt.dataset.paretoPt);
  });

  // filter chips
  root.querySelectorAll<HTMLButtonElement>("[data-pareto-h]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const h = btn.dataset.paretoH ?? "";
      if (onH.has(h)) onH.delete(h);
      else onH.add(h);
      if (onH.size === 0) {
        // never hide everything — reset
        for (const s of data.stacks) onH.add(s.h);
      }
      btn.classList.toggle("is-on", onH.has(h));
      btn.setAttribute("aria-pressed", String(onH.has(h)));
      applyFilters();
    });
  });
  root.querySelectorAll<HTMLButtonElement>("[data-pareto-m]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const m = btn.dataset.paretoM ?? "";
      if (onM.has(m)) onM.delete(m);
      else onM.add(m);
      if (onM.size === 0) {
        for (const s of data.stacks) onM.add(s.m);
      }
      btn.classList.toggle("is-on", onM.has(m));
      btn.setAttribute("aria-pressed", String(onM.has(m)));
      applyFilters();
    });
  });
  resetBtn?.addEventListener("click", () => {
    onH.clear();
    onM.clear();
    for (const s of data.stacks) {
      onH.add(s.h);
      onM.add(s.m);
    }
    root.querySelectorAll<HTMLButtonElement>("[data-pareto-h],[data-pareto-m]").forEach((b) => {
      b.classList.add("is-on");
      b.setAttribute("aria-pressed", "true");
    });
    applyFilters();
  });
  clearBtn?.addEventListener("click", () => {
    pinned.clear();
    for (const el of pts()) el.classList.remove("is-pinned");
    tip.hidden = true;
    renderCompare();
  });
  cards.addEventListener("click", (ev) => {
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>("[data-pareto-unpin]");
    const key = btn?.dataset.paretoUnpin;
    if (!key) return;
    pinned.delete(key);
    const el = svg.querySelector<HTMLElement>(`[data-pareto-pt="${CSS.escape(key)}"]`);
    el?.classList.remove("is-pinned");
    renderCompare();
    if (pinned.size === 0) tip.hidden = true;
  });

  /* ---------- Pareto — switchable axes (client recompute) ----------
     Mirrors the server paretoDomain geometry: log10 X with a 9% gutter
     for $0/free stacks, linear Y padded to the observed band. The SSR
     default (cost × solution) stays byte-identical until a chip moves. */
  const PLOT = { w: 760, h: 440, ml: 56, mr: 24, mt: 24, mb: 48 };
  const SVG_NS = "http://www.w3.org/2000/svg";
  const gridX = svg.querySelector<SVGGElement>("[data-pareto-grid-x]");
  const gridY = svg.querySelector<SVGGElement>("[data-pareto-grid-y]");
  const zeroLine = svg.querySelector<SVGGElement>("[data-pareto-zeroline]");
  const quadrant = svg.querySelector<SVGRectElement>("[data-pareto-quadrant]");
  const titleX = svg.querySelector<SVGTextElement>("[data-pareto-axistitle-x]");
  const titleY = svg.querySelector<SVGTextElement>("[data-pareto-axistitle-y]");
  const frontier = svg.querySelector<SVGPolylineElement>("[data-bb-pareto-frontier]");

  const AXIS_TITLE_X: Record<AxisX, string> = {
    cost: "median cost per task · USD, log scale (list-price, token-derived)",
    wall: "median wall time per task · log scale",
    tok: "median tokens per task · log scale"
  };
  const AXIS_TITLE_Y: Record<AxisY, string> = {
    sol: "solution rate",
    str: "strict rate",
    qual: "Kimi quality (1–5)"
  };
  const xVal = (p: PtMetrics, ax: AxisX): number | null =>
    ax === "cost" ? p.cost : ax === "wall" ? p.wall : p.tok;
  const yVal = (p: PtMetrics, ay: AxisY): number | null =>
    ay === "sol" ? p.sol : ay === "str" ? p.str : p.qual;

  /** Human-friendly log ticks. Cost/tokens use 1·2·5×10ⁿ; wall time uses
      clock-named values (30s, 1m, 2m, 5m…) so a narrow domain still gets
      several readable ticks instead of a lone decade label. */
  const WALL_COARSE = [15, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200];
  const WALL_FINE = [10, 20, 45, 90, 150, 240, 420, 900, 1500, 2700, 5400];
  const niceTicks = (ax: AxisX, min: number, max: number): number[] => {
    const inDomain = (v: number): boolean => v >= min * 0.995 && v <= max * 1.005;
    let ticks: number[];
    if (ax === "wall") {
      ticks = WALL_COARSE.filter(inDomain);
      if (ticks.length < 4) {
        // Densify with fine values, greedily picking the widest log-gap fill
        // so clean clock values (1m, 2m, 5m) are never thinned away.
        const fine = WALL_FINE.filter((v) => inDomain(v) && !ticks.includes(v));
        while (ticks.length < 5 && fine.length > 0) {
          let best = 0;
          let bestD = -1;
          for (let i = 0; i < fine.length; i++) {
            const fv = fine[i];
            if (fv === undefined) continue;
            const d = Math.min(...ticks.map((t) => Math.abs(Math.log10(fv) - Math.log10(t))));
            if (d > bestD) {
              bestD = d;
              best = i;
            }
          }
          const picked = fine.splice(best, 1)[0];
          if (picked === undefined) break;
          ticks.push(picked);
        }
        ticks.sort((a, b) => a - b);
      }
      while (ticks.length > 6) ticks = ticks.filter((_, i) => i % 2 === 0);
    } else {
      const all: number[] = [];
      for (let e = Math.floor(Math.log10(min)) - 1; e <= Math.ceil(Math.log10(max)); e++) {
        for (const m of [1, 2, 5]) all.push(m * Math.pow(10, e));
      }
      ticks = all.filter(inDomain);
      if (ticks.length > 6)
        ticks = ticks.filter((v) => {
          const m = v / Math.pow(10, Math.floor(Math.log10(v)));
          return m === 1 || m === 5;
        });
      if (ticks.length > 6)
        ticks = ticks.filter(
          (v) => Math.abs(v / Math.pow(10, Math.round(Math.log10(v))) - 1) < 1e-9
        );
    }
    // Never leave an axis bare: fall back to the domain endpoints.
    if (ticks.length < 2) ticks = [min, max];
    return ticks;
  };

  /** Log10 axis fraction with the server's free-stack gutter. */
  const logScale = (
    values: number[],
    ax: AxisX
  ): { frac: (v: number) => number; ticks: number[] } => {
    const positive = values.filter((v) => v > 0);
    const xMinPos = positive.length > 0 ? Math.min(...positive) : 0.001;
    const xMax = Math.max(...values, xMinPos * 10);
    const lo = Math.log10(xMinPos);
    const hi = Math.log10(xMax);
    const span = hi - lo || 1;
    const gutterW = 0.09;
    const frac = (v: number): number => {
      if (v <= 0) return gutterW / 2;
      return gutterW + ((Math.log10(v) - lo) / span) * (1 - gutterW);
    };
    return { frac, ticks: niceTicks(ax, xMinPos, xMax) };
  };

  /** Linear Y domain: rates pad to 0.05 steps like the server; quality
      pads the observed 1–5 band to half-point steps. */
  const linDomain = (
    vals: number[],
    isQual: boolean
  ): { min: number; max: number; ticks: number[] } => {
    let yMin: number;
    let yMax: number;
    if (isQual) {
      yMin = Math.max(1, Math.floor((Math.min(...vals) - 0.25) * 2) / 2);
      yMax = Math.min(5, Math.ceil((Math.max(...vals) + 0.25) * 2) / 2);
    } else {
      yMin = Math.max(0, Math.floor(Math.min(...vals, 0.5) * 20) / 20);
      yMax = Math.ceil(Math.max(...vals, 0.6) * 20) / 20;
    }
    if (yMax <= yMin) yMax = yMin + (isQual ? 1 : 0.05);
    const span = yMax - yMin;
    const step = isQual ? (span <= 1 ? 0.5 : 1) : span <= 0.2 ? 0.05 : span <= 0.5 ? 0.1 : 0.2;
    const ticks: number[] = [];
    for (let t = yMin; t <= yMax + 1e-9; t += step) ticks.push(Math.round(t * 100) / 100);
    return { min: yMin, max: yMax, ticks };
  };

  const svgEl = <K extends keyof SVGElementTagNameMap>(
    tag: K,
    attrs: Record<string, string>,
    text?: string
  ): SVGElementTagNameMap[K] => {
    const node = document.createElementNS(SVG_NS, tag);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (text != null) node.textContent = text;
    return node;
  };

  const applyAxes = (ax: AxisX, ay: AxisY): void => {
    missingAxis.clear();
    const present: { pt: PtMetrics; x: number; y: number }[] = [];
    for (const p of pmetrics) {
      const x = xVal(p, ax);
      const y = yVal(p, ay);
      if (x == null || y == null) missingAxis.add(p.key);
      else present.push({ pt: p, x, y });
    }
    if (present.length === 0) {
      applyFilters();
      return;
    }
    const xs = present.map((p) => p.x);
    const ys = present.map((p) => p.y);
    const scX = logScale(xs, ax);
    const dY = linDomain(ys, ay === "qual");
    const px = (v: number): number => PLOT.ml + scX.frac(v) * (PLOT.w - PLOT.ml - PLOT.mr);
    const py = (v: number): number =>
      PLOT.mt + (1 - (v - dY.min) / (dY.max - dY.min)) * (PLOT.h - PLOT.mt - PLOT.mb);

    // Reposition both circles of every visible point.
    for (const p of present) {
      const cx = px(p.x).toFixed(1);
      const cy = py(p.y).toFixed(1);
      p.pt.el.querySelectorAll("circle").forEach((c) => {
        c.setAttribute("cx", cx);
        c.setAttribute("cy", cy);
      });
    }

    // Rebuild gridlines + tick labels for the active axes. Tick labels use
    // compact unit-aware forms ("$0.5", "90s", "20k") since niceTicks only
    // emits round values.
    const fmtCostTick = (t: number): string =>
      `$${t >= 1 ? (Number.isInteger(t) ? t : t.toFixed(2)) : t}`;
    const fmtWallTick = (t: number): string =>
      t % 60 === 0 ? fmtWall(t) : t < 180 ? `${t}s` : fmtWall(t);
    const fmtXTick = (t: number): string =>
      ax === "cost" ? fmtCostTick(t) : ax === "wall" ? fmtWallTick(t) : fmtTokens(t);
    const fmtYTick = (t: number): string =>
      ay === "qual" ? (Number.isInteger(t) ? String(t) : t.toFixed(1)) : `${Math.round(t * 100)}%`;
    if (gridY) {
      gridY.replaceChildren(
        ...dY.ticks.flatMap((t) => [
          svgEl("line", {
            class: "bb-pareto__grid",
            x1: String(PLOT.ml),
            x2: String(PLOT.w - PLOT.mr),
            y1: py(t).toFixed(1),
            y2: py(t).toFixed(1)
          }),
          svgEl(
            "text",
            {
              class: "bb-pareto__tick",
              x: String(PLOT.ml - 8),
              y: (py(t) + 4).toFixed(1),
              "text-anchor": "end"
            },
            fmtYTick(t)
          )
        ])
      );
    }
    if (gridX) {
      gridX.replaceChildren(
        ...scX.ticks.flatMap((t) => [
          svgEl("line", {
            class: "bb-pareto__grid",
            x1: px(t).toFixed(1),
            x2: px(t).toFixed(1),
            y1: String(PLOT.mt),
            y2: String(PLOT.h - PLOT.mb)
          }),
          svgEl(
            "text",
            {
              class: "bb-pareto__tick",
              x: px(t).toFixed(1),
              y: String(PLOT.h - PLOT.mb + 18),
              "text-anchor": "middle"
            },
            fmtXTick(t)
          )
        ])
      );
    }

    // Axis titles + accessible description.
    if (titleX) titleX.textContent = AXIS_TITLE_X[ax];
    if (titleY) titleY.textContent = AXIS_TITLE_Y[ay];
    svg.setAttribute(
      "aria-label",
      `Interactive scatter: ${AXIS_TITLE_X[ax]} versus ${AXIS_TITLE_Y[ay]}. Hover for details, click to pin comparisons.`
    );

    // The $0 gutter marker only means something on the cost axis.
    if (zeroLine) zeroLine.style.display = ax === "cost" ? "" : "none";

    // "Most attractive" quadrant: below-median x, above-median y.
    const median = (arr: number[]): number => {
      const s = [...arr].sort((a, b) => a - b);
      return s[Math.floor(s.length / 2)] ?? 0;
    };
    if (quadrant) {
      quadrant.setAttribute("width", Math.max(0, px(median(xs)) - PLOT.ml).toFixed(1));
      quadrant.setAttribute("height", Math.max(0, py(median(ys)) - PLOT.mt).toFixed(1));
    }

    // Pareto frontier for the active axes: sort by x ascending, keep
    // strictly improving y (lower x is always better here).
    const sorted = [...present].sort((a, b) => a.x - b.x);
    let best = -Infinity;
    const fKeys = new Set<string>();
    const fpts: string[] = [];
    for (const p of sorted) {
      const y = p.y;
      if (y > best + 1e-9) {
        best = y;
        fKeys.add(p.pt.key);
        fpts.push(`${px(p.x).toFixed(1)},${py(y).toFixed(1)}`);
      }
    }
    if (frontier) frontier.setAttribute("points", fpts.join(" "));
    for (const p of pmetrics) p.el.classList.toggle("bb-pareto__pt--frontier", fKeys.has(p.key));

    applyFilters();
  };

  // Axis chips — one active per axis, persisted to localStorage.
  const AXES_KEY = "bb-pareto-axes";
  let axisX: AxisX = "cost";
  let axisY: AxisY = "sol";
  try {
    const raw = localStorage.getItem(AXES_KEY);
    if (raw) {
      const saved: { x?: string; y?: string } = JSON.parse(raw);
      if (saved.x === "cost" || saved.x === "wall" || saved.x === "tok") axisX = saved.x;
      if (saved.y === "sol" || saved.y === "str" || saved.y === "qual") axisY = saved.y;
    }
  } catch {
    /* storage unavailable — defaults stand */
  }
  const persistAxes = (): void => {
    try {
      localStorage.setItem(AXES_KEY, JSON.stringify({ x: axisX, y: axisY }));
    } catch {
      /* storage unavailable */
    }
  };
  const syncAxisChips = (): void => {
    root.querySelectorAll<HTMLButtonElement>("[data-pareto-axis-x]").forEach((b) => {
      const on = b.dataset.paretoAxisX === axisX;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-pressed", String(on));
    });
    root.querySelectorAll<HTMLButtonElement>("[data-pareto-axis-y]").forEach((b) => {
      const on = b.dataset.paretoAxisY === axisY;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-pressed", String(on));
    });
  };
  root.querySelectorAll<HTMLButtonElement>("[data-pareto-axis-x]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const v = btn.dataset.paretoAxisX;
      if (v !== "cost" && v !== "wall" && v !== "tok") return;
      axisX = v;
      persistAxes();
      syncAxisChips();
      setParetoScale(1);
      applyAxes(axisX, axisY);
    });
  });
  root.querySelectorAll<HTMLButtonElement>("[data-pareto-axis-y]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const v = btn.dataset.paretoAxisY;
      if (v !== "sol" && v !== "str" && v !== "qual") return;
      axisY = v;
      persistAxes();
      syncAxisChips();
      setParetoScale(1);
      applyAxes(axisX, axisY);
    });
  });

  syncAxisChips();
  // Restore a saved non-default view; the default matches the SSR markup.
  if (axisX !== "cost" || axisY !== "sol") applyAxes(axisX, axisY);
  else applyFilters();
}

/* ---------- boot ---------- */

void loadDataset().then((data) => {
  if (!data) return; // SSR page remains fully meaningful without enhancement
  initTabs(data);
  initTuner(data);
  initHeatLens(data);
  initLens(data);
  initPareto(data);
  initAsk(data);
});
