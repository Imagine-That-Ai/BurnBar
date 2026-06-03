import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex items-center gap-1.5 rounded-pill border px-2.5 py-0.5 text-xs font-medium font-mono tracking-tight",
  {
    variants: {
      tier: {
        server_readable:
          "border-[color:var(--color-tier-server-readable)]/40 text-[color:var(--color-tier-server-readable)] bg-[color:var(--color-tier-server-readable)]/10",
        zero_access:
          "border-[color:var(--color-tier-zero-access)]/40 text-[color:var(--color-tier-zero-access)] bg-[color:var(--color-tier-zero-access)]/10",
        end_to_end:
          "border-[color:var(--color-tier-end-to-end)]/40 text-[color:var(--color-tier-end-to-end)] bg-[color:var(--color-tier-end-to-end)]/10",
        neutral: "border-glass-line text-content-mute bg-mercury-wash",
      },
    },
    defaultVariants: { tier: "neutral" },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

export function Badge({ className, tier, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ tier }), className)} {...props} />;
}
