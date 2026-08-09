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
    const mode = btn.dataset.mx === "str" ? "str" : "sol";
    tabs.querySelectorAll(".bb-tab").forEach((t) => {
      const active = t === btn;
      t.classList.toggle("is-active", active);
      t.setAttribute("aria-selected", String(active));
    });
    table.querySelectorAll<HTMLElement>(".mx-cell[data-sol]").forEach((cell) => {
      const sol = cell.dataset.sol ?? "";
      const str = cell.dataset.str ?? "";
      const n = cell.dataset.n ?? "";
      const val = cell.querySelector("[data-mx-val]");
      const sub = cell.querySelector("[data-mx-sub]");
      if (val) val.textContent = mode === "str" ? str : sol;
      if (sub) sub.textContent = mode === "str" ? `solution ${sol} · n ${n}` : `strict ${str} · n ${n}`;
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

/** Slim cell row: [harness, model, task, n, solutionPasses, strictPasses, cost, wall, tokens]. */
type CellRow = [
  number,
  number,
  number,
  number,
  number,
  number,
  number | null,
  number | null,
  number | null
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
        const hay = `${data.h[hi] ?? ""} ${data.hd[hi] ?? ""} ${data.m[mi] ?? ""} ${data.md[mi] ?? ""} ${data.t[ti] ?? ""} ${data.tf[ti] ?? ""}`.toLowerCase();
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
      const [hi, mi, ti, n, sp, stp, cost, wall, tok] = row;
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

/* ---------- boot ---------- */

initMatrix();
initTaskFilter();
initExplorer();
