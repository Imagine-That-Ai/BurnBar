---
category: Brand
---

# BrandMark

The BurnBar app mark, framed as a soft app-icon tile that sits elegantly on the paper. Plays the looping brand video when `public/brand/burnbar-mark.mp4` is present, and falls back to the static logo (with a gentle sheen) until then — so the sign-in never shows a broken frame.

```tsx
import { BrandMark } from "@openburnbar/console";

<BrandMark />            {/* 92px default */}
<BrandMark size={120} />
```

- **size** — square size in pixels (default 92). The corner radius scales with it.

Decorative (`aria-hidden`). Expects the brand assets under `/brand/` to be served by the host app.
