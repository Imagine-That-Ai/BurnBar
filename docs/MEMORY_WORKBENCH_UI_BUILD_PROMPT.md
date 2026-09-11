# Memory Workbench & Daily Brief — UI build prompt

**Hand this to the implementing agent verbatim.** It assumes
[`docs/MEMORY_WORKBENCH_AND_DAILY_BRIEF.md`](MEMORY_WORKBENCH_AND_DAILY_BRIEF.md) as the
architecture brief — that document owns *what* to build and the data constraints; this one owns
*how it must look and feel*.

---

## Your mission

Build the Memory Workbench and the Daily Brief as one coherent, beautiful, uniform surface across
macOS, iOS, Android, Windows, Linux, and the web console.

The standard is not "matches the mockup." The standard is **Apple-grade**: every state designed
(not just the happy one), every transition intentional, every pixel on a rhythm, every string
honest, nothing left to the framework's defaults. A member should be able to open this on their Mac
and their phone and feel the same product — not a port.

If you find yourself writing a raw `Color(red:green:blue:)`, a magic `padding(13)`, a spinner with
no empty state behind it, or a destructive button with no confirmation, stop: that is the line
between this and ordinary work.

---

## Read before you write a line

**Architecture and constraints — non-negotiable, read fully:**
1. `docs/MEMORY_WORKBENCH_AND_DAILY_BRIEF.md` — the companion brief. §4 hard constraints and §5.1
   the edit model are binding. In particular: **editing a memory mints a new version and returns it
   to review**; it never mutates in place, and it never silently re-enters prompts.
2. `docs/AI_INBOX.md` and `docs/AI_INBOX_FOUNDER_LENS.md` — the voice, and the item lifecycle the
   Daily Brief lives inside.
3. `OpenBurnBarCore/Sources/OpenBurnBarKernel/Memory/MemoryServing.swift` — the frozen contract you
   render. Note `MemoryReviewStatus` has four states; today's UI shows two.

**Design precedent — study these before designing anything new:**
4. `AgentLens/Views/Dashboard/ProjectMemoryEditorialPrimitives.swift` — `EditorialHero`,
   `HermesReadingCard`, `NumberedSectionRow`, `FootnoteCitationChip`, `CitationQuoteCard`,
   `VisualChart`, `HFlowLayout`. This is the repo's best long-form reading language. **Reuse it.**
   "Editorial" here means magazine-grade layout — that is the bar for the brief and the detail view.
5. `AgentLens/Views/Dashboard/ProjectMemoryWikiPrimitives.swift` — `WikiBreadcrumb`,
   `WikiTableOfContents`, `WikiSeeAlsoRail`, `WikiPivotPillRow`. The only navigate/organize
   vocabulary in the app, currently stranded on a read-only lane. The workbench is where it belongs.
6. `AgentLens/Views/SafariLearning/SafariLearningTimelineView.swift` **on branch
   `fix/quota-multi-account-readiness`** — an unmerged, nearly-complete workbench: standalone window,
   live search, filter chips, an editor sheet with byte counters, versioned optimistic-concurrency
   saves, honest conflict copy that preserves the draft, rollback, delete-profile. **Salvage it
   rather than reinventing it**, and keep its accessibility-identifier scheme (`safariLearning.editor`,
   `.editorTitle`, `.editorContent`, `.search`).
7. `apps/linux-desktop/src/surfaces/memory/MemorySurface.tsx` — the most capable shipped review
   surface (five filters, real forget, audit trail). Its fail-closed guards are worth copying
   verbatim, including refusing to save a memory with no body text.
8. `docs/DASHBOARD_CONTROL_CENTER_REDESIGN.md` — the standing redesign doctrine.

**Then read the design-system inventory addendum** (`MEMORY_WORKBENCH_UI_DESIGN_INVENTORY.md`,
delivered alongside this prompt) for the concrete token names, glass materials, motion curves,
per-platform theme files, and where the platforms currently diverge.

---

## The design bar, concretely

### 1. Tokens or nothing
Every color, type ramp, spacing step, radius, shadow, and duration comes from the design system.
No literals. If a token you need does not exist, add it to the system — do not inline it. The
design-system inventory names the canonical files per platform; consume those, never a sibling copy.

### 2. Design every state
For every surface, ship all of: **empty** (first-run, and "filtered to nothing" — these are
different and deserve different copy), **loading** (skeleton that matches the real layout's
geometry, not a centered spinner), **partial** (some data, some pending), **error** (what failed,
what it means, what the member can do — never a raw error string), **offline / degraded** (the web
console must degrade to metadata-only when the browser has no vault key — say so plainly), and
**locked** (below the entitlement tier; reuse the existing veil pattern rather than hiding the
feature).

### 3. Motion with intent
Transitions explain relationships: a memory expanding to detail should feel like the *same object*
growing, not a new screen appearing. Use the system's existing curves and durations. Every animation
must honor reduced-motion, and a reduced-motion path is a designed path — not "animations off."

### 4. Density and efficiency
This is a workbench, not a feed. Members will have thousands of memories.
- Keyboard-first on desktop: arrow-key traversal, `⌘F` to search, `Space` to preview, `⌘⌫` to
  forget with confirmation, `Esc` to dismiss. Document the full map in the PR.
- Multi-select with shift/cmd ranges, a selection count, and bulk actions that state exactly what
  they will do to how many items.
- Virtualized lists and real pagination. The current inbox fetches 200 rows and calls it a page;
  that is a review queue's shortcut and must not survive into the workbench.
