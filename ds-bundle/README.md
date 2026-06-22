# OpenBurnBar Console — design system

The member **Data & Privacy Control Center** UI (`app.burnbar.ai`). Aesthetic: **"Quiet Editorial"** — a light, paper-bright surface. Near-black ink on warm paper, **one** restrained accent (oxblood/coral), big grotesk display headings, mono figures, hairlines, generous whitespace. No glow, no gradient, no glass. Built on React 19 + Radix + `class-variance-authority`. Components are exported from `window.OpenBurnBarConsole.*`.

## Setup — no provider, just the stylesheet
There is **no theme provider to wrap**. The design language is delivered entirely through CSS custom properties (the "Pensieve" tokens + the editorial overrides) in the bound **`styles.css`** (which imports `_ds_bundle.css`). As long as that stylesheet is loaded, every component is styled and the `var(--*)` tokens below resolve. The page is **light** (`color-scheme: light`); the canvas is `var(--color-ink-void)`. Brand fonts (Bricolage Grotesque, Geist, Geist Mono, Newsreader) load from Google Fonts via an `@import` already in the closure.

## Styling idiom — token-first
This is a **token-driven** system, not a utility-class framework. To style your own layout glue, reach for the **components first**, then the **`var(--*)` tokens** directly. A curated subset of Tailwind utilities mapped to these tokens also ships (e.g. `text-content-mute`, `bg-mercury-wash`, `border-glass-line`, `rounded-pill`, `rounded-lg`, `font-display`, `font-mono`, `p-token-6`, `gap-token-4`) — but the **complete, reliable** surface is the components + the tokens; do not assume an arbitrary Tailwind class exists in the bundle.

**Token families** (all defined in the closure — use via `var(--name)`):
- **Paper / ink:** `--color-ink-void` (the page), `--color-ink-base` (recessed), `--color-ink-elevated` (raised paper).
- **Text:** `--color-text-bright` (headings), `--color-text-base` (body), `--color-text-mute` (secondary), `--color-text-dim` (labels).
- **Accent — the single oxblood:** `--accent`, `--accent-deep`, `--accent-wash`. (`--color-brass-*` alias the accent.)
- **Hairlines / tints:** `--color-glass-line`, `--color-glass-line-bright`, `--color-mercury-wash`.
- **Encryption tiers:** `--color-tier-end-to-end` (teal), `--color-tier-zero-access` (slate), `--color-tier-server-readable` (ochre).
- **Destructive:** `--color-seal-crimson` (crimson is **destructive-only** — never decorative).
- **Type:** `--font-display`, `--font-body`, `--font-mono`, `--font-serif`. **Radii:** `--radius-sm|md|lg|pill`. **Spacing:** `--space-1|2|3|4|6|8|12`.

**Helper classes that ship** (prefer the components, but these exist): `glass-pane` / `glass-pane--elevated` (the paper panel — what `Card` uses), `eyebrow` (mono uppercase kicker), `epigraph` (serif aside), `rule` (hairline). The `btn-*` classes back `Button`; use `<Button>` instead.

## Where the truth lives
Read the bound **`styles.css` → `_ds_bundle.css`** for the exact tokens and component CSS, and each component's **`.prompt.md`** for its API + usage. Encryption-tier copy comes from the canonical registry — use `TierBadge`/`TierGlyph` rather than hand-coloring.

## Idiomatic example
```tsx
import { Card, CardHeader, CardTitle, CardDescription, CardContent,
         TierBadge, Button } from "window.OpenBurnBarConsole";

<Card style={{ maxWidth: 420 }}>
  <CardHeader>
    <span className="eyebrow">Privacy footprint</span>
    <CardTitle>Messages</CardTitle>
    <CardDescription>End-to-end encrypted; only your devices can read this.</CardDescription>
  </CardHeader>
  <CardContent>
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between",
                  gap: "var(--space-4)", marginTop: "var(--space-2)" }}>
      <TierBadge tier="end_to_end" />
      <Button variant="secondary" size="sm">Manage</Button>
    </div>
  </CardContent>
</Card>
```
Style custom glue with the tokens (`var(--space-*)`, `var(--color-text-mute)`, `var(--color-glass-line)`); let the components carry the rest.

# OpenBurnBarConsole (@openburnbar/console@0.1.0)

This design system is the published @openburnbar/console React library, bundled as a single
browser global. All 9 components are the real upstream code.

## Where things are

- `_ds_bundle.js` — the whole-DS bundle at the project root; loads every component to `window.OpenBurnBarConsole`. First line is a `/* @ds-bundle: … */` metadata header.
- `styles.css` — the single stylesheet entry: it `@import`s the tokens, fonts, and component styles (`_ds_bundle.css`). Link this one file.
- `components/<group>/<Name>/<Name>.prompt.md` (example JSX + variants), `<Name>.d.ts` (types), `<Name>.html` (variant grid).
- `tokens/*.css` — CSS custom properties, names verbatim from upstream.
- `fonts/` — `@font-face` files + `fonts.css` (when the package ships fonts).

For a specific component, `read_file("components/<group>/<Name>/<Name>.prompt.md")`.

## Loading

Add these two lines to your page once (React must be on the page first):

```html
<link rel="stylesheet" href="styles.css">
<script src="_ds_bundle.js"></script>
```

Components are then available at `window.OpenBurnBarConsole.*`. Mount into a dedicated child node (e.g. `<div id="ds-root">`), not the host page's own React root, so the two trees don't collide:

```jsx
const { Badge } = window.OpenBurnBarConsole;
ReactDOM.createRoot(document.getElementById('ds-root')).render(<Badge />);
```

## Tokens

115 CSS custom properties from @openburnbar/console. Names are
preserved verbatim from upstream. They are declared inside `_ds_bundle.css` (this DS ships one compiled stylesheet rather than separate token files).

- **color** (32): `--color-ink-void`, `--color-ink-base`, `--color-ink-elevated`, …
- **spacing** (9): `--space-1`, `--space-2`, `--space-3`, …
- **typography** (5): `--font-display`, `--font-body`, `--font-mono`, …
- **radius** (4): `--radius-sm`, `--radius-md`, `--radius-lg`, …
- **shadow** (4): `--tw-ring-offset-shadow`, `--tw-ring-shadow`, `--tw-shadow`, …
- **other** (61): `--motion-swirl-seconds`, `--motion-frost-flip-ms`, `--motion-ease-standard`, …

## Components

### primitives
- `Badge`
- `Button`
- `Card`
- `Dialog`
- `Progress`

### brand
- `BrandMark`
- `DotCrestField`
- `TierBadge`
- `TierGlyph`
