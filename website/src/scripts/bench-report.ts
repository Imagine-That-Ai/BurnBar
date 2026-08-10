/**
 * @fileoverview BurnBench report client module (/bench/report).
 *
 * Progressive enhancement over a fully SSR'd page:
 *  1. Matrix metric toggle (solution ↔ strict) — swaps preformatted strings
 *     out of data attributes; no fetch, no reflow of the table.
 *  2. Task-browser family filter — DOM-only over the SSR'd rows.
 *  3. Cell explorer — lazily fetches /data/bench-cells.json the first time
 *     the section scrolls into view OR the user touches a control, then
 *     renders a filtered, capped table (200 rows) built entirely with
 *     DOM APIs + textContent (no innerHTML anywhere: the data is public
 *     benchmark evidence, but the habit keeps the CSP story airtight).
 */

/* ---------- shared formatting (mirrors bench.ts) ---------- */

// Module marker: without an import/export, tsc treats this file as a global
// script and these helpers collide with bench-dashboard.ts's identical set.
export {};

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
  v == null ? "—" : v >= 1000 ? `${Math.round(v / 1000)}k` : `${v}`;

const fmtInt = (v: number): string => v.toLocaleString("en-US");

/* ---------- 1 · matrix metric toggle ---------- */

function initMatrix(): void {
  const tabs = document.querySelector<HTMLElement>("[data-br-mxtabs]");
  const table = document.querySelector<HTMLElement>("[data-br-mx]");
  if (!tabs || !table) return;
  tabs.addEventListener("click", (ev) => {
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>("[data-mx]");
    if (!btn) return;
    const mode = btn.dataset.mx === "str" ? "str" : btn.dataset.mx === "qual" ? "qual" : "sol";
    tabs.querySelectorAll(".bb-tab").forEach((t) => {
      const active = t === btn;
      t.classList.toggle("is-active", active);
      t.setAttribute("aria-selected", String(active));
    });
    table.querySelectorAll<HTMLElement>(".mx-cell[data-sol]").forEach((cell) => {
      const sol = cell.dataset.sol ?? "";
      const str = cell.dataset.str ?? "";
      const qual = cell.dataset.qual ?? "";
      const n = cell.dataset.n ?? "";
      const val = cell.querySelector("[data-mx-val]");
      const sub = cell.querySelector("[data-mx-sub]");
      if (val) val.textContent = mode === "str" ? str : mode === "qual" ? qual : sol;
      if (sub)
        sub.textContent =
          mode === "str"
            ? `solution ${sol} · n ${n}`
            : mode === "qual"
              ? `solution ${sol} · n ${n}`
              : `strict ${str} · n ${n}`;
    });
  });
}

/* ---------- 2 · task-browser family filter ---------- */

function initTaskFilter(): void {
  const root = document.querySelector<HTMLElement>("[data-br-tasks]");
  if (!root) return;
  const chips = root.querySelector<HTMLElement>(".bb-tasks__chips");
  if (!chips) return;
  chips.addEventListener("click", (ev) => {
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>("[data-fam]");
    if (!btn) return;
    const fam = btn.dataset.fam ?? "";
    chips.querySelectorAll(".bb-chip").forEach((c) => c.classList.toggle("is-active", c === btn));
    root.querySelectorAll<HTMLElement>(".bb-trow[data-family]").forEach((row) => {
      row.style.display = fam === "" || row.dataset.family === fam ? "" : "none";
    });
  });
}

/* ---------- 3 · cell explorer (lazy dataset) ---------- */

/** Slim cell row: [harness, model, task, n, solutionPasses, strictPasses, cost, wall, tokens, noopRuns]. */
type CellRow = [
  number,
  number,
  number,
  number,
  number,
  number,
  number | null,
  number | null,
  number | null,
  number?
];

interface CellsPayload {
  generated: string;
  h: string[];
  hd: string[];
  hc: string[];
  m: string[];
  md: string[];
  mc: string[];
  t: string[];
  tf: string[];
  fams: string[];
  cells: CellRow[];
}

const ROW_CAP = 200;

async function fetchCells(): Promise<CellsPayload | null> {
  try {
    const res = await fetch("/data/bench-cells.json");
    if (!res.ok) return null;
    return (await res.json()) as CellsPayload;
  } catch {
    return null;
  }
}

function option(value: string, label: string): HTMLOptionElement {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = label;
  return o;
}

