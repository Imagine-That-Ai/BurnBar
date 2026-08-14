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
import { closestFrom, onlyElements } from "./dom.js";

declare global {
  interface Window {
    /** Set by the synthesis section so the print button can await its lazy fetch. */
    __bbSynthesisLoad?: () => Promise<void>;
  }
}
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

/* ---------- 1 · matrix metric toggle + header sorting + highlight search ---------- */

function initMatrix(): void {
  const tabs = document.querySelector<HTMLElement>("[data-br-mxtabs]");
  const table = document.querySelector<HTMLElement>("[data-br-mx]");
  if (!tabs || !table) return;
  const theadRow = table.querySelector<HTMLTableRowElement>("thead tr");
  const tbody = table.querySelector<HTMLElement>("tbody");
  const search = document.querySelector<HTMLInputElement>("[data-br-mxq]");
  let mode: "sol" | "str" | "qual" = "sol";

  const cellScore = (cell: Element): number => {
    if (!(cell instanceof HTMLElement)) return NaN;
    const el = cell;
    const raw =
      mode === "str" ? el.dataset.strnum : mode === "qual" ? el.dataset.qualnum : el.dataset.solnum;
    const v = raw == null || raw === "" ? NaN : Number(raw);
    return v;
  };

  tabs.addEventListener("click", (ev) => {
    const btn = closestFrom(ev.target, "[data-mx]", HTMLButtonElement);
    if (!btn) return;
    mode = btn.dataset.mx === "str" ? "str" : btn.dataset.mx === "qual" ? "qual" : "sol";
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

  /* Header sorting: a model column header ranks harness rows by that
     column's active-metric score; a harness row header ranks model columns
     the same way; the corner cell restores the default (data) order.
     Empty cells sink to the end. */
  if (theadRow && tbody) {
    const defaultRowOrder = [...tbody.querySelectorAll<HTMLElement>("tr[data-mxrow]")];
    const defaultColOrder = [...theadRow.querySelectorAll<HTMLElement>("th[data-mxsort-col]")].map(
      (th) => th.dataset.mxsortCol ?? ""
    );
    let sortCol: string | null = null;
    let sortRow: string | null = null;

    const applyColOrder = (order: string[]): void => {
      const headCells = onlyElements(theadRow.children, HTMLElement);
      const corner = headCells.find((c) => c.hasAttribute("data-mxsort-reset"));
      const byId = new Map(
        headCells.filter((c) => c.dataset.mxsortCol).map((c) => [c.dataset.mxsortCol ?? "", c])
      );
      theadRow.replaceChildren(
        ...(corner ? [corner] : []),
        ...order.map((id) => byId.get(id)).filter((c): c is HTMLElement => c != null)
      );
      for (const tr of tbody.querySelectorAll<HTMLElement>("tr[data-mxrow]")) {
        const rowHead = tr.querySelector<HTMLElement>("th[data-mxsort-row]");
        const cellsByCol = new Map(
          [...tr.querySelectorAll<HTMLElement>("td[data-mxcol]")].map((td) => [
            td.dataset.mxcol ?? "",
            td
          ])
        );
        tr.replaceChildren(
          ...(rowHead ? [rowHead] : []),
          ...order.map((id) => cellsByCol.get(id)).filter((c): c is HTMLElement => c != null)
        );
      }
    };

    const markActive = (): void => {
      table.querySelectorAll<HTMLElement>("[data-mxsort-col]").forEach((th) => {
        const active = th.dataset.mxsortCol === sortCol;
        th.classList.toggle("is-sorted", active);
        th.setAttribute("aria-sort", active ? "descending" : "none");
      });
      table.querySelectorAll<HTMLElement>("[data-mxsort-row]").forEach((th) => {
        const active = th.dataset.mxsortRow === sortRow;
        th.classList.toggle("is-sorted", active);
        th.setAttribute("aria-sort", active ? "descending" : "none");
      });
    };

    const sortByCol = (mid: string): void => {
      sortCol = sortCol === mid ? null : mid;
      sortRow = null;
      const rows = [...tbody.querySelectorAll<HTMLElement>("tr[data-mxrow]")];
      if (sortCol) {
        const score = (tr: HTMLElement): number => {
          const cell = tr.querySelector(`td[data-mxcol="${CSS.escape(sortCol ?? "")}"]`);
          const v = cell ? cellScore(cell) : NaN;
          return Number.isNaN(v) ? -Infinity : v;
        };
        rows.sort((a, b) => score(b) - score(a));
        rows.forEach((tr) => tbody.appendChild(tr));
      } else {
        defaultRowOrder.forEach((tr) => tbody.appendChild(tr));
      }
      markActive();
    };

    const sortByRow = (hid: string): void => {
      sortRow = sortRow === hid ? null : hid;
      sortCol = null;
      if (sortRow) {
        const tr = tbody.querySelector<HTMLElement>(`tr[data-mxrow="${CSS.escape(sortRow)}"]`);
        const scoreOf = (mid: string): number => {
          const cell = tr?.querySelector(`td[data-mxcol="${CSS.escape(mid)}"]`);
          const v = cell ? cellScore(cell) : NaN;
          return Number.isNaN(v) ? -Infinity : v;
        };
        applyColOrder([...defaultColOrder].sort((a, b) => scoreOf(b) - scoreOf(a)));
      } else {
        applyColOrder(defaultColOrder);
      }
      markActive();
    };

    const reset = (): void => {
      sortCol = null;
      sortRow = null;
      defaultRowOrder.forEach((tr) => tbody.appendChild(tr));
      applyColOrder(defaultColOrder);
      markActive();
    };

    table.addEventListener("click", (ev) => {
      const col = closestFrom(ev.target, "[data-mxsort-col]", HTMLElement);
      if (col) {
        sortByCol(col.dataset.mxsortCol ?? "");
        return;
      }
      const rowH = closestFrom(ev.target, "[data-mxsort-row]", HTMLElement);
      if (rowH) {
        sortByRow(rowH.dataset.mxsortRow ?? "");
        return;
      }
      if (closestFrom(ev.target, "[data-mxsort-reset]", HTMLElement)) reset();
    });
    table.addEventListener("keydown", (ev) => {
      if (ev.key !== "Enter" && ev.key !== " ") return;
      const el = closestFrom(
        ev.target,
        "[data-mxsort-col],[data-mxsort-row],[data-mxsort-reset]",
        HTMLElement
      );
      if (!el) return;
      ev.preventDefault();
      el.click();
    });
  }

  /* Highlight search: dims non-matching rows/columns, never hides data. */
  if (search) {
    search.addEventListener("input", () => {
      const q = search.value.trim().toLowerCase();
      const rows = table.querySelectorAll<HTMLElement>("tr[data-mxrow]");
      const cols = table.querySelectorAll<HTMLElement>("th[data-mxsort-col]");
      if (!q) {
        table.classList.remove("mx--filtering");
        rows.forEach((r) => r.classList.remove("mx-dim"));
        cols.forEach((c) => c.classList.remove("mx-dim"));
        table.querySelectorAll("td[data-mxcol]").forEach((c) => c.classList.remove("mx-dim"));
        return;
      }
      table.classList.add("mx--filtering");
      const matchCols = new Set<string>();
      const matchRows = new Set<string>();
      cols.forEach((c) => {
        const name = (c.dataset.mname ?? "").toLowerCase();
        const id = (c.dataset.mxsortCol ?? "").toLowerCase();
        if (name.includes(q) || id.includes(q)) matchCols.add(c.dataset.mxsortCol ?? "");
      });
      rows.forEach((r) => {
        const name = (r.dataset.mxhname ?? "").toLowerCase();
        const id = (r.dataset.mxrow ?? "").toLowerCase();
        if (name.includes(q) || id.includes(q)) matchRows.add(r.dataset.mxrow ?? "");
      });
      rows.forEach((r) => r.classList.toggle("mx-dim", !matchRows.has(r.dataset.mxrow ?? "")));
      cols.forEach((c) => c.classList.toggle("mx-dim", !matchCols.has(c.dataset.mxsortCol ?? "")));
      for (const tr of rows) {
        const rowMatch = matchRows.has(tr.dataset.mxrow ?? "");
        tr.querySelectorAll<HTMLElement>("td[data-mxcol]").forEach((td) => {
          td.classList.toggle("mx-dim", !rowMatch && !matchCols.has(td.dataset.mxcol ?? ""));
        });
      }
    });
  }
}

/* ---------- 2 · task-browser family filter + text search ---------- */

function initTaskFilter(): void {
  const root = document.querySelector<HTMLElement>("[data-br-tasks]");
  if (!root) return;
  const chips = root.querySelector<HTMLElement>(".bb-tasks__chips");
  if (!chips) return;
  const search = root.querySelector<HTMLInputElement>("[data-br-taskq]");
  let fam = "";
  const apply = (): void => {
    const q = (search?.value ?? "").trim().toLowerCase();
    root.querySelectorAll<HTMLElement>(".bb-trow[data-family]").forEach((row) => {
      const famOk = fam === "" || row.dataset.family === fam;
      const qOk = q === "" || row.textContent.toLowerCase().includes(q);
      row.style.display = famOk && qOk ? "" : "none";
    });
  };
  chips.addEventListener("click", (ev) => {
    const btn = closestFrom(ev.target, "[data-fam]", HTMLButtonElement);
    if (!btn) return;
    fam = btn.dataset.fam ?? "";
    chips.querySelectorAll(".bb-chip").forEach((c) => c.classList.toggle("is-active", c === btn));
    apply();
  });
  search?.addEventListener("input", apply);
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
    const payload: CellsPayload = await res.json();
    return payload;
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

  /* Column sorting: click / Enter / Space on a th[data-sort]. Text keys
     start A→Z, numeric keys start high→low; clicking the active column
     flips direction. Sorting happens before the ROW_CAP slice so "top 200"
     is always the top of the SORTED, filtered set. */
  type SortKey = "h" | "m" | "t" | "n" | "sol" | "str" | "cost" | "wall" | "tok";
  const SORT_KEYS: readonly SortKey[] = ["h", "m", "t", "n", "sol", "str", "cost", "wall", "tok"];
  const asSortKey = (value: string | undefined): SortKey | undefined =>
    SORT_KEYS.find((key) => key === value);
  let sortKey: SortKey | null = null;
  let sortDir: 1 | -1 = 1;
  const TEXT_KEYS = new Set<SortKey>(["h", "m", "t"]);
  const cellVal = (data: CellsPayload, row: CellRow, key: SortKey): string | number | null => {
    const [hi, mi, ti, n, sp, stp, cost, wall, tok] = row;
    switch (key) {
      case "h":
        return (data.hd[hi] ?? data.h[hi] ?? "").toLowerCase();
      case "m":
        return (data.md[mi] ?? data.m[mi] ?? "").toLowerCase();
      case "t":
        return (data.t[ti] ?? "").toLowerCase();
      case "n":
        return n;
      case "sol":
        return n > 0 ? sp / n : 0;
      case "str":
        return n > 0 ? stp / n : 0;
      case "cost":
        return cost;
      case "wall":
        return wall;
      case "tok":
        return tok;
    }
  };
  const sortMatches = (data: CellsPayload, matches: { row: CellRow; idx: number }[]): void => {
    if (!sortKey) return;
    const key = sortKey;
    matches.sort((a, b) => {
      const va = cellVal(data, a.row, key);
      const vb = cellVal(data, b.row, key);
      if (va == null && vb == null) return a.idx - b.idx;
      if (va == null) return 1; // nulls sink regardless of direction
      if (vb == null) return -1;
      const c =
        typeof va === "string" && typeof vb === "string"
          ? va.localeCompare(vb)
          : Number(va) - Number(vb);
      return c === 0 ? a.idx - b.idx : c * sortDir;
    });
  };
  const syncSortHeads = (): void => {
    root.querySelectorAll<HTMLElement>("th[data-sort]").forEach((th) => {
      const active = th.dataset.sort === sortKey;
      th.setAttribute("aria-sort", active ? (sortDir === 1 ? "ascending" : "descending") : "none");
      th.classList.toggle("is-sorted", active);
      th.classList.toggle("is-desc", active && sortDir === -1);
    });
  };
  const thead = root.querySelector<HTMLElement>("thead");
  const onSort = (th: HTMLElement): void => {
    const key = asSortKey(th.dataset.sort);
    if (!key) return;
    if (sortKey === key) {
      sortDir = sortDir === 1 ? -1 : 1;
    } else {
      sortKey = key;
      sortDir = TEXT_KEYS.has(key) ? 1 : -1;
    }
    syncSortHeads();
    void load().then((data) => {
      if (data) render(data);
    });
  };
  thead?.addEventListener("click", (ev) => {
    const th = closestFrom(ev.target, "th[data-sort]", HTMLElement);
    if (th) onSort(th);
  });
  thead?.addEventListener("keydown", (ev) => {
    if (ev.key !== "Enter" && ev.key !== " ") return;
    const th = closestFrom(ev.target, "th[data-sort]", HTMLElement);
    if (!th) return;
    ev.preventDefault();
    onSort(th);
  });

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

    sortMatches(data, matches);
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
    const btn = closestFrom(ev.target, "[data-qcard-toggle], [data-qlq-toggle]", HTMLButtonElement);
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

function renderSynthGroup(
  root: HTMLElement,
  entries: Record<string, SynthEntry>,
  kind: "combos" | "harnesses" | "models"
): void {
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
      if (res.ok) {
        const payload: SynthPayload = await res.json();
        data = payload;
      }
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

  // Print preparation (Save as PDF) awaits the synthesis fetch + render.
  window.__bbSynthesisLoad = async () => {
    if (loaded) return;
    if (!loading) loading = load();
    await loading;
  };

  // A tap on any "synthesis for this combo →" link must trigger the lazy
  // fetch immediately — the anchor target doesn't exist until the render.
  document.addEventListener("click", (ev) => {
    const a = closestFrom(ev.target, 'a[href^="#synth-"]', HTMLAnchorElement);
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

/* ---------- 6 · quality-leaderboard search ---------- */

function initQlqFilter(): void {
  const search = document.querySelector<HTMLInputElement>("[data-br-qlq-q]");
  const rows = document.querySelector<HTMLElement>("[data-br-qlq]");
  if (!search || !rows) return;
  search.addEventListener("input", () => {
    const q = search.value.trim().toLowerCase();
    rows.querySelectorAll<HTMLElement>("[data-qlq]").forEach((row) => {
      const show = q === "" || row.textContent.toLowerCase().includes(q);
      row.style.display = show ? "" : "none";
    });
  });
}

/* ---------- 7 · print / PDF ---------- */

function initPrint(): void {
  const buttons = document.querySelectorAll<HTMLButtonElement>("[data-print-report]");
  if (buttons.length === 0) return;
  const prepareAndPrint = async (): Promise<void> => {
    // Print CSS force-expands every collapsible; here we only need the lazy
    // synthesis section rendered before the snapshot.
    const loader = window.__bbSynthesisLoad;
    if (loader) await loader();
    window.print();
  };
  buttons.forEach((btn) =>
    btn.addEventListener("click", () => {
      void prepareAndPrint();
    })
  );
}

/* ---------- boot ---------- */

initMatrix();
initTaskFilter();
initExplorer();
initQualityCards();
initSynthesis();
initQlqFilter();
initPrint();
// Deep links into quality cards land expanded, on arrival and on tap.
openQualityHashTarget();
window.addEventListener("hashchange", openQualityHashTarget);
