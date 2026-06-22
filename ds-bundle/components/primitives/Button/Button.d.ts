import * as React from 'react';

/**
 * Button — from @openburnbar/console@0.1.0.
 */
export interface ButtonProps {
/** Visual style. `primary` is the single accent (oxblood); `destructive` is for dangerous actions ONLY; `link` renders inline. */
variant?: "primary" | "secondary" | "ghost" | "destructive" | "link";
/** Control height/padding. `icon` is a square icon-only button. */
size?: "sm" | "md" | "lg" | "icon";
/** Render as the single child element (Radix Slot), merging props onto it instead of a `<button>`. */
asChild?: boolean;
children?: React.ReactNode;
className?: string;
/** All native `<button>` attributes are also accepted (onClick, disabled, type, name, aria-*, …). */
disabled?: boolean;
onClick?: React.MouseEventHandler<HTMLButtonElement>;
type?: "button" | "submit" | "reset";
}

export declare const Button: React.ComponentType<ButtonProps>;
