TierGlyph from @openburnbar/console. Use via `window.OpenBurnBarConsole.TierGlyph` (bundle loaded from the root `_ds_bundle.js`).

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

## Props

```ts
interface TierGlyphProps {
/** Which encryption crest to draw: shield (end-to-end), lock (zero-access), or eye (server-readable). */
glyph: "shield" | "lock" | "eye";
/** CSS custom-property name the glyph is lit in, e.g. "--color-tier-end-to-end". */
colorVar: string;
/** Square canvas size in pixels (default 34). */
size?: number;
/** Accessible label (defaults to "<glyph> tier mark"). */
label?: string;
}
```
