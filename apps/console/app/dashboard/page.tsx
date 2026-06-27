"use client";

import * as React from "react";

import { useDashboardUsage } from "@/lib/dashboard/useDashboardUsage";
import type { UsageWindowKey } from "@/lib/usage";
import { useBackdrop } from "@/lib/useBackdrop";
import { DashboardToolbar } from "@/components/dashboard/DashboardToolbar";
import { GlassGrid } from "@/components/dashboard/GlassGrid";
import { useDashboardController } from "@/components/dashboard/useDashboardController";

export default function DashboardPage() {
  const controller = useDashboardController();
  const { kernelId, setKernelId } = useBackdrop();
  const [window, setWindow] = React.useState<UsageWindowKey>("30d");
  const { data, loading, error, reload } = useDashboardUsage(window);

  // Expose the frost level to the glass-card CSS for this subtree only.
  const frostStyle = {
    "--lg-frost": String(controller.frost),
  } as React.CSSProperties;

  return (
    <div className="lg-dashboard" style={frostStyle}>
      <header className="lg-bar mb-token-6 flex flex-col gap-token-3 sm:flex-row sm:items-center">
        <div className="shrink-0">
          <span className="eyebrow">Studio</span>
          <h1 className="font-display text-2xl text-content-bright">Your usage</h1>
        </div>
        <div className="min-w-0 flex-1">
          <DashboardToolbar
            window={window}
            setWindow={setWindow}
            source={data.source}
            computedAt={data.computedAt}
            loading={loading}
            onRefresh={() => reload(true)}
            placedIds={controller.placedIds}
            addCard={controller.addCard}
            removeCard={controller.removeCard}
            editable={controller.editable}
            setEditable={controller.setEditable}
            kernelId={kernelId}
            setKernel={setKernelId}
            frost={controller.frost}
            setFrost={controller.setFrost}
            reset={controller.reset}
          />
        </div>
      </header>

      {error && (
        <div
          role="alert"
          className="lg-bar mb-token-4 text-sm"
          style={{ color: "var(--color-seal-crimson)" }}
        >
          {error}
        </div>
      )}
      {!error && !loading && data.source === "empty" && (
        <div className="lg-bar mb-token-4 text-sm text-content-mute">
          No usage has synced from your devices yet — the cards will fill in as the
          BurnBar app reports usage to your account.
        </div>
      )}

      <GlassGrid
        items={controller.items}
        editable={controller.editable}
        data={data}
        onCommitRect={controller.updateRect}
        onRemove={controller.removeCard}
      />
    </div>
  );
}
