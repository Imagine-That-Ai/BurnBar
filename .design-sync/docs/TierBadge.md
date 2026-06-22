---
category: Brand
---

# TierBadge

The canonical encryption-tier badge: a `Badge` composed with the tier's Lucide icon (eye / shield / lock) and its member-facing copy, driven entirely by the `tier` prop. Use this instead of hand-composing `Badge` when you want the standard tier presentation.

```tsx
import { TierBadge } from "@openburnbar/console";

<TierBadge tier="end_to_end" />      {/* lock · "Only your devices" */}
<TierBadge tier="zero_access" />     {/* shield · "Encrypted at rest" */}
<TierBadge tier="server_readable" /> {/* eye · "Operational" */}
```

- **tier** — `"server_readable" | "zero_access" | "end_to_end"` (required). Selects the icon, colour, copy, and the "who can read this" promise (surfaced as the badge `title`).

Builds on `Badge` + the canonical `TIER_META` registry, so copy never drifts from the data-domain source of truth.