function td(text: string, className?: string): HTMLTableCellElement {
  const cell = document.createElement("td");
  cell.textContent = text;
  if (className) cell.className = className;
  return cell;
}

function initExplorer(): void {
  const root = document.querySelector<HTMLElement>("[data-br-explorer]");
  if (!root) return;
  const q = root.querySelector<HTMLInputElement>("[data-br-q]");
  const selH = root.querySelector<HTMLSelectElement>("[data-br-h]");
  const selM = root.querySelector<HTMLSelectElement>("[data-br-m]");
  const selF = root.querySelector<HTMLSelectElement>("[data-br-f]");
  const selV = root.querySelector<HTMLSelectElement>("[data-br-v]");
  const reset = root.querySelector<HTMLButtonElement>("[data-br-reset]");
  const count = root.querySelector<HTMLElement>("[data-br-count]");
  const body = root.querySelector<HTMLElement>("[data-br-body]");
  const idle = root.querySelector<HTMLElement>("[data-br-idle]");
  if (!q || !selH || !selM || !selF || !selV || !reset || !count || !body) return;

  let loadPromise: Promise<CellsPayload | null> | null = null;
  const load = (): Promise<CellsPayload | null> => {
    loadPromise ??= fetchCells();
    return loadPromise;
  };

  const render = (data: CellsPayload): void => {
    const query = q.value.trim().toLowerCase();
    const fh = selH.value;
    const fm = selM.value;
    const ff = selF.value;
    const fv = selV.value;

    const matches: { row: CellRow; idx: number }[] = [];
    let trials = 0;
    for (let i = 0; i < data.cells.length; i++) {
      const row = data.cells[i];
      if (!row) continue;
      const [hi, mi, ti, n, sp, stp] = row;
      if (fh && data.h[hi] !== fh) continue;
      if (fm && data.m[mi] !== fm) continue;
      if (ff && data.tf[ti] !== ff) continue;
      if (fv === "pass" && stp !== n) continue;
      if (fv === "fail" && sp !== 0) continue;
      if (fv === "partial" && !(sp > 0 && stp < n)) continue;
      if (fv === "flip" && sp <= stp) continue;
      if (query) {
        const hay =
          `${data.h[hi] ?? ""} ${data.hd[hi] ?? ""} ${data.m[mi] ?? ""} ${data.md[mi] ?? ""} ${data.t[ti] ?? ""} ${data.tf[ti] ?? ""}`.toLowerCase();
        if (!hay.includes(query)) continue;
      }
      trials += n;
      matches.push({ row, idx: i });
    }

    const capped = matches.slice(0, ROW_CAP);
    count.textContent =
      matches.length === 0
        ? "no cells match — loosen the filters"
        : matches.length > ROW_CAP
          ? `showing first ${fmtInt(ROW_CAP)} of ${fmtInt(matches.length)} cells (${fmtInt(trials)} trials) — refine filters to narrow`
          : `${fmtInt(matches.length)} cells · ${fmtInt(trials)} trials`;

    body.replaceChildren();
    const frag = document.createDocumentFragment();
    capped.forEach(({ row, idx }) => {
      const [hi, mi, ti, n, sp, stp, cost, wall, tok, noop = 0] = row;
      const tr = document.createElement("tr");

      tr.appendChild(td(String(idx + 1), "d-sub"));

      const hCell = td("", `d-name h--${data.hc[hi] ?? "unknown"}`);
      hCell.textContent = data.hd[hi] ?? data.h[hi] ?? "";
      tr.appendChild(hCell);

      const mCell = td("", `d-model m--${data.mc[mi] ?? "unknown"}`);
      mCell.textContent = data.md[mi] ?? data.m[mi] ?? "";
      tr.appendChild(mCell);

      const tCell = td("", "d-sub");
      const tName = document.createElement("span");
      tName.textContent = data.t[ti] ?? "";
      const tFam = document.createElement("span");
      tFam.className = "bb-explorer__fam";
      tFam.textContent = data.tf[ti] ?? "";
      tCell.append(tName, tFam);
      tr.appendChild(tCell);

      tr.appendChild(td(String(n)));
      tr.appendChild(td(`${sp}/${n} · ${fmtPct(n > 0 ? sp / n : 0)}`, "d-sol"));
      tr.appendChild(td(`${stp}/${n} · ${fmtPct(n > 0 ? stp / n : 0)}`));
      tr.appendChild(td(fmtCost(cost ?? null)));
      tr.appendChild(td(fmtWall(wall ?? null)));
      tr.appendChild(td(fmtTokens(tok ?? null)));

      const flags = td("", "d-sub");
      if (sp > stp) {
        const tag = document.createElement("span");
        tag.className = "tag tag--derived";
        tag.textContent = `t/o-pass ×${sp - stp}`;
        flags.appendChild(tag);
      }
      if (noop > 0) {
        const tag = document.createElement("span");
        tag.className = "tag tag--noop";
        tag.title = "No-op runs ended with no source edits — counted as failures";
        tag.textContent = `${noop}/${n} no-op`;
        flags.appendChild(tag);
      }
      tr.appendChild(flags);

      frag.appendChild(tr);
    });
    body.appendChild(frag);
  };

  const boot = async (): Promise<void> => {
    if (idle) idle.textContent = "Loading cells…";
    const data = await load();
    if (!data) {
      if (idle) {
        idle.textContent =
          "The cell dataset couldn't be loaded — the full stack table below is rendered from the same export.";
      }
      return;
    }
    // Populate filter options once, from the payload's own lookups.
    if (selH.options.length <= 1) {
      data.h.forEach((id, i) => selH.appendChild(option(id, data.hd[i] ?? id)));
      data.m.forEach((id, i) => selM.appendChild(option(id, data.md[i] ?? id)));
      data.fams.forEach((f) => selF.appendChild(option(f, f)));
    }
    if (idle) idle.remove();
    render(data);
    const onChange = (): void => render(data);
    q.addEventListener("input", onChange);
    selH.addEventListener("change", onChange);
    selM.addEventListener("change", onChange);
    selF.addEventListener("change", onChange);
    selV.addEventListener("change", onChange);
    reset.addEventListener("click", () => {
      q.value = "";
      selH.value = "";
      selM.value = "";
      selF.value = "";
      selV.value = "";
      render(data);
    });
  };

  // Lazy trigger: first scroll-into-view OR first interaction with the controls.
  let booted = false;
  const bootOnce = (): void => {
    if (booted) return;
    booted = true;
    void boot();
  };
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          io.disconnect();
          bootOnce();
        }
      },
      { rootMargin: "240px" }
    );
    io.observe(root);
  }
  root.addEventListener("focusin", bootOnce, { once: true });
  root.addEventListener("pointerdown", bootOnce, { once: true });
}

