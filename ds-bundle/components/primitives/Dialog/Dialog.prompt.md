Dialog from @openburnbar/console. Use via `window.OpenBurnBarConsole.Dialog` (bundle loaded from the root `_ds_bundle.js`).

# Dialog

A centered modal on elevated vellum, built on Radix Dialog. Includes a built-in close affordance and a blurred overlay.

```tsx
import {
  Dialog, DialogTrigger, DialogContent, DialogHeader,
  DialogTitle, DialogDescription, DialogFooter, Button,
} from "@openburnbar/console";

<Dialog>
  <DialogTrigger asChild>
    <Button variant="secondary">Connect repository</Button>
  </DialogTrigger>
  <DialogContent>
    <DialogHeader>
      <DialogTitle>Connect a repository</DialogTitle>
      <DialogDescription>Grant Pensieve read access to index your code.</DialogDescription>
    </DialogHeader>
    <DialogFooter>
      <Button variant="ghost">Cancel</Button>
      <Button variant="primary">Authorize</Button>
    </DialogFooter>
  </DialogContent>
</Dialog>
```

## Compound parts (same module)
`DialogTrigger`, `DialogContent`, `DialogHeader`, `DialogTitle`, `DialogDescription`, `DialogFooter`, `DialogClose`.

`Dialog` is the Radix root: control it with `open` / `onOpenChange`, or leave it uncontrolled with `defaultOpen`. `DialogContent` renders into a portal with the overlay + close button supplied for you.

## Props

```ts
interface DialogProps {
/** Controlled open state. Omit for uncontrolled (use `defaultOpen`). */
open?: boolean;
defaultOpen?: boolean;
onOpenChange?: (open: boolean) => void;
/** When true (default), interaction outside the content is blocked. */
modal?: boolean;
/** Compose with `DialogTrigger`, `DialogContent`, `DialogHeader`, `DialogTitle`, `DialogDescription`, `DialogFooter`, `DialogClose` (all exported from the same module). */
children?: React.ReactNode;
}
```
