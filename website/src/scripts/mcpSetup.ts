/**
 * mcpSetup — the shared behaviour behind every MCP setup surface on this
 * site (`/memory` and `/mcp`). One module, so a keyboard or screen-reader
 * fix lands on both pages instead of on whichever one was edited last.
 *
 * It is entirely attribute-driven, which is what lets two pages with
 * completely different visual languages share it:
 *
 *   [data-tabs]           a tablist + its panels
 *     [role="tab"][data-target]      → the tab
 *     [role="tabpanel"][data-panel]  → the panel it controls
 *   [data-code]           a copyable block
 *     pre code                       → the text that gets copied
 *     [data-copy]                    → the button ([data-copy-label] names it)
 *   [data-copy-live]      the page's polite live region (optional)
 *   [data-verify]         a persisted checklist
 *     [data-verify-item]             → one checkbox, keyed by its value
 *     [data-verify-progress]         → where the count is written
 *
 * Three deliberate contracts:
 *
 *   1. Tabs follow the WAI-ARIA roving-tabindex pattern: exactly one tab in
 *      the page tab order, arrows and Home/End to move, and the panel is
 *      focusable so the next Tab lands on the config rather than skipping
 *      past it. The site's previous implementation left every tab tabbable
 *      and had no Home/End, which is a real keyboard cost on an eight-tab
 *      row.
 *   2. Copy announces. A label that flashes "copied" tells a sighted user
 *      what happened and tells a screen-reader user nothing, so the result —
 *      including the failure, which is common on locked-down profiles — goes
 *      through a polite live region.
 *   3. The checklist is progressive. The checkboxes are real inputs that
 *      work with this module absent; it only adds persistence and the count.
 *
 * Everything is scoped and null-guarded: a missing node is never allowed to
 * become a console error on someone's first visit.
 */

const STORAGE_KEY = "burnbar-memory-verify";

function announce(message: string): void {
  const live = document.querySelector<HTMLElement>("[data-copy-live]");
  if (!live) return;
  // Re-setting identical text does not re-announce in some engines; clearing
  // first makes a repeat copy of the same block speak every time.
  live.textContent = "";
  window.setTimeout(() => {
    live.textContent = message;
  }, 40);
}

function initTabs(): void {
  document.querySelectorAll<HTMLElement>("[data-tabs]").forEach((group) => {
    const tabs = Array.from(group.querySelectorAll<HTMLButtonElement>('[role="tab"]'));
    const panels = Array.from(group.querySelectorAll<HTMLElement>('[role="tabpanel"]'));
    if (tabs.length === 0 || panels.length === 0) return;

    // Establish the roving tabindex from whatever the server rendered, so a
    // page that forgot the attribute still gets the right keyboard contract.
    tabs.forEach((tab) => {
      tab.tabIndex = tab.getAttribute("aria-selected") === "true" ? 0 : -1;
    });

    const select = (tab: HTMLButtonElement, moveFocus: boolean): void => {
      const target = tab.dataset.target;
      tabs.forEach((candidate) => {
        const active = candidate === tab;
        candidate.setAttribute("aria-selected", active ? "true" : "false");
        candidate.tabIndex = active ? 0 : -1;
      });
      panels.forEach((panel) => {
        if (panel.dataset.panel === target) panel.removeAttribute("hidden");
        else panel.setAttribute("hidden", "");
      });
      if (moveFocus) tab.focus();
    };

    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => select(tab, false));
      tab.addEventListener("keydown", (event: KeyboardEvent) => {
        let next = -1;
        if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
        else if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
        else if (event.key === "Home") next = 0;
        else if (event.key === "End") next = tabs.length - 1;
        if (next < 0) return;
        const target = tabs[next];
        if (!target) return;
        event.preventDefault();
        select(target, true);
      });
    });
  });
}

function initCopy(): void {
  document.querySelectorAll<HTMLButtonElement>("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const block = button.closest<HTMLElement>("[data-code]");
      const code = block?.querySelector("pre code");
      const text = code?.textContent ?? "";
      const label = button.dataset.copyLabel ?? "snippet";
      if (!text) return;

      const restore = (message: string, ok: boolean): void => {
        const original = button.textContent;
        button.textContent = message;
        if (ok) button.setAttribute("data-flash", "true");
        window.setTimeout(() => {
          button.textContent = original;
          button.removeAttribute("data-flash");
        }, 1600);
      };

      try {
        await navigator.clipboard.writeText(text);
        restore("copied", true);
        announce(`Copied the ${label} to your clipboard.`);
      } catch {
        // Clipboard access is denied in a surprising number of real setups —
        // insecure origins, locked-down enterprise profiles, some in-app
        // browsers. Say what to do instead of failing silently.
        restore("select it", false);
        announce(`Could not reach the clipboard. Select the ${label} and copy it manually.`);
      }
    });
  });
}

function initChecklist(): void {
  const list = document.querySelector<HTMLElement>("[data-verify]");
  const progress = document.querySelector<HTMLElement>("[data-verify-progress]");
  if (!list) return;

  const boxes = Array.from(list.querySelectorAll<HTMLInputElement>("[data-verify-item]"));
  if (boxes.length === 0) return;

  const read = (): string[] => {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      const parsed: unknown = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === "string") : [];
    } catch {
      // Private mode, blocked storage, a corrupted value — an empty checklist
      // is the correct fallback, never an exception on a marketing page.
      return [];
    }
  };

  const write = (ids: string[]): void => {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(ids));
    } catch {
      /* nothing to do: progress simply will not persist */
    }
  };

  const paint = (): void => {
    const done = boxes.filter((box) => box.checked).length;
    if (progress) {
      progress.textContent =
        done === boxes.length
          ? `All ${boxes.length} confirmed — it is working.`
          : `${done} of ${boxes.length} confirmed`;
    }
  };

  const saved = read();
  boxes.forEach((box) => {
    const id = box.dataset.verifyItem;
    if (id && saved.includes(id)) box.checked = true;
    box.addEventListener("change", () => {
      write(
        boxes
          .filter((candidate) => candidate.checked)
          .map((candidate) => candidate.dataset.verifyItem ?? "")
          .filter(Boolean)
      );
      paint();
    });
  });
  paint();
}

export function initMcpSetup(): void {
  if (typeof document === "undefined") return;
  initTabs();
  initCopy();
  initChecklist();
}
