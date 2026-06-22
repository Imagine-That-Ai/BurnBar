---
category: Primitives
---

# Progress

A slim quota meter. `value` is a fraction (0..1). Over-quota values (> 1) clamp the bar to full and tint it crimson as a warning.

```tsx
import { Progress } from "@openburnbar/console";

<Progress value={0.4} />
<Progress value={0.85} />
<Progress value={1.2} />            {/* over quota → crimson */}
<Progress value={0.6} fillVar="--color-tier-end-to-end" />
```

- **value** — fill fraction, 0..1 (clamped). `> 1` renders full + crimson.
- **fillVar** — CSS custom-property name for the fill (default `--color-brass-core`, the accent). Pass a tier token to colour the bar by tier.

2px tall, pill radius, washed track. The fill animates its width.
