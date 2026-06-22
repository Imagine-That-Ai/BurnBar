Card from @openburnbar/console. Use via `window.OpenBurnBarConsole.Card` (bundle loaded from the root `_ds_bundle.js`).

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

## Props

```ts
interface CardProps {
/** Card body. Compose with the compound parts exported from the same module: `CardHeader`, `CardTitle`, `CardDescription`, `CardContent`. */
children?: React.ReactNode;
className?: string;
/** All native `<div>` attributes are also accepted. */
}
```
