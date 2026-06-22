---
category: Primitives
---

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
