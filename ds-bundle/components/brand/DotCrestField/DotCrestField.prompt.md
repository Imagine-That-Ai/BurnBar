DotCrestField from @openburnbar/console. Use via `window.OpenBurnBarConsole.DotCrestField` (bundle loaded from the root `_ds_bundle.js`).

# DotCrestField

The signature ambient background: the BurnBar Cloud crests and the full provider-logo roster rendered as fine, full-colour dot constellations. One logo materialises somewhere on the page, shimmers and breathes, then its dots scatter and dissolve as the next resolves into being — slow, organic, alive. Sits at `z-index: -1`, above the paper and behind content.

```tsx
import { DotCrestField } from "@openburnbar/console";

export default function Layout({ children }) {
  return (
    <body>
      <DotCrestField />
      {children}
    </body>
  );
}
```

Takes no props. Render it once, as a direct child of `<body>` (or a positioned page root). Expects the crest + provider-logo assets under `/brand/` to be served by the host app; it pulls from the same provider roster the native app tracks. Honors `prefers-reduced-motion`.

## Props

```ts
interface DotCrestFieldProps {
/** No props. Ambient full-viewport canvas that drifts the BurnBar crests and provider logos as dot constellations; renders fixed at z-index -1 (behind page content). Expects the brand assets under /brand/ to be served by the host app. */
}
```
