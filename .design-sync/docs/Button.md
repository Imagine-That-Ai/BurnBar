---
category: Primitives
---

# Button

The single, restrained editorial button. One accent (oxblood/coral) carries the primary action; wax-crimson is reserved exclusively for destructive actions.

```tsx
import { Button } from "@openburnbar/console";

<Button variant="primary">Save changes</Button>
<Button variant="secondary">Cancel</Button>
<Button variant="ghost" size="sm">Dismiss</Button>
<Button variant="destructive">Delete domain</Button>
<Button variant="link">Learn more</Button>
```

## Variants
- **primary** (default) — the accent action. Use one per view.
- **secondary** — hairline outline, for the lesser action beside a primary.
- **ghost** — bare, for low-emphasis or toolbar actions.
- **destructive** — crimson outline that fills on hover. Dangerous actions only.
- **link** — inline text link.

## Sizes
`sm`, `md` (default), `lg`, `icon` (square, for icon-only buttons). Lucide icons inside a button are auto-sized to 1rem.

Set `asChild` to project the button styling onto a custom element (e.g. an `<a>` or `Link`).
