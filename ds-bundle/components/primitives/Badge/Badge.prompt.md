Badge from @openburnbar/console. Use via `window.OpenBurnBarConsole.Badge` (bundle loaded from the root `_ds_bundle.js`).

# Badge

A small mono pill. Its `tier` carries an encryption-tier identity through colour; the default `neutral` is a plain grey label.

```tsx
import { Badge } from "@openburnbar/console";

<Badge>Operational</Badge>
<Badge tier="end_to_end">End-to-end</Badge>
<Badge tier="zero_access">Zero-access</Badge>
<Badge tier="server_readable">Server-readable</Badge>
```

## Tiers
- **neutral** (default) — grey, for non-tier labels.
- **server_readable** — ochre.
- **zero_access** — slate.
- **end_to_end** — teal.

Badge content is usually a short word, optionally with a leading 12px Lucide icon (see `TierBadge` for the canonical tier+icon composition). Mono font, tight tracking, pill radius.

## Props

```ts
interface BadgeProps {
/** Encryption-tier identity; selects the colour. `neutral` (default) is a plain grey pill. */
tier?: "server_readable" | "zero_access" | "end_to_end" | "neutral";
/** Badge content — a short label, optionally with a leading icon. */
children?: React.ReactNode;
className?: string;
title?: string;
}
```
