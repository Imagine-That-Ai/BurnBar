"use client";

import * as React from "react";
import { GripVertical, X, type LucideIcon } from "lucide-react";

import {
  GRID,
  clampRect,
  colToPx,
  rowToPx,
  snapPxRect,
  spanHeightPx,
  spanWidthPx,
  type GridRect,
} from "./gridMath";

type GestureMode = "move" | "resize";

interface GestureState {
  mode: GestureMode;
  dx: number;
  dy: number;
}

interface BaseGeometry {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface GlassGridItemProps {
  rect: GridRect;
  colW: number;
  cols: number;
  title: string;
  icon?: LucideIcon;
  editable: boolean;
  onCommit: (rect: GridRect) => void;
  onRemove: () => void;
  children: React.ReactNode;
}

export function GlassGridItem({
  rect,
  colW,
  cols,
  title,
  icon: Icon,
  editable,
  onCommit,
  onRemove,
  children,
}: GlassGridItemProps) {
  const [gesture, setGesture] = React.useState<GestureState | null>(null);
  // Live gesture bookkeeping kept in a ref so window listeners never go stale.
  const tracking = React.useRef<{
    mode: GestureMode;
    startX: number;
    startY: number;
    base: BaseGeometry;
  } | null>(null);

  const base: BaseGeometry = {
    left: colToPx(rect.x, colW),
    top: rowToPx(rect.y),
    width: spanWidthPx(rect.w, colW),
    height: spanHeightPx(rect.h),
  };

  const minWidthPx = spanWidthPx(GRID.minW, colW);
  const minHeightPx = spanHeightPx(GRID.minH);

  // Latest geometry, read at commit time so a mid-gesture container resize
  // doesn't snap against a stale column width.
  const geomRef = React.useRef({ colW, cols });
  geomRef.current = { colW, cols };

  // Teardown of the active gesture's window listeners; called on pointerup,
  // pointercancel, and unmount so a gesture can never leak or get stuck.
  const teardownRef = React.useRef<(() => void) | null>(null);
  React.useEffect(() => () => teardownRef.current?.(), []);

  function beginGesture(mode: GestureMode, e: React.PointerEvent) {
    if (!editable) return;
    e.preventDefault();
    tracking.current = {
      mode,
      startX: e.clientX,
      startY: e.clientY,
      base: { ...base },
    };
    setGesture({ mode, dx: 0, dy: 0 });

    const onMove = (ev: PointerEvent) => {
      const t = tracking.current;
      if (!t) return;
      setGesture({ mode: t.mode, dx: ev.clientX - t.startX, dy: ev.clientY - t.startY });
    };
    const teardown = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("pointercancel", onCancel);
      teardownRef.current = null;
      tracking.current = null;
      setGesture(null);
    };
    const onUp = (ev: PointerEvent) => {
      const t = tracking.current;
      teardown();
      if (!t) return;
      const dx = ev.clientX - t.startX;
      const dy = ev.clientY - t.startY;
      const { colW: cw, cols: cc } = geomRef.current;
      const next =
        t.mode === "move"
          ? snapPxRect(
              { left: t.base.left + dx, top: t.base.top + dy, width: t.base.width, height: t.base.height },
              cw,
              cc,
            )
          : snapPxRect(
              {
                left: t.base.left,
                top: t.base.top,
                width: Math.max(minWidthPx, t.base.width + dx),
                height: Math.max(minHeightPx, t.base.height + dy),
              },
              cw,
              cc,
              GRID.rowHeight,
              GRID.gap,
              "resize",
            );
      onCommit(next);
    };
    // A cancelled gesture (touch interrupt, OS long-press menu, capture loss)
    // never fires pointerup — abort without committing, but still tear down.
    const onCancel = () => teardown();

    teardownRef.current = teardown;
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("pointercancel", onCancel);
  }

  function onHeaderKeyDown(e: React.KeyboardEvent) {
    if (!editable) return;
    const deltas: Record<string, [number, number]> = {
      ArrowLeft: [-1, 0],
      ArrowRight: [1, 0],
      ArrowUp: [0, -1],
      ArrowDown: [0, 1],
    };
    const d = deltas[e.key];
    if (!d) return;
    e.preventDefault();
    const [dx, dy] = d;
    // Plain arrows move; Shift+arrows resize.
    const next: GridRect = e.shiftKey
      ? { ...rect, w: rect.w + dx, h: rect.h + dy }
      : { ...rect, x: rect.x + dx, y: rect.y + dy };
    onCommit(clampRect(next, cols));
  }

  // Apply the live gesture as an offset on the base geometry.
  const visual: BaseGeometry = { ...base };
  if (gesture) {
    if (gesture.mode === "move") {
      visual.left = base.left + gesture.dx;
      visual.top = base.top + gesture.dy;
    } else {
      visual.width = Math.max(minWidthPx, base.width + gesture.dx);
      visual.height = Math.max(minHeightPx, base.height + gesture.dy);
    }
  }

  const dragging = gesture != null;

  return (
    <div
      className="lg-card absolute flex flex-col"
      style={{
        left: visual.left,
        top: visual.top,
        width: visual.width,
        height: visual.height,
        zIndex: dragging ? 30 : 1,
        transition: dragging ? "none" : "left .18s var(--motion-ease-standard), top .18s var(--motion-ease-standard), width .18s var(--motion-ease-standard), height .18s var(--motion-ease-standard)",
        cursor: dragging && gesture?.mode === "move" ? "grabbing" : undefined,
      }}
      data-card-dragging={dragging ? "" : undefined}
    >
      <div className="lg-card__header flex items-center gap-2">
        {editable ? (
          <button
            type="button"
            className="lg-card__grip"
            aria-label={`Move ${title} — arrow keys to move, shift+arrows to resize`}
            onPointerDown={(e) => beginGesture("move", e)}
            onKeyDown={onHeaderKeyDown}
          >
            <GripVertical size={14} aria-hidden />
          </button>
        ) : (
          Icon && <Icon size={14} aria-hidden className="text-content-dim" />
        )}
        <span className="flex-1 truncate font-mono text-[0.66rem] uppercase tracking-[0.14em] text-content-mute">
          {title}
        </span>
        {editable && (
          <button
            type="button"
            className="lg-card__remove"
            aria-label={`Remove ${title}`}
            onPointerDown={(e) => e.stopPropagation()}
            onClick={onRemove}
          >
            <X size={14} aria-hidden />
          </button>
        )}
      </div>

      <div className="min-h-0 flex-1 px-token-4 pb-token-4">{children}</div>

      {editable && (
        // Pointer-only affordance — keyboard users resize via the focusable
        // grip (Shift+Arrows), so this is removed from the tab order and AT tree.
        <button
          type="button"
          aria-hidden
          tabIndex={-1}
          className="lg-card__resize"
          onPointerDown={(e) => beginGesture("resize", e)}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
            <path d="M11 5 L5 11 M11 9 L9 11" stroke="currentColor" strokeWidth="1.2" fill="none" />
          </svg>
        </button>
      )}
    </div>
  );
}
