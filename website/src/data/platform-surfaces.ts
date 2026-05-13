/**
 * @fileoverview Platform device manifest.
 *
 * Drives `<PlatformShowcase />` and `/platforms`. Each entry describes one
 * surface that has a faithful in-browser device mockup. Adding a new
 * device (Pi pixel screen, Apple TV, etc.) is one entry + one mockup
 * component — the section template stays the same.
 *
 * Joins to `SURFACES` in `surfaces.ts` via `surfaceId` so the device
 * inherits its shipping status, attribution copy, and the full feature
 * bullets without duplicating them here.
 */

import { bySurfaceId, type Surface } from "./surfaces";

export type PlatformMockupComponent = "nest-hub" | "ulanzi-tc001";

export interface PlatformDevice {
  /** Stable slug used in URL hashes and data-attributes. */
  id: "nest-hub" | "ulanzi-tc001" | string;
  /** Operator-facing hardware name. */
  name: string;
  /** Vendor + form factor pill, e.g. "Google · 7\" smart display". */
  formFactor: string;
  /** One-sentence value prop shown beneath the device. */
  blurb: string;
  /** Joins to SURFACES[].id — inherits status + bullets. */
  surfaceId: Surface["id"];
  /** Dispatch key for which mockup component renders the screen. */
  mockup: PlatformMockupComponent;
  /** Physical aspect ratio of the rendered screen, used to size the frame. */
  aspect: { w: number; h: number };
  /** 3 short capability bullets shown below the device. */
  marqueeBullets: string[];
  /** Setup / docs target — internal href or external doc. */
  setupHref: string;
  setupLabel: string;
  /** Optional caption (faithfulness disclosure, mirrors BarMockup). */
  caption?: string;
}

export const PLATFORM_DEVICES: PlatformDevice[] = [
  {
    id: "nest-hub",
    name: "Google Nest Hub",
    formFactor: "Google · 7-inch smart display · Cast V2",
    blurb:
      "BurnBar casts a live provider dashboard to the Nest Hub on your kitchen counter. Refresh, brightness, theme, and provider filter are all controlled from the Mac app.",
    surfaceId: "smart-display",
    mockup: "nest-hub",
    aspect: { w: 16, h: 9 },
    marqueeBullets: [
      "Cast V2 + Home Assistant blueprints — no third-party server",
      "Provider rail, big-total, ambient, photo-blend layouts ship today",
      "Acceptance probe before \"healthy\" — `docs/SMART_DISPLAY_DEVICE_QA.md`",
    ],
    setupHref:
      "https://github.com/Imagine-That-Ai/BurnBar/blob/main/docs/SMART_DISPLAY_DEVICE_QA.md",
    setupLabel: "Smart display QA matrix",
    caption: "Faithful re-render · mirrors NestHubMiniPreview.swift",
  },
  {
    id: "ulanzi-tc001",
    name: "ULANZI TC001",
    formFactor: "Pixel clock · 32×8 LED matrix · AWTRIX HTTP",
    blurb:
      "A faithful 32×8 LED matrix render — same glyph tables, same palette, same per-pixel glow blur the BurnBar daemon paints to AWTRIX firmware.",
    surfaceId: "smart-display",
    mockup: "ulanzi-tc001",
    aspect: { w: 32, h: 8 },
    marqueeBullets: [
      "AWTRIX HTTP — works on stock or community firmware",
      "Four layouts · provider dashboard, quota carousel, burn status, alerts",
      "Ember & whimsy palette by default · five palettes ship",
    ],
    setupHref:
      "https://github.com/Imagine-That-Ai/BurnBar/blob/main/docs/SMART_DISPLAY_DEVICE_QA.md#ulanzi-tc001",
    setupLabel: "ULANZI setup guide",
    caption: "Faithful re-render · mirrors PixelClockPreviewView.swift",
  },
];

/** Convenience accessor — returns undefined if the device id isn't known. */
export function byDeviceId(id: string): PlatformDevice | undefined {
  return PLATFORM_DEVICES.find((d) => d.id === id);
}

/** Returns the full `Surface` row the device inherits from. */
export function surfaceForDevice(device: PlatformDevice): Surface | undefined {
  return bySurfaceId(device.surfaceId);
}