/* ---------- 4 · quality cards + combo rows (tap-to-expand, deep links) ----------

   Non-destructive: toggling flips .is-open on the card and updates
   aria-expanded; CSS owns the height animation. No navigation, no scroll
   repositioning. One delegated listener covers the per-task commentary
   cards ([data-qcard]) and the stack quality leaderboard rows ([data-qlq]).

   Deep links: every quality number on the site points at #qcard-<task> or
   #qlq-<harness>-<model>; on load and on hashchange we expand the target
   in place and scroll it into view. */

function setCardOpen(card: HTMLElement, btn: HTMLButtonElement | null, open: boolean): void {
  card.classList.toggle("is-open", open);
  btn?.setAttribute("aria-expanded", String(open));
}

function initQualityCards(): void {
  document.addEventListener("click", (ev) => {
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>(
      "[data-qcard-toggle], [data-qlq-toggle]"
    );
    if (!btn) return;
    const card = btn.closest<HTMLElement>("[data-qcard], [data-qlq]");
    if (!card) return;
    setCardOpen(card, btn, !card.classList.contains("is-open"));
  });
}

/** Expand + scroll to the card named by location.hash, if any. Returns
    true when the hash named a quality card (so callers can skip other
    hash work). Synthesis anchors (#synth-*) are handled by initSynthesis
    after its fetch lands. */
function openQualityHashTarget(): boolean {
  const hash = window.location.hash.slice(1);
  if (!hash || (!hash.startsWith("qcard-") && !hash.startsWith("qlq-"))) return false;
  const card = document.getElementById(hash);
  if (!card) return false;
  const btn = card.querySelector<HTMLButtonElement>("[data-qcard-toggle], [data-qlq-toggle]");
  setCardOpen(card, btn, true);
  // The browser already scrolled for same-page anchors; scrollIntoView is
  // the cross-page / JS-injected case. block:"start" keeps the head visible
  // under the sticky site header via scroll-margin-top in CSS.
  card.scrollIntoView({ block: "start" });
  return true;
}

