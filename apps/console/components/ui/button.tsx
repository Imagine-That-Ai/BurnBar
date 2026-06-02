"use client";

import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors duration-150 ease-standard focus-visible:outline-none disabled:pointer-events-none disabled:opacity-50 [&_svg]:size-4 [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        // Brass/amber keys + CTA warmth.
        primary:
          "bg-brass-core text-ink-void font-semibold hover:bg-brass-bright shadow-[0_0_24px_var(--color-brass-glow)]",
        secondary:
          "glass-pane text-content-bright hover:bg-glass-bg-elevated border border-glass-line-bright",
        ghost: "text-content-base hover:bg-mercury-wash hover:text-content-bright",
        // Wax-crimson is DESTRUCTIVE ONLY.
        destructive:
          "bg-transparent text-[color:var(--color-seal-crimson)] border border-[color:var(--color-seal-crimson)] hover:bg-[color:var(--color-seal-crimson)] hover:text-content-bright",
        link: "text-brass-core underline-offset-4 hover:underline",
      },
      size: {
        sm: "h-8 px-3 text-xs",
        md: "h-10 px-4",
        lg: "h-12 px-6 text-base",
        icon: "h-10 w-10",
      },
    },
    defaultVariants: { variant: "primary", size: "md" },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button";
    return (
      <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
    );
  },
);
Button.displayName = "Button";

export { Button, buttonVariants };
