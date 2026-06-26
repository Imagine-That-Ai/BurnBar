"use client";

import * as React from "react";

import { useDashboardUsage } from "@/lib/dashboard/useDashboardUsage";
import type { DashboardRange } from "@/lib/dashboard/types";
import { DashboardToolbar } from "@/components/dashboard/DashboardToolbar";
import { GlassGrid } from "@/components/dashboard/GlassGrid";
import { KernelBackdrop } from "@/components/dashboard/KernelBackdrop";
import { useDashboardController } from "@/components/dashboard/useDashboardController";

export default function DashboardPage() {
  const controller = useDashboardController();
  const [range, setRange] = React.useState<DashboardRange>("7d");
  const { data, source } = useDashboardUsage(range);

  // Expose the frost level to the glass-card CSS for this subtree only.
  const frostStyle = {
    "--lg-frost": String(controller.frost),
  } as React.CSSProperties;

  return (
    <div className="lg-dashboard" style={frostStyle}>
      <KernelBackdrop kernelId={controller.kernelId} />

      <header className="lg-bar mb-token-6 flex flex-col gap-token-3 sm:flex-row sm:items-center">
        <div className="shrink-0">
          <span className="eyebrow">Studio</span>
          <h1 className="font-display text-2xl text-content-bright">Your dashboard</h1>
        </div>
        <div className="min-w-0 flex-1">
          <DashboardToolbar
            range={range}
            setRange={setRange}
            source={source}
            placedIds={controller.placedIds}
            addCard={controller.addCard}
            removeCard={controller.removeCard}
            editable={controller.editable}
            setEditable={controller.setEditable}
            kernelId={controller.kernelId}
            setKernel={controller.setKernel}
            frost={controller.frost}
            setFrost={controller.setFrost}
            reset={controller.reset}
          />
        </div>
      </header>

      <GlassGrid
        items={controller.items}
        editable={controller.editable}
        window={data}
        source={source}
        onCommitRect={controller.updateRect}
        onRemove={controller.removeCard}
      />
    </div>
  );
}
