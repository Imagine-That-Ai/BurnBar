---
category: Primitives
---

# Card

The paper panel — a hairline border and the faintest lift on raised paper. The surface for grouped content in the console.

```tsx
import {
  Card, CardHeader, CardTitle, CardDescription, CardContent,
} from "@openburnbar/console";

<Card>
  <CardHeader>
    <CardTitle>Pensieve</CardTitle>
    <CardDescription>Your connected repositories and recall sources.</CardDescription>
  </CardHeader>
  <CardContent>
    {/* … */}
  </CardContent>
</Card>
```

## Compound parts (same module)
- **CardHeader** — vertical stack with tight gap.
- **CardTitle** — display-font heading (`<h3>`).
- **CardDescription** — muted body copy (`<p>`).
- **CardContent** — body region with top padding.

Compose them; `Card` itself is just the panel. All accept `className` and native `<div>` attributes.
