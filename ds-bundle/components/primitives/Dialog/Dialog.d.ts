import * as React from 'react';

/**
 * Dialog — from @openburnbar/console@0.1.0.
 */
export interface DialogProps {
/** Controlled open state. Omit for uncontrolled (use `defaultOpen`). */
open?: boolean;
defaultOpen?: boolean;
onOpenChange?: (open: boolean) => void;
/** When true (default), interaction outside the content is blocked. */
modal?: boolean;
/** Compose with `DialogTrigger`, `DialogContent`, `DialogHeader`, `DialogTitle`, `DialogDescription`, `DialogFooter`, `DialogClose` (all exported from the same module). */
children?: React.ReactNode;
}

export declare const Dialog: React.ComponentType<DialogProps>;
