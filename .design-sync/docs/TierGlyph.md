---
category: Brand
---

# TierGlyph

An encryption-tier crest "formed by the dots" — a 11×11 dot-grid glyph (shield, lock, or eye) lit in the tier's hue, with a slow iridescent sheen sweeping the lit dots. Rendered on a canvas; respects `prefers-reduced-motion` (paints a single static frame).

```tsx
import { TierGlyph } from "@openburnbar/console";

<TierGlyph glyph="shield" colorVar="--color-tier-end-to-end" label="End-to-end" />
<TierGlyph glyph="lock"   colorVar="--color-tier-zero-access" />
<TierGlyph glyph="eye"    colorVar="--color-tier-server-readable" size={48} />
```

## Encryption semantics
- **shield** → end-to-end
- **lock** → zero-access
- **eye** → server-readable

- **glyph** — which crest to draw (required).
- **colorVar** — CSS custom-property name for the lit hue (required), e.g. a `--color-tier-*` token.
- **size** — square canvas size in px (default 34).
- **label** — accessible label (defaults to "<glyph> tier mark").
