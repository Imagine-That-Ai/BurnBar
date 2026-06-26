"use client";

import * as React from "react";

import type { DashboardData } from "@/lib/dashboard/useDashboardUsage";
import { CARD_DEF_BY_ID, isCardId, type CardId } from "./cardRegistry";
import {
  GRID,
  columnWidth,
  nextRow,
  spanHeightPx,
  type GridRect,
} from "./gridMath";
import { GlassGridItem } from "./GlassGridItem";
import type { DashboardLayoutItem } from "./layoutStore";

export interface GlassGridProps {
  items: DashboardLayoutItem[];
  editable: boolean;
  data: DashboardData;
  onCommitRect: (cardId: string, rect: GridRect) => void;
  onRemove: (cardId: string) => void;
}

export function GlassGrid({
  items,
  editable,
  data,
  onCommitRect,
  onRemove,
}: GlassGridProps) {
  const ref = React.useRef<HTMLDivElement>(null);
  const [width, setWidth] = React.useState(0);

  React.useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setWidth(el.clientWidth);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const colW = width > 0 ? columnWidth(width) : 0;
  const rects: GridRect[] = items.map((it) => it.rect);
  const minHeight = rects.length ? spanHeightPx(nextRow(rects)) : GRID.rowHeight * 3;

  return (
    <div ref={ref} className="relative w-full" style={{ minHeight }}>
      {width > 0 &&
        items.map((item) => {
          if (!isCardId(item.cardId)) return null;
          const def = CARD_DEF_BY_ID[item.cardId as CardId];
          const Body = def.component;
          return (
            <GlassGridItem
              key={item.cardId}
              rect={item.rect}
              colW={colW}
              cols={GRID.cols}
              title={def.title}
              icon={def.icon}
              editable={editable}
              onCommit={(rect) => onCommitRect(item.cardId, rect)}
              onRemove={() => onRemove(item.cardId)}
            >
              <Body data={data} />
            </GlassGridItem>
          );
        })}

      {items.length === 0 && (
        <div className="grid h-40 place-items-center rounded-lg border border-dashed border-glass-line text-sm text-content-mute">
          No cards yet — open “Add cards” to build your dashboard.
        </div>
      )}
    </div>
  );
}
