import * as React from "react";
import { cn } from "@/lib/utils";

interface ProgressProps extends React.HTMLAttributes<HTMLDivElement> {
  value: number; // 0..1
  /** Tier token color the fill should use. */
  fillVar?: string;
}

/** A quota meter. Over-quota (>1) clamps the bar and tints it crimson. */
export function Progress({ value, fillVar = "--color-brass-core", className, ...props }: ProgressProps) {
  const pct = Math.max(0, Math.min(1, value));
  const over = value > 1;
  return (
    <div
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(pct * 100)}
      className={cn("h-2 w-full overflow-hidden rounded-pill bg-mercury-wash", className)}
      {...props}
    >
      <div
        className="h-full rounded-pill transition-[width] duration-500 ease-standard"
        style={{
          width: `${pct * 100}%`,
          background: over ? "var(--color-seal-crimson)" : `var(${fillVar})`,
        }}
      />
    </div>
  );
}
