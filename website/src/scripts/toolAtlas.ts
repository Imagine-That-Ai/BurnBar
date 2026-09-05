/**
 * toolAtlas.ts — the filter over /memory's tool atlas.
 *
 * The atlas ships as twelve native <details> groups, every one of them open,
 * so a reader whose JavaScript is blocked or whose bundle failed still sees
 * all eighty-nine tools. Everything this module adds is an enhancement on
 * top of that: it reveals a filter field, adds a collapse-all control, and
 * hides rows that do not match what you typed.
 *
 * Design notes worth keeping:
 *
 *  - `hidden` rather than a class. `[hidden]` is honoured by assistive
 *    technology and by find-in-page; a `display: none` class is honoured by
 *    neither reliably.
 *  - Filtering re-opens a group that has matches and hides one that has
 *    none, so a query never leaves a match sitting behind a closed summary.
 *  - Results are announced through a polite live region. A count that only
 *    changes visually tells a sighted user what happened and a screen-reader
 *    user nothing.
 *  - The whole thing is guarded: if the section is not on the page, this is
 *    a no-op, so the module is safe to import from any route.
 */

type Row = {
  el: HTMLElement;
  terms: string;
};

type Group = {
  el: HTMLDetailsElement;
  rows: Row[];
  /** Whether the group was open before filtering started. */
  wasOpen: boolean;
};

const normalize = (value: string) => value.toLowerCase().replace(/\s+/g, " ").trim();

export function initToolAtlas(): void {
  const atlas = document.querySelector<HTMLElement>("[data-atlas]");
  if (!atlas) return;

  const input = document.querySelector<HTMLInputElement>("[data-atlas-input]");
  const count = document.querySelector<HTMLElement>("[data-atlas-count]");
  const live = document.querySelector<HTMLElement>("[data-atlas-live]");
  const empty = document.querySelector<HTMLElement>("[data-atlas-empty]");
  const toggleAll = document.querySelector<HTMLButtonElement>("[data-atlas-toggle-all]");

  const groups: Group[] = [...atlas.querySelectorAll<HTMLDetailsElement>("[data-atlas-group]")].map(
    (el) => ({
      el,
      wasOpen: el.open,
      rows: [...el.querySelectorAll<HTMLElement>("[data-atlas-tool]")].map((row) => ({
        el: row,
        // The row's own text already carries the tool name, its description
        // and its capability chips. Reading it once beats maintaining a
        // parallel keyword attribute that can drift from what is rendered.
        terms: normalize(row.textContent ?? "")
      }))
    })
  );

  const total = groups.reduce((n, g) => n + g.rows.length, 0);
  if (total === 0) return;

  const label = (n: number) => `${n} ${n === 1 ? "tool" : "tools"}`;

  const apply = (raw: string) => {
    const query = normalize(raw);
    // Multi-word queries are AND, not phrase: "cloud delete" should find the
    // cloud snapshot delete even though those words are not adjacent.
    const needles = query ? query.split(" ") : [];
    let shown = 0;

    for (const group of groups) {
      let groupShown = 0;
      for (const row of group.rows) {
        const match = needles.every((n) => row.terms.includes(n));
        row.el.hidden = !match;
        if (match) groupShown += 1;
      }
      group.el.hidden = groupShown === 0;
      if (needles.length > 0) {
        // A match must never hide behind a closed summary.
        if (groupShown > 0) group.el.open = true;
      } else {
        group.el.open = group.wasOpen;
      }
      shown += groupShown;
    }

    if (empty) empty.hidden = shown > 0;
    if (count) count.textContent = needles.length ? `${label(shown)} of ${total}` : label(total);
    if (live) {
      live.textContent = needles.length
        ? `${label(shown)} ${shown === 1 ? "matches" : "match"} ${raw.trim()}.`
        : `Filter cleared. ${label(total)}.`;
    }
  };

  if (input) {
    input.hidden = false;
    let frame = 0;
    input.addEventListener("input", () => {
      // One repaint per frame: sixty-three rows is cheap, but typing into a
      // search field should never be the thing that costs a frame.
      if (frame) cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => apply(input.value));
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && input.value !== "") {
        event.preventDefault();
        input.value = "";
        apply("");
      }
    });
  }

  if (toggleAll) {
    toggleAll.hidden = false;
    toggleAll.addEventListener("click", () => {
      const anyOpen = groups.some((g) => g.el.open && !g.el.hidden);
      for (const group of groups) {
        group.el.open = !anyOpen;
        group.wasOpen = !anyOpen;
      }
      toggleAll.textContent = anyOpen ? "Expand all" : "Collapse all";
      if (live) live.textContent = anyOpen ? "All surfaces collapsed." : "All surfaces expanded.";
    });
  }

  // A group the reader opens or closes by hand becomes the state a cleared
  // filter returns to.
  for (const group of groups) {
    group.el.addEventListener("toggle", () => {
      if (!input || input.value === "") group.wasOpen = group.el.open;
    });
  }
}
