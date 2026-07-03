# Command Deck — Dashboard top-chrome redesign

## Goal

Collapse ~146pt of stacked dashboard chrome (toolbar + tab-card strip) into one ~52pt bar.

## Concept

**Concept E — Command Deck.** Left = current section as a dropdown + ⌘K "jump anywhere" palette. Right = the BURN hero as the visual headline, with the time range folded into it. Navigation moves to a menu + keyboard-first palette.

## Steps

1. **Centralize route metadata** — add `title`, `systemImage`, `accent`, `subtitle` computed properties + `primarySections` static list to `DashboardMainRoute`.
2. **Rewrite toolbar** — single Command Deck bar: section switcher menu + ⌘K hint chip + BURN hero (range/unit in popover) + overflow ⌘ menu. Move Agents/Models toggle to sidebar.
3. **Delete tab strip** — remove `dashboardWorkspaceNavStrip` from `detailView`, delete `DashboardWorkspaceNavStrip.swift`.
4. **⌘1–⌘7 shortcuts** — hidden window-level buttons driving `navigate(to:)`.
5. **⌘K Command Palette** — `CommandDeckPalette` sheet with section fuzzy-filter + session search.
6. **Dead-code cleanup** (separate PR) — delete `DashboardView+Chrome.swift`, `DashboardToolbar.swift`, vestigial `navigationModel`.

## PR breakdown

- **PR 1:** Steps 1–4 (one-bar layout, section menu, hero popover, ⌘1–7)
- **PR 2:** Step 5 (⌘K palette)
- **PR 3:** Step 6 (dead-code deletion, gated on grep)