/* ---------- 5 · Judge's Synthesis (lazy /data/synthesis.json) ----------

   The synthesis job may still be running, so the payload loads client-side
   with a graceful placeholder on 404/network failure. DOM-built with
   textContent throughout — no innerHTML. Mirrors the SynthesisPayload
   contract in bench.ts. */

interface SynthEntry {
  summary: string;
  observations: string[];
  n_tasks?: number;
  n_models?: number;
  n_harnesses?: number;
}

interface SynthPayload {
  combos: Record<string, SynthEntry>;
  harnesses: Record<string, SynthEntry>;
  models: Record<string, SynthEntry>;
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const e = document.createElement(tag);
  e.className = className;
  if (text != null) e.textContent = text;
  return e;
}

/* Brand logos for synthesis cards — mirrors MODEL_LOGO / HARNESS_LOGO in
   bench.ts (a server module; client scripts can't import it). Unknown ids
   fall back to no image, matching the site's monogram-free client style. */
const HARNESS_LOGO_SRC: Record<string, string> = {
  droid: "/brand/providers/factory.png",
  omp: "/brand/providers/omp.svg",
  pi: "/brand/providers/pi-agent.svg",
  codex: "/brand/providers/codex.png",
  claude: "/brand/providers/claude-code.png",
  "prime-agent": "/brand/providers/prime-intellect.png",
  hermes: "/brand/providers/hermes.png",
  opencode: "/brand/providers/opencode.png"
};
const MODEL_LOGO_SRC: Record<string, string> = {
  "deepseek-v4-flash-0731": "/brand/providers/deepseek.svg",
  "glm-5-2": "/brand/providers/zai.png",
  "gpt-5-6-luna-max": "/brand/providers/openai.png",
  "muse-spark-1-2-contributor": "/brand/providers/meta.svg"
};

function logoImg(src: string | undefined, size = 16): HTMLElement | null {
  if (!src) return null;
  const badge = el("span", "bb-badge bb-badge--sm");
  const img = document.createElement("img");
  img.src = src;
  img.alt = "";
  img.width = size;
  img.height = size;
  img.loading = "lazy";
  img.decoding = "async";
  badge.appendChild(img);
  return badge;
}

function synthCard(
  id: string,
  title: string,
  entry: SynthEntry,
  nLabel: string | null,
  logos: (HTMLElement | null)[]
): HTMLElement {
  const card = el("article", "bb-scard bb-glass");
  card.id = id;

  const head = document.createElement("button");
  head.type = "button";
  head.className = "bb-scard__head";
  head.setAttribute("aria-expanded", "false");
  const titleWrap = el("span", "bb-scard__title");
  for (const logo of logos) if (logo) titleWrap.appendChild(logo);
  titleWrap.appendChild(el("span", "", title));
  head.appendChild(titleWrap);
  const right = el("span", "bb-scard__n");
  if (nLabel) right.appendChild(el("span", "", nLabel));
  right.appendChild(el("span", "bb-scard__chev", "›"));
  head.appendChild(right);

  const body = el("div", "bb-scard__body");
  // Lean syntheses may legitimately return no observations and an empty
  // summary — say so plainly instead of rendering an empty card.
  const summary =
    entry.summary.trim().length > 0
      ? entry.summary
      : entry.observations.length === 0
        ? "No strong, consistent patterns survived the skeptic rounds for this slice."
        : "";
  if (summary) body.appendChild(el("p", "bb-scard__summary", summary));
  if (entry.observations.length > 0) {
    const obs = el("div", "bb-scard__obs");
    const inner = el("div", "bb-scard__obs-inner");
    const list = el("ul", "bb-scard__obs-list");
    for (const o of entry.observations) {
      list.appendChild(el("li", "", o));
    }
    inner.appendChild(list);
    obs.appendChild(inner);
    body.appendChild(obs);
  }

  // Tap anywhere on the head toggles observations open/closed in place.
  head.addEventListener("click", () => {
    const open = card.classList.toggle("is-open");
    head.setAttribute("aria-expanded", String(open));
  });

  card.append(head, body);
  return card;
}