- An inspector/detail split on wide layouts; a push-navigation stack on narrow ones. Same
  information architecture, different affordance.

### 5. Typography and rhythm
Long-form memory bodies and the daily brief are *reading* surfaces. Measure (line length), leading,
and paragraph spacing must be tuned for reading, not for chrome. Follow the editorial primitives.
Numbers in the brief are tabular-figure aligned. Never truncate a memory body to three lines in a
surface whose job is to let someone read and correct it.

### 6. Accessibility is part of "beautiful"
Full VoiceOver/TalkBack/Narrator labels with meaningful traits and ordering. Dynamic Type to the
accessibility sizes without clipping or horizontal scroll. Every interactive element ≥44×44pt on
touch. Contrast verified against the tokens in both light and dark. Focus rings visible and
correctly ordered. Accessibility identifiers on everything testable, following the existing scheme.

### 7. Honest copy, in the Founder Lens voice
`BurnBarFounderLens.swift` carries the voice rules and a 17-entry banned-phrase list — "delve",
"robust", "comprehensive", "it looks like", "you might want to". **The UI copy obeys the same list.**
Blunt, specific, numbers over adjectives. Say what a control does and what it costs:
- destructive actions name the consequence and whether it is reversible;
- an edit says *"Saving creates a new version. The original is kept, superseded, and the new version
  goes back to review."*;
- when a model did not run, say so (the inbox already does this: *"rule-based brief (no model ran)"*);
- when a capability is unavailable on this platform, say **why**, the way the Android inbox card does.

### 8. Uniform, not identical
Uniform means: same information architecture, same vocabulary, same state model, same iconography
and semantics, same copy. It does **not** mean pixel-cloning macOS onto Android. Each platform uses
its own idiom — SwiftUI + the app's glass language on Apple, Material 3 on Android, WinUI styles on
Windows, the Tauri CSS tokens on Linux, the console's existing visual language on web — while a
member moving between them never has to relearn anything. Where a platform genuinely cannot do
something, it says so in the same words everywhere.

---

## What to build

Follow §5.4 and §5.5 of the architecture brief for scope. In priority order:

**A. Workbench — Browse.** Faceted list (source kind, status including *forgotten*, kind, tags,
date range), sort, multi-select, virtualization, real pagination, and a search field that is honest
about which corpus it searches (the brief's §5.3 requires two clearly-labeled scopes — never a
silent blend).

**B. Workbench — Inspect.** Full body, provenance with jump-to-source (the citation resolver and
jump-highlight already work), lineage (revision/merge/split), salience and corroboration rendered
as meaning rather than raw numbers, and the audit trail — which macOS writes today and shows
nowhere.

**C. Workbench — Edit & Compose.** The editor sheet, built on the salvaged blueprint: byte counters,
optimistic concurrency with conflict copy that preserves the draft, and the version consequence
stated in the UI. Compose is a first-class action, not a hidden affordance — today a member cannot
type a memory anywhere in the product.

**D. Workbench — Curate.** Duplicate clusters with merge, contradiction pairs with resolve. Show the
member *why* two memories are proposed as duplicates.

**E. Workbench — Forget.** Per-row, with the receipt made visible, plus bulk. Implement the
`forgotten` state the contract already defines.

**F. Daily Brief.** An editorial reading surface, not a notification dump: what moved, what stalled,
what it cost, what you committed to, the single next move, and a delta against yesterday. Cites
memories and commitments with deep links into the workbench. Shows its own provenance honestly
(which model wrote it, or that none did). One per day, never repeating a resolved item.

**G. The seam.** Memories the brief cited are marked *"used in your brief"* in the workbench;
correcting one from the brief is one click and changes tomorrow's brief.

---

## Definition of done

- Every surface ships all seven states from §2 above, on every platform you touch.
- Zero literal colors/spacings/durations; everything from tokens.
- Keyboard map documented and working on desktop; touch targets and gestures correct on mobile.
- VoiceOver pass recorded (screenshots or a short capture) for Browse, Inspect, and Edit.
- Dynamic Type at the largest accessibility size screenshotted without clipping.
- Light and dark verified on every platform you touch.
- Reduced-motion path verified.
- Copy passes the Founder Lens banned-phrase list — add a lint or test for it if none exists.
- Snapshot/visual tests where the repo already has that tooling; if it has none for your platform,
  attach before/after screenshots in the PR for every surface and every state.
- Accessibility identifiers on all interactive elements, following the existing scheme.
- The PR body carries a **state matrix** (surface × state × platform) with a screenshot per cell you
  built, so a reviewer can see completeness rather than take your word for it.

---

## How to work

- **Study first, then design, then build.** Read the eight references above end to end before
  proposing a layout. Most of this product's vocabulary already exists; your job is to compose it,
  not to invent a dialect.
- **Ship platform by platform, deepest first.** macOS is the authority surface and the richest;
  build it completely, extract the shared view-model, then port. The
  `MemoryReviewInboxModel` → `MemoryReviewInboxModel.cs` port proves the pattern.
- **One PR per coherent surface**, each independently reviewable, each with its state matrix. Do not
  open a single mega-PR.
- **Never invent data.** If a field you want to show does not exist, say so in the PR rather than
  faking a plausible value. The Linux surface already refuses to save a memory with placeholder
  text; hold that line.
- When the architecture brief and a design instinct conflict, the brief wins — and tell the human
  what you wanted to do instead.
