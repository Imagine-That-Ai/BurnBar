import type { BoundingBox, ViewportInfo } from '../shared/protocol';

function finite(value: number): number {
  return Number.isFinite(value) ? value : 0;
}

export function roundCoordinate(value: number): number {
  return Math.round(finite(value) * 100) / 100;
}

export function rectToBoundingBox(
  rect: Pick<DOMRect, 'left' | 'top' | 'width' | 'height'>,
  visualViewport: Pick<VisualViewport, 'offsetLeft' | 'offsetTop'> | null = window.visualViewport
): BoundingBox {
  return {
    x: roundCoordinate(rect.left + (visualViewport?.offsetLeft ?? 0)),
    y: roundCoordinate(rect.top + (visualViewport?.offsetTop ?? 0)),
    width: roundCoordinate(Math.max(0, rect.width)),
    height: roundCoordinate(Math.max(0, rect.height))
  };
}

export function boxAnnotation(box: BoundingBox): string {
  return `[box=${box.x},${box.y},${box.width},${box.height}]`;
}

export function isBoxInViewport(box: BoundingBox, viewport: Pick<ViewportInfo, 'width' | 'height'>): boolean {
  return (
    box.width > 0 &&
    box.height > 0 &&
    box.x < viewport.width &&
    box.y < viewport.height &&
    box.x + box.width > 0 &&
    box.y + box.height > 0
  );
}

export function cssPixelsToDevicePixels(value: number, devicePixelRatio: number): number {
  return roundCoordinate(value * Math.max(0.1, finite(devicePixelRatio)));
}

export function viewportInfo(documentValue: Document = document, windowValue: Window = window): ViewportInfo {
  const root = documentValue.documentElement;
  const body = documentValue.body;
  const visual = windowValue.visualViewport;
  return {
    width: roundCoordinate(visual?.width ?? windowValue.innerWidth ?? root.clientWidth),
    height: roundCoordinate(visual?.height ?? windowValue.innerHeight ?? root.clientHeight),
    scrollX: roundCoordinate(windowValue.scrollX),
    scrollY: roundCoordinate(windowValue.scrollY),
    pageWidth: Math.max(root.scrollWidth, root.clientWidth, body?.scrollWidth ?? 0, body?.clientWidth ?? 0),
    pageHeight: Math.max(root.scrollHeight, root.clientHeight, body?.scrollHeight ?? 0, body?.clientHeight ?? 0),
    devicePixelRatio: roundCoordinate(windowValue.devicePixelRatio || 1),
    visualViewportOffsetLeft: roundCoordinate(visual?.offsetLeft ?? 0),
    visualViewportOffsetTop: roundCoordinate(visual?.offsetTop ?? 0),
    visualViewportScale: roundCoordinate(visual?.scale ?? 1)
  };
}
