"use client";

import * as React from "react";
import Link from "next/link";

import { KERNEL_META } from "@/lib/gl/engine/registry";
import type { KernelId } from "@/lib/gl/engine/types";
import { useBackdrop } from "@/lib/useBackdrop";
import { KernelTile } from "@/components/experimental/KernelTile";

export default function ExperimentalPage() {
  const { kernelId: selected, setKernelId } = useBackdrop();
  const [toast, setToast] = React.useState<string | null>(null);
  const toastTimer = React.useRef<number | undefined>(undefined);

  const onSelect = React.useCallback(
    (id: KernelId, label: string) => {
      setKernelId(id);
      setToast(label);
      window.clearTimeout(toastTimer.current);
      toastTimer.current = window.setTimeout(() => setToast(null), 4000);
    },
    [setKernelId],
  );

  React.useEffect(() => () => window.clearTimeout(toastTimer.current), []);

  return (
    <div>
      <header className="mb-token-5">
        <span className="eyebrow eyebrow--accent">Experimental</span>
        <h1 className="font-display text-2xl text-content-bright">All kernels</h1>
        <p className="mt-1 max-w-2xl text-sm text-content-mute">
          Every backdrop kernel in the engine, rendering live. Click one and it
          becomes your backdrop on the spot — the gallery's own background is the
          preview, here and everywhere else. {KERNEL_META.length} kernels.
        </p>
      </header>

      <div className="grid grid-cols-1 gap-token-4 sm:grid-cols-2 lg:grid-cols-3">
        {KERNEL_META.map((k) => (
          <KernelTile
            key={k.id}
            id={k.id}
            label={k.label}
            blurb={k.blurb}
            active={selected === k.id}
            onSelect={() => onSelect(k.id, k.label)}
          />
        ))}
      </div>

      {/* Confirmation toast */}
      {toast && (
        <div
          role="status"
          className="glass-pane glass-pane--elevated fixed bottom-6 left-1/2 z-50 flex -translate-x-1/2 items-center gap-token-3 px-token-4 py-token-2 text-sm"
        >
          <span
            className="grid size-5 place-items-center rounded-full text-xs text-white"
            style={{ background: "var(--accent)" }}
            aria-hidden
          >
            ✓
          </span>
          <span className="text-content-base">
            <span className="font-display text-content-bright">{toast}</span> is now your
            backdrop
          </span>
          <Link
            href="/dashboard"
            className="font-medium text-[color:var(--accent-deep)] underline-offset-2 hover:underline"
          >
            View →
          </Link>
        </div>
      )}
    </div>
  );
}
