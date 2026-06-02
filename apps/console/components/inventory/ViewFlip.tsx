"use client";

import { AnimatePresence, motion } from "motion/react";
import { cn } from "@/lib/utils";

export type FlipSide = "yours" | "server";

/**
 * The yours <-> server view-flip. "Server" frosts the content (the etched-glass
 * "what the server sees" overlay) and swaps the facet list. Reduced-motion users
 * get an instant crossfade (global CSS zeroes the duration).
 */
export function ViewFlip({
  side,
  yours,
  server,
  className,
}: {
  side: FlipSide;
  yours: React.ReactNode;
  server: React.ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("relative", className)}>
      <AnimatePresence mode="wait" initial={false}>
        <motion.div
          key={side}
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.26, ease: [0.2, 0.8, 0.2, 1] }}
          className={cn(
            "rounded-md p-token-3",
            side === "server" && "frost-overlay",
          )}
        >
          {side === "yours" ? yours : server}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}

export function FlipToggle({
  side,
  onChange,
}: {
  side: FlipSide;
  onChange: (s: FlipSide) => void;
}) {
  return (
    <div className="inline-flex rounded-pill border border-glass-line bg-mercury-wash p-0.5 text-xs">
      {(["yours", "server"] as const).map((s) => (
        <button
          key={s}
          type="button"
          onClick={() => onChange(s)}
          aria-pressed={side === s}
          className={cn(
            "rounded-pill px-token-3 py-1 font-medium transition-colors duration-150 ease-standard",
            side === s
              ? s === "server"
                ? "bg-frost-veil text-content-bright"
                : "bg-brass-core text-ink-void"
              : "text-content-mute hover:text-content-base",
          )}
        >
          {s === "yours" ? "Your view" : "Server view"}
        </button>
      ))}
    </div>
  );
}