function renderSynthGroup(root: HTMLElement, entries: Record<string, SynthEntry>, kind: "combos" | "harnesses" | "models"): void {
  const frag = document.createDocumentFragment();
  const keys = Object.keys(entries).sort((a, b) => a.localeCompare(b));
  for (const key of keys) {
    const entry = entries[key];
    if (!entry) continue;
    let title = key;
    let nLabel: string | null = null;
    let id = `synth-${kind}-${key}`;
    let logos: (HTMLElement | null)[] = [];
    if (kind === "combos") {
      const [h, m] = key.split("/");
      title = m ? `${h} × ${m}` : key;
      nLabel = entry.n_tasks != null ? `${entry.n_tasks} tasks` : null;
      id = `synth-combo-${h}-${m ?? ""}`;
      logos = [logoImg(HARNESS_LOGO_SRC[h ?? ""]), logoImg(MODEL_LOGO_SRC[m ?? ""])];
    } else if (kind === "harnesses") {
      nLabel = entry.n_models != null ? `${entry.n_models} models` : null;
      id = `synth-harness-${key}`;
      logos = [logoImg(HARNESS_LOGO_SRC[key])];
    } else {
      nLabel = entry.n_harnesses != null ? `${entry.n_harnesses} harnesses` : null;
      id = `synth-model-${key}`;
      logos = [logoImg(MODEL_LOGO_SRC[key])];
    }
    frag.appendChild(synthCard(id, title, entry, nLabel, logos));
  }
  root.replaceChildren(frag);
}

function initSynthesis(): void {
  const root = document.querySelector<HTMLElement>("[data-br-synthesis]");
  if (!root) return;
  const status = root.querySelector<HTMLElement>("[data-br-synthesis-status]");
  const body = root.querySelector<HTMLElement>("[data-br-synthesis-body]");
  const combos = root.querySelector<HTMLElement>("[data-br-synthesis-combos]");
  const harnesses = root.querySelector<HTMLElement>("[data-br-synthesis-harnesses]");
  const models = root.querySelector<HTMLElement>("[data-br-synthesis-models]");
  if (!status || !body || !combos || !harnesses || !models) return;

  let loaded = false;
  let loading: Promise<void> | null = null;

  /** After a render, honor a #synth-* hash: open the named card and scroll
      it into view. Called post-load and on hashchange. */
  const openHashCard = (): void => {
    const hash = window.location.hash.slice(1);
    if (!hash.startsWith("synth-")) return;
    const card = document.getElementById(hash);
    if (!card) return;
    card.classList.add("is-open");
    card.querySelector("button")?.setAttribute("aria-expanded", "true");
    card.scrollIntoView({ block: "start" });
  };

  const load = async (): Promise<void> => {
    let data: SynthPayload | null = null;
    try {
      const res = await fetch("/data/synthesis.json", { cache: "no-store" });
      if (res.ok) data = (await res.json()) as SynthPayload;
    } catch {
      data = null;
    }
    if (
      !data ||
      (Object.keys(data.combos ?? {}).length === 0 &&
        Object.keys(data.harnesses ?? {}).length === 0 &&
        Object.keys(data.models ?? {}).length === 0)
    ) {
      // Keep the "synthesis in progress" placeholder — nothing to show yet.
      return;
    }
    renderSynthGroup(combos, data.combos ?? {}, "combos");
    renderSynthGroup(harnesses, data.harnesses ?? {}, "harnesses");
    renderSynthGroup(models, data.models ?? {}, "models");
    status.hidden = true;
    body.hidden = false;
    loaded = true;
    openHashCard();
  };

  const ensureLoaded = (): void => {
    if (!loaded && !loading) loading = load();
  };

  // A tap on any "synthesis for this combo →" link must trigger the lazy
  // fetch immediately — the anchor target doesn't exist until the render.
  document.addEventListener("click", (ev) => {
    const a = (ev.target as HTMLElement).closest<HTMLAnchorElement>('a[href^="#synth-"]');
    if (!a) return;
    ensureLoaded();
  });

  window.addEventListener("hashchange", () => {
    if (window.location.hash.startsWith("#synth-")) {
      if (loaded) openHashCard();
      else ensureLoaded();
    }
  });

  // Lazy: wait until the section nears the viewport before fetching — but
  // a #synth-* deep link on arrival forces the load immediately.
  if (window.location.hash.startsWith("#synth-")) {
    ensureLoaded();
  } else if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          io.disconnect();
          ensureLoaded();
        }
      },
      { rootMargin: "240px" }
    );
    io.observe(root);
  } else {
    ensureLoaded();
  }
}

/* ---------- boot ---------- */

initMatrix();
initTaskFilter();
initExplorer();
initQualityCards();
initSynthesis();
// Deep links into quality cards land expanded, on arrival and on tap.
openQualityHashTarget();
window.addEventListener("hashchange", openQualityHashTarget);
